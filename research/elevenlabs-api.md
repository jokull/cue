# ElevenLabs API brief for Cue

Researched 2026-10-22 against the live docs (`elevenlabs.io/docs/*.md`, `elevenlabs.io/pricing/api`, changelog through 2026-10-19). Source keys like `[rt-api]` are listed with URLs at the bottom. **[probe]** = verified by a request I ran today (see §9). **[unconfirmed]** = not documented and not tested.

## TL;DR

1. **Live tracking:** Scribe v2 Realtime (`wss://api.elevenlabs.io/v1/speech-to-text/realtime`), connected straight from the iPhone with a `realtime_scribe` single-use token minted by the Worker. Use `language_code=is`, `audio_format=pcm_16000`, `commit_strategy=vad`, `vad_silence_threshold_secs=0.5`, and `previous_text` set to the first ≤50 chars of the script. Add `keyterms` (≤50 rare script words, ≤20 chars each). Track position by matching **partial text** against the script on the client. Partials carry no timings.
2. **Never commit manually mid-speech.** In my probe, a manual commit every 4 s made the Icelandic output much worse: repeated phrases and invented words. VAD only commits at real pauses, and that is fine.
3. **`previous_text` + `keyterms` made a big difference on Icelandic partials [probe].** Without them, the opening words came out as "Jú, einhver klúðrastarfa…" for the first ~6 s. With either one, the very first partial read "Jökull, þú starfar í…".
4. **Caption timing:** keep batch `scribe_v2` with `timestamps_granularity=word`, plus `keyterms` from the script, then align its words to the script in our own code. **Don't use Forced Alignment.** Its docs don't list Icelandic, and it does no better than Scribe's timings: on a clean read its word timings matched Scribe's to within 20 ms [probe]. It also breaks as soon as the text differs from what was said: unread script words get stacked, zero-length timings, and a restarted line is lost [probe].
5. **Worker endpoints to add:** `POST /v1/realtime-token` and, optionally, `POST /v1/batch-token`. With a `batch_scribe` token the app can upload directly and skip the Worker's 25 MB cap. Also scope the API key to STT only and give it a credit quota.
6. **Cost per 3-minute take:** realtime $0.0195 + keyterms $0.004 + batch $0.011 + batch keyterms $0.0025 ≈ **$0.04**. Silence is billed too, so close the socket when recording stops.
7. **Plan:** the account is on the **free** tier [probe]: 6 concurrent realtime sessions and 2.5 h of realtime included. Upgrade before shipping. Zero Retention Mode is enterprise-only: the server ignored `enable_logging=false` and sent a warning [probe]. Turn off "Improve the models for everyone" in the dashboard (I did not touch it).
8. **No official Swift STT SDK.** `elevenlabs-swift-sdk` only covers Conversational AI, so build the client on `URLSessionWebSocketTask` with hand-written JSON.

---

## 1. Realtime STT (Scribe v2 Realtime)

**Endpoint:** `GET wss://api.elevenlabs.io/v1/speech-to-text/realtime`. Regional hosts: `api.us.elevenlabs.io`, and `api.eu|in|sg.residency.elevenlabs.io`, which are enterprise-only. Auth is either the `xi-api-key` header or a `token` query param [rt-api][residency].

### Query params [rt-api][rt-commit][py-scribe]

