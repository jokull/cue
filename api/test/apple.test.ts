// node --test test/apple.test.ts   (Node 23+ runs TypeScript directly)
import { execFileSync } from "node:child_process";
import { createHash, createPrivateKey, sign } from "node:crypto";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { verifyTransaction } from "../src/apple.ts";

const dir = mkdtempSync(join(tmpdir(), "cue-chain-"));
execFileSync(join(import.meta.dirname, "chain.sh"), [dir]);
const der = (name: string) => {
	const pem = readFileSync(join(dir, name), "utf8");
	return Buffer.from(pem.replace(/-----[^-]+-----|\s/g, ""), "base64");
};
const x5c = ["leaf.pem", "int.pem", "root.pem"].map((name) => der(name).toString("base64"));
const root = createHash("sha256").update(der("root.pem")).digest("hex");
const key = createPrivateKey(readFileSync(join(dir, "leaf.p8")));

const payload = { bundleId: "is.solberg.cue", productId: "is.solberg.cue.voice.yearly", originalTransactionId: "2000000123", expiresDate: Date.now() + 1e9 };
const jws = (header: object, body: object) => {
	const part = (value: object) => Buffer.from(JSON.stringify(value)).toString("base64url");
	const input = `${part(header)}.${part(body)}`;
	const signature = sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" });
	return `${input}.${signature.toString("base64url")}`;
};

test("accepts a transaction signed down a well-formed chain", async () => {
	const transaction = await verifyTransaction(jws({ alg: "ES256", x5c }, payload), root);
	assert.equal(transaction.originalTransactionId, "2000000123");
});

test("rejects a chain that doesn't end in the pinned root", async () => {
	await assert.rejects(verifyTransaction(jws({ alg: "ES256", x5c }, payload)), /not apple's root/);
});

test("rejects a tampered payload", async () => {
	const [header, , signature] = jws({ alg: "ES256", x5c }, payload).split(".");
	const forged = Buffer.from(JSON.stringify({ ...payload, originalTransactionId: "1" })).toString("base64url");
	await assert.rejects(verifyTransaction(`${header}.${forged}.${signature}`, root), /bad signature/);
});

test("rejects a leaf the intermediate didn't sign", async () => {
	await assert.rejects(verifyTransaction(jws({ alg: "ES256", x5c: [x5c[1], x5c[1], x5c[2]] }, payload), root), /not an apple chain|broken chain/);
});
