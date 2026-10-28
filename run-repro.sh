#!/usr/bin/env bash
# Installs a built app on a simulator, runs the repro and prints its log.
# Usage: ./run-repro.sh <path/to/App.app> <bundle id> [simulator id, default: booted]
# REPRO_MODE=-recheck checks the previous run's collection again; KEEP_DATA=1
# installs over the existing app, keeping its Firestore cache.
set -euo pipefail

app="$1"
bundle_id="$2"
device="${3:-booted}"
mode="${REPRO_MODE:--autorun}"

if [[ "${KEEP_DATA:-}" != 1 ]]; then
  xcrun simctl uninstall "$device" "$bundle_id" 2>/dev/null || true
fi
xcrun simctl install "$device" "$app"
xcrun simctl launch --console-pty --terminate-running-process "$device" "$bundle_id" "$mode" 2>&1 |
  while IFS= read -r line; do
    case "$line" in
      *"[repro]"*)
        echo "$line"
        case "$line" in *REPRODUCED* | *"not reproduced"* | *"[repro] error"*) break ;; esac
        ;;
    esac
  done
xcrun simctl terminate "$device" "$bundle_id" 2>/dev/null || true
