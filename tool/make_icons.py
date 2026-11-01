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

S = 2048  # drawing size; scaled down with antialiasing

K = 0.2493  # tan(14 degrees): how far the envelope leans forward

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def tile():
    """The lagoon tile: a diagonal gradient in a rounded square."""
    grad = Image.new('RGBA', (S, S))
    top, bottom = (0x14, 0x91, 0x7C), (0x0B, 0x4A, 0x40)
    gd = ImageDraw.Draw(grad)
    for i in range(2 * S):  # diagonal bands, top left to bottom right
        gd.line([(i, 0), (i - S, S)], fill=lerp(top, bottom, i / (2 * S)) + (255,), width=2)
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([S / 32, S / 32, S - S / 32, S - S / 32], radius=S * 7 / 32, fill=255)
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    img.paste(grad, (0, 0), mask)
    return img

def round_line(d, a, b, w, fill):
    d.line([a, b], fill=fill, width=w)
    for q in (a, b):
        d.ellipse([q[0] - w / 2, q[1] - w / 2, q[0] + w / 2, q[1] + w / 2], fill=fill)

def mark(img):
    """The envelope, leaning forward, and three citrus speed lines.
    Coordinates are in the 512 design space of assets/icon/icon.svg."""
    z = S / 512
    w = int(22 * z)
    lagoon, citrus = (0x0F, 0x7A, 0x69, 255), (0xF4, 0xB7, 0x40, 255)
    # Upright envelope on its own layer, then sheared like the SVG's skewX.
    env = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(env)
    d.rounded_rectangle([150 * z, 160 * z, 402 * z, 344 * z], radius=26 * z, fill=(255, 255, 255, 255))
    pts = [(166 * z, 180 * z), (276 * z, 262 * z), (386 * z, 180 * z)]
    d.line(pts, fill=lagoon, width=w, joint='curve')
    for q in (pts[0], pts[2]):
        d.ellipse([q[0] - w / 2, q[1] - w / 2, q[0] + w / 2, q[1] + w / 2], fill=lagoon)
    # Output (x, y) reads input (x + K*y - 96, y).
    env = env.transform((S, S), Image.AFFINE, (1, K, -96 * z, 0, 1, 0), resample=Image.BICUBIC)
    img.alpha_composite(env)
    d = ImageDraw.Draw(img)
    for x0, x1, y in ((104, 168, 206), (84, 160, 252), (104, 148, 298)):
        round_line(d, (x0 * z, y * z), (x1 * z, y * z), w, citrus)
    return img

def save(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)

icon = mark(tile())
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
