/**
 * cue-api — Cue's speech, on ElevenLabs Scribe. Holds the API key so the app never ships it.
 *
 * POST /v1/realtime-token   → { token }   single-use, one WebSocket session, valid 15 min;
 *                                         the app connects to Scribe v2 Realtime directly.
 * POST /v1/transcribe?language=is&keyterm=…   body: the take's audio (audio/mp4)
 *                           → { language, words: [{ text, start, end, logprob }] }
 *
 * All routes need `Authorization: Bearer <app token>`. Audio is never stored here.
 */

const MAX_BYTES = 25 * 1024 * 1024; // ~25 min of AAC at Cue's export bitrate
const SCRIBE = "https://api.elevenlabs.io/v1/speech-to-text";
const TOKENS = "https://api.elevenlabs.io/v1/single-use-token";

interface ScribeWord {
	text: string;
	start: number;
	end: number;
	type: "word" | "spacing" | "audio_event";
	logprob?: number;
}

export default {
	async fetch(request, env): Promise<Response> {
		const url = new URL(request.url);
		if (request.method === "GET" && url.pathname === "/health") return json({ ok: true });
		const routes = ["/v1/transcribe", "/v1/realtime-token"];
		if (request.method !== "POST" || !routes.includes(url.pathname)) return json({ error: "not found" }, 404);

		if (!authorized(request, env.CUE_API_TOKEN)) return json({ error: "unauthorized" }, 401);
		const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
		if (!(await env.TRANSCRIBE_LIMIT.limit({ key: ip })).success) return json({ error: "slow down" }, 429);

		if (url.pathname === "/v1/realtime-token") {
			const response = await fetch(`${TOKENS}/realtime_scribe`, {
				method: "POST",
				headers: { "xi-api-key": env.ELEVENLABS_API_KEY },
			});
			if (!response.ok) {
				console.error("token failed", response.status, await response.text());
				return json({ error: "token unavailable" }, 502);
			}
			const { token } = (await response.json()) as { token: string };
			return json({ token });
		}

		const length = Number(request.headers.get("content-length") ?? 0);
		if (!length || length > MAX_BYTES) return json({ error: "audio missing or too large" }, 413);
		const language = url.searchParams.get("language") ?? "";
		if (language && !/^[a-z]{2,3}$/.test(language)) return json({ error: "bad language" }, 400);

		const form = new FormData();
		form.append("model_id", "scribe_v2");
		form.append("timestamps_granularity", "word");
		form.append("tag_audio_events", "false");
		if (language) form.append("language_code", language);
		// The script's rare words (names, compounds): ≤1000 terms, <50 chars each.
		for (const term of url.searchParams.getAll("keyterm").slice(0, 100)) {
			if (term.length < 50 && !/[<>{}\[\]\\]/.test(term)) form.append("keyterms", term);
		}
		const type = request.headers.get("content-type") ?? "audio/mp4";
		form.append("file", new Blob([await request.arrayBuffer()], { type }), "take.m4a");

		const started = Date.now();
		const response = await fetch(SCRIBE, {
			method: "POST",
			headers: { "xi-api-key": env.ELEVENLABS_API_KEY },
			body: form,
		});
		if (!response.ok) {
			console.error("scribe failed", response.status, await response.text());
			return json({ error: "transcription failed" }, 502);
		}
		const result = (await response.json()) as { language_code?: string; words?: ScribeWord[] };
		const words = (result.words ?? [])
			.filter((word) => word.type === "word")
			.map(({ text, start, end, logprob }) => ({ text, start, end, logprob }));
		console.log("transcribed", { language: result.language_code, words: words.length, ms: Date.now() - started, bytes: length });
		return json({ language: result.language_code, words });
	},
} satisfies ExportedHandler<Env>;

/** Constant-time comparison so the token can't be guessed byte by byte. */
function authorized(request: Request, token: string): boolean {
	const header = request.headers.get("authorization") ?? "";
	const given = new TextEncoder().encode(header.replace(/^Bearer /, ""));
	const expected = new TextEncoder().encode(token);
	if (!token || given.length !== expected.length) return false;
	let difference = 0;
	for (let i = 0; i < given.length; i++) difference |= given[i] ^ expected[i];
	return difference === 0;
}

function json(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}
