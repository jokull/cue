/**
 * The playing time an MP4/M4A file declares, in seconds: the longest of the movie header (mvhd)
 * and every track's media header (mdhd). Undefined when the file has no readable moov.
 *
 * The Worker meters and caps transcription by this, because ElevenLabs bills audio length while
 * the transcript only shows where the last word ended. A file can still lie in its headers; the
 * byte cap and per-subscription request caps bound what a lie can buy.
 */
export function mp4Duration(bytes: Uint8Array): number | undefined {
	const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
	let longest: number | undefined;

	const walk = (start: number, end: number, depth: number) => {
		for (let offset = start; offset + 8 <= end; ) {
			let size = view.getUint32(offset);
			const type = String.fromCharCode(...bytes.subarray(offset + 4, offset + 8));
			let header = 8;
			if (size === 1) {
				if (offset + 16 > end) return;
				const big = view.getBigUint64(offset + 8);
				if (big > BigInt(end - offset)) return;
				size = Number(big);
				header = 16;
			} else if (size === 0) {
				size = end - offset;
			}
			if (size < header || offset + size > end) return;
			const body = offset + header;
			if (type === "mvhd" || type === "mdhd") {
				const seconds = headerDuration(view, body, offset + size);
				if (seconds !== undefined) longest = Math.max(longest ?? 0, seconds);
			} else if (depth < 4 && (type === "moov" || type === "trak" || type === "mdia")) {
				walk(body, offset + size, depth + 1);
			}
			offset += size;
		}
	};

	walk(0, bytes.byteLength, 0);
	return longest;
}

/** mvhd and mdhd share a layout: version, flags, two dates, timescale, duration. */
function headerDuration(view: DataView, body: number, end: number): number | undefined {
	const version = view.getUint8(body);
	if (version === 1) {
		if (body + 32 > end) return undefined;
		const timescale = view.getUint32(body + 20);
		const duration = Number(view.getBigUint64(body + 24));
		return timescale ? duration / timescale : undefined;
	}
	if (body + 20 > end) return undefined;
	const timescale = view.getUint32(body + 12);
	const duration = view.getUint32(body + 16);
	return timescale ? duration / timescale : undefined;
}
