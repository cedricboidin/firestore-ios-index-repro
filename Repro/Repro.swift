import FirebaseFirestore
import Foundation

/// Reproduces stale entries in the iOS SDK's client-side cache index.
///
/// One cache index on `(group ASC, ts DESC)`. Eight "static" documents never
/// change; two "hot" documents get a larger `ts` several times, and the index
/// backfiller runs between each bump. A limited query served by that index
/// should return `limit` documents; with the bug it returns fewer, because
/// the hot documents keep stale index entries that use up the limit.
@MainActor
final class Repro: ObservableObject {
  @Published private(set) var lines: [String] = []
  @Published private(set) var running = false
  @Published private(set) var verdict: String?
  @Published private(set) var reproduced: Bool?

  private static let limit = 5
  private static let staticDocumentCount = 8
  private static let rounds = 4
  /// The backfiller first runs 15 s after a client starts, then every 60 s.
  /// Restarting the client after each write only waits for that first run.
  private static let backfillWait: UInt64 = 18
  /// Lets the write reach the emulator and come back into the remote
  /// document cache, which is what the backfiller reads.
  private static let ackWait: UInt64 = 3
  private static let lastCollectionKey = "lastCollectionID"

  static func configure(_ db: Firestore) {
    let settings = db.settings
    settings.host = ProcessInfo.processInfo.environment["FIRESTORE_EMULATOR_HOST"]
      ?? "127.0.0.1:8399"
    settings.isSSLEnabled = false
    settings.cacheSettings = PersistentCacheSettings()
    db.settings = settings
  }

  private var db = Firestore.firestore()
  private var collection: CollectionReference!
  private var listeners: [ListenerRegistration] = []

  func run() async {
    running = true
    verdict = nil
    reproduced = nil
    lines = []
    defer { running = false }

    collection = db.collection("items-\(Int(Date().timeIntervalSince1970))")
    UserDefaults.standard.set(collection.collectionID, forKey: Self.lastCollectionKey)
    do {
      try await configureIndex()
      listenToEverything()
      try await seed()
      await waitForBackfill(after: "seed")
      for round in 1...Self.rounds {
        try await bumpHotDocuments(round: round)
        await waitForBackfill(after: "round \(round)")
      }
      try await check()
    } catch {
      log("error: \(error)")
    }
    listeners.forEach { $0.remove() }
    listeners = []
  }

  /// Checks the previous run's collection again without writing anything, to
  /// see whether a build with another SDK repairs a cache an earlier one
  /// corrupted.
  func recheck() async {
    running = true
    verdict = nil
    reproduced = nil
    lines = []
    defer { running = false }

    guard let collectionID = UserDefaults.standard.string(forKey: Self.lastCollectionKey) else {
      log("error: no previous run to recheck")
      return
    }
    collection = db.collection(collectionID)
    do {
      let limited = try await limitedQuery().getDocuments(source: .cache)
      log("recheck \(collectionID), cache, limit \(Self.limit) at start: \(limited.count) documents = \(limited.documents.map(\.documentID))")
      listenToEverything()
      log("waiting \(Self.backfillWait) s for the index backfiller")
      try? await Task.sleep(nanoseconds: Self.backfillWait * 1_000_000_000)
      try await check()
    } catch {
      log("error: \(error)")
    }
    listeners.forEach { $0.remove() }
    listeners = []
  }

  private func limitedQuery() -> Query {
    collection
      .whereField("group", isEqualTo: "g")
      .order(by: "ts", descending: true)
      .limit(to: Self.limit)
  }

  private func unlimitedQuery() -> Query {
    collection
      .whereField("group", isEqualTo: "g")
      .order(by: "ts", descending: true)
  }

  private func configureIndex() async throws {
    let json = """
      {
        "indexes": [{
          "collectionGroup": "\(collection.collectionID)",
          "queryScope": "COLLECTION",
          "fields": [
            { "fieldPath": "group", "order": "ASCENDING" },
            { "fieldPath": "ts", "order": "DESCENDING" }
          ]
        }],
        "fieldOverrides": []
      }
      """
    try await db.setIndexConfiguration(json)
    log("cache index on \(collection.collectionID): group ASC, ts DESC")
  }

