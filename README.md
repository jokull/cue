# Cue

An iPhone teleprompter that follows your voice, then burns word-by-word captions into the video.

Hold the record button to film a clip; the script, under the camera, moves line by line as you read
it, and waits where you stopped. Clips stitch into one take; captions are timed to your actual words.
Works in Icelandic.

## Layout

| Path | What |
|---|---|
| `App/` | The iOS app (SwiftUI, iOS 26). `project.yml` generates the Xcode project. |
| `Packages/CueCore/` | Testable core: script tracking, reading pace, alignment, captions, export, clips. |
| `api/` | `cue-api` Cloudflare Worker: holds the ElevenLabs key, mints realtime tokens, proxies batch STT. |
| `site/` | cue.solberg.is (static, Cloudflare). |
| `branding/` | Icon (`App/Cue.icon`), App Store frames (`frames.py`), Blender scripts. |
| `research/` | Speech research and the eval tools (`scribe_eval.py`, realtime recorder, `tracklag` replay). |
| `docs/TESTING.md` | How to test each layer, from unit tests to the phone. |

## Setup

```sh
brew install xcodegen
cp .env.example .env            # ELEVENLABS_API_KEY, CUE_API_URL, CUE_API_TOKEN
scripts/cloud-config.sh         # writes the gitignored Config/Cloud.secrets.xcconfig
xcodegen generate && open Cue.xcodeproj
(cd Packages/CueCore && swift test)
```

Speech runs on ElevenLabs Scribe (realtime for the prompter, batch for captions) through the Worker;
see `research/elevenlabs-api.md` and `research/voice-tracking.md` for why.
