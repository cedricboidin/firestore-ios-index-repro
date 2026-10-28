# Firestore iOS: stale cache index entries make limited queries return too few documents

Minimal reproduction on the official `firebase-ios-sdk` **12.19.0** (Swift Package
Manager), against the Firestore emulator. No Firebase project needed.

## Symptom

With a client-side cache index (explicit, or created by
`enablePersistentCacheIndexAutoCreation`), a query
`where(group == "g").order(by: "ts", descending: true).limit(to: 5)` returns
**2 documents instead of 5**, from the cache *and* from a re-opened snapshot
listener once it is in sync with the server. Android is not affected.

```
cache, no limit: 10 documents, top 5 = ["hot-b", "hot-a", "static-7", "static-6", "static-5"]
cache, limit 5: 2 documents = ["hot-b", "hot-a"]
re-listen, limit 5: 2 documents, fromCache=true = ["hot-b", "hot-a"]
re-listen, limit 5: 2 documents, fromCache=false = ["hot-b", "hot-a"]
```

## Run it

```bash
brew install xcodegen                       # only to regenerate the project
firebase emulators:start --only firestore --project demo-repro   # port 8399, see firebase.json
xcodegen generate                           # FirestoreIndexRepro.xcodeproj
open FirestoreIndexRepro.xcodeproj          # run on any iOS simulator, tap "Run"
```

Or headless, on a booted simulator:

```bash
xcodebuild -project FirestoreIndexRepro.xcodeproj -scheme FirestoreIndexRepro \
  -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath build build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/FirestoreIndexRepro.app
xcrun simctl launch --console-pty booted dev.repro.firestoreindex -autorun | grep '\[repro\]'
```

A run takes about two minutes. `-firestoreDebugLogs` turns on the SDK's debug
logs. `FIRESTORE_EMULATOR_HOST` overrides `127.0.0.1:8399`.

## What the app does

1. Sets one cache index on `(group ASC, ts DESC)` for a fresh collection.
2. Writes 8 static documents (`ts` 50…57) and two hot ones (`ts` 1 and 2).
3. Four times, raises `ts` on both hot documents (100, 200, 300, 400), and lets
   the index backfiller run in between. The backfiller first runs 15 s after a
   client starts, then every 60 s, so the app terminates and recreates the
   client after each write to wait for that first run only.
4. Compares the limited query against the unlimited one, then re-listens.

## Cause

In `Firestore/core/src/local/leveldb_index_manager.cc`, a document's index
entries are kept with a reverse lookup (document → entries) used to find and
delete them when the document changes. `UpdateEntries` walks the old and new
entries in byte order (`DiffSets`):

- On a `DESCENDING` segment, a larger value encodes smaller, so when the field
  grows the new entry sorts first: it is **added before the old one is
  deleted**.
- `AddIndexEntry` picks the reverse lookup's sequence number by reading the
  **committed** database (`db_->ptr()->NewIterator`), not the transaction.
- `DeleteIndexEntry` then deletes the old entry and **every** reverse lookup of
  the document through the transaction iterator, including the one just added.

The new entry is left without a reverse lookup, so the next update does not
see it and never deletes it. Every other bump leaves a stale entry behind.
`GetDocumentsMatchingTarget` counts those duplicates against the limit
(`count < target.limit()`) before deduplicating keys, so the index scan yields
fewer distinct documents. `QueryEngine::NeedsRefill` does not catch it, since
every returned document still matches. A resumed listen only receives changes
from the backend, so the listener never recovers.

The same reverse-lookup wipe also affects array (`array-contains`) indexes,
where a document has several entries.

Android stores entries in SQLite without that reverse lookup, and is not
affected.

A second, related leak: `DeleteAllFieldIndexes` and `DeleteFieldIndex` delete
the configurations, states and entries but not the reverse lookups. Index ids
restart from the highest persisted configuration after a restart, so an index
recreated with a deleted one's id reads the leftover lookups as existing
entries and never writes them for unchanged documents.

## Workaround

Do not enable cache index auto-creation on iOS, and call
`PersistentCacheIndexManager.deleteAllIndexes()` to purge indexes that are
already corrupted. Because of the leak above, do not create indexes again on
that cache.

## Verifying a fix on a corrupted cache

`-recheck` checks the previous run's collection again without writing. Run
the repro with a build of the unfixed SDK, install a build of the fixed one
over it, keeping its data, and recheck:

```bash
./run-repro.sh path/to/Unfixed.app dev.repro.firestoreindex.localsdk
KEEP_DATA=1 REPRO_MODE=-recheck ./run-repro.sh path/to/Fixed.app dev.repro.firestoreindex.localsdk
```
