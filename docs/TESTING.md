# Testing Cue's speech pipeline

Speech has two paths. **On-device** (iOS 26 `SpeechAnalyzer`) handles every language the iPhone
supports. **Cloud** (the `cue-api` Worker → ElevenLabs Scribe v2) handles the rest, Icelandic
first, and only after the user allows it once. The script's language is detected silently
(`NLLanguageRecognizer`) and picks the path.

Test from the bottom up. Each layer is cheap to run on its own.

## 1. Logic — macOS, seconds

```sh
cd Packages/CueCore && swift test
```

Covers tracking, alignment, paging, rendering, export, and decoding Scribe's response. The
Icelandic fixtures in `Tests/CueCoreTests/Fixtures/scribe-is-*.json` are a real Scribe v2
response; the test aligns it to its script and checks every word lands with the voice's timing.

## 2. The Worker — seconds, costs a fraction of a cent

```sh
scripts/test-api.sh                      # health, 401 without token, 400 on bad input, real transcription
scripts/test-api.sh path/to/take.m4a is  # any audio, any language
```

Locally: `cd api && npx wrangler dev --port 8788` (secrets in `api/.dev.vars`, gitignored),
then point `CUE_API_URL` in `.env` at `http://localhost:8788`. Logs: `cd api && npx wrangler tail`.

## 3. Simulator end to end — a minute

The Simulator can't recognize speech on-device, but it has network, so the cloud path runs for
real. Debug builds accept a take from Mac files:

```sh
xcrun simctl launch <sim> is.solberg.cue \
  -cueTakeVideo $PWD/research/eval/takes/demo-is.mp4 \
  -cueTakeScript $PWD/research/eval/takes/smoke-is.txt
```

- Without consent: the take shows the one-time "Time captions to your Icelandic?" card.
- Add `-cloudSpeechConsent YES` (a launch-argument UserDefaults override): the status turns to
  "Anchored to your voice" — the audio went Simulator → Worker → Scribe v2 → aligner.

## 4. On the iPhone — the real test

Signs to read, no extra UI:

| Where | Means |
|---|---|
| Prompter tag **VOICE** | live tracking runs on-device for this language |
| Prompter tag **1.0×** | no on-device engine (e.g. Icelandic): auto-scroll |
| Take: consent card | cloud language, first time |
| Take: **Anchored to your voice** | captions timed from the speech (on-device or cloud) |
| Take: **Estimated timing** | recognition failed or was declined |

Checklist: one English take (proves the on-device `SpeechAnalyzer` path); three to five
Icelandic takes with different scripts, one with a stumble and one with an ad-lib.

## 5. Accuracy — numbers, not impressions

```sh
scripts/pull-takes.sh                                   # phone → research/eval/takes/device/*.mp4 + .txt
for take in research/eval/takes/device/*.mp4; do
  dotenvx run -q -f .env -- python3 -I research/eval/scribe_eval.py "$take" "${take%.mp4}.txt"
done
```

Reports word error rate against the script, timed-word coverage and latency per take, and saves
the raw response beside each take. Extend `scribe_eval.py` with other providers (Gemini,
Soniox, Monologue's engine) to compare like for like.

## Before release

- The app token in `Config/Cloud.secrets.xcconfig` is fine for development and TestFlight but
  extractable from a shipped binary. Replace it with App Attest verification in the Worker.
- Privacy: `PrivacyInfo.xcprivacy` now declares Audio Data (app functionality, not linked,
  not tracking). The App Store privacy answers and the privacy policy must say the same.
