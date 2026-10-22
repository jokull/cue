"""compose.py — headline typography over each device render, for the App Store frames.

Copy comes from branding/screens/captions.txt, read fresh every run, so wording changes
never need a re-render.  python3 branding/blender/compose.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FONTS = Path("/Library/Fonts")
HEADLINE = ImageFont.truetype(str(FONTS / "SF-Pro-Display-Bold.otf"), 104)
SUBLINE = ImageFont.truetype(str(FONTS / "SF-Pro-Display-Medium.otf"), 50)
OUT = ROOT / "appstore" / "iphone-6.9"


def wrap(draw, text, font, width):
    lines, line = [], ""
    for word in text.split():
        trial = f"{line} {word}".strip()
        if draw.textlength(trial, font=font) > width and line:
            lines.append(line)
            line = word
        else:
            line = trial
    return lines + [line]


def compose(number, headline, subline):
    image = Image.open(ROOT / "out" / f"device-{number}.png").convert("RGB")
    draw = ImageDraw.Draw(image)
    width = image.width
    y = 190
    for line in wrap(draw, headline, HEADLINE, width - 200):
        draw.text((width / 2, y), line, font=HEADLINE, fill=(255, 255, 255), anchor="ma")
        y += 122
    y += 22
    for line in wrap(draw, subline, SUBLINE, width - 240):
        draw.text((width / 2, y), line, font=SUBLINE, fill=(168, 168, 176), anchor="ma")
        y += 64
    OUT.mkdir(parents=True, exist_ok=True)
    image.save(OUT / f"0{number}.png")
    return y


if __name__ == "__main__":
    for row in (ROOT / "screens" / "captions.txt").read_text().strip().splitlines():
        number, headline, subline = row.split("|")
        bottom = compose(number, headline, subline)
        print("COMPOSE_OK", number, "text ends at", bottom)
