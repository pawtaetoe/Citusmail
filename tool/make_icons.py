# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Regenerates the app icon files from code (needs Python 3 with Pillow):
#   python3 tool/make_icons.py
# Draws the app icon (matching assets/icon/icon.svg) and writes every
# platform's sizes. Run from the repository root.
import os
from PIL import Image, ImageDraw

S = 1024  # drawing size; scaled down with antialiasing

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def tile(full_bleed=False):
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    grad = Image.new('RGBA', (S, S))
    top, bottom = (0x3B, 0x8C, 0xF5), (0x1F, 0x5F, 0xC4)
    gd = ImageDraw.Draw(grad)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S) + (255,))
    mask = Image.new('L', (S, S), 0)
    md = ImageDraw.Draw(mask)
    if full_bleed:
        md.rectangle([0, 0, S, S], fill=255)
    else:
        md.rounded_rectangle([32, 32, S - 32, S - 32], radius=224, fill=255)
    img.paste(grad, (0, 0), mask)
    return img

def envelope(img, scale=1.0, colour=(255, 255, 255, 255), line=(0x2F, 0x80, 0xED, 255)):
    d = ImageDraw.Draw(img)
    c = S / 2
    def p(x, y):  # coordinates in the 512 design space, scaled around the centre
        return (c + (x - 256) * 2 * scale, c + (y - 256) * 2 * scale)
    x0, y0 = p(104, 150); x1, y1 = p(408, 362)
    d.rounded_rectangle([x0, y0, x1, y1], radius=56 * scale, fill=colour)
    w = int(44 * scale)
    pts = [p(120, 172), p(256, 270), p(392, 172)]
    d.line(pts, fill=line, width=w, joint='curve')
    for q in (pts[0], pts[2]):
        d.ellipse([q[0] - w / 2, q[1] - w / 2, q[0] + w / 2, q[1] + w / 2], fill=line)
    return img

def save(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)

icon = envelope(tile())
# Linux
for size in (16, 32, 48, 64, 128, 256, 512):
    save(icon, f'assets/icon/png/{size}.png', size)
# Android legacy launcher icons
android = 'app/android/app/src/main/res'
for name, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    save(icon, f'{android}/mipmap-{name}/ic_launcher.png', size)
# Windows .ico with the usual sizes
icon.resize((256, 256), Image.LANCZOS).save(
    'app/windows/runner/resources/app_icon.ico',
    sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
)
print('icons written')
