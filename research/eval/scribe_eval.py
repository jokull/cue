"""scribe_eval.py — how well does ElevenLabs Scribe v2 hear an Icelandic take?

Sends audio to Scribe v2 with word timestamps, then scores it against the script Cue would
have shown: word error rate on normalized words (the same normalization CueCore matches on),
plus how many script words got a timestamp. Saves the raw response next to the audio.

    dotenvx run -f .env -- python3 research/eval/scribe_eval.py take.m4a script.txt [--language is]
    dotenvx run -f .env -- python3 research/eval/scribe_eval.py --synthesize script.txt   # TTS smoke test

Standard library only. Needs ELEVENLABS_API_KEY.
"""

import argparse
import json
import os
import sys
import time
import unicodedata
import urllib.request
import uuid
from pathlib import Path

API = "https://api.elevenlabs.io/v1"
KEY = os.environ.get("ELEVENLABS_API_KEY", "")


def request(path, body=None, headers=None, method="GET"):
    req = urllib.request.Request(API + path, data=body, method=method, headers={"xi-api-key": KEY, **(headers or {})})
    with urllib.request.urlopen(req, timeout=300) as response:
        return response.read()


def multipart(fields, file_field, file_path):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    data = Path(file_path).read_bytes()
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{Path(file_path).name}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n".encode() + data + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), {"Content-Type": f"multipart/form-data; boundary={boundary}"}


def synthesize(text, out, model="eleven_v4"):
    """Icelandic speech for a pipeline smoke test. A synthetic voice is an easy case: real
    takes are the actual benchmark."""
    voices = json.loads(request("/voices"))["voices"]
    voice = voices[0]["voice_id"]
    body = json.dumps({"text": text, "model_id": model}).encode()
    audio = request(f"/text-to-speech/{voice}?output_format=mp3_44100_128", body,
                    {"Content-Type": "application/json"}, "POST")
    Path(out).write_bytes(audio)
    return out


def transcribe(audio, language):
    body, headers = multipart(
        {"model_id": "scribe_v2", "language_code": language, "timestamps_granularity": "word",
         "tag_audio_events": "false"}, "file", audio)
    started = time.time()
    result = json.loads(request("/speech-to-text", body, headers, "POST"))
    return result, time.time() - started


def normalize(word):
    """Matches CueCore's ScriptWord.normalize: casefold, drop diacritics, keep letters and digits."""
    folded = unicodedata.normalize("NFKD", word.casefold())
    return "".join(c for c in folded if not unicodedata.combining(c) and c.isalnum())


def word_errors(reference, hypothesis):
    """Levenshtein distance over words: substitutions + deletions + insertions."""
    previous = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, 1):
        current = [i] + [0] * len(hypothesis)
        for j, hyp in enumerate(hypothesis, 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref != hyp))
        previous = current
    return previous[-1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", nargs="?")
    parser.add_argument("script")
    parser.add_argument("--language", default="is")
    parser.add_argument("--synthesize", action="store_true", help="make the audio from the script with TTS")
    args = parser.parse_args()
    if not KEY:
        sys.exit("ELEVENLABS_API_KEY missing — run through dotenvx")

    script = Path(args.script).read_text().strip()
    audio = args.audio
    if args.synthesize:
        audio = synthesize(script, str(Path(args.script).with_suffix(".tts.mp3")))
        print("synthesized", audio)

    result, seconds = transcribe(audio, args.language)
    Path(audio).with_suffix(".scribe.json").write_text(json.dumps(result, ensure_ascii=False, indent=1))

    words = [w for w in result.get("words", []) if w.get("type") == "word"]
    reference = [n for n in (normalize(w) for w in script.split()) if n]
    hypothesis = [n for n in (normalize(w["text"]) for w in words) if n]
    errors = word_errors(reference, hypothesis)
    timed = sum(1 for w in words if w.get("start") is not None and w.get("end") is not None)

    print(f"language detected: {result.get('language_code')} (p={result.get('language_probability', 0):.2f})")
    print(f"request time: {seconds:.1f}s")
    print(f"WER vs script: {errors}/{len(reference)} = {errors / max(len(reference), 1):.1%}")
    print(f"timed words: {timed}/{len(words)}")
    print("transcript:", result.get("text", "").strip())
    for w in words[:8]:
        print(f"  {w['start']:6.2f}–{w['end']:6.2f}  {w['text']}")


if __name__ == "__main__":
    main()
