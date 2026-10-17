"""Render Grain Mono, the system font: printable ASCII from DejaVu Sans Mono,
anti-aliased, one alpha byte per pixel, in fixed cells.

    python3 tools/font/gen.py [path/to/DejaVuSansMono.ttf]

Writes grain/lib/font/mono.bin: glyphs 32..126 in order, each W*H bytes,
rows top to bottom. W, H and the baseline are printed for grain/lib/font.zig.
Needs Pillow; the build does not (the output is checked in). The license of
the outlines is in grain/lib/font/LICENSE.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SIZE = 15
W, H = 9, 18

src = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
font = ImageFont.truetype(src, SIZE)
ascent, descent = font.getmetrics()
top = (H - (ascent + descent)) // 2
out = bytearray()
for c in range(32, 127):
    img = Image.new("L", (W, H), 0)
    ImageDraw.Draw(img).text((0, top), chr(c), font=font, fill=255)
    out += img.tobytes()
dst = os.path.join(os.path.dirname(__file__), "..", "..", "grain", "lib", "font", "mono.bin")
with open(dst, "wb") as f:
    f.write(out)
print(f"W={W} H={H} baseline={top + ascent} advance={font.getlength('M'):.2f} bytes={len(out)}")
