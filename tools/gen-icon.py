# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""Generate Antiphon.icns from the brand mark (the concentric-circle mati eye
from the marketing-site handoff): a cream macOS squircle with the cobalt eye,
pupil and highlight, drawn at 4x and downsampled per icon size.

    uv run tools/gen-icon.py

Writes native/ChamberApp/Resources/Antiphon.icns (via iconutil).
"""

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "native/ChamberApp/Resources/Antiphon.icns"

CREAM = (251, 247, 240, 255)  # #FBF7F0
COBALT = (39, 67, 184, 255)  # #2743B8
INK = (42, 35, 27, 255)  # #2A231B


def render(size: int) -> Image.Image:
    ss = 4  # supersample
    S = size * ss
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # the macOS squircle grid: 824/1024 rounded-rect, radius ~185/1024
    m = S * (1 - 824 / 1024) / 2
    d.rounded_rectangle([m, m, S - m, S - m], radius=S * 185 / 1024, fill=CREAM)

    # the eye (hero proportions: 108 cream/stroke, 88 cobalt, 60 cream, 30 pupil,
    # 7 highlight at (-10,-10)), scaled so the outer ring sits inside the squircle
    cx = cy = S / 2
    R = (S - 2 * m) * 0.335  # outer eye radius within the plate

    def disc(r: float, fill, ox: float = 0, oy: float = 0):
        d.ellipse([cx + ox - r, cy + oy - r, cx + ox + r, cy + oy + r], fill=fill)

    k = R / 108
    disc(108 * k, COBALT)  # stroke ring reads better as a solid cobalt rim at icon sizes
    disc(103 * k, CREAM)
    disc(88 * k, COBALT)
    disc(60 * k, CREAM)
    disc(30 * k, INK)
    disc(7 * k, CREAM, ox=-10 * k, oy=-10 * k)

    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    with tempfile.TemporaryDirectory() as td:
        iconset = Path(td) / "Antiphon.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            render(pt).save(iconset / f"icon_{pt}x{pt}.png")
            render(pt * 2).save(iconset / f"icon_{pt}x{pt}@2x.png")
        OUT.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
