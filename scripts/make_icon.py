#!/usr/bin/env python3
"""Generate the SteamPhone app icon (original artwork, Deck-inspired).

Draws at 4x supersampling and downsamples: dark navy rounded square, a
cyan->blue gradient ring (the 'Deck circle' language), and a minimal
handheld-gamepad silhouette: d-pad left, two buttons right, center screen.

Usage: python3 scripts/make_icon.py [output.png] [size]
Output defaults to Platform/Assets.xcassets/SteamPhoneIcon.appiconset/icon_1024.png
"""

import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT / "Platform/Assets.xcassets/SteamPhoneIcon.appiconset/icon_1024.png"

SS = 4  # supersample factor


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


CYAN = (110, 226, 255)
BLUE = (16, 74, 210)
BG_TOP = (10, 16, 32)
BG_BOTTOM = (20, 38, 63)
SILVER = (232, 240, 250)
DIM = (150, 175, 205)


def rounded_gradient_bg(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad = Image.new("RGBA", (size, size))
    d = ImageDraw.Draw(grad)
    for y in range(size):
        t = y / max(size - 1, 1)
        d.line([(0, y), (size, y)], fill=lerp(BG_TOP, BG_BOTTOM, t) + (255,))
    # rounded-rect mask at iOS radius (~22.37%)
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    r = round(size * 0.2237)
    md.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    img.paste(grad, (0, 0), mask)
    return img


def gradient_ring(size, width_frac=0.055, radius_frac=0.415):
    """Ring drawn as many short arcs with angle-interpolated colors."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx = cy = size / 2
    r_out = size * radius_frac
    w = size * width_frac
    r_in = r_out - w
    bbox = [cx - r_out, cy - r_out, cx + r_out, cy + r_out]
    steps = 720
    for i in range(steps):
        a0 = 360.0 * i / steps
        a1 = 360.0 * (i + 1) + 0.8  # slight overlap to avoid seams
        # angle 0 at 3 o'clock; start cyan at top (270 deg) going clockwise
        t = (math.radians(a0 - 270) / (2 * math.pi)) % 1.0
        color = lerp(CYAN, BLUE, t) + (255,)
        d.arc(bbox, start=a0, end=a1, fill=color, width=round(w))
    # inner soft edge: draw a slightly blurred copy under a crisp one
    soft = layer.filter(ImageFilter.GaussianBlur(size * 0.004))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(soft)
    out.alpha_composite(layer)
    return out


def handheld(size):
    """Minimal handheld-gamepad silhouette centered in the ring."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    s = size / 1024.0  # work in 1024-design units

    body_cx, body_cy = size / 2, size / 2
    body_w = 520 * s
    body_h = 300 * s
    # Body: horizontal pill (the deck body without separate grips)
    bbox = [body_cx - body_w / 2, body_cy - body_h / 2,
            body_cx + body_w / 2, body_cy + body_h / 2]
    d.rounded_rectangle(bbox, radius=body_h / 2, fill=(12, 22, 40, 255))

    # subtle rim on the body
    d.rounded_rectangle(bbox, radius=body_h / 2,
                        outline=tuple(list(SILVER) + [70]), width=round(6 * s))

    # Screen slit in the center
    sw, sh = 190 * s, 120 * s
    sbox = [body_cx - sw / 2, body_cy - sh / 2, body_cx + sw / 2, body_cy + sh / 2]
    d.rounded_rectangle(sbox, radius=18 * s, fill=(5, 10, 20, 255))
    d.rounded_rectangle(sbox, radius=18 * s,
                        outline=tuple(list(CYAN) + [160]), width=round(5 * s))
    # power dot on screen top-right
    d.ellipse([sbox[2] - 26 * s, sbox[1] + 10 * s,
               sbox[2] - 14 * s, sbox[1] + 22 * s], fill=tuple(list(CYAN) + [220]))

    # D-pad (left): plus shape
    dcx, dcy = body_cx - 172 * s, body_cy
    arm = 34 * s   # half thickness
    reach = 78 * s  # center to arm end
    d.rounded_rectangle([dcx - reach, dcy - arm, dcx + reach, dcy + arm],
                        radius=arm * 0.6, fill=tuple(list(SILVER) + [235]))
    d.rounded_rectangle([dcx - arm, dcy - reach, dcx + arm, dcy + reach],
                        radius=arm * 0.6, fill=tuple(list(SILVER) + [235]))

    # Buttons (right): two staggered circles (A up-right, B down-left)
    bcx, bcy = body_cx + 172 * s, body_cy
    br = 30 * s
    a_pos = (bcx + 26 * s, bcy - 34 * s)
    b_pos = (bcx - 26 * s, bcy + 34 * s)
    d.ellipse([a_pos[0] - br, a_pos[1] - br, a_pos[0] + br, a_pos[1] + br],
              fill=tuple(list(CYAN) + [255]))
    d.ellipse([b_pos[0] - br, b_pos[1] - br, b_pos[0] + br, b_pos[1] + br],
              fill=tuple(list(DIM) + [235]))

    # small 'menu' dots between screen and buttons
    for k, yy in enumerate([-14 * s, 0, 14 * s]):
        d.ellipse([body_cx + 74 * s - 4 * s, bcy + yy - 4 * s,
                   body_cx + 74 * s + 4 * s, bcy + yy + 4 * s],
                  fill=tuple(list(DIM) + [200]))
    return layer


def generate(out_path: Path, size: int = 1024):
    big = size * SS
    img = rounded_gradient_bg(big)
    img.alpha_composite(gradient_ring(big))
    img.alpha_composite(handheld(big))
    img = img.resize((size, size), Image.LANCZOS)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path, "PNG")
    print(f"wrote {out_path} ({size}x{size})")


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    px = int(sys.argv[2]) if len(sys.argv) > 2 else 1024
    generate(out, px)
