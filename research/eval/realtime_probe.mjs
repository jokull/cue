// Streams raw 16 kHz mono PCM to ElevenLabs Scribe v2 Realtime at speaking pace and logs what
// comes back with arrival times — does it understand the language, and how fast are partials?
// dotenvx run -f .env -- node research/eval/realtime_probe.mjs audio.pcm is
import { readFileSync } from "node:fs";

const [file, language = "is"] = process.argv.slice(2);
const tokenResponse = await fetch("https://api.elevenlabs.io/v1/single-use-token/realtime_scribe", {
  method: "POST",
  headers: { "xi-api-key": process.env.ELEVENLABS_API_KEY },
});
const { token } = await tokenResponse.json();
if (!token) throw new Error(`token: ${tokenResponse.status}`);

const params = new URLSearchParams({
  model_id: "scribe_v2_realtime", token, language_code: language, audio_format: "pcm_16000",
  commit_strategy: "vad", include_timestamps: "true",
});
const socket = new WebSocket(`wss://api.elevenlabs.io/v1/speech-to-text/realtime?${params}`);
const pcm = readFileSync(file);
const chunk = 3200; // 100 ms of 16-bit mono at 16 kHz
const started = Date.now();
const at = () => ((Date.now() - started) / 1000).toFixed(2).padStart(6);

socket.onmessage = ({ data }) => {
  const message = JSON.parse(data);
  const text = message.text ?? message.error ?? "";
  console.log(`${at()}s  ${message.message_type.padEnd(36)} ${text.slice(0, 100)}`);
};
socket.onerror = (error) => console.log("error", error.message ?? error);
socket.onopen = async () => {
  for (let offset = 0; offset < pcm.length; offset += chunk) {
    socket.send(JSON.stringify({
      message_type: "input_audio_chunk",
      audio_base_64: pcm.subarray(offset, offset + chunk).toString("base64"),
      commit: offset + chunk >= pcm.length,
      sample_rate: 16000,
    }));
    await new Promise((resolve) => setTimeout(resolve, 100)); // real time
  }
  setTimeout(() => socket.close(), 4000);
};
