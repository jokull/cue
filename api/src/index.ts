/**
 * cue-api — Cue's speech, on ElevenLabs Scribe. Holds the API key so the app never ships it.
 *
 * POST /v1/realtime-token   → { token }   single-use, one WebSocket session, valid 15 min;
 *                                         the app connects to Scribe v2 Realtime directly.
 * POST /v1/transcribe?language=is&keyterm=…   body: the take's audio (audio/mp4)
 *                           → { language, words: [{ text, start, end, logprob }] }
 *
 * All routes need `Authorization: Bearer <app token>`, and — when REQUIRE_SUBSCRIPTION is on — a
 * current Cue Voice subscription: `X-Cue-Transaction: <StoreKit signed transaction>`. Use is metered
 * per subscription per month (fair use, so a year of the heaviest use still costs less than the
 * subscription brings in). Only App Store (Production) purchases count; TestFlight and sandbox
 * builds use `Bearer <dev token>`, which skips both, as do eval scripts and the Simulator.
 * Audio is never stored here.
 */

import { verifyTransaction } from "./apple";
import { mp4Duration } from "./duration";

/** A take is capped at 3 minutes; the app's M4A export runs ~245 kbps, so ~5.5 MB. */
const MAX_BYTES = 8 * 1024 * 1024;
/** 3 minutes plus slack for the export's padding. */
const MAX_TAKE_SECONDS = 200;
const SCRIBE = "https://api.elevenlabs.io/v1/speech-to-text";
const TOKENS = "https://api.elevenlabs.io/v1/single-use-token";

const BUNDLE_ID = "is.solberg.cue";
const PRODUCTS = ["is.solberg.cue.voice.yearly"];
/** A lapsed renewal keeps working this long, for Apple's billing retry. */
const GRACE_MS = 3 * 24 * 3600 * 1000;
/** Per subscription per month. Realtime sessions are one per recorded clip; take audio is
 *  transcribed once per finished take. At list prices the cap is ~$2/month of ElevenLabs. */
const MONTHLY = { sessions: 300, takeSeconds: 3 * 3600, transcribes: 150 };

interface Usage {
	sessions: number;
	takeSeconds: number;
	transcribes: number;
}

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

		const developer = authorized(request, env.CUE_DEV_TOKEN);
		if (!developer && !authorized(request, env.CUE_API_TOKEN)) return json({ error: "unauthorized" }, 401);
		const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
		if (!(await env.TRANSCRIBE_LIMIT.limit({ key: ip })).success) return json({ error: "slow down" }, 429);

		// Whose subscription pays for this, if one is required.
		let meter: string | undefined;
		if (!developer && env.REQUIRE_SUBSCRIPTION === "true") {
			const subscription = await subscriber(request.headers.get("x-cue-transaction"));
			if (!subscription) return json({ error: "subscription required" }, 402);
			// Rotating IPs doesn't help: what an abuser has to pay for is the subscription.
			if (!(await env.SUBSCRIPTION_LIMIT.limit({ key: subscription })).success) return json({ error: "slow down" }, 429);
			meter = `${subscription}:${new Date().toISOString().slice(0, 7)}`;
		}
		const stored = meter ? await env.USAGE.get<Partial<Usage>>(meter, "json") : null;
		const usage: Usage = { sessions: 0, takeSeconds: 0, transcribes: 0, ...stored };
		const record = (change: Partial<Usage>) =>
			meter &&
			env.USAGE.put(
				meter,
				JSON.stringify({
					sessions: usage.sessions + (change.sessions ?? 0),
					takeSeconds: usage.takeSeconds + (change.takeSeconds ?? 0),
					transcribes: usage.transcribes + (change.transcribes ?? 0),
				}),
				{ expirationTtl: 40 * 24 * 3600 },
			);

		if (url.pathname === "/v1/realtime-token") {
			if (usage.sessions >= MONTHLY.sessions) return json({ error: "monthly limit" }, 429);
			const response = await fetch(`${TOKENS}/realtime_scribe`, {
				method: "POST",
				headers: { "xi-api-key": env.ELEVENLABS_API_KEY },
			});
			if (!response.ok) {
				console.error("token failed", response.status, await response.text());
				return json({ error: "token unavailable" }, 502);
			}
			const { token } = (await response.json()) as { token: string };
			await record({ sessions: 1 });
			return json({ token });
		}

		if (usage.takeSeconds >= MONTHLY.takeSeconds || usage.transcribes >= MONTHLY.transcribes) return json({ error: "monthly limit" }, 429);
		const declared = Number(request.headers.get("content-length") ?? 0);
		if (!declared || declared > MAX_BYTES) return json({ error: "audio missing or too large" }, 413);
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
		const audio = new Uint8Array(await request.arrayBuffer());
		const length = audio.byteLength;
		if (!length || length > MAX_BYTES) return json({ error: "audio missing or too large" }, 413);
		// ElevenLabs bills the audio's length, so meter that, not where the last word ended.
		const seconds = mp4Duration(audio);
		if (seconds === undefined || seconds > MAX_TAKE_SECONDS) return json({ error: "audio missing or too long" }, 413);
		// Counted before the call, so parallel requests can't all slip under the cap on one read.
		await record({ transcribes: 1, takeSeconds: Math.ceil(seconds) });
		form.append("file", new Blob([audio], { type: "audio/mp4" }), "take.m4a");

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

/** The subscription's original transaction ID, if the signed transaction is a current Cue Voice one. */
async function subscriber(jws: string | null): Promise<string | undefined> {
	if (!jws) return undefined;
	try {
		const transaction = await verifyTransaction(jws);
		const current =
			transaction.bundleId === BUNDLE_ID &&
			// Sandbox (TestFlight, sandbox testers) purchases are free; they don't pay for speech.
			transaction.environment === "Production" &&
			PRODUCTS.includes(transaction.productId) &&
			!transaction.revocationDate &&
			(transaction.expiresDate ?? 0) + GRACE_MS > Date.now();
		if (!current) console.log("not entitled", { product: transaction.productId, expires: transaction.expiresDate, env: transaction.environment });
		return current ? transaction.originalTransactionId : undefined;
	} catch (error) {
		console.error("transaction rejected", String(error));
		return undefined;
	}
}

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
