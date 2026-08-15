#!/usr/bin/env python3
"""Render ANSI terminal output to SVG.

Used to build the README demos. Screenshots were the obvious approach and the
wrong one: capturing a terminal means capturing whatever else is on screen, and
the result is a bitmap nobody can diff. This takes the actual bytes a command
writes and draws them, so the demos are reproducible from source and contain
nothing but the command's own output.

    some-command | tools/ansi2svg.py --title "termpeek diff" -o out.svg

Handles SGR colour (truecolor, 256, and the 16 basic colours), bold, dim,
inverse, and underline — which covers what bat, delta and chafa emit.
"""

import argparse
import re
import sys
from html import escape

CELL_W = 8.4
CELL_H = 18.0
PAD = 18.0
TITLEBAR = 34.0

BG = "#0d1117"
FG = "#c9d1d9"

# GitHub-ish ANSI palette; normal then bright.
BASIC = [
    "#484f58", "#ff7b72", "#3fb950", "#d29922",
    "#58a6ff", "#bc8cff", "#39c5cf", "#b1bac4",
    "#6e7681", "#ffa198", "#56d364", "#e3b341",
    "#79c0ff", "#d2a8ff", "#56d4dd", "#f0f6fc",
]

SGR = re.compile(r"\x1b\[([0-9;]*)m")
OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
CSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def xterm256(n: int) -> str:
    if n < 16:
        return BASIC[n]
    if n < 232:
        n -= 16
        r, g, b = n // 36, (n % 36) // 6, n % 6
        f = lambda v: 0 if v == 0 else 55 + v * 40
        return "#%02x%02x%02x" % (f(r), f(g), f(b))
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


class Style:
    __slots__ = ("fg", "bg", "bold", "dim", "inverse", "underline")

    fg: "str | None"
    bg: "str | None"
    bold: bool
    dim: bool
    inverse: bool
    underline: bool

    def __init__(self):
        self.reset()

    def reset(self):
        self.fg = None
        self.bg = None
        self.bold = False
        self.dim = False
        self.inverse = False
        self.underline = False

    def copy(self):
        s = Style()
        for k in self.__slots__:
            setattr(s, k, getattr(self, k))
        return s

    def key(self):
        return tuple(getattr(self, k) for k in self.__slots__)


def apply_sgr(style: Style, params: str) -> None:
    codes = [int(p) if p else 0 for p in (params or "0").split(";")]
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:
            style.reset()
        elif c == 1:
            style.bold = True
        elif c == 2:
            style.dim = True
        elif c == 4:
            style.underline = True
        elif c == 7:
            style.inverse = True
        elif c in (22,):
            style.bold = style.dim = False
        elif c == 24:
            style.underline = False
        elif c == 27:
            style.inverse = False
        elif 30 <= c <= 37:
            style.fg = BASIC[c - 30]
        elif 90 <= c <= 97:
            style.fg = BASIC[c - 90 + 8]
        elif 40 <= c <= 47:
            style.bg = BASIC[c - 40]
        elif 100 <= c <= 107:
            style.bg = BASIC[c - 100 + 8]
        elif c == 39:
            style.fg = None
        elif c == 49:
            style.bg = None
        elif c in (38, 48):
            # Extended colour: 5;n (256) or 2;r;g;b (truecolor)
            target = "fg" if c == 38 else "bg"
            if i + 1 < len(codes) and codes[i + 1] == 5 and i + 2 < len(codes):
                setattr(style, target, xterm256(codes[i + 2]))
                i += 2
            elif i + 1 < len(codes) and codes[i + 1] == 2 and i + 4 < len(codes):
                setattr(style, target, "#%02x%02x%02x" % tuple(codes[i + 2:i + 5]))
                i += 4
        i += 1


def parse(text: str):
    """-> list of lines, each a list of (text, Style) runs."""
    text = OSC.sub("", text).replace("\r\n", "\n").replace("\r", "")
    lines, cur, style = [], [], Style()
    buf, buf_style = "", style.copy()

    def flush():
        nonlocal buf, buf_style
        if buf:
            cur.append((buf, buf_style))
            buf = ""

    pos = 0
    while pos < len(text):
        m = SGR.match(text, pos)
        if m:
            flush()
            apply_sgr(style, m.group(1))
            buf_style = style.copy()
            pos = m.end()
            continue
        m = CSI.match(text, pos)
        if m:  # any other control sequence: drop it
            pos = m.end()
            continue
        ch = text[pos]
        if ch == "\n":
            flush()
            lines.append(cur)
            cur = []
            buf_style = style.copy()
        elif ch == "\t":
            buf += "    "
        elif ch == "\x1b":
            pass
        else:
            buf += ch
        pos += 1
    flush()
    if cur:
        lines.append(cur)
    return lines