| Param | Values / limits | Notes |
|---|---|---|
| `model_id` | `scribe_v2_realtime` (only value) | |
| `token` | `sutkn_…` | Single-use token; see §2. |
| `audio_format` | `pcm_8000`, `pcm_16000` (default, recommended), `pcm_22050`, `pcm_24000`, `pcm_44100`, `pcm_48000`, `ulaw_8000` | 16-bit LE mono only [rt-commit]. |
| `language_code` | ISO-639-1 or -3; empty = auto-detect | `is` works [probe]. Batch *returns* `isl` [probe]. |
| `secondary_languages` | repeated param | Restricts language ID to a set of languages [py-scribe]. |
| `commit_strategy` | `manual` (default), `vad`, `turn_prediction` | `turn_prediction` is rejected for `scribe_v2_realtime`: `invalid_request`, close 1008 [probe][cl-2026-10-12]. |
| `vad_silence_threshold_secs` | API 0.192–3.0; JS/Py SDKs 0.3–3.0; default 1.5 | 0.2 accepted [probe]. |
| `vad_threshold` | 0.1–0.9, default 0.4 (lower = more sensitive) | [js-scribe] |
| `min_speech_duration_ms` | 50–2000, default 100 | [js-scribe] |
| `min_silence_duration_ms` | 50–2000, default 100 | [js-scribe] |
| `include_timestamps` | bool, default false | Adds the `committed_transcript_with_timestamps` event. |
| `include_language_detection` | bool, default false | Also arrives via `committed_transcript_with_timestamps` (`language_code`) [rt-events]. |
| `keyterms` | repeated param; max 50, ≤20 chars each | Billed extra (§7) [keyterm][cl-2026-4-27]. |
| `no_verbatim` | bool | Strips fillers, false starts and disfluencies. |
| `entity_detection` | `all` / category / list | Emits `committed_transcript_entities`. |
| `transcript_edit` | string ≤2000 chars | Emits `edited_transcript`. Adds 30%, with a 10 s minimum per commit [py-scribe]. |
| `filter_background_audio` | bool | VAD ignores background speech, and `vad_threshold` defaults to 0.15. **Cannot be combined with `include_timestamps`**: you get `invalid_request` and close 1008 [rt-commit][probe]. The ignored audio is still billed. |
| `keepalive_interval_ms` | 500–10000 | Server resends the last partial (or an empty one) once per interval, but only while you keep sending audio [rt-commit]. |
| `enable_logging` | bool, default true | `false` means ZRM, enterprise only. Non-enterprise keys get a `warning` and the session is still logged [probe]. |

`session_started.config` echoes back the settings plus one undocumented field, `max_tokens_to_recompute: 5`. The `disable_logging` key appeared in the echo [probe].

### Client → server [rt-api]

There is one message type, `input_audio_chunk`:

```json
{"message_type":"input_audio_chunk","audio_base_64":"…","commit":false,"sample_rate":16000,"previous_text":"…"}
```

- `previous_text` is accepted **only on the first chunk**. Sending it later is an error. It works best under 50 chars [rt-commit].
- Setting `commit:true` on a chunk is how you commit manually. There is no separate commit message.
- Chunk size: 0.1–1 s [rt-commit]. Above some unknown maximum you get `chunk_size_exceeded` [unconfirmed max].

### Server → client [rt-api][rt-events]

- `session_started` `{session_id, config}`
- `partial_transcript` `{text}`: the text of the whole uncommitted segment. Each partial **replaces** the previous one. It carries **no words or timings**: in the probe, partials had no fields beyond `text`.
- `committed_transcript` `{text}`: final text for the segment.
- `committed_transcript_with_timestamps` `{text, language_code, words[]}`. Each word has `text`, `start`, `end`, `type` (`word`/`spacing`), `speaker_id`, `logprob` and `characters[]` with timings [probe]. Times are in seconds from the start of the session's audio. In the probe, the first word started at 1.58 s, and batch Scribe and Forced Alignment put it at 1.60 s.
- `committed_transcript_entities`, `edited_transcript`, `warning`.
- Errors (sent just before the socket closes): `error`, `auth_error`, `quota_exceeded`, `commit_throttled`, `unaccepted_terms`, `rate_limited`, `queue_overflow`, `resource_exhausted`, `session_time_limit_exceeded`, `input_error`, `invalid_request`, `chunk_size_exceeded`, `insufficient_audio_activity`, `transcriber_error`.

**Close codes.** None are documented. Observed: `invalid_request` → 1008; `auth_error` → 1000 [probe].

### Timing, keepalive, session limits

