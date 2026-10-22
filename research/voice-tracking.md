# Voice tracking: speech-to-text and script position for Cue

Researched 2026-10-22. Every source was seen on that date unless noted. **[unverified]** marks claims I could not confirm from a primary source. "Vendor claim" marks a number the vendor publishes about itself.

## TL;DR

1. **Ship first, free, on-device:** move both passes from `SFSpeechRecognizer` to `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26). Use `.audioTimeRange` + `.transcriptionConfidence` for captions and volatile results for the prompter. Fall back to `DictationTranscriber` for locales SpeechTranscriber lacks. It has no per-minute cost, adds nothing to app size, and keeps the privacy label empty.
2. **Fix the algorithms before buying accuracy.** The tracker should match on word-level results rather than re-split the whole string, use phonetic fuzzy matching, and allow a backward jump on a strong n-gram match so restarted lines work. The aligner should weight matches by confidence and snap word edges to the audio energy envelope.
3. **Icelandic is the gap.** No Apple recognizer supports `is` (probed locally, see §1a). Of the cloud services checked, only **ElevenLabs Scribe v2** has Icelandic, word timestamps and a good (vendor-claimed) accuracy band.
4. **Sell languages, not "better accuracy".** PromptSmart already sells VoiceTrack languages as IAPs, so there's precedent. Make it an auto-renewing "Cue Pro" subscription with a monthly cloud-minute cap. Cloud cost is ~1–3¢ per 3-minute take, so margin isn't the problem. Whether people will pay is.
5. **Don't** use MMS_FA (CC-BY-NC), WhisperKit Pro (1,000-device/month minimum), or on-device Whisper for Icelandic (weak accuracy).

---

## 1. Speech-to-text engines

### 1a. Apple on-device

**Locale probe.** I compiled and ran a probe against the Speech framework on macOS 26.6.2, which shares Speech with iOS 26. Results:

| Engine | Locales | Icelandic |
|---|---|---|
| `SFSpeechRecognizer.supportedLocales()` | 63 | **no** |
| `DictationTranscriber.supportedLocales` | 54 (same set as legacy on-device: adds da, fi, nb, sv, nl, pl, etc.) | **no** |
| `SpeechTranscriber.supportedLocales` | 30 (de, en×10, es×4, fr×4, it×2, ja, ko, pt×2, yue, zh×3) | **no** |

**SpeechAnalyzer vs SFSpeechRecognizer.** From the WWDC25 session 277 and the iOS 27.1 SDK `.swiftinterface`:

- **Long-form and live use.** SpeechTranscriber is built for "long-form and distant audio". For live use you get volatile results "almost as soon as they're spoken", which are later finalized. Apple calls it "faster and more flexible than the one previously available through SFSpeechRecognizer". [WWDC25-277]
- **Word timing.** `ResultAttributeOption.audioTimeRange` puts a `CMTimeRange` on each run of the `AttributedString`. Apple says transcripts sync to audio "down to an individual audio sample" (vendor claim, demoed as playback highlighting). Also available: `.transcriptionConfidence`, `ReportingOption.volatileResults/.fastResults/.alternativeTranscriptions`, and the preset `.timeIndexedProgressiveTranscription`. [SDK]
- **Model delivery.** Models come through `AssetInventory.assetInstallationRequest(supporting:)`. They are "retained in system storage and does not increase the download or storage size of your application… nor run-time memory". There is a per-app cap on reserved locales (`AssetInventory.maximumReservedLocales`). [WWDC25-277, SDK]
- **Device check.** Check `SpeechTranscriber.isAvailable`. On unsupported hardware Apple says to use `DictationTranscriber`, which has the same languages and devices as legacy on-device SFSpeech and needs no Siri/Dictation toggle. [Apple docs: SpeechTranscriber; WWDC25-277]
- **⚠ Script biasing.** Apple's docs for `AnalysisContext.contextualStrings` name only DictationTranscriber, with a limit of ≤100 phrases of 1–2 words. The `ContentHint.customizedLanguage(modelConfiguration:)` hint, a custom LM built from `SFCustomLanguageModelData`, exists only on DictationTranscriber in the SDK. Today's code relies on `contextualStrings` for script names. **Whether SpeechTranscriber honours contextual strings is unverified. Test it empirically.** Bonus: a custom LM built *from the script itself* on DictationTranscriber could bias recognition strongly toward the script. Compile time and accuracy are untested. [Apple docs: contextualStrings; SDK]
- **⚠ iOS 27-only APIs.** These are `anyAppleOS 27` in the SDK, so don't use them on an iOS 26 target: `AssetInputSequenceProvider` (AVAsset → input), `AnalyzerInputConverter`, `Options.ignoresResourceLimits`, and `AnalyzerInput(buffer: CMReadySampleBuffer)`. The core SpeechAnalyzer, SpeechTranscriber, SpeechDetector and `audioTimeRange` are all iOS 26. [SDK]
- **⚠ Possible current privacy issue.** `Speech.swift` sets `requiresOnDeviceRecognition` only when `supportsOnDeviceRecognition` is true. Otherwise SFSpeech can fall back to **Apple servers**, which also have short-form limits. SpeechTranscriber is on-device only, so the switch removes the ambiguity.
- **Cost and licence:** free, part of the SDK.
- **Accuracy:** I found **no independent public WER or timestamp benchmark** of SpeechTranscriber. [unverified] Measure it yourself (§2c).

### 1b. On-device open models (Core ML / MLX)

| Model | Size | Languages | Streaming | Word timestamps | Licence | Notes |
|---|---|---|---|---|---|---|
| **Whisper** via **WhisperKit** (Argmax) | tiny → large-v3-turbo (recommended multilingual build `large-v3-v20240930_626MB`) | 98–99 depending on source, incl. Icelandic | CLI `--stream`; not a native streaming model | yes (word/segment in local server) | WhisperKit MIT. Whisper weights MIT [unverified, not re-checked] | No iPhone RTF found. The benchmark Space didn't render. Argmax points to `make benchmark-devices`. [WhisperKit README, BENCHMARKS.md] |
| WhisperKit **Pro** | — | — | — | — | **$1.33 or $1.00 per device-month, minimum 1,000 licences/month** | That is a ~$1k/month floor. Not viable for a solo dev. [argmaxinc.com/pricing] |
| **Parakeet TDT 0.6B v3** (NVIDIA) via **FluidAudio** | 0.6B | 25 European languages, **no Icelandic** | FluidAudio sliding window; Parakeet EOU 120M is English-only streaming | yes (word + segment) | **CC-BY-4.0** (attribution required, commercial OK). FluidAudio SDK Apache-2.0 | Open ASR average WER 6.34%. ~190× RT on an M4 Pro (Mac). No iPhone figure published. [HF card, FluidAudio README] |
| **Nemotron speech streaming en 0.6B** (NVIDIA) | 0.6B | English (a 40-locale "Nemotron 3.5" is mentioned) | yes, chunks of 80/160/560/1120 ms | via API flag | NVIDIA Open Model License, "commercial/non-commercial use" | WER 7.67% at 160 ms, 6.93% at 1.12 s. [HF card] No Core ML port verified. |
| **Moonshine streaming medium** (Useful Sensors) | 245M | **English only** | yes, ~80 ms lookahead | — | MIT | Open ASR average 6.65%. Built for sub-1 GB edge devices. [HF card] |
| **Kyutai STT 1B en_fr** | 1B | en, fr | yes, 0.5 s delay | derivable from token offsets | CC-BY 4.0 | No iPhone/MLX claim on the card. [HF card] |
| Icelandic Whisper fine-tune (BuzzASR/icelandic) | large-v3 | is | no | — | **licence not checked** | Combined WER 21.38%, FLEURS 27.73% (self-reported). Shows how weak zero-shot Whisper is on Icelandic. [HF card, via search] |

**Leaderboard context** (secondary source, May 2026 snapshot, because the HF Space is JS-rendered). The top average WERs on the Open ASR Leaderboard are Granite Speech 4.1 2B at 5.33, Cohere Transcribe 03-2026 at 5.42, Granite 4.0 1B at 5.52, and Canary-Qwen 2.5B at 5.63. With private accent/conversational data added, `zoom/scribe_v1` (as the source names it; not confirmed to be ElevenLabs) rises to #1 at 6.24. [Appen blog via search; llmreference] These are server-class models, and none has a verified iPhone port.

**Verdict.** For the 30 SpeechTranscriber locales, no open model is worth the bundle size and battery cost until your own eval shows Apple losing. For Icelandic on-device, nothing commercially usable is good enough today.

### 1c. Cloud

Per-minute figures are derived from hourly list prices. All prices were seen 2026-10-22.

| Provider / model | Batch $/min | Streaming $/min | Word timestamps | Icelandic | Training / retention |
|---|---|---|---|---|---|
| **ElevenLabs Scribe v2** | $0.0037 ($0.22/h) +$0.05/h keyterms | Scribe v2 Realtime $0.0065 ($0.39/h), ~150 ms partials (vendor) | yes, both | **yes, "Excellent ≤5% WER" band** (vendor self-rating). Realtime: "90+ languages", Icelandic **not confirmed** | Zero Retention Mode is enterprise-only. The claim that non-enterprise audio is used for training comes from a Deepgram (competitor) blog **[unverified]** |
| **Deepgram Nova-3** | $0.0043 mono / $0.0052 multi | $0.0048 / $0.0058 (promo; list $0.0077 / $0.0092). Flux $0.0065 | yes | **no** (not in any model's list) | Model Improvement Program unless `mip_opt_out=true`. Opted-out audio is kept "only for the duration necessary to process". Price effect of opting out not stated |
| **AssemblyAI** | Universal-2 $0.0025, Universal-3.5 Pro $0.0035 | Universal-Streaming $0.0025, U-3.6 Pro RT $0.0075 (billed on session time) | yes | Universal-2 only, **">25% to ≤50% WER" tier** | Not on pricing page **[unverified]**. EU endpoint available |
| **OpenAI** | gpt-transcribe $0.0045, gpt-4o-transcribe $0.006, gpt-4o-mini-transcribe $0.003, whisper-1 $0.006 | gpt-live-transcribe / gpt-realtime-whisper $0.017 | **only `whisper-1`**, which is deprecated and shuts down **2027-02-26** | Whisper family covers it; list not on page **[unverified]** | Not trained on by default. `/v1/audio/transcriptions`: no abuse-monitoring retention, ZDR-eligible |
| **Cloudflare Workers AI** whisper-large-v3-turbo | **$0.000513** | — | segments + VTT. Word-level **not shown** in the docs **[unverified]** | Whisper covers it, but accuracy is weak | Runs on your own CF account |
| **Speechmatics** | Standard $0.0075, Enhanced $0.0125 | $0.0075 / $0.0133 | — | **no** | 33% discount if you opt into training |
| **Google Chirp 3** | V2 standard $0.016 (dynamic batch $0.003) per search snippet **[unverified on live page]** | streaming supported | **no** (listed as unsupported) | Preview | — |
| **Azure Speech** | pricing page renders `$-` without JS **[unverified]** | — | yes | `is-IS` listed for fast transcription | — |

### 1d. Benchmarks

- **Open ASR Leaderboard:** see §1b. The live Space would not render, so the snapshot is via secondary sources and dated May 2026.
- **Streaming latency:** only vendor numbers, namely Scribe v2 RT at ~150 ms and Nemotron chunk sizes. I found no neutral 2026 latency benchmark. **[gap]**

---

## 2. Text → position and alignment

### 2a. Live script following (prompter)

**Problem shape.** This is *online* alignment of a noisy, revisable word stream against a known text. The closest literature is score following with On-Line Time Warping (Dixon 2005). It does incremental DTW in linear time and space, with a reported mean error of 59 ms and median 20 ms on piano audio, and Windowed Time Warping extends it [Dixon IJCAI-05; Macrae & Dixon ISMIR-10]. I found no published teleprompter algorithm. PromptSmart describes VoiceTrack only as "patented", "on-device", and pausing during ad-libs. BIGVU, Captions and Teleprompter Premium were not researched; I expect no public algorithm documentation for them.

**Today's `ScriptTracker`:** last-4-words tail, a window from −3 to +30 words, fuzzy match, monotonic. Concrete upgrades, in order of value:

1. **Feed it structured results, not a re-split string.** With SpeechTranscriber, keep finalized words and their `audioTimeRange`, and only re-match the volatile tail. Each result's `range` tells you which audio span changed. This stops cursor flicker when the recognizer rewrites old words.
2. **Phonetic key in `fuzzyMatches`.** Add a Metaphone-class code alongside the edit distance. Most recognizer errors on script names are homophones ("Cue" vs "queue", proper nouns). Weight each match by `transcriptionConfidence`.
3. **Anchored jumps instead of a fixed window.** Allow forward jumps of any length when a ≥3-word n-gram matches *uniquely* in the script. Precompute an n-gram index of the script for this. This handles skipped paragraphs.
4. **Allow backward jumps on strong evidence.** If ≥4 consecutive words match uniquely behind the cursor, the speaker restarted a line, so move back. Strict monotonicity is wrong for flub-and-retake, which is how people actually use a teleprompter.
5. **Speech-rate extrapolation between hits.** Estimate words/sec from recent finalized words, and scroll smoothly toward `cursor + rate × latency` so the prompter doesn't stall during recognizer lag.
6. **Optional DictationTranscriber + custom LM from the script** (§1a). If it compiles fast enough, recognition becomes script-biased, which is roughly what a keyword spotter does. Test against SpeechTranscriber on accented speakers.

### 2b. Offline caption timing

| Method | Word-boundary accuracy (TIMIT / Buckeye, % within tolerance) | Licence / ship? |
|---|---|---|
| Montreal Forced Aligner (GMM-HMM, 10 ms frames) | ≤25 ms: 72.8 / 69.9 · ≤50 ms: 89.4 / 84.9 · ≤100 ms: 97.4 / 91.8 | Server/Mac tool, not iOS. MFA 3.0 (Interspeech 2026) reports mean boundary error <15 ms |
| WhisperX (Whisper + wav2vec2 CTC align) | ≤25 ms: 52.7 / 43.1 · ≤50 ms: 82.4 / 67.4 · ≤100 ms: 94.2 / 77.4 | Code BSD [unverified]. Align models vary |
| MMS CTC (torchaudio `MMS_FA`) | ≤25 ms: 43.5 / 52.7 · ≤50 ms: 75.7 / 75.0 · ≤100 ms: 94.7 / 87.9 | **Weights CC-BY-NC 4.0, so not usable commercially.** torchaudio's `forced_align` was also removed in 2.9 |
| NeMo Forced Aligner | No numbers published. Works with CTC or hybrid models such as Parakeet (CC-BY-4.0) | Server-side |
| Raw Whisper timestamps | Utterance-level, "can be inaccurate by several seconds" (WhisperX README) | — |

Source for the accuracy numbers: Rousso et al., Interspeech 2024. One video frame at 30 fps is 33 ms. Word-by-word captions look right at roughly ≤50 ms onset error. Anything CTC-based lands ~80% within that. Classic HMM alignment lands ~87–89%.

**Recommendation for `Aligner`.** Keep Needleman–Wunsch; it's correct for script-vs-heard, and O(n·m) is trivial at 400 words. Then:

1. **Source timings from SpeechTranscriber `audioTimeRange`** on the finished file, via `SpeechAnalyzer(inputAudioFile:…)`.
2. **Snap edges to the audio.** Compute a 10 ms RMS or spectral-flux envelope of the take and move each word start to the nearest onset within ±60 ms. Move each end to the nearest drop. This is cheap DSP and uses HMM-style 10 ms resolution without an HMM. Use `SpeechDetector` speech/non-speech ranges to bound interpolated skipped runs and to clip trailing silence.
3. **Score pairs by confidence.** A low-confidence near-match should cost less than a high-confidence mismatch.
4. **Interpolate by syllable weight.** Weight interpolated words by syllable or character weight (as `estimate` already does) rather than evenly.

### 2c. Build an eval before anything else

1. Record ~20 takes: accents, ad-libs, a skipped paragraph, a restarted line.
2. Get reference word timings by running MFA on the Mac. It's dev-time only, so its licence doesn't ship; still check it.
3. Score three things: (a) % of caption onsets within 33/50/100 ms; (b) prompter lag, meaning the time from word spoken to cursor passing it; and (c) cursor errors on skips and restarts.
4. Run it for SFSpeech vs SpeechTranscriber vs Scribe v2. That turns "Pro accuracy" from a guess into a number.

---

## 3. Licensing summary for a paid iOS app

| Component | Licence | Commercial | Obligation |
|---|---|---|---|
| Apple Speech (SFSpeech / SpeechAnalyzer) | Apple SDK | yes | none |
| WhisperKit / Argmax OSS | MIT | yes | keep notice |
| Whisper weights | MIT [unverified] | yes | keep notice |
| FluidAudio SDK | Apache-2.0 | yes | notice |
| Parakeet TDT v3 | CC-BY-4.0 | yes | **attribution in app/credits** |
| Nemotron streaming | NVIDIA Open Model License | yes ("commercial/non-commercial") | read the licence terms |
| Moonshine | MIT | yes | notice |
| Kyutai STT | CC-BY 4.0 | yes | attribution |
| **MMS / MMS_FA** | **CC-BY-NC 4.0** | **no** | avoid |
| WhisperKit Pro | commercial subscription | yes | 1,000-licence/month minimum |
| Cloud APIs | provider ToS | yes | disclose third-party AI processing (App Store 5.1.2(i)) |

---

## 4. As an in-app purchase

**Product shape.**

- **Guideline 3.1.1.** Unlocking features requires IAP, and "credits… may not expire". Consumable minute packs therefore become an open-ended liability.
- **Non-consumable.** A one-off unlock with unlimited cloud means unbounded cost.
- **Use an auto-renewing subscription** with a soft monthly cloud-minute cap. Guideline 3.1.2(a) requires ongoing value and a period of at least 7 days. The cloud service qualifies as ongoing value.
- **Precedent:** PromptSmart sells VoiceTrack languages as separate IAPs.

**What's in Pro.**

1. Cloud captions for languages Apple can't do (Icelandic, plus anything outside the 54 Dictation locales), via Scribe v2 batch.
2. Cloud live tracking for those languages, via Scribe v2 Realtime once Icelandic support there is confirmed. Otherwise use timed auto-scroll for live and cloud only for captions.
3. Optional "re-time with cloud" for any language. Keep it only if the §2c eval shows a measurable win.

**Privacy.**

- **Label.** Apple defines "collect" as data retained longer than "necessary to service the transmitted request in real time" [App Privacy Details]. ZDR or no-retention endpoints (OpenAI transcriptions; Deepgram with `mip_opt_out`) arguably aren't "collected". Scribe without enterprise ZRM probably is. **Conservative choice:** declare *Audio Data, App Functionality, not linked, not tracking*, and add `NSPrivacyCollectedDataTypeAudioData` to `PrivacyInfo.xcprivacy`.
- **Consent.** Regardless of the label, guideline 5.1.2(i) requires that you "clearly disclose where personal data will be shared with third parties, including with third-party AI, and obtain explicit permission". Show a one-time consent sheet that names the provider before the first cloud pass. Keep the free tier fully on-device.

**Unit cost per 3-minute take**, with 1 retake factored in by the user's choice:

| Route | Live pass | Caption pass | Per 3-min take |
|---|---|---|---|
| Scribe v2 RT + Scribe v2 batch | $0.0195 | $0.011 | **$0.031** |
| Captions only, Scribe v2 batch | — | $0.011 | **$0.011** |
| Captions only, AssemblyAI U-2 | — | $0.0075 | $0.0075 |
| Captions only, Workers AI Whisper turbo | — | $0.0015 | $0.0015 (word timing unverified) |

**Worked pricing:** "Cue Pro" at **$3.99/month or $29.99/year**.

- **Monthly plan.**
  - Revenue: $3.99 × 0.85 = **$3.39 net** (a 10% rate after year one appears on the Small Business Program page but the wording may tie it to EU alternative terms **[unverified]**).
  - Cap: 150 cloud-minutes/month.
  - Worst case at the cap, live + batch on Scribe: 150 × $0.0102 = **$1.53**, leaving $1.86 (55%).
  - Typical user: 10 videos × 2 takes × 2 min = 40 min, costing **$0.41**, leaving 88%.
- **Yearly plan.** Revenue: $29.99 × 0.85 = $25.49, or **$2.12/month**. Typical cost $0.41/month, so margin is fine. Use the same cap.
- **Fixed costs:** Cloudflare Workers paid plan (~$5/month **[not re-checked]**), plus the ElevenLabs plan minimum. PAYG exists; Starter is $6/month and appears to include 27 h of Scribe (the tier mapping is inferred from row order on the pricing page).
- **Conclusion:** cost isn't the constraint; the size of the Icelandic and other-languages market is.

**Abuse and cost controls (Cloudflare Worker proxy).**

1. Provider keys live only in Worker secrets.
2. **App Attest:**
   - Attest once per install and sign each request with `generateAssertion`. The Worker verifies the signature and that the counter is increasing.
   - Apple says to check `isSupported` and "gracefully bypass" on unsupported devices. Give those devices no cloud access, or a tiny quota.
   - Large apps need a gradual ramp. [Apple: Establishing your app's integrity]
3. **Entitlement:** send the StoreKit 2 signed `Transaction` JWS (`originalTransactionId`) with requests, verify it in the Worker against Apple's certificate chain, and key quotas by `originalTransactionId` in Durable Objects or KV.
4. **Limits:**
   - Hard per-take cap (e.g. 10 min of audio).
   - Per-day and per-month minute caps.
   - Reject audio longer than the take duration.
   - Compress before upload to AAC 16 kHz mono.
5. **Streaming:** the Worker mints short-lived provider tokens, if the provider supports single-use tokens **[check per provider]**, or proxies the WebSocket.

---

## 5. Feasibility and phased plan (solo dev)

| Phase | Work | Effort | Ships as |
|---|---|---|---|
| **0. Eval harness** | 20 labelled takes, MFA reference, a scoring script | 2–3 days | internal |
| **1. SpeechAnalyzer migration** | `SpeechTranscriber` live (volatile + fast results) and file pass (`audioTimeRange`, confidence). `DictationTranscriber` fallback with contextual strings. AssetInventory download UI. Drop the SFSpeech path once the eval passes | 1 week | free update |
| **2. Algorithm upgrades** | Tracker: structured tail, phonetic match, n-gram anchors, backward jumps, rate extrapolation. Aligner: energy-onset snapping, confidence weights, SpeechDetector bounds | 1 week | free update |
| **3. Cue Pro (cloud languages)** | CF Worker (App Attest + StoreKit JWS + quotas) and Scribe v2 batch captions. Consent sheet and privacy label update. Subscription with cap | 1–2 weeks | IAP |
| **4. Cloud live** | Scribe v2 Realtime over a WebSocket via the Worker, for Pro languages. Only if Icelandic RT is confirmed and phase 3 sells | 1 week | Pro feature |
| Later / maybe | Parakeet v3 via FluidAudio for European locales Apple handles badly, if the eval says so | 1–2 weeks | Pro feature |

**Risks.**

- **SpeechTranscriber accuracy.** Its accuracy and timestamp precision are unbenchmarked publicly, and contextual-strings support is unverified. The phase 0 eval mitigates this.
- **Icelandic demand.** The Icelandic market is tiny, so validate Pro demand before building phase 4.
- **ElevenLabs terms.**
  - Training defaults for non-enterprise accounts are unverified, and that is a privacy-copy risk.
  - Scribe v2 Realtime Icelandic coverage is unconfirmed.
- **OpenAI word timestamps.** They depend on `whisper-1`, which retires 2027-02-26, so don't build on it.
- **App Review.** Sending voice to third-party AI without explicit consent fails 5.1.2(i), and an undeclared Audio Data label is a rejection risk.

---

## Sources (all seen 2026-10-22)

- Local probe: Speech framework `supportedLocales` on macOS 26.6.2 (25G83). SDK interface `iPhoneOS27.1.sdk/.../Speech.swiftmodule/arm64e-apple-ios.swiftinterface`
- WWDC25-277 SpeechAnalyzer: https://developer.apple.com/videos/play/wwdc2025/277/
- SpeechTranscriber docs: https://developer.apple.com/documentation/speech/speechtranscriber
- AnalysisContext.contextualStrings: https://developer.apple.com/documentation/speech/analysiscontext/contextualstrings
- WhisperKit: https://github.com/argmaxinc/WhisperKit · benchmarks: https://github.com/argmaxinc/WhisperKit/blob/main/BENCHMARKS.md · Argmax pricing: https://www.argmaxinc.com/pricing
- FluidAudio: https://github.com/FluidInference/FluidAudio
- speech-swift (MLX/Core ML model zoo): https://github.com/soniqo/speech-swift
- Parakeet TDT 0.6B v3: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Nemotron streaming: https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
- Moonshine streaming medium: https://huggingface.co/UsefulSensors/moonshine-streaming-medium
- Kyutai STT: https://huggingface.co/kyutai/stt-1b-en_fr
- BuzzASR Icelandic: https://huggingface.co/BuzzASR/icelandic (via search)
- Open ASR Leaderboard (live Space would not render): https://huggingface.co/spaces/hf-audio/open_asr_leaderboard. Secondary: https://www.appen.com/blog/hugging-face-open-llm-leaderboard, https://www.llmreference.com/benchmark/wer-open-asr
- ElevenLabs API pricing: https://elevenlabs.io/pricing/api · STT docs: https://elevenlabs.io/docs/overview/capabilities/speech-to-text · models: https://elevenlabs.io/docs/overview/models · ZRM: https://elevenlabs.io/docs/developers/resources/zero-retention-mode · competitor claim on training: https://deepgram.com/learn/how-elevenlabs-uses-your-audio-data
- Deepgram pricing: https://deepgram.com/pricing · languages: https://developers.deepgram.com/docs/models-languages-overview · MIP: https://developers.deepgram.com/docs/the-deepgram-model-improvement-partnership-program
- AssemblyAI pricing: https://www.assemblyai.com/pricing · languages: https://www.assemblyai.com/docs/pre-recorded-audio/supported-languages
- OpenAI pricing: https://developers.openai.com/api/docs/pricing · STT guide: https://developers.openai.com/api/docs/guides/speech-to-text · data controls: https://developers.openai.com/api/docs/guides/your-data
- Cloudflare Workers AI Whisper turbo: https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/
- Speechmatics pricing: https://www.speechmatics.com/pricing · languages: https://docs.speechmatics.com/speech-to-text/languages
- Google Chirp 3: https://docs.cloud.google.com/speech-to-text/docs/models/chirp-3 · pricing (snippet only): https://cloud.google.com/speech-to-text/pricing
- Azure STT languages: https://learn.microsoft.com/en-us/azure/ai-services/speech-service/language-support?tabs=stt · pricing (unrendered): https://azure.microsoft.com/en-us/pricing/details/speech/
- Rousso et al., "Tradition or Innovation", Interspeech 2024: https://arxiv.org/html/2406.19363v1
- WhisperX: https://arxiv.org/abs/2303.00747, https://github.com/m-bain/whisperx
- NeMo Forced Aligner: https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/tools/nemo_forced_aligner.html
- torchaudio CTC forced alignment (removed in 2.9): https://docs.pytorch.org/audio/main/tutorials/ctc_forced_alignment_api_tutorial.html · MMS_FA licence: https://docs.pytorch.org/audio/main/generated/torchaudio.pipelines.MMS_FA.html
- Dixon, On-Line Time Warping, IJCAI 2005: https://webspace.eecs.qmul.ac.uk/s.e.dixon/pub/2005/ijcai05.pdf · Macrae & Dixon, ISMIR 2010: https://webspace.eecs.qmul.ac.uk/s.e.dixon/pub/2010/Macrae-Dixon-ISMIR-2010-WindowedTimeWarping.pdf
- PromptSmart App Store listings: https://apps.apple.com/app/id1526733375, https://apps.apple.com/app/id894811756
- App Store Review Guidelines (3.1.1, 3.1.2(a), 5.1.2(i), 2.5.14): https://developer.apple.com/app-store/review/guidelines/
- App Privacy Details: https://developer.apple.com/app-store/app-privacy-details/
- App Attest: https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity
- Small Business Program: https://developer.apple.com/app-store/small-business-program/
