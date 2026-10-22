"""frames.py — App Store frames in the icon's language: exact geometry, flat, a tiny bit of depth.

Real simulator screenshots in a drawn device outline on the icon's near-black gradient, an SF Pro
headline whose *starred* word sits on a caption-yellow pill (the highlight Cue burns into videos),
and the logo mark above it. Drawn at 2x and downscaled. Copy lives in screens/captions.txt.

    python3 branding/frames.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent
FONTS = Path("/Library/Fonts")
W, H = 1320, 2868  # 6.9" iPhone App Store size
S = 2  # supersample

YELLOW, RED, WHITE = (255, 214, 10), (255, 59, 48), (255, 255, 255)
SUBTLE = (152, 152, 160)
BG_TOP, BG_BOTTOM = (30, 30, 33), (9, 9, 10)  # the icon's automatic gradient, as a page

HEADLINE = ImageFont.truetype(str(FONTS / "SF-Pro-Display-Bold.otf"), 96 * S)
SUBLINE = ImageFont.truetype(str(FONTS / "SF-Pro-Display-Medium.otf"), 46 * S)

SCREEN_W = 940  # screenshot width on the frame
BEZEL = 20
SCREEN_R = 118  # corner radius of the screen, scaled from the device's
DEVICE_TOP = 720  # one position for every frame, so the set lines up side by side


def gradient(size, top, bottom):
    column = Image.new("RGB", (1, size[1]))
    for y in range(size[1]):
        t = y / (size[1] - 1)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize(size)


def mark(draw, cx, y, scale):
    """The logo: dot plus three lines, same proportions as Cue.icon (112/184/520/128/64)."""
    unit = scale / 712  # mark width
    line_h, pitch, line_w, dot_d, gap = 112 * unit, 184 * unit, 520 * unit, 128 * unit, 64 * unit
    left = cx - scale / 2
    cy = y + pitch + line_h / 2
    draw.ellipse([left, cy - dot_d / 2, left + dot_d, cy + dot_d / 2], fill=RED)
    x = left + dot_d + gap
    for row, color in ((-1, WHITE), (0, YELLOW), (1, WHITE)):
        top = cy + row * pitch - line_h / 2
        draw.rounded_rectangle([x, top, x + line_w, top + line_h], radius=line_h / 2, fill=color)


def headline(draw, text, y):
    """Centered headline; a *starred* run sits on the caption pill. Two-line headlines are
    balanced (no one-word widows), and pills get their padding as extra space beside them."""
    marked, inside = [], False
    for raw in text.split():
        starts, ends = raw.startswith("*"), raw.endswith("*")
        inside = inside or starts
        marked.append((raw.strip("*"), inside))
        if ends:
            inside = False

    space = draw.textlength(" ", font=HEADLINE)
    pad_x, pad_y = 20 * S, 10 * S
    widths = [draw.textlength(word, font=HEADLINE) for word, _ in marked]

    def advance(i, j):
        """Width of words i..j-1 laid out on one line, including pill padding at run edges."""
        total = sum(widths[i:j]) + space * (j - i - 1)
        for k in range(i, j):
            lit = marked[k][1]
            if lit and (k == i or not marked[k - 1][1]):
                total += pad_x
            if lit and (k == j - 1 or not marked[k + 1][1]):
                total += pad_x
        return total

    max_w = (W - 140) * S
    n = len(marked)
    if advance(0, n) <= max_w:
        lines = [(0, n)]
    else:
        # Never break inside a highlighted run.
        splits = [k for k in range(1, n) if not (marked[k - 1][1] and marked[k][1])]
        split = min(splits, key=lambda k: max(advance(0, k), advance(k, n)))
        lines = [(0, split), (split, n)]

    line_h = 118 * S
    ascent, descent = HEADLINE.getmetrics()
    for row, (i, j) in enumerate(lines):
        x = (W * S - advance(i, j)) / 2
        top = y * S + row * line_h
        k = i
        while k < j:
            word, lit = marked[k]
            if lit:
                run_end = k
                while run_end + 1 < j and marked[run_end + 1][1]:
                    run_end += 1
                run_w = sum(widths[k : run_end + 1]) + space * (run_end - k)
                draw.rounded_rectangle([x, top + pad_y, x + run_w + 2 * pad_x, top + ascent + descent * 0.35 + pad_y],
                                       radius=22 * S, fill=YELLOW)
                x += pad_x
                for m in range(k, run_end + 1):
                    draw.text((x, top), marked[m][0], font=HEADLINE, fill=(0, 0, 0))
                    x += widths[m] + space
                x += pad_x
                k = run_end + 1
            else:
                draw.text((x, top), word, font=HEADLINE, fill=WHITE)
                x += widths[k] + space
                k += 1
    return y + len(lines) * 118


def device(canvas, screenshot, top):
    shot = Image.open(screenshot).convert("RGB")
    sw = SCREEN_W * S
    sh = round(shot.height * sw / shot.width)
    shot = shot.resize((sw, sh), Image.LANCZOS)
    dw, dh = sw + 2 * BEZEL * S, sh + 2 * BEZEL * S
    x, y = (W * S - dw) // 2, top * S
    radius = (SCREEN_R + BEZEL) * S

    # Depth, kept small: one soft contact shadow and a hairline highlight on the rail.
    shadow = Image.new("L", canvas.size, 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 40 * S, x + dw, y + dh + 30 * S], radius=radius, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(60 * S))
    canvas.paste((0, 0, 0), mask=shadow)

    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle([x, y, x + dw, y + dh], radius=radius, fill=(14, 14, 15), outline=(78, 78, 84), width=3 * S)
    draw.rounded_rectangle([x + 3 * S, y + 3 * S, x + dw - 3 * S, y + dh - 3 * S], radius=radius - 3 * S,
                           outline=(34, 34, 37), width=2 * S)
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=SCREEN_R * S, fill=255)
    canvas.paste(shot, (x + BEZEL * S, y + BEZEL * S), mask)


def frame(number, text, subline):
    canvas = gradient((W * S, H * S), BG_TOP, BG_BOTTOM)
    draw = ImageDraw.Draw(canvas)
    mark(draw, W * S / 2, 140 * S, 150 * S)
    bottom = headline(draw, text, 320)
    draw.text((W * S / 2, (bottom + 26) * S), subline, font=SUBLINE, fill=SUBTLE, anchor="ma")
    shot = next((ROOT / "screens" / "prepped").glob(f"{number}-*.png"))
    device(canvas, shot, DEVICE_TOP)
    out = ROOT / "appstore" / "iphone-6.9"
    out.mkdir(parents=True, exist_ok=True)
    canvas.resize((W, H), Image.LANCZOS).save(out / f"0{number}.png")
    print("FRAME_OK", number, "headline ends", bottom)


if __name__ == "__main__":
    for row in (ROOT / "screens" / "captions.txt").read_text().strip().splitlines():
        frame(*row.split("|"))
