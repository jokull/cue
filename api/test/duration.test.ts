// node --test test/duration.test.ts
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { mp4Duration } from "../src/duration.ts";

const fixture = new Uint8Array(readFileSync(join(import.meta.dirname, "fixtures", "say.m4a")));

test("reads the declared duration of an M4A take", () => {
	const seconds = mp4Duration(fixture);
	assert.ok(seconds !== undefined && seconds > 2 && seconds < 10, `got ${seconds}`);
});

test("undefined for bytes that aren't an MP4", () => {
	assert.equal(mp4Duration(new TextEncoder().encode("not audio at all, just text")), undefined);
	assert.equal(mp4Duration(new Uint8Array(0)), undefined);
});

test("doesn't run past a truncated or oversized box", () => {
	assert.equal(mp4Duration(fixture.slice(0, 40)), undefined);
	const lying = fixture.slice();
	new DataView(lying.buffer).setUint32(0, 0xffffffff); // first box claims to run past the end
	assert.equal(mp4Duration(lying), undefined);
});