def render(lines, title, bare=False, min_cols=40):
    cols = max((sum(len(t) for t, _ in ln) for ln in lines), default=0)
    cols = max(cols, len(title) + 8, min_cols)
    rows = len(lines)
    bar = 0.0 if bare else TITLEBAR
    w = cols * CELL_W + PAD * 2
    h = rows * CELL_H + PAD * 2 + bar

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" '
        f'viewBox="0 0 {w:.0f} {h:.0f}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">',
        f'<rect width="{w:.0f}" height="{h:.0f}" rx="{0 if bare else 10}" fill="{BG}"/>',
    ]
    if not bare:
        out += [
            f'<rect width="{w:.0f}" height="{TITLEBAR}" rx="10" fill="#161b22"/>',
            f'<rect y="{TITLEBAR-10}" width="{w:.0f}" height="10" fill="#161b22"/>',
        ]
        for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")):
            out.append(f'<circle cx="{20+i*18}" cy="{TITLEBAR/2}" r="6" fill="{c}"/>')
        out.append(
            f'<text x="{w/2:.0f}" y="{TITLEBAR/2+4.5:.0f}" font-size="12.5" fill="#8b949e" '
            f'text-anchor="middle">{escape(title)}</text>'
        )

    y = bar + PAD
    for ln in lines:
        x = PAD
        for text, st in ln:
            fg = st.fg or FG
            bg = st.bg
            if st.inverse:
                fg, bg = bg or BG, fg
            width = len(text) * CELL_W
            if bg:
                out.append(
                    f'<rect x="{x:.1f}" y="{y:.1f}" width="{width:.1f}" '
                    f'height="{CELL_H:.1f}" fill="{bg}"/>'
                )
            if text.strip():
                attrs = f'fill="{fg}" font-size="13"'
                if st.bold:
                    attrs += ' font-weight="700"'
                if st.dim:
                    attrs += ' opacity="0.62"'
                if st.underline:
                    attrs += ' text-decoration="underline"'
                out.append(
                    f'<text x="{x:.1f}" y="{y+13.2:.1f}" {attrs} '
                    f'xml:space="preserve">{escape(text)}</text>'
                )
            x += width
        y += CELL_H
    out.append("</svg>")
    return "\n".join(out)


def render_image(png_path, title, prompt, width=980):
    """Terminal chrome around a rendered image.

    Under a pixel protocol the terminal draws the image itself, so embedding the
    same bitmap the renderer produced is what the pane actually shows — closer
    to the truth than approximating it as character art.
    """
    import base64
    import struct

    data = open(png_path, "rb").read()
    # PNG dimensions live in the IHDR chunk at a fixed offset.
    iw, ih = struct.unpack(">II", data[16:24])
    inner = width - PAD * 2
    scale = min(1.0, inner / iw)
    dw, dh = iw * scale, ih * scale
    top = TITLEBAR + PAD + (CELL_H if prompt else 0)
    h = top + dh + PAD
    b64 = base64.b64encode(data).decode()

    out = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.0f}" height="{h:.0f}" '
        f'viewBox="0 0 {width:.0f} {h:.0f}" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">',
        f'<rect width="{width:.0f}" height="{h:.0f}" rx="10" fill="{BG}"/>',
        f'<rect width="{width:.0f}" height="{TITLEBAR}" rx="10" fill="#161b22"/>',
        f'<rect y="{TITLEBAR-10}" width="{width:.0f}" height="10" fill="#161b22"/>',
    ]
    for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        out.append(f'<circle cx="{20+i*18}" cy="{TITLEBAR/2}" r="6" fill="{c}"/>')
    out.append(
        f'<text x="{width/2:.0f}" y="{TITLEBAR/2+4.5:.0f}" font-size="12.5" fill="#8b949e" '
        f'text-anchor="middle">{escape(title)}</text>'
    )
    if prompt:
        out.append(
            f'<text x="{PAD}" y="{TITLEBAR+PAD+13:.0f}" font-size="13" fill="#8b949e" '
            f'xml:space="preserve">$ <tspan fill="{FG}">{escape(prompt)}</tspan></text>'
        )
    out.append(
        f'<image x="{PAD}" y="{top:.1f}" width="{dw:.1f}" height="{dh:.1f}" '
        f'href="data:image/png;base64,{b64}"/>'
    )
    out.append("</svg>")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", default="termpeek")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("-i", "--input", help="read from a file instead of stdin")
    ap.add_argument("--image", help="frame a PNG instead of reading ANSI text")
    ap.add_argument("--prompt", default="", help="command line to show above the image")
    ap.add_argument("--bare", action="store_true", help="omit the window chrome")
    ap.add_argument("--min-cols", type=int, default=40)
    a = ap.parse_args()

    if a.image:
        svg = render_image(a.image, a.title, a.prompt)
    else:
        raw = open(a.input, "rb").read() if a.input else sys.stdin.buffer.read()
        lines = parse(raw.decode("utf-8", "replace"))
        while lines and not any(t.strip() for t, _ in lines[-1]):
            lines.pop()
        svg = render(lines, a.title, bare=a.bare, min_cols=a.min_cols)

    with open(a.out, "w") as f:
        f.write(svg)
    print(a.out)


if __name__ == "__main__":
    sys.exit(main())
