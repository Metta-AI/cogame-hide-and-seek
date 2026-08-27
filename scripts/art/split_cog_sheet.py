#!/usr/bin/env python3
"""Chroma-key, split and pad the nano-banana cog sheet into the two role kits.

    python3 scripts/art/split_cog_sheet.py

Reads `scripts/art/source/cogs_sheet.png` — one nano-banana render of the
Softmax cog in its HIDER and SEEKER kits on a flat green backdrop — and writes
`data/cog_hider.png` and `data/cog_seeker.png`, which `src/hns/rig_art.nim`
composites into the sixteen board facings.  Also handles the furniture sheet
(`scripts/art/source/objects_sheet.png` -> `data/obj_{crate,panel,ramp}.png`).

Gemini does not return alpha and the "pure green" you asked for comes back as
*some* green with a tinted edge, so the key is a flood fill from the image
border against the MEDIAN border colour (corners sometimes carry a smudge),
which keeps green accents inside a character.  The model also likes to write
the role name under each figure; the largest horizontal band of ink is the
figure row and everything else (captions) is dropped.
"""

import os
import sys
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))

SHEETS = [
    # (sheet, outputs, size, pad_to_square)
    #
    # A COG is padded to a square: rig_art rotates it about its centre through
    # sixteen facings, and a non-square master would clip its own corners.
    # An OBJECT is cropped TIGHT and left at its own aspect: global.nim
    # stretches the master to the object's rectangle, so a transparent margin
    # would be stretched with it and the crate would stop filling its box.
    ("cogs_sheet.png", ["cog_hider.png", "cog_seeker.png"], 256, True),
    ("objects_sheet.png",
     ["obj_crate.png", "obj_panel.png", "obj_ramp.png"], 192, False),
]

KEY_TOLERANCE = 62


def median_border(image):
    w, h = image.size
    pixels = image.load()
    samples = []
    for x in range(w):
        samples.append(pixels[x, 0][:3])
        samples.append(pixels[x, h - 1][:3])
    for y in range(h):
        samples.append(pixels[0, y][:3])
        samples.append(pixels[w - 1, y][:3])
    channels = []
    for c in range(3):
        values = sorted(sample[c] for sample in samples)
        channels.append(values[len(values) // 2])
    return tuple(channels)


def close_enough(a, b, tolerance=KEY_TOLERANCE):
    return (abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])) <= tolerance


def chroma_key(image):
    """Flood-fill the backdrop from the border, so interior greens survive."""
    image = image.convert("RGBA")
    w, h = image.size
    pixels = image.load()
    backdrop = median_border(image)
    seen = bytearray(w * h)
    queue = deque()
    for x in range(w):
        for y in (0, h - 1):
            queue.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= w or y >= h:
            continue
        index = y * w + x
        if seen[index]:
            continue
        if not close_enough(pixels[x, y][:3], backdrop):
            continue
        seen[index] = 1
        pixels[x, y] = (0, 0, 0, 0)
        queue.append((x + 1, y))
        queue.append((x - 1, y))
        queue.append((x, y + 1))
        queue.append((x, y - 1))
    # Soften the keyed rim: a pixel that still reads as backdrop but survived
    # the fill (an enclosed pocket) is knocked to zero alpha rather than left
    # as a green halo around the silhouette.
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a and close_enough((r, g, b), backdrop, KEY_TOLERANCE // 2):
                pixels[x, y] = (r, g, b, 0)
    # GREEN-SPILL SUPPRESSION. A translucent element drawn over the backdrop
    # (the seeker's torch beam) comes back tinted, and the flood fill will not
    # touch it because it is not the backdrop colour. Clamping green to the
    # red/blue average is the standard chroma-key answer and turns the beam
    # back into the warm light it is meant to be.
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if not a:
                continue
            limit = (r + b) // 2 + 12
            if g > limit:
                pixels[x, y] = (r, limit, b, a)
    return image


def row_ink(image):
    w, h = image.size
    pixels = image.load()
    rows = []
    for y in range(h):
        count = 0
        for x in range(w):
            if pixels[x, y][3] > 24:
                count += 1
        rows.append(count)
    return rows


def largest_run(values, threshold):
    best = (0, 0)
    start = None
    for i, value in enumerate(values + [0]):
        if value > threshold:
            if start is None:
                start = i
        elif start is not None:
            if i - start > best[1] - best[0]:
                best = (start, i)
            start = None
    return best


def column_groups(image, y0, y1, min_width):
    w, _ = image.size
    pixels = image.load()
    columns = []
    for x in range(w):
        count = 0
        for y in range(y0, y1):
            if pixels[x, y][3] > 24:
                count += 1
        columns.append(count)
    groups = []
    start = None
    for x, value in enumerate(columns + [0]):
        if value > 0:
            if start is None:
                start = x
        elif start is not None:
            if x - start >= min_width:
                groups.append((start, x))
            start = None
    return groups


def pad_square(image, size):
    w, h = image.size
    side = max(w, h)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image, ((side - w) // 2, (side - h) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def tight(image, size):
    box = image.getbbox()
    part = image.crop(box) if box else image
    return part.resize((size, size), Image.LANCZOS)


def split_sheet(source, names, size, pad):
    path = os.path.join(HERE, "source", source)
    if not os.path.exists(path):
        print("skipping missing sheet:", path)
        return True
    keyed = chroma_key(Image.open(path))
    rows = row_ink(keyed)
    y0, y1 = largest_run(rows, max(2, keyed.size[0] // 100))
    if y1 <= y0:
        print("no figure band found in", source, file=sys.stderr)
        return False
    groups = column_groups(keyed, y0, y1, keyed.size[0] // 40)
    if len(groups) != len(names):
        print("found %d figures in %s, expected %d"
              % (len(groups), source, len(names)), file=sys.stderr)
        return False
    for (x0, x1), name in zip(groups, names):
        part = keyed.crop((x0, y0, x1, y1))
        out = os.path.join(ROOT, "data", name)
        (pad_square(part, size) if pad else tight(part, size)).save(out)
        print("wrote", out)
    return True


def main():
    ok = True
    for source, names, size, pad in SHEETS:
        if not split_sheet(source, names, size, pad):
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
