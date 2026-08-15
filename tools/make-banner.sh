#!/usr/bin/env bash
# Build the README banner.
#
#   tools/make-banner.sh
#
# Generated rather than designed in a tool nobody else has, for the same reason
# every other image in this README is: it rebuilds from source, it diffs, and it
# stays honest about what the product looks like. The terminal on the right is
# the actual demo chart, at the actual proportions termpeek draws it.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/assets/readme"
W=1280
H=420

command -v rsvg-convert >/dev/null 2>&1 || { echo "rsvg-convert required" >&2; exit 127; }
mkdir -p "$OUT"

SANS='Helvetica Neue, Helvetica, Arial, sans-serif'
MONO='SF Mono, Menlo, DejaVu Sans Mono, monospace'

# Terminal mock geometry (right-hand side).
TX=690; TY=78; TW=520; TH=268

{
cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" viewBox="0 0 $W $H">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#0d1117"/>
      <stop offset="100%" stop-color="#11161f"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.18" cy="0.12" r="0.75">
      <stop offset="0%" stop-color="#3b82f6" stop-opacity="0.22"/>
      <stop offset="100%" stop-color="#3b82f6" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#3b82f6"/>
      <stop offset="100%" stop-color="#8b5cf6"/>
    </linearGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="18" flood-color="#000" flood-opacity="0.55"/>
    </filter>
    <clipPath id="screen">
      <rect x="$TX" y="$(( TY + 34 ))" width="$TW" height="$(( TH - 34 ))"/>
    </clipPath>
  </defs>

  <rect width="$W" height="$H" fill="url(#bg)"/>
  <rect width="$W" height="$H" fill="url(#glow)"/>

  <!-- wordmark -->
  <g font-family="$SANS">
    <text x="72" y="150" fill="#e6edf3" font-size="72" font-weight="700"
          letter-spacing="-2">termpeek</text>
    <rect x="74" y="168" width="132" height="4" rx="2" fill="url(#accent)"/>

    <text x="72" y="222" fill="#adbac7" font-size="25" font-weight="500">Your agent can see the image.</text>
    <text x="72" y="256" fill="#adbac7" font-size="25" font-weight="500">Now you can too.</text>

    <!-- Keep both lines inside x &lt; $TX or they run under the terminal mock. -->
    <text x="72" y="300" fill="#7d8590" font-size="16">Images · video · PDFs · diffs · X posts</text>
    <text x="72" y="324" fill="#7d8590" font-size="16">Claude Code · Codex · Hermes · any MCP client</text>
  </g>

  <!-- command line -->
  <g font-family="$MONO" font-size="17">
    <rect x="72" y="348" width="452" height="44" rx="8" fill="#161b22" stroke="#30363d"/>
    <text x="92" y="376" fill="#3fb950">\$</text>
    <text x="112" y="376" fill="#e6edf3">termpeek out/render.mp4</text>
  </g>

  <!-- terminal mock -->
  <g filter="url(#shadow)">
    <rect x="$TX" y="$TY" width="$TW" height="$TH" rx="12" fill="#161b22" stroke="#30363d"/>
    <path d="M $TX $(( TY + 12 )) a 12 12 0 0 1 12 -12 h $(( TW - 24 )) a 12 12 0 0 1 12 12 v 22 h -$TW z"
          fill="#1c2230"/>
    <circle cx="$(( TX + 22 ))" cy="$(( TY + 17 ))" r="5.5" fill="#ff5f57"/>
    <circle cx="$(( TX + 41 ))" cy="$(( TY + 17 ))" r="5.5" fill="#febc2e"/>
    <circle cx="$(( TX + 60 ))" cy="$(( TY + 17 ))" r="5.5" fill="#28c840"/>
    <text x="$(( TX + TW / 2 ))" y="$(( TY + 22 ))" fill="#7d8590" font-size="12"
          font-family="$MONO" text-anchor="middle">termpeek — sidebar</text>
SVG

# The chart inside the terminal: the same p95-by-region data the demo project
# uses, so the banner shows the real thing rather than invented filler.
CX=$(( TX + 26 ))
CY=$(( TY + 62 ))
BARMAX=$(( TW - 150 ))
printf '    <g font-family="%s" clip-path="url(#screen)">\n' "$MONO"
printf '      <text x="%s" y="%s" fill="#7d8590" font-size="11">[termpeek] p95 latency by region</text>\n' \
  "$CX" "$(( CY - 18 ))"

REGIONS=(us-east-1 us-west-2 eu-west-1 ap-south-1)
VALUES=(118 104 247 163)
y=$CY
for i in "${!REGIONS[@]}"; do
  v="${VALUES[$i]}"
  bw=$(( v * BARMAX / 280 ))
  colour="#3b82f6"; [[ "$v" -gt 200 ]] && colour="#f97316"
  printf '      <text x="%s" y="%s" fill="#adbac7" font-size="12" text-anchor="end">%s</text>\n' \
    "$(( CX + 78 ))" "$(( y + 15 ))" "${REGIONS[$i]}"
  printf '      <rect x="%s" y="%s" width="%s" height="22" rx="4" fill="%s"/>\n' \
    "$(( CX + 90 ))" "$y" "$bw" "$colour"
  printf '      <text x="%s" y="%s" fill="#e6edf3" font-size="12" font-weight="600">%s</text>\n' \
    "$(( CX + 90 + bw + 10 ))" "$(( y + 15 ))" "$v"
  y=$(( y + 40 ))
done
printf '    </g>\n'

cat <<'SVG'
  </g>
</svg>
SVG
} > "$OUT/banner.svg"

rsvg-convert -w "$(( W * 2 ))" -o "$OUT/banner.png" "$OUT/banner.svg" \
  || { echo "rasterise failed" >&2; exit 1; }

printf 'banner.svg  %s\n' "$(du -h "$OUT/banner.svg" | cut -f1)"
printf 'banner.png  %s  %s\n' \
  "$(du -h "$OUT/banner.png" | cut -f1)" \
  "$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$OUT/banner.png" 2>/dev/null)"
