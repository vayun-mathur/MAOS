#!/usr/bin/env python3
"""Generate the MAOS boot animation from the mouse glyph.

Renders a draw-on wipe of the MAOS mouse silhouette (white on black),
holds, then loops a gentle fade while boot continues. Output is a
bootanimation.zip in this directory, ready for
PRODUCT_COPY_FILES into system/media/bootanimation.zip.

The SVG path is parsed + flattened with only the standard library + Pillow
(no rsvg/inkscape needed), so the file is reproducible anywhere.

Usage: ./generate.py   (writes bootanimation.zip next to this script)
"""

import math
import os
import zipfile

from PIL import Image, ImageDraw

# The MAOS mouse glyph (same path as the maproj.org tab icon / homepage card).
PATH_D = (
    "M12,22q-2.9,0-4.95-2.05T5,15V9Q5,6.1 7.05,4.05T12,2t4.95,2.05T19,9v6"
    "q0,2.9-2.05,4.95T12,22ZM13,9h4q0-1.8-1.14-3.18T13,4.1V9ZM7,9h4V4.1Q9.28,"
    "4.45 8.14,5.82T7,9Zm5,11q2.08,0 3.54-1.46T17,15V11H7v4q0,2.07 1.46,3.54"
    "T12,20Zm0-9Zm1-2ZM11,9Zm1,2Z"
)

SIZE = 1080          # square canvas; bootanimation centers/scales on device
FPS = 30
DRAW_FRAMES = 24     # wipe-in duration
HOLD_FRAMES = 12     # full glyph hold before the loop section
LOOP_FRAMES = 30     # gentle fade loop while boot continues
GLYPH_SCALE = 560    # glyph pixel size on the canvas


def tokenize(d):
    out, num, i = [], "", 0
    while i < len(d):
        c = d[i]
        if c in "MmLlHhVvQqTtZz":
            if num:
                out.append(float(num))
                num = ""
            out.append(c)
        elif c in "0123456789.+-":
            # a sign starts a new number (but not a decimal point or exponent)
            if c in "+-" and num and num[-1] not in "eE":
                out.append(float(num))
                num = c
            else:
                num += c
        # commas / whitespace just separate
        elif num:
            out.append(float(num))
            num = ""
        i += 1
    if num:
        out.append(float(num))
    return out


def flatten_quadratic(p0, p1, p2, steps=24):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        pts.append((
            mt * mt * p0[0] + 2 * mt * t * p1[0] + t * t * p2[0],
            mt * mt * p0[1] + 2 * mt * t * p1[1] + t * t * p2[1],
        ))
    return pts


def parse_path(d):
    """Parse the SVG path into a list of subpaths (each a point list)."""
    toks = tokenize(d)
    subpaths, cur, pos, start = [], [], (0.0, 0.0), (0.0, 0.0)
    last_q = None  # control point reflected by smooth T/t
    i = 0

    def args(n):
        nonlocal i
        vals = toks[i:i + n]
        i += n
        return vals

    while i < len(toks):
        t = toks[i]
        if isinstance(t, str):
            cmd = t
            i += 1
        else:
            cmd = last_cmd  # implicit repetition of previous command
        last_cmd = cmd
        rel = cmd.islower()
        c = cmd.upper()

        if c == "M":
            x, y = args(2)
            if rel:
                x, y = pos[0] + x, pos[1] + y
            if cur:
                subpaths.append(cur)
            cur, pos, start = [], (x, y), (x, y)
            last_q = None
            # subsequent implicit pairs are linetos
            while i < len(toks) and not isinstance(toks[i], str):
                x, y = args(2)
                if rel:
                    x, y = pos[0] + x, pos[1] + y
                cur.append((x, y))
                pos = (x, y)
        elif c == "Z":
            if cur:
                cur.append(start)
                subpaths.append(cur)
                cur = []
            pos = start
            last_q = None
        elif c in "Q":
            while i < len(toks) and not isinstance(toks[i], str):
                x1, y1, x, y = args(4)
                if rel:
                    x1, y1 = pos[0] + x1, pos[1] + y1
                    x, y = pos[0] + x, pos[1] + y
                cur += flatten_quadratic(pos, (x1, y1), (x, y))[1:]
                last_q = (x1, y1)
                pos = (x, y)
        elif c in "T":
            while i < len(toks) and not isinstance(toks[i], str):
                x, y = args(2)
                if rel:
                    x, y = pos[0] + x, pos[1] + y
                # reflection of previous control point (or current point)
                if last_q is None:
                    x1, y1 = pos
                else:
                    x1, y1 = 2 * pos[0] - last_q[0], 2 * pos[1] - last_q[1]
                cur += flatten_quadratic(pos, (x1, y1), (x, y))[1:]
                last_q = (x1, y1)
                pos = (x, y)
        elif c == "H":
            while i < len(toks) and not isinstance(toks[i], str):
                (x,) = args(1)
                if rel:
                    x = pos[0] + x
                cur.append((x, pos[1]))
                pos = (x, pos[1])
            last_q = None
        elif c == "V":
            while i < len(toks) and not isinstance(toks[i], str):
                (y,) = args(1)
                if rel:
                    y = pos[1] + y
                cur.append((pos[0], y))
                pos = (pos[0], y)
            last_q = None
        else:
            raise ValueError(f"unsupported path command: {cmd}")
    if cur:
        subpaths.append(cur)
    return subpaths


