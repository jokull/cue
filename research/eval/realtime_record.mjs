// Streams 16 kHz mono PCM to Scribe v2 Realtime at speaking pace and records every message with
// its arrival time relative to the first audio sample, for the prompter-lag replay.
// dotenvx run -f .env -- node research/eval/realtime_record.mjs audio.pcm out.json [language] [key=value ...]
import { readFileSync, writeFileSync } from "node:fs";

const [file, out, language = "is", ...extra] = process.argv.slice(2);
// Optional hints JSON (from `tracklag hints script.txt`): previous_text + keyterms.
const hintsArg = extra.find((pair) => pair.startsWith("hints="));
const hints = hintsArg ? JSON.parse(readFileSync(hintsArg.slice(6), "utf8")) : {};
const rest = extra.filter((pair) => pair !== hintsArg);
const tokenResponse = await fetch("https://api.elevenlabs.io/v1/single-use-token/realtime_scribe", {
  method: "POST",
  headers: { "xi-api-key": process.env.ELEVENLABS_API_KEY },
});
const { token } = await tokenResponse.json();
const params = new URLSearchParams({
  model_id: "scribe_v2_realtime", token, language_code: language, audio_format: "pcm_16000",
  commit_strategy: "vad", include_timestamps: "true",
  ...Object.fromEntries(rest.map((pair) => pair.split("="))),
});
for (const term of hints.keyterms ?? []) params.append("keyterms", term);
const chunkMs = Number(params.get("chunk_ms") ?? 100);
params.delete("chunk_ms");
const socket = new WebSocket(`wss://api.elevenlabs.io/v1/speech-to-text/realtime?${params}`);
const pcm = readFileSync(file);
const chunk = 32 * chunkMs; // bytes: 16-bit mono at 16 kHz = 32 bytes/ms
const messages = [];
let audioStart = 0;

socket.onmessage = ({ data }) => {
  const message = JSON.parse(data);
  messages.push({ at: audioStart ? (performance.now() - audioStart) / 1000 : 0, ...message });
};
socket.onopen = async () => {
  audioStart = performance.now();
  for (let offset = 0, i = 0; offset < pcm.length; offset += chunk, i++) {
    socket.send(JSON.stringify({
      message_type: "input_audio_chunk",
      audio_base_64: pcm.subarray(offset, offset + chunk).toString("base64"),
      commit: offset + chunk >= pcm.length,
      sample_rate: 16000,
      ...(i === 0 && hints.previous_text ? { previous_text: hints.previous_text } : {}),
    }));
    // Pace against the clock, not with fixed sleeps, so sends don't drift late.
    const due = audioStart + (i + 1) * chunkMs;
    await new Promise((resolve) => setTimeout(resolve, Math.max(0, due - performance.now())));
  }
  setTimeout(() => socket.close(), 5000);
};
socket.onclose = () => {
  writeFileSync(out, JSON.stringify({ params: Object.fromEntries([...params].filter(([k]) => k !== "token")), hints, chunkMs, messages }, null, 1));
  const partials = messages.filter((m) => m.message_type === "partial_transcript");
  console.log(`${out}: ${partials.length} partials, first at ${partials[0]?.at.toFixed(2)}s, ${messages.filter((m) => m.message_type.startsWith("committed")).length} commits`);
};
