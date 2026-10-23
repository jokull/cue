# Cue — handoff

*As of 23 October 2026.*

## What it is

Cue is an iPhone app for talking to camera. You paste a script, hold the record button, and read. The script sits right under the front camera, so your eyes stay near the lens, and it moves along as you speak — it listens to you rather than scrolling on a timer. When you're done, Cue burns captions into the video, every word lit up at the moment you said it, ready for Instagram, TikTok or LinkedIn.

It works in Icelandic as well as English and most other languages. That was a hard requirement and it shaped the whole speech side of the app.

## How it feels to use

1. **Paste a script.** Tap the red **+** and a black panel drops out of the Dynamic Island with room to paste. The app quietly works out which language the script is in.
2. **Record in clips.** Hold the red button. Its ring fills like a loading indicator and recording starts when it closes, with a firm tap of haptics and a red frame around the screen so there's no doubt you're live. Let go to stop. Slide up while holding to keep recording hands-free.
3. **Read naturally.** Three lines of script show at a time — the one you just said, the one you're on, the next one. They move a line at a time as you read, stop when you pause, and pick up where you stopped for the next clip.
4. **Move around the script between clips.** Drag anywhere on the camera picture. The script opens up to show more, follows your thumb, and settles on a line when you let go — flick it to travel further, catch it again before it closes.
5. **Fix clips.** The clips line up at the bottom of the screen. Tap one to retake it (the script jumps back to its lines), hold to watch it, drag to reorder, and tap the backspace button twice to delete (with undo). If you skipped part of the script, a little yellow note offers to take you there.
6. **Finish.** Tap the checkmark. The clips join into one video, and a few seconds later the captions are timed to your actual words.
7. **Style and export.** Pick Fun (bold capitals, a coloured pill on the spoken word), Pro (clean text on a dark bar) or Serif (the spoken word turns italic). Choose a colour and size, drag the captions to the height you want on the video (they start 70% of the way down), fix any word that came out wrong, and export — captions burned in, without captions, or as subtitle files — cropped for Stories, square or widescreen, following your face.

Takes are capped at three minutes, but the app doesn't show a countdown; it only tells you if you hit the limit.

## How the listening works

All speech recognition is done by **ElevenLabs** (their "Scribe" models). Apple's built-in speech recognition was tried first and dropped: it doesn't support Icelandic.

- **While you record**, your voice streams to ElevenLabs, and Cue matches what comes back against the script to work out where you are.
- Recognition always runs about a second behind your voice. To hide that, the script moves by **line**, not word, and Cue learns how fast you read and keeps moving between updates — then corrects itself whenever a new transcript arrives. Measured on real Icelandic takes, lines change on time or slightly early, never late.
- **After you finish**, the take's audio goes to ElevenLabs once more for exact word timings, and Cue pins your script's spelling to those times — so captions use your words, spelled right, even if you stumbled.

Before the first recording, Cue asks permission to send audio. Say no and everything stays on the phone: the script scrolls at a steady pace and captions are spaced evenly.

The ElevenLabs key never ships inside the app. A small service on Cloudflare (`cue-api`) holds it and hands the app one-time passes.

**Cost:** roughly 4 cents per three-minute take.

## Where things are

| | |
|---|---|
| Code | github.com/jokull/cue (public) |
| Website | cue.solberg.is — home, privacy policy, support |
| Speech service | cue-api.solberg.workers.dev (Cloudflare, personal account) |
| App Store Connect | "Cue: Read, Record, Caption", app ID 6825918577, bundle `is.solberg.cue` |
| TestFlight | External group "Vinir": Sunna and Halldór. Build 1 approved and installed; build 2 (caption dragging) waiting for review |
| Secrets | `.env` in the repo folder (never committed): ElevenLabs key and the app's pass for cue-api |

Inside the repo: `App/` is the iPhone app, `Packages/CueCore/` the tested core (tracking, timing, captions, export, clips), `api/` the Cloudflare service, `site/` the website, `branding/` the icon and App Store images, `research/` the speech research and measuring tools, `docs/TESTING.md` how to test each part.

## What's done

- The full recording flow above, on a real iPhone and in TestFlight.
- Voice-following in Icelandic and English, measured on real takes.
- Captions in three styles with word editing, colour, size and free placement; export in four formats.
- App icon (made in Apple's Icon Composer), six App Store screenshots, website with privacy and support pages.
- 47 automated tests for the core logic.

## What's open

**Before more testers or the App Store**
- **Lock down the speech service.** The app proves itself to cue-api with a password built into every copy. Fine for friends, but anyone could dig it out of a public build. It should use Apple's App Attest instead.
- **Upgrade ElevenLabs.** The account is on the free plan: six people recording at once, 2.5 hours of live listening a month.
- **App Store privacy answers** must say: audio data, not linked to the person, not used for tracking, used for app functionality *and* other purposes (because ElevenLabs may use audio to improve its models — the setting was deliberately left on, and the privacy policy says so). Turning that setting off at ElevenLabs would simplify this.
- **App Store submission itself:** listing text, uploading the screenshots, and submitting for review. Not started.

**Known rough edges**
- If you restart a sentence mid-clip, the script doesn't follow you back.
- Catching the script mid-flick can make it jump slightly before following your thumb.
- The voice-following numbers come from a handful of takes; more recordings would firm them up.
- Long takes that span several listening sessions haven't been tested.

**Ideas raised but not built**
- Trimming clips (only delete-and-retake for now).
- A paid tier, most likely for extra languages rather than "better accuracy".
- Dubbing a take into another language in your own voice (ElevenLabs supports Icelandic, but it costs about $2 a minute).

## How a new build gets to testers

Same as Lyklaborð: build and sign from the command line with the App Store Connect key, upload with `asccli`, attach to the "Vinir" group with a short note, and submit for beta review. Later builds usually clear review within hours.
