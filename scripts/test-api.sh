#!/bin/sh
# Smoke-tests the deployed cue-api Worker: health, auth, input validation, a real transcription.
# Usage: scripts/test-api.sh [audio-file] [language]   (defaults: the Icelandic TTS smoke clip)
set -eu
cd "$(dirname "$0")/.."
AUDIO="${1:-research/eval/takes/smoke-is.tts.mp3}"
LANGUAGE="${2:-is}"
dotenvx run -q -f .env -- sh -c '
  set -eu
  check() { [ "$2" = "$3" ] && echo "ok   $1 ($3)" || { echo "FAIL $1: expected $2, got $3"; exit 1; }; }
  code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
  check health 200 "$(code "$CUE_API_URL/health")"
  check "no token" 401 "$(code -X POST --data-binary @"$0" "$CUE_API_URL/v1/transcribe")"
  check "bad language" 400 "$(code -X POST --data-binary @"$0" -H "authorization: Bearer $CUE_API_TOKEN" "$CUE_API_URL/v1/transcribe?language=XX1")"
  curl -s -X POST --data-binary @"$0" -H "content-type: audio/mp4" -H "authorization: Bearer $CUE_API_TOKEN" \
    "$CUE_API_URL/v1/transcribe?language=$1" | python3 -I -c "
import json, sys
d = json.load(sys.stdin)
words = d.get(\"words\", [])
assert words, d
print(f\"ok   transcription ({d.get(\"language\")}, {len(words)} words, first: {words[0]})\")"
' "$AUDIO" "$LANGUAGE"
