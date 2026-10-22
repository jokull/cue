"""finish.py — the last 5% of a premium render: a soft vignette and fine luminance grain.

Blender 5's compositor has no vignette or grain node, and both belong at final resolution
anyway (grain rendered at 2x and downscaled turns to mush). Run after the Blender render:

    python3 branding/blender/finish.py branding/out/icon-luxe-1024.png --vignette 0.22 --grain 0.018
"""

import argparse

import numpy as np
from PIL import Image


def finish(path, vignette, grain, seed):
    image = Image.open(path).convert("RGB")
    pixels = np.asarray(image, dtype=np.float32) / 255
    height, width = pixels.shape[:2]

    # Vignette: darken toward the corners on a smooth curve, never touching the centre third.
    y, x = np.mgrid[0:height, 0:width]
    radius = np.hypot((x - width / 2) / (width / 2), (y - height / 2) / (height / 2)) / np.sqrt(2)
    falloff = 1 - vignette * np.clip((radius - 0.35) / 0.65, 0, 1) ** 1.8
    pixels *= falloff[..., None]

    # Grain: monochrome so it reads as film, not as colour noise; weaker in the highlights.
    rng = np.random.default_rng(seed)
    noise = rng.normal(0, grain, (height, width))[..., None]
    luminance = pixels.mean(axis=2, keepdims=True)
    pixels += noise * (1 - 0.6 * luminance)

    Image.fromarray((np.clip(pixels, 0, 1) * 255 + 0.5).astype(np.uint8)).save(path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--vignette", type=float, default=0.22)
    parser.add_argument("--grain", type=float, default=0.018)
    parser.add_argument("--seed", type=int, default=7)  # fixed, so re-runs are byte-identical
    args = parser.parse_args()
    finish(args.path, args.vignette, args.grain, args.seed)
    print("FINISH_OK", args.path)