- Transcription starts only after the first ~2 s of audio [rt-commit]. Audio is processed in ~1 s chunks, so partials arrive about once per second [rt-commit]. That matches the earlier probe (first partial ~2.3 s) and today's (2.6 s). The advertised "~150 ms" latency excludes this buffering and the network [models].
- The server closes the socket after **15 s without any client message**, and this is not configurable. While paused, keep streaming silence; it is billed [rt-commit][stt].
- Without a manual commit, the model auto-commits after ~36 s of accumulated audio. ElevenLabs suggests committing every 20–30 s, but only during silence. "Committing manually several times in a short sequence can degrade model performance" [rt-commit].
- **Max session duration: [unconfirmed].** All that's documented is the `session_time_limit_exceeded` error ("start a new session or upgrade your subscription").
- **Reconnect guidance:** open a new socket and send `previous_text` with the first chunk, "using the previous text as guidance" [rt-commit]. Timestamps restart at 0 on each session, so keep an offset on the client.
- Concurrency per plan (realtime sessions): Free 6, Starter 9, Creator 15, Pro 30, Scale 45, Business 45, Enterprise elevated [models][stt-conc].

### What the probes showed (`rt-test.pcm`, Icelandic, 17 s)

| Config | Result |
|---|---|
| `vad`, `vad_silence_threshold_secs=0.2`, `min_silence_duration_ms=50` | One commit, at the only real pause (~1.1 s). Pauses of ~0.3 s did not trigger a commit. The opening partials were wrong ("Jú, einhver klúðrastarfa…") and only corrected themselves at the commit. |
| `manual`, `commit:true` every 4 s | **Accuracy fell apart.** Phrases repeated ("hefur þetta haft-- hefur þetta haft--"), words were invented ("kaupnaðarsetningum"), and one segment was duplicated. |
| `vad` 0.3 + `previous_text` (script's first sentence) | First partial "Jökull — þú starfar í…", stable after that. It copied the script's "—" into the transcript. |
| `vad` 0.3 + 5 `keyterms` | First partial "Jökull, þú starfar í…". Rare words (greiðslumiðlun, gagnaflutning) came through correctly. |
| `vad` 0.3 + both | Cleanest partials and commit. |

Across all runs, the **last few words of a partial were often made up** and replaced in the next partial (e.g. "…bein áhrif á það hvernig þú starfar?" became "…á rekstur ykkar"). The words near the start of a partial were stable.

### Best settings for following a known script

- `commit_strategy=vad`, `vad_silence_threshold_secs=0.5` (tune between 0.3 and 1.0), other VAD params at their defaults. That gives a commit per sentence and keeps partial strings short, without committing mid-speech. **Never** commit manually on a timer.
- `previous_text` = first ≤50 chars of the script. On reconnect, use the ≤50 script chars just before the current position.
- `keyterms` = up to 50 of the script's rarest words that fit in 20 chars (names, compounds). Costs +$0.08/h.
- `include_timestamps=true`. It's cheap and gives provisional per-word timings on each commit. That rules out `filter_background_audio`.
- `no_verbatim=false`. A false start is a signal for the tracker to jump back. Drop fillers like "uh" on the client.
- Tracker rule: advance only on words that have stayed the same across 2 partials, or that match the script within a forward window. Treat the last 2–3 words of a partial as unreliable.
- `keepalive_interval_ms` isn't needed: Cue streams audio continuously, and `URLSessionWebSocketTask` has no idle timeout.
- Audio: tap AVAudioEngine and convert to 16 kHz mono Int16. Send 100 ms chunks (3200 bytes, base64).

## 2. Single-use tokens [token][rt-client][stt-api][cl-2026-7-20]

- `POST https://api.elevenlabs.io/v1/single-use-token/{token_type}` with header `xi-api-key`, no body. `token_type` is one of `realtime_scribe`, `batch_scribe`, `tts_websocket`.
- Response is `{"token":"sutkn_…"}`. Errors return 422 `{detail:[…]}`.
- Tokens expire **15 minutes** after minting and are "consumed on use". **One token = one connection:** reusing one gave `auth_error` and close 1000 [probe]. Whether 15 min is the deadline to *connect* or also caps the session is [unconfirmed]. Assume it's the deadline to connect.
- Scope: each token type only works for its own endpoint. A `batch_scribe` token goes in `POST /v1/speech-to-text?token=…`. Parameters are not baked into the token, so the client picks `model_id`, `language_code` and the rest.
- Rate limits for minting are [unconfirmed]. Put the Worker's own rate limiter in front of it.

## 3. Forced Alignment

- `POST https://api.elevenlabs.io/v1/forced-alignment`, multipart: `file` (required; "<1GB" per the API ref, "3 GB" per the capability page) and `text` (required, plain string, no diarization) [fa-api][fa].
- Response: `characters[{text,start,end}]`, `words[{text,start,end,loss}]`, `loss`. **The `words` array includes entries that are just spaces;** filter them out [probe].
- Limits: 10 h of audio and 675,000 chars of text [fa]. It costs the same as STT, $0.22/h [fa][pricing]. The response sets `character-cost: 15` for 13 s of audio [probe].
- **Languages:** the docs list only the 29 "multilingual v2" languages, and **Icelandic isn't one** [fa]. It still returned 200 on Icelandic [probe], but Icelandic is **not officially supported**.
- Probe results:
  - *Clean TTS read with the exact text:* word timings matched batch Scribe's to within 20 ms (mean 2 ms) across 33 words, and per-word `loss` was ~0.4–0.9. It is probably the same model underneath, so there is no gain over Scribe.
  - *Real take with ad-libs* (script "t.d." / "á" against spoken "til dæmis" / "í", plus an "uh"): substitutions still got plausible timings, with `loss` around 1–2. **Script words that were never spoken got `loss` 3.3–4.9** and were stretched across the trailing silence.
  - *Partial read with a restart* (12.9 s of audio against a 72-word script): the first 11 words were right (`loss` ≈1). After that, words got `loss` 2.6–7, many had zero duration and piled up at the same instant, and the restarted line was lost. Overall `loss` was 3.95.
- **Verdict for Cue:** FA needs the text that was *actually spoken*. Cue doesn't have that until STT has run, and once STT has run, Scribe's timings are already just as good. A `loss` above ~2.5 is a usable "not said" signal, but alignment against the Scribe transcript gives that more reliably. **Use batch `scribe_v2` + our own script alignment for captions.** FA could be a fallback for officially supported languages if Scribe mishears a lot, but nothing so far calls for it.

## 4. Batch STT (`scribe_v2`) [stt-api][stt]

`POST /v1/speech-to-text`, multipart. Query params: `token` (batch single-use token) and `enable_logging` (default true; `false` = ZRM, enterprise only).

Body fields:

- `model_id`: `scribe_v2` or `scribe_v2_medical`. `scribe_v1` was removed on 2026-07-09 [cl-2026-6-8].
- Input: `file` (min 100 ms, <5.0 GB [cl-2026-6-1]; the capability page still says 3 GB), **or** `source_url` (hosted URLs, YouTube, TikTok), **or** `cloud_storage_url` (deprecated, <2 GB). `file_format`: `pcm_s16le_16` or `other`; raw PCM has lower latency.
- `language_code`: ISO-639-1/3, auto-detected if omitted. The response's `language_code` is ISO-639-3 (`isl`).
- `timestamps_granularity`: `none` / `word` / `character`. With `character`, each word gets `characters[]`.
- `diarize`, `num_speakers` (≤32), `diarization_threshold` (≈0.22 default), `use_speaker_library`, `detect_speaker_roles` (+10%).
- `tag_audio_events`: bool; adds `(laughter)` and similar as `type:"audio_event"`.
- `use_multi_channel` (≤5 channels, each billed separately) and `multichannel_output_style` (`separate` / `combined`).
- `keyterms`: ≤1000 terms, each <50 chars and ≤5 words; `<>{}[]\` not allowed. Costs +20%, and with more than 100 terms the minimum bill is 20 s. Multipart accepts repeated fields or a JSON array [cl-2026-9-21].
- `no_verbatim`, `entity_detection`, `entity_redaction`, `entity_redaction_mode`, `transcript_edit` (≤2000 chars, +30%, not combinable with entities or multichannel), `additional_formats`.
- `temperature`: 0.0–2.0, usually 0 by default. `seed`: 0–2147483647, best-effort determinism.
- Async: `webhook=true` (returns 202 and posts the result to the webhooks set up under Developers → Webhooks, with HMAC or OAuth), `webhook_id`, `webhook_metadata` (JSON, ≤16 KB, depth 2) [webhooks].

Response: `language_code`, `language_probability`, `text`, `words[{text,type,logprob,start,end,speaker_id,characters,channel_index}]`, `transcription_id`, `audio_duration_secs`, `entities`, `edited_transcript`.

Transcripts are kept by default: `GET` / `DELETE /v1/speech-to-text/transcripts/{transcription_id}` [stt-get][stt-del].

Limits: 10 h per file (the multichannel limit is given as both "<10 h combined" and "1 h" — the docs contradict themselves). Batch concurrency: Free 8, Starter 12, Creator 20, Pro 40, Scale/Business 60 [stt][stt-conc]. Files over 8 min are split into chunks and processed in parallel [stt].

**For Cue, add `keyterms`** (the script's rare words) and `timestamps_granularity=word` (already set). Pass `logprob` through to the app so alignment can weight by confidence. `tag_audio_events=false` and `diarize=false` are already right.

## 5. Other endpoints

- **Voice Isolator** (`POST /v1/audio-isolation`, plus `/v1/audio-isolation/stream`). Multipart `audio` and optional `file_format`. Files up to 500 MB / 1 h, audio or video. **$0.12/min**, which is ~11× the cost of batch STT. No language restriction is documented, and Voice Isolator isn't in the ZRM product table. The output audio format isn't documented [iso][iso-api][pricing][zrm]. *Fit:* an optional "Clean audio" export toggle for noisy takes. It's too expensive to run on every take. Re-mux the result with the video on the device.
- **Voice Changer** (`POST /v1/voice-changer/{voice_id}`, formerly `speech-to-speech`). Max 5 min per request. `model_id` is `eleven_multilingual_sts_v2`, and the 29 listed languages don't include Icelandic. Also takes `remove_background_noise`, `output_format`, `seed`, `voice_settings`. $0.12/min [vc][vc-api][pricing]. *Fit:* none for a teleprompter, and it changes who the speaker is.
- **Dubbing** (`POST /v1/dubbing/project`). Takes `file` (≤3 GiB) or `source_url`, plus `source_language`, `target_language`, `model_id` (`dubbing_v2` default, or `dubbing_v1`), `keyterms`, `webhook_ids`, and `transcript` (bring your own; enterprise only). Icelandic `is` is supported in both v1 and v2. The translated transcript (`GET …/language/{id}/transcript`) is **per segment only** (`start_s`, `end_s`, `source_text`, `translation`), so word-level translated captions would need a batch STT pass on the dubbed audio. Price: **$2.20/min for v2** and $0.33/min for v1 per the pricing cards, while the pricing FAQ says "$0.33–$0.50"; the two conflict. You pay per source minute per target language, the first language is charged when the project is created, free-tier dubs carry a watermark, and v2 transcript editing via the API is enterprise-only. Dubbing is not ZRM-eligible [dub][dub-api][dub-tt][dub-cost][dub-plans][pricing][zrm]. *Fit:* a promising later feature ("post this in English in your own voice"), but it costs 5–8× the rest of the pipeline per minute. Charge for it separately.
- **Text to Speech.** `eleven_v4` ($0.08 per 1k chars, ≤10,000 chars) and `eleven_v4_turbo` ($0.04 per 1k) both list Icelandic. Flash v2.5's 32 languages don't. `/v1/text-to-speech/{voice_id}/with-timestamps` returns character timings [models][pricing][tts-ts]. *Fit:* a "hear your script" rehearsal mode, and synthetic test takes for the eval harness, which is already used that way.
- **SDKs.** The official REST SDKs are Python and JS only [libs]. The Swift SDK (`elevenlabs/elevenlabs-swift-sdk`, v3.4.0, 2026-09-29) is described as a "Conversational AI Swift SDK". Its source tree has no Scribe or STT code, only Agents and a token service [swift]. **There is no official iOS realtime STT client.** The JS `@elevenlabs/client` `Scribe` class is a useful reference for the protocol.

## 6. Language support (Icelandic)

| Capability | Icelandic | Evidence |
|---|---|---|
| `scribe_v2` batch | **Yes, "Excellent (≤5% WER)" tier** | [stt] language breakdown lists "Icelandic (isl)" under Excellent; near-verbatim in our eval |
| `scribe_v2_realtime` | **Yes, but no separate accuracy tier is published** | [models] links realtime to the same 90+ list; works [probe] |
| Forced Alignment | **Not listed** (only the 29 multilingual-v2 languages). Returned 200 with sensible timings on a clean read [probe] | [fa] |
| Voice Isolator | No language list (the feature is language-agnostic) | [iso] |
| Voice Changer | Not listed (29 languages) | [vc] |
| Dubbing v1 / v2 | Yes (`is`) | [dub] |
| TTS v4 / v4 Turbo / v3 | Yes (`is`) | [models] |

## 7. Pricing, plans, data

API list prices are the same on every tier; tiers differ in how much is included [pricing]:

| Item | Price |
|---|---|
| Scribe v2 / v2 Medical (batch) | $0.22/h; keyterms +$0.05/h; transcript_edit +$0.07/h |
| Scribe v2 Realtime | $0.39/h; keyterms +$0.08/h; transcript_edit +$0.12/h |
| Forced Alignment | same as STT [fa] |
| Voice Isolator / Voice Changer | $0.12/min |
| Dubbing v1 / v2 | $0.33/min / $2.20/min (FAQ conflicts, see §5) |
| TTS v4 / v4 Turbo | $0.08 / $0.04 per 1k chars |

The keyterm surcharges work out to 20% of the base price ($0.22→$0.05, $0.39→$0.08), which matches the API ref's "+20%" [stt-api].

- **Plans** (monthly price; batch STT hours included / realtime hours included): Free $0 (4.5 h / 2.5 h), Starter $6 (27 / 15), Creator $22 (100 / 56), Pro $99 (450 / 254), Scale $299 (1359 / 767), Business $990 (4500 / 2538) [pricing].
- **Concurrency** (batch / realtime): Free 8/6, Starter 12/9, Creator 20/15, Pro 40/30, Scale and Business 60/45 [models]. A Free account on PAYG is limited to Starter-level concurrency [payg]. Responses carry `current-concurrent-requests` and `maximum-concurrent-requests` headers [models], but these weren't present on the Forced Alignment responses [probe].
- **Overage:** new self-serve accounts have no overage billing. They use **PAYG prepaid top-ups**: minimum $5, optional auto top-up, and service **pauses at $0**. Without 2FA there's a monthly top-up cap ($100 on Free–Creator). Usage-based billing is legacy-only [payg][billing].
- **Billing basis:** STT bills "every second of audio you send, including pauses and silent stretches", for both batch and realtime [stt]. So realtime bills **audio time sent, not wall-clock session time**. A socket kept open with silence frames is billed. `filter_background_audio` does not reduce the bill [rt-commit].
- **Retention:** by default, history and retention are on for STT input and output. You can delete through the API, but backups keep data for up to 30 days, and debug and moderation logs may keep it longer. ZRM (`enable_logging=false`) is enterprise-only [zrm][probe]. Data residency is enterprise-only too [residency].
- **Training:** non-enterprise data *is* used to improve the models by default. The opt-out is the dashboard toggle Profile → Terms and privacy → Data use → "Improve the models for everyone". Enterprise data isn't trained on by default [data-use].
- **Key hygiene:** API keys can be limited to specific endpoints, given a credit quota, and IP-allowlisted [keys]. Give the Worker's key STT and single-use-token scope only, with a monthly credit quota.

## 8. Recommendation for Cue

**Architecture**

```
record ──► AVAudioEngine tap ─► 16 kHz Int16 ─► WSS scribe_v2_realtime (token from Worker)
                                                   partial_transcript ─► script tracker (client)
stop   ──► close socket
       ──► export m4a (audio only) ─► batch scribe_v2 (Worker proxy or batch_scribe token)
                                       words[] ─► align to script (client) ─► burn captions
```

**Realtime URL**

```
wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&token=…
  &language_code=is&audio_format=pcm_16000&commit_strategy=vad&vad_silence_threshold_secs=0.5
  &include_timestamps=true&keyterms=…(≤50, ≤20 chars)
```

The first chunk carries `previous_text` (≤50 chars of script). Chunks are 100 ms with `commit:false`. When recording ends, send one last chunk with `commit:true`, wait for `committed_transcript`, then close.

**Batch:** `model_id=scribe_v2`, `language_code`, `timestamps_granularity=word`, `tag_audio_events=false`, `keyterms` = the script's rare words (≤1000, <50 chars, ≤5 words each). Afterwards, optionally `DELETE /v1/speech-to-text/transcripts/{id}`.

**Worker changes** (`api/src/index.ts`):

1. `POST /v1/realtime-token`: bearer auth + `TRANSCRIBE_LIMIT`. It calls `POST /v1/single-use-token/realtime_scribe` and returns `{token}`. The app must mint a token right before each connect, including every reconnect.
2. Optional `POST /v1/batch-token` (`batch_scribe`). The app then uploads straight to `/v1/speech-to-text?token=…`, which removes the 25 MB cap and the Worker's request-size and CPU limits on long takes.
3. If `/v1/transcribe` stays: accept `keyterms` (e.g. a JSON query param or a header) and forward them, return `logprob`, then delete the transcript after reading it.
4. Give the key STT and token scope only, with a credit quota. Never let it reach the app.

**Gotchas**

- Partials have no timings, and their last few words are guesses. Match the stable start of each partial to the script.
- Never commit on a timer (it breaks accuracy, see §1).
- Committing resets the partial text to the new segment. The tracker has to keep committed text and the live partial as separate buffers.
- `filter_background_audio` ⟂ `include_timestamps`.
- `previous_text` is first-chunk-only and can leak script punctuation ("—") into the transcript.
- The server drops the socket after 15 s with no client messages. Keep sending silence frames while recording is paused, or close and reconnect.
- Timestamps restart at 0 on each session, so add an offset after a reconnect.
- Batch returns `isl` while the request uses `is`. Normalize language codes.
- Forced Alignment's `words[]` includes entries that are just spaces.
- The free tier allows 6 realtime sessions at once and 2.5 h of realtime a month. Upgrade before beta. PAYG pauses the service at a $0 balance.
- Token minting has no documented rate limit, and the max session length is undocumented. Test a 15+ minute take before launch.

## 9. Probes run (2026-10-22, key from `~/Code/cue/.env`)

Scripts are in the session scratchpad, not the repo. Nothing in the repo or the account was changed.

- `GET /v1/user/subscription` → `tier: free`.
- `POST /v1/forced-alignment` ×3: `smoke-is.tts.mp3` + `smoke-is.txt`; `device/D466….mp4` audio + `.txt`; `device/784DC44B….mp4` audio + `.txt` (≈43 s of audio in total).
- Realtime WebSocket ×9 on `rt-test.pcm` (17.4 s) or a 3 s slice of it: `turn_prediction`; `enable_logging=false`; `filter_background_audio` + `include_timestamps`; token reuse; VAD at 0.2; manual commit every 4 s; `previous_text` + `keyterms`; `previous_text` only; `keyterms` only (≈110 s of audio in total).
- Approximate spend: FA ≈ $0.003, realtime ≈ $0.012, keyterm surcharges < $0.001 → **≈ $0.02**. On the free tier this came out of included quota.

## Unconfirmed / conflicting

- Max realtime session duration and how it depends on plan.
- Rate limits for minting single-use tokens; whether the 15-minute expiry also caps a session that's already open.
- Maximum realtime chunk size.
- Realtime WebSocket close codes (only 1008 and 1000 were observed).
- Forced Alignment's file limit (1 GB in the API ref vs 3 GB on the capability page) and its Icelandic support (works but isn't listed).
- Batch file limit (5 GB per the API ref and changelog vs 3 GB on the capability page); multichannel duration (10 h vs 1 h).
- Dubbing price (cards say $0.33 for v1 and $2.20 for v2; the FAQ says $0.33/$0.50).
- Voice Isolator's output format and whether it can use ZRM.
- No accuracy tier is published for Icelandic on the realtime model.

## Sources (all fetched 2026-10-22)

- [rt-api] https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
- [rt-commit] https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies
- [rt-events] https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference
- [rt-client] https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/client-side-streaming
- [js-scribe] https://elevenlabs.io/docs/eleven-api/resources/libraries/scribe-stt/javascript-scribe
- [py-scribe] https://github.com/elevenlabs/elevenlabs-python/blob/main/src/elevenlabs/realtime/scribe.py
- [token] https://elevenlabs.io/docs/api-reference/tokens/create
- [stt] https://elevenlabs.io/docs/overview/capabilities/speech-to-text
- [stt-api] https://elevenlabs.io/docs/api-reference/speech-to-text/convert
- [stt-get] https://elevenlabs.io/docs/api-reference/speech-to-text/get
- [stt-del] https://elevenlabs.io/docs/api-reference/speech-to-text/delete
- [stt-conc] https://elevenlabs.io/docs/help-center/product/core-capabilities/speech-to-text/how-many-speech-to-text-requests-can-i-make-and-can-i-increase-it
- [keyterm] https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/keyterm-prompting
- [webhooks] https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/batch/webhooks
- [models] https://elevenlabs.io/docs/overview/models
- [fa] https://elevenlabs.io/docs/overview/capabilities/forced-alignment
- [fa-api] https://elevenlabs.io/docs/api-reference/forced-alignment/create
- [iso] https://elevenlabs.io/docs/overview/capabilities/voice-isolator
- [iso-api] https://elevenlabs.io/docs/api-reference/audio-isolation/convert · https://elevenlabs.io/docs/api-reference/audio-isolation/stream
- [vc] https://elevenlabs.io/docs/overview/capabilities/voice-changer
- [vc-api] https://elevenlabs.io/docs/api-reference/speech-to-speech/convert
- [dub] https://elevenlabs.io/docs/overview/capabilities/dubbing
- [dub-api] https://elevenlabs.io/docs/api-reference/dubbing/create-project
- [dub-tt] https://elevenlabs.io/docs/api-reference/dubbing/target-transcript/get-target-transcript
- [dub-cost] https://elevenlabs.io/docs/help-center/product/dubbing/how-much-does-dubbing-cost
- [dub-plans] https://elevenlabs.io/docs/help-center/product/dubbing/on-which-plans-can-i-use-dubbing
- [tts-ts] https://elevenlabs.io/docs/api-reference/text-to-speech/convert-with-timestamps
- [libs] https://elevenlabs.io/docs/eleven-api/resources/libraries
- [swift] https://elevenlabs.io/docs/eleven-agents/libraries/swift · https://github.com/elevenlabs/elevenlabs-swift-sdk
- [pricing] https://elevenlabs.io/pricing/api
- [billing] https://elevenlabs.io/docs/overview/administration/billing
- [payg] https://elevenlabs.io/docs/overview/administration/pay-as-you-go
- [zrm] https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode
- [data-use] https://elevenlabs.io/docs/help-center/legal/is-my-data-used-to-improve-eleven-labs-ai-models
- [residency] https://elevenlabs.io/docs/overview/administration/data-residency
- [keys] https://elevenlabs.io/docs/overview/administration/workspaces/api-keys
- [cl-YYYY-M-D] https://elevenlabs.io/docs/changelog/YYYY/M/D (used: 2026/4/27, 2026/6/1, 2026/6/8, 2026/7/20, 2026/9/21, 2026/10/12)
