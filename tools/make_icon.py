#!/usr/bin/env python3
"""Draw the OldDV Rescue icon (a MiniDV cassette) and write mac/OldDV.icns
with 256/512 px PNG entries (ic08 / ic09, supported since Mac OS X 10.5)."""
import io
import struct
from PIL import Image, ImageDraw

def draw(size):
    s = size / 512.0
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    R = lambda x0, y0, x1, y1: [x0 * s, y0 * s, x1 * s, y1 * s]
    d.rounded_rectangle(R(40, 110, 472, 402), radius=36 * s, fill=(38, 40, 46, 255), outline=(12, 12, 14, 255), width=int(6 * s))
    d.rounded_rectangle(R(70, 140, 442, 270), radius=18 * s, fill=(200, 205, 214, 255))
    d.rectangle(R(70, 175, 442, 235), fill=(230, 60, 50, 255))
    d.text((92 * s, 182 * s), "", fill=(255, 255, 255, 255))
    for cx in (170, 342):
        d.ellipse(R(cx - 52, 290, cx + 52, 394), fill=(20, 20, 22, 255), outline=(150, 150, 160, 255), width=int(5 * s))
        d.ellipse(R(cx - 20, 322, cx + 20, 362), fill=(210, 210, 215, 255))
    d.rectangle(R(222, 318, 290, 366), fill=(90, 70, 50, 255))
    # "DV" letters drawn with rectangles (no font dependency)
    def bar(x0, y0, x1, y1):
        d.rectangle(R(x0, y0, x1, y1), fill=(255, 255, 255, 255))
    bar(180, 185, 192, 225); bar(180, 185, 214, 196); bar(180, 214, 214, 225); bar(212, 192, 224, 218)
    d.polygon([(250 * s, 185 * s), (264 * s, 185 * s), (282 * s, 214 * s), (300 * s, 185 * s), (314 * s, 185 * s), (288 * s, 226 * s), (276 * s, 226 * s)], fill=(255, 255, 255, 255))
    return im

def png(im):
    b = io.BytesIO()
    im.save(b, "PNG")
    return b.getvalue()

entries = [(b"ic08", png(draw(256))), (b"ic09", png(draw(512)))]
body = b"".join(t + struct.pack(">I", len(p) + 8) + p for t, p in entries)
open("mac/OldDV.icns", "wb").write(b"icns" + struct.pack(">I", len(body) + 8) + body)
draw(512).save("mac/icon.png")
print("mac/OldDV.icns written")
