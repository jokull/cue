#!/bin/sh
# Copies Cue's takes and their scripts off a connected iPhone into research/eval/takes/device/,
# as <take>.mp4 + <take>.txt pairs ready for research/eval/scribe_eval.py.
# Usage: scripts/pull-takes.sh [device-id]
set -eu
cd "$(dirname "$0")/.."
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ {print $3; exit}')}"
OUT=research/eval/takes/device
STAGE=$(mktemp -d)
mkdir -p "$OUT"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier is.solberg.cue --source Documents --destination "$STAGE/Documents" >/dev/null
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier is.solberg.cue --source "Library/Application Support" --destination "$STAGE/Support" >/dev/null
STORE=$(find "$STAGE/Support" -name "default.store" | head -1)
# Take file name → script text, straight from the SwiftData store.
sqlite3 -separator '	' "$STORE" \
  "SELECT t.ZFILENAME, s.ZTEXT FROM ZTAKE t JOIN ZSCRIPT s ON t.ZSCRIPT = s.Z_PK;" |
while IFS='	' read -r file text; do
  name="${file%.mp4}"
  cp "$STAGE/Documents/Takes/$file" "$OUT/$name.mp4" 2>/dev/null || continue
  printf '%s\n' "$text" > "$OUT/$name.txt"
  echo "pulled $name"
done
rm -rf "$STAGE"
