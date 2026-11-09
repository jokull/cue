/**
 * Verifies a StoreKit 2 signed transaction (the JWS from `Transaction.jwsRepresentation`) the way
 * Apple's App Store Server Library does: the x5c chain ends in Apple Root CA - G3 (pinned by
 * fingerprint), each certificate is signed by the next, the intermediate and leaf carry Apple's
 * marker extensions, and the leaf's key signs the JWS. Nothing here talks to Apple.
 */

/** SHA-256 of https://www.apple.com/certificateauthority/AppleRootCA-G3.cer */
const APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
/** 1.2.840.113635.100.6.11.1 (receipt signing leaf) and 1.2.840.113635.100.6.2.1 (WWDR intermediate). */
const LEAF_MARKER = oidBytes("1.2.840.113635.100.6.11.1");
const INTERMEDIATE_MARKER = oidBytes("1.2.840.113635.100.6.2.1");

export interface SignedTransaction {
	bundleId: string;
	productId: string;
	originalTransactionId: string;
	transactionId: string;
	expiresDate?: number;
	revocationDate?: number;
	environment: "Production" | "Sandbox" | "Xcode" | "LocalTesting";
}

export async function verifyTransaction(jws: string, rootFingerprint = APPLE_ROOT_G3_SHA256): Promise<SignedTransaction> {
	const [headerPart, payloadPart, signaturePart] = jws.split(".");
	if (!headerPart || !payloadPart || !signaturePart) throw new Error("malformed jws");
	const header = JSON.parse(text(base64url(headerPart))) as { alg?: string; x5c?: string[] };
	if (header.alg !== "ES256" || header.x5c?.length !== 3) throw new Error("unexpected jws header");

	const [leaf, intermediate, root] = header.x5c.map((cert) => parseCertificate(base64(cert)));
	if (hex(await crypto.subtle.digest("SHA-256", root.der)) !== rootFingerprint) throw new Error("not apple's root");
	if (!contains(intermediate.der, INTERMEDIATE_MARKER) || !contains(leaf.der, LEAF_MARKER)) throw new Error("not an apple chain");
	if (!(await signedBy(intermediate, root)) || !(await signedBy(leaf, intermediate))) throw new Error("broken chain");

	const key = await importKey(leaf);
	const signed = new TextEncoder().encode(`${headerPart}.${payloadPart}`);
	const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, base64url(signaturePart), signed);
	if (!valid) throw new Error("bad signature");
	return JSON.parse(text(base64url(payloadPart))) as SignedTransaction;
}

// MARK: Just enough X.509

interface Certificate {
	der: Uint8Array;
	tbs: Uint8Array;
	signatureHash: "SHA-256" | "SHA-384";
	signature: Uint8Array;
	spki: Uint8Array;
	curve: "P-256" | "P-384";
}

interface Node {
	tag: number;
	start: number; // of the whole element
	contentStart: number;
	end: number;
}

function read(bytes: Uint8Array, offset: number): Node {
	const tag = bytes[offset];
	let length = bytes[offset + 1];
	let contentStart = offset + 2;
	if (length & 0x80) {
		const count = length & 0x7f;
		length = 0;
		for (let i = 0; i < count; i++) length = (length << 8) | bytes[offset + 2 + i];
		contentStart += count;
	}
	return { tag, start: offset, contentStart, end: contentStart + length };
}

function children(bytes: Uint8Array, node: Node): Node[] {
	const nodes: Node[] = [];
	for (let offset = node.contentStart; offset < node.end; ) {
		const child = read(bytes, offset);
		nodes.push(child);
		offset = child.end;
	}
	return nodes;
}

function parseCertificate(der: Uint8Array): Certificate {
	const [tbsNode, algorithmNode, signatureNode] = children(der, read(der, 0));
	const tbsFields = children(der, tbsNode);
	// tbsCertificate: [0] version, serial, signature, issuer, validity, subject, subjectPublicKeyInfo, …
	const spkiNode = tbsFields[tbsFields[0].tag === 0xa0 ? 6 : 5];
	const spki = der.slice(spkiNode.start, spkiNode.end);
	const algorithm = der.slice(algorithmNode.start, algorithmNode.end);
	return {
		der,
		tbs: der.slice(tbsNode.start, tbsNode.end),
		signatureHash: contains(algorithm, oidBytes("1.2.840.10045.4.3.3")) ? "SHA-384" : "SHA-256",
		signature: der.slice(signatureNode.contentStart + 1, signatureNode.end), // skip the BIT STRING's unused-bits byte
		spki,
		curve: contains(spki, oidBytes("1.3.132.0.34")) ? "P-384" : "P-256",
	};
}

function importKey(cert: Certificate): Promise<CryptoKey> {
	return crypto.subtle.importKey("spki", cert.spki, { name: "ECDSA", namedCurve: cert.curve }, false, ["verify"]);
}

async function signedBy(cert: Certificate, issuer: Certificate): Promise<boolean> {
	const size = issuer.curve === "P-384" ? 48 : 32;
	return crypto.subtle.verify(
		{ name: "ECDSA", hash: cert.signatureHash },
		await importKey(issuer),
		rawSignature(cert.signature, size),
		cert.tbs,
	);
}

/** DER `SEQUENCE { r INTEGER, s INTEGER }` → the fixed-width r‖s WebCrypto expects. */
function rawSignature(der: Uint8Array, size: number): Uint8Array {
	const [r, s] = children(der, read(der, 0)).map((n) => der.slice(n.contentStart, n.end));
	const out = new Uint8Array(size * 2);
	const place = (value: Uint8Array, at: number) => {
		const trimmed = value.slice(Math.max(0, value.length - size));
		out.set(trimmed, at + size - trimmed.length);
	};
	place(r, 0);
	place(s, size);
	return out;
}

function oidBytes(oid: string): Uint8Array {
	const parts = oid.split(".").map(Number);
	const body = [parts[0] * 40 + parts[1]];
	for (const part of parts.slice(2)) {
		const chunk = [part & 0x7f];
		for (let rest = part >> 7; rest > 0; rest >>= 7) chunk.unshift((rest & 0x7f) | 0x80);
		body.push(...chunk);
	}
	return new Uint8Array([0x06, body.length, ...body]);
}

function contains(haystack: Uint8Array, needle: Uint8Array): boolean {
	outer: for (let i = 0; i + needle.length <= haystack.length; i++) {
		for (let j = 0; j < needle.length; j++) if (haystack[i + j] !== needle[j]) continue outer;
		return true;
	}
	return false;
}

// MARK: Encodings

function base64(value: string): Uint8Array {
	return Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
}

function base64url(value: string): Uint8Array {
	const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
	return base64(padded);
}

function text(bytes: Uint8Array): string {
	return new TextDecoder().decode(bytes);
}

function hex(buffer: ArrayBuffer): string {
	return [...new Uint8Array(buffer)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
