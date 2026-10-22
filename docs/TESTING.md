# Testing Cue

All speech runs on ElevenLabs Scribe through the `cue-api` Worker: **Scribe v2 Realtime** follows
the reader live (the app connects directly with a single-use token), **Scribe v2 batch** times the
captions of the stitched take. The script's language is detected on-device and sent as a hint.
Users allow this once, before their first recording; declining means auto-scroll and estimated
captions, with nothing leaving the phone.

Test from the bottom up — each layer is cheap on its own.

## 1. Logic — macOS, seconds

```sh
cd Packages/CueCore && swift test
```

Tracking, reading pace, alignment, paging, caption rendering and export, script hints, clip editing
(add, retake, reorder, delete/undo, the 3-minute limit, skipped lines), stitching, and decoding a real
Icelandic Scribe response.

## 2. The Worker — seconds, a fraction of a cent

```sh
scripts/test-api.sh                      # health, 401 without token, 400 on bad input, real transcription
scripts/test-api.sh path/to/take.m4a is  # any audio, any language
```

Locally: `cd api && npx wrangler dev --port 8788` (secrets in `api/.dev.vars`, gitignored), with
`CUE_API_URL=http://localhost:8788` in `.env`. Logs: `cd api && npx wrangler tail`.

## 3. Live tracking, measured — seconds per run

How late the prompter changes line, from real takes. Record a take's realtime transcript once, then
replay it through CueCore's actual tracker and pace model as often as you like:

```sh
node research/eval/realtime_record.mjs take.pcm out.json is hints=hints.json vad_silence_threshold_secs=0.5
research/eval/tracklag/.build/release/tracklag hints script.txt > hints.json
research/eval/tracklag/.build/release/tracklag script.txt batch.scribe.json out.json take.pcm --trim 1
```

(`take.pcm`: `ffmpeg -i take.mp4 -ac 1 -ar 16000 -f s16le take.pcm`; `batch.scribe.json` from
`research/eval/scribe_eval.py`; run node through `dotenvx run -q -f .env --`.) It prints each line's
switch time against when the reader actually started it. Target: within ±0.5 s, never late.

## 4. Simulator, end to end — a minute

The Simulator has no camera but has network, so the full live pipeline runs for real. Debug builds:

```sh
xcrun simctl launch <sim> is.solberg.cue -cloudSpeechConsent YES -cloudSpeechConsentAsked YES \
  -cueFakeCamera $PWD/branding/generated/presenter-2.png \
  -cueFakeMic $PWD/take.pcm -cueTakeScript $PWD/script.txt
```

- `-cueFakeMic` plays 16 kHz mono audio through the microphone feed → Scribe Realtime → tracker →
  prompter, as one clip. Screenshot every couple of seconds and compare lines to the audio.
- `-cueFakeClips <mp4>` fills the clip tray instead, for the editor UI.
- `-cueTakeVideo <mp4> -cueTakeScript <txt>` opens a finished take, for the caption pass.
- `-cueSeed`, `-cueCompose`, `-cueDemo`: screens for App Store screenshots.

## 5. On the iPhone — the real test

| Where | Means |
|---|---|
| Prompter tag **VOICE** | live tracking is on |
| Prompter tag **1.0×** | no consent, or tracking unreachable: auto-scroll |
| Red frame round the screen | recording has started (after the ring fills) |
| Take: **Anchored to your voice** | captions timed from the speech |
| Take: **Estimated timing** | captions spread evenly (declined, offline or failed) |

Checklist: an English and an Icelandic script; hold, slide-to-lock, release; drag the script between
clips (flick and re-catch); retake a clip; reorder; delete and undo; Done → captions.

## 6. Accuracy on your own takes

```sh
scripts/pull-takes.sh   # phone → research/eval/takes/device/*.mp4 + .txt (gitignored: your voice)
for take in research/eval/takes/device/*.mp4; do
  dotenvx run -q -f .env -- python3 -I research/eval/scribe_eval.py "$take" "${take%.mp4}.txt"
done
```

Word error rate is scored against the whole script, so a partial read looks worse than it is;
compare the transcript to what was actually read.

## Before release

- The app token in `Config/Cloud.secrets.xcconfig` is compiled into the build: fine for development,
  extractable from a shipped binary. Replace it with App Attest verification in the Worker.
- Upgrade the ElevenLabs plan (the free tier allows 6 concurrent realtime sessions, 2.5 h/month).
- Privacy: `PrivacyInfo.xcprivacy` declares Audio Data (app functionality, not linked, not
  tracking); the App Store privacy answers and the policy at cue.solberg.is must match.
