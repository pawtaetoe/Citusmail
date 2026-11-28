# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Regenerates the app icon files from code (needs Python 3 with Pillow):
#   python3 tool/make_icons.py
# Draws the app icon (matching assets/icon/icon.svg) and writes every
# platform's sizes, plus the Android adaptive icon's foreground. Run from
# the repository root.
import os
from PIL import Image, ImageChops, ImageDraw

S = 2048  # drawing size; scaled down with antialiasing

K = 0.2493  # tan(14 degrees): how far the envelope leans forward
LAGOON, CITRUS, WHITE = (0x0F, 0x7A, 0x69), (0xF4, 0xB7, 0x40), (0xFF, 0xFF, 0xFF)

# The shapes, in the 512 design space of assets/icon/icon.svg. The
# envelope is drawn upright, then leans (skewX -14 degrees about y = 256).
ENVELOPE = (140, 156, 372, 356)  # left, top, right, bottom
RADIUS = 30
# The flap and the body: what of the envelope lies above and below the
# fold, a V-shaped gap 30 wide.
FLAP = [(100, 100), (412, 100), (412, 127), (256, 249), (100, 127)]
BODY = [(100, 165), (256, 287), (412, 165), (412, 400), (100, 400)]


def lean(x, y):
    return x - K * (y - 256), y


def tile():
    """The flat lagoon tile, a rounded square."""
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(img).rounded_rectangle(
        [S / 32, S / 32, S - S / 32, S - S / 32], radius=S * 7 / 32, fill=LAGOON + (255,))
    return img


def mark(img):
    """The envelope with its citrus flap, leaning forward."""
    z = S / 512
    envelope = Image.new('L', (S, S), 0)
    ImageDraw.Draw(envelope).rounded_rectangle(
        [c * z for c in ENVELOPE], radius=RADIUS * z, fill=255)
    layer = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    for shape, colour in ((FLAP, CITRUS), (BODY, WHITE)):
        part = Image.new('L', (S, S), 0)
        ImageDraw.Draw(part).polygon([(x * z, y * z) for x, y in shape], fill=255)
        layer.paste(colour + (255,), None, ImageChops.multiply(part, envelope))
    # Output (x, y) reads input (x + K*y - K*256, y).
    layer = layer.transform((S, S), Image.AFFINE, (1, K, -K * 256 * z, 0, 1, 0), resample=Image.BICUBIC)
    img.alpha_composite(layer)
    return img


def save(img, path, size):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path)


def android_foreground(path):
    """The adaptive icon's foreground (and themed icon) as a vector: the
    mark at 0.15 dp per design unit, centred, well inside the 66 dp safe
    zone. The fold is a real gap, so the one-colour themed icon keeps it."""
    s, o = 0.15, 54 - 256 * 0.15

    def pt(x, y):
        x, y = lean(x, y)
        return f'{o + s * x:.2f},{o + s * y:.2f}'

    def poly(points):
        return 'M' + 'L'.join(pt(x, y) for x, y in points) + 'Z'

    # The envelope's outline, its corners as cubic curves (they stay exact
    # when leaned, unlike arcs).
    l, t, r, b = ENVELOPE
    q = RADIUS * (1 - 0.5523)
    clip = (
        f'M{pt(l + RADIUS, t)}L{pt(r - RADIUS, t)}'
        f'C{pt(r - q, t)} {pt(r, t + q)} {pt(r, t + RADIUS)}'
        f'L{pt(r, b - RADIUS)}'
        f'C{pt(r, b - q)} {pt(r - q, b)} {pt(r - RADIUS, b)}'
        f'L{pt(l + RADIUS, b)}'
        f'C{pt(l + q, b)} {pt(l, b - q)} {pt(l, b - RADIUS)}'
        f'L{pt(l, t + RADIUS)}'
        f'C{pt(l, t + q)} {pt(l + q, t)} {pt(l + RADIUS, t)}Z'
    )
    with open(path, 'w') as f:
        f.write(f'''<?xml version="1.0" encoding="utf-8"?>
<!-- Adaptive icon foreground (also the themed icon): a forward-leaning
     envelope with a citrus flap, inside the 66dp safe zone. Written by
     tool/make_icons.py from the shapes of assets/icon/icon.svg. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <group>
        <clip-path android:pathData="{clip}"/>
        <path
            android:fillColor="#FFF4B740"
            android:pathData="{poly(FLAP)}"/>
        <path
            android:fillColor="#FFFFFFFF"
            android:pathData="{poly(BODY)}"/>
    </group>
</vector>
''')


icon = mark(tile())
# Linux
for size in (16, 32, 48, 64, 128, 256, 512):
    save(icon, f'assets/icon/png/{size}.png', size)
# Android legacy launcher icons and the adaptive icon's foreground
android = 'app/android/app/src/main/res'
for name, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    save(icon, f'{android}/mipmap-{name}/ic_launcher.png', size)
android_foreground(f'{android}/drawable/ic_launcher_foreground.xml')
# Windows .ico with the usual sizes
icon.resize((256, 256), Image.LANCZOS).save(
    'app/windows/runner/resources/app_icon.ico',
    sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
)
print('icons written')