def render_glyph(size):
    """Rasterize the glyph white-on-transparent at the given pixel size.

    Uses the nonzero winding rule across ALL subpaths as one path (matching
    SVG's default fill-rule): inner detail subpaths wound opposite to the
    outline carve the button/panel voids. PIL fills each polygon
    independently, so the winding is resolved here with a scanline fill.
    """
    subs = parse_path(PATH_D)
    s = size / 24.0
    scaled = [[(x * s, y * s) for x, y in sub] for sub in subs]
    # edge list with direction sign for the winding count
    edges = []
    for sub in scaled:
        for i in range(len(sub)):
            x0, y0 = sub[i]
            x1, y1 = sub[(i + 1) % len(sub)]
            if y0 != y1:
                edges.append((x0, y0, x1, y1))
    img = Image.new("L", (size, size), 0)
    px = img.load()
    for y in range(size):
        yc = y + 0.5
        crossings = []
        for x0, y0, x1, y1 in edges:
            if (y0 <= yc < y1) or (y1 <= yc < y0):
                x = x0 + (yc - y0) * (x1 - x0) / (y1 - y0)
                crossings.append((x, 1 if y1 > y0 else -1))
        crossings.sort()
        winding, prev = 0, 0.0
        for x, d in crossings:
            if winding != 0 and x > prev:
                for xx in range(max(int(prev), 0), min(int(x) + 1, size)):
                    px[xx, y] = 255
            winding += d
            prev = x
    return img


def frame(reveal, alpha):
    """One SIZE×SIZE frame: black bg, glyph revealed top-to-`reveal`, at `alpha`."""
    canvas = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    glyph = render_glyph(GLYPH_SCALE)
    ox, oy = (SIZE - GLYPH_SCALE) // 2, (SIZE - GLYPH_SCALE) // 2
    if reveal < 1.0:
        # wipe: keep only rows above the reveal line (with a soft edge)
        cutoff = int(GLYPH_SCALE * reveal)
        mask = Image.new("L", (GLYPH_SCALE, GLYPH_SCALE), 0)
        md = ImageDraw.Draw(mask)
        md.rectangle([0, 0, GLYPH_SCALE, max(cutoff - 8, 0)], fill=255)
        if 0 < cutoff < GLYPH_SCALE:
            for r in range(8):
                md.line([0, cutoff - 8 + r, GLYPH_SCALE, cutoff - 8 + r],
                        fill=int(255 * (1 - r / 8)))
        cut = Image.new("L", (GLYPH_SCALE, GLYPH_SCALE), 0)
        cut.paste(mask)
        empty = Image.new("L", (GLYPH_SCALE, GLYPH_SCALE), 0)
        glyph = Image.composite(glyph, empty, cut)
    if alpha < 1.0:
        glyph = glyph.point(lambda v: int(v * alpha))
    white = Image.new("RGB", (GLYPH_SCALE, GLYPH_SCALE), (255, 255, 255))
    canvas.paste(white, (ox, oy), glyph)
    return canvas


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    work = os.path.join(here, "work")
    for part in ("part0", "part1"):
        os.makedirs(os.path.join(work, part), exist_ok=True)

    # part0: draw-on wipe, then hold — plays once.
    frames = []
    for f in range(DRAW_FRAMES):
        t = (f + 1) / DRAW_FRAMES
        ease = 1 - (1 - t) ** 2  # ease-out: fast start, soft landing
        frames.append(("part0", frame(ease, 1.0)))
    for _ in range(HOLD_FRAMES):
        frames.append(("part0", frame(1.0, 1.0)))
    # part1: gentle fade loop while boot continues — loops forever.
    for f in range(LOOP_FRAMES):
        a = 0.75 + 0.25 * math.cos(2 * math.pi * f / LOOP_FRAMES)
        frames.append(("part1", frame(1.0, a)))

    counters = {"part0": 0, "part1": 0}
    for part, img in frames:
        counters[part] += 1
        img.save(os.path.join(work, part, f"{counters[part]:05d}.png"))

    desc = (
        f"{SIZE} {SIZE} {FPS}\n"
        f"p 1 0 part0\n"
        f"p 0 0 part1\n"
    )
    with open(os.path.join(work, "desc.txt"), "w") as f:
        f.write(desc)

    # bootanimation.zip must be STORED (uncompressed) — the loader mmaps it.
    out = os.path.join(here, "bootanimation.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        z.write(os.path.join(work, "desc.txt"), "desc.txt")
        for part in ("part0", "part1"):
            d = os.path.join(work, part)
            for name in sorted(os.listdir(d)):
                z.write(os.path.join(d, name), f"{part}/{name}")
    total = DRAW_FRAMES + HOLD_FRAMES + LOOP_FRAMES
    print(f"wrote {out}: {total} frames, {os.path.getsize(out)} bytes")


if __name__ == "__main__":
    main()
