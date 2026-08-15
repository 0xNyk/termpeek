#!/usr/bin/env python3
"""Find the content region of a terminal recording.

Prints an ffmpeg crop filter (crop=w:h:x:y), or nothing if it cannot tell.

    tools/content-crop.py frame.rgb WIDTH HEIGHT

Why not ffmpeg's cropdetect: it thresholds on absolute luma, and a terminal's
own background is not black. Set the limit low and it crops nothing; set it
high enough to remove the background and it starts eating dark content — a
diff's red and green line backgrounds sit at roughly the same luma as an empty
pane, so a threshold that removes one removes the other. That is what produced
a clip cropped into its own text and then scaled up to fill the frame.

This samples the actual background colour from the corners instead, then keeps
every pixel that differs from it. No absolute threshold, so it adapts to
whatever theme and display transform are in play.
"""

import sys


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: content-crop.py <raw rgb24> <w> <h>", file=sys.stderr)
        return 2
    path, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    pad = int(sys.argv[4]) if len(sys.argv) > 4 else 12
    data = open(path, "rb").read()
    if len(data) < w * h * 3:
        return 1

    def px(x, y):
        i = (y * w + x) * 3
        return data[i], data[i + 1], data[i + 2]

    # Corners are the safest bet for "empty pane": content starts inset from
    # them in every scene. Take the median so one stray corner cannot skew it.
    corners = [px(4, 4), px(w - 5, 4), px(4, h - 5), px(w - 5, h - 5)]
    bg = tuple(sorted(c[i] for c in corners)[1] for i in range(3))

    # Generous tolerance: anti-aliased glyph edges sit close to the background,
    # and clipping them looks like the text has been shaved.
    tol = 18

    def differs(x, y):
        r, g, b = px(x, y)
        return abs(r - bg[0]) > tol or abs(g - bg[1]) > tol or abs(b - bg[2]) > tol

    step = 2
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(0, h, step):
        for x in range(0, w, step):
            if differs(x, y):
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y

    if maxx < 0:
        return 1

    minx = max(0, minx - pad); miny = max(0, miny - pad)
    maxx = min(w - 1, maxx + pad); maxy = min(h - 1, maxy + pad)

    cw = (maxx - minx + 1) // 2 * 2
    ch = (maxy - miny + 1) // 2 * 2
    if cw < 80 or ch < 40:
        return 1

    # Refuse a crop that barely trims anything; leaving it uncropped is safer
    # than a marginal one, and the caller can then skip the extra encode.
    if cw > w * 0.97 and ch > h * 0.97:
        return 1

    print(f"crop={cw}:{ch}:{minx}:{miny}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
