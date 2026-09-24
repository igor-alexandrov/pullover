#!/bin/sh
# Renders the demo inbox's screens to PNGs in the given directory (default docs/).
set -e
cd "$(dirname "$0")/.."
OUT="${1:-docs}"
mkdir -p "$OUT"
swift build
for state in inbox dark-compact settings repositories; do
  PULLOVER_DEMO=1 PULLOVER_SNAPSHOT="$OUT/$state.png" PULLOVER_SNAPSHOT_STATE="$state" .build/debug/Pullover &
  PID=$!
  ( sleep 20; kill $PID 2>/dev/null ) &
  wait $PID || true
done
ls "$OUT"