  /// Keeps every document of the collection in the cache, and keeps the
  /// limited query's target alive so that re-listening later resumes it.
  private func listenToEverything() {
    listeners.append(collection.addSnapshotListener { _, _ in })
    listeners.append(limitedQuery().addSnapshotListener { _, _ in })
  }

  private func seed() async throws {
    let batch = db.batch()
    for index in 0..<Self.staticDocumentCount {
      batch.setData(
        ["group": "g", "ts": 50 + index],
        forDocument: collection.document("static-\(index)")
      )
    }
    batch.setData(["group": "g", "ts": 1], forDocument: collection.document("hot-a"))
    batch.setData(["group": "g", "ts": 2], forDocument: collection.document("hot-b"))
    try await batch.commit()
    log("seeded \(Self.staticDocumentCount) static documents (ts 50…57) and hot-a, hot-b")
  }

  private func bumpHotDocuments(round: Int) async throws {
    let batch = db.batch()
    batch.updateData(["ts": round * 100], forDocument: collection.document("hot-a"))
    batch.updateData(["ts": round * 100 + 1], forDocument: collection.document("hot-b"))
    try await batch.commit()
    log("round \(round): hot-a.ts = \(round * 100), hot-b.ts = \(round * 100 + 1)")
  }

  private func waitForBackfill(after step: String) async {
    try? await Task.sleep(nanoseconds: Self.ackWait * 1_000_000_000)
    await restartClient()
    log("restarted the client, waiting \(Self.backfillWait) s for the index backfiller (\(step))")
    try? await Task.sleep(nanoseconds: Self.backfillWait * 1_000_000_000)
  }

  private func restartClient() async {
    listeners.forEach { $0.remove() }
    listeners = []
    try? await db.terminate()
    db = Firestore.firestore()
    Self.configure(db)
    collection = db.collection(collection.collectionID)
    listenToEverything()
  }

  private func check() async throws {
    let unlimited = try await unlimitedQuery().getDocuments(source: .cache)
    let expected = Array(unlimited.documents.prefix(Self.limit).map(\.documentID))
    log("cache, no limit: \(unlimited.count) documents, top \(Self.limit) = \(expected)")

    let limited = try await limitedQuery().getDocuments(source: .cache)
    log("cache, limit \(Self.limit): \(limited.count) documents = \(limited.documents.map(\.documentID))")

    let server = try await limitedQuery().getDocuments(source: .server)
    log("server, limit \(Self.limit): \(server.count) documents = \(server.documents.map(\.documentID))")

    listeners.forEach { $0.remove() }
    listeners = []
    let relistened = await snapshots(of: limitedQuery(), for: 10)
    for snapshot in relistened {
      log(
        "re-listen, limit \(Self.limit): \(snapshot.count) documents, fromCache=\(snapshot.metadata.isFromCache) = \(snapshot.documents.map(\.documentID))"
      )
    }

    let lastListenCount = relistened.last?.count ?? 0
    reproduced = limited.count < Self.limit || lastListenCount < Self.limit
    verdict = reproduced == true
      ? "REPRODUCED: limit \(Self.limit) query returned \(limited.count) from cache, listener settled on \(lastListenCount)"
      : "not reproduced: limit \(Self.limit) query returned \(limited.count), listener settled on \(lastListenCount)"
    log(verdict!)
  }

  private func snapshots(of query: Query, for seconds: UInt64) async -> [QuerySnapshot] {
    var received: [QuerySnapshot] = []
    let registration = query.addSnapshotListener(includeMetadataChanges: true) { snapshot, _ in
      if let snapshot { received.append(snapshot) }
    }
    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    registration.remove()
    return received
  }

  private func log(_ line: String) {
    let stamp = Date().formatted(date: .omitted, time: .standard)
    lines.append("\(stamp) \(line)")
    print("[repro] \(line)")
  }
}
