# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Makes the README's screenshots smaller (needs Python 3 with Pillow):
#   python3 tool/shrink_screenshots.py docs/screenshots
# Each PNG becomes a 256-colour PNG, about a third of its size; flat app
# screens with antialiased text look the same. A file that is already
# palette-based is left as it is, so running it twice changes nothing.
import os
import sys

from PIL import Image


def shrink(path):
    image = Image.open(path)
    if image.mode == "P":
        return None
    before = os.path.getsize(path)
    image.convert("RGB").quantize(
        colors=256,
        method=Image.Quantize.FASTOCTREE,
        dither=Image.Dither.FLOYDSTEINBERG,
    ).save(path, optimize=True)
    return before, os.path.getsize(path)


def main(folder):
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".png"):
            continue
        sizes = shrink(os.path.join(folder, name))
        if sizes:
            print(f"{name}: {sizes[0] // 1024} KB -> {sizes[1] // 1024} KB")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "docs/screenshots")
