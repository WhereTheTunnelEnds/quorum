#!/usr/bin/env bash
# Is the probe image actually what the docs say it is?
#
# This test exists because of a specific mistake. The docs described the probe image as
# "red circle (top-left), green square (top-right)..." and I read that as *the circle is
# red*. It is not: the circle is WHITE and the QUADRANT is red. `make-probe-image` says so
# in the docstring of the function that draws the shapes, but the prose describing it did
# not, and prose was what I checked against.
#
# The consequence: I asked codex for "<colour> <shape>", got `white circle` on some runs and
# `red circle` on others -- both correct -- scored one of them as failure, and published a
# 36% vision failure rate that did not exist. The probe prompt, the codex adapter's verified
# claim, a field note and an evidence row all had to be retracted.
#
# The ground truth for a vision probe cannot live in a sentence. It has to be read out of
# the pixels, by a program, on every run. That is this file.
#
# It asserts the two things the prompt depends on:
#   1. every shape is white          -> so "name the colour" is ambiguous unless you say which
#   2. each quadrant's background is the colour the docs name, in the position they name
#
# If someone changes the palette or moves a shape, the prompt in probe-checklist.md and the
# expected-answer table in make-probe-image become wrong, and this fails rather than letting
# a future run be scored against a stale table.
#
# Pure stdlib PNG decode. No Pillow, no network, no provider calls.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GEN="$HERE/../scripts/make-probe-image"
pass=0; fail=0
check() {
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo "probe image matches the ground truth the docs publish"

command -v python3 >/dev/null 2>&1 || { echo "  SKIP: python3 not installed"; exit 0; }
[ -x "$GEN" ] || { echo "  FAIL  $GEN is not executable"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
IMG="$T/probe.png"
"$GEN" "$IMG" >/dev/null 2>&1
check "make-probe-image produces a file" "$([ -s "$IMG" ] && echo 0 || echo 1)"
[ -s "$IMG" ] || { echo; printf '%d passed, %d failed\n' "$pass" "$fail"; exit 1; }

RES=$(python3 - "$IMG" <<'PY'
import zlib, struct, sys

d = open(sys.argv[1], 'rb').read()
if d[:8] != b'\x89PNG\r\n\x1a\n':
    print("BAD not a PNG"); sys.exit(0)

i, idat, w, h, depth, ctype = 8, b'', 0, 0, 0, 0
while i + 8 <= len(d):
    ln = struct.unpack('>I', d[i:i+4])[0]
    typ = d[i+4:i+8]
    if typ == b'IHDR':
        w, h, depth, ctype = struct.unpack('>IIBB', d[i+8:i+18])
    elif typ == b'IDAT':
        idat += d[i+8:i+8+ln]
    i += 12 + ln

if (depth, ctype) != (8, 2):
    print(f"BAD expected 8-bit truecolour, got depth={depth} colourtype={ctype}"); sys.exit(0)
print(f"DIM {w} {h}")

raw = zlib.decompress(idat)
stride = w * 3 + 1

# Undo the per-scanline PNG filters. make-probe-image may emit filter 0, but decoding all
# five means this test does not silently break if the generator starts filtering.
out = bytearray()
prev = bytearray(w * 3)
for y in range(h):
    f = raw[y * stride]
    line = bytearray(raw[y * stride + 1: (y + 1) * stride])
    for x in range(len(line)):
        a = line[x - 3] if x >= 3 else 0
        b = prev[x]
        c = prev[x - 3] if x >= 3 else 0
        if   f == 1: line[x] = (line[x] + a) & 0xFF
        elif f == 2: line[x] = (line[x] + b) & 0xFF
        elif f == 3: line[x] = (line[x] + (a + b) // 2) & 0xFF
        elif f == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xFF
    out += line
    prev = line

def px(x, y):
    o = y * w * 3 + x * 3
    return tuple(out[o:o+3])

WHITE = (255, 255, 255)
# The palette make-probe-image defines, keyed by the label the docs use for it.
EXPECT = {
    'top-left':     ('red',    (200, 30, 30),   (0,   0)),
    'top-right':    ('green',  (30, 150, 60),   (256, 0)),
    'bottom-left':  ('blue',   (30, 70, 200),   (0,   256)),
    'bottom-right': ('yellow', (220, 190, 40),  (256, 256)),
}

for label, (name, rgb, (ox, oy)) in EXPECT.items():
    # Quadrant centre lands inside the shape for all four shapes drawn here.
    centre = px(ox + 128, oy + 128)
    # A corner is background for all four: no shape reaches the quadrant's corner.
    corner = px(ox + 8, oy + 8)
    print(f"SHAPE {label} {'white' if centre == WHITE else 'notwhite'} {centre[0]},{centre[1]},{centre[2]}")
    print(f"BG {label} {name} {'match' if corner == rgb else 'mismatch'} {corner[0]},{corner[1]},{corner[2]}")

# The four backgrounds must be DISTINCT, or "name the colour" cannot discriminate quadrants.
print("DISTINCT", len({v[1] for v in EXPECT.values()}))

# There must be a substantial amount of white, or "the shapes are white" is vacuous, and a
# substantial amount of non-white, or the image is blank. This is the assertion that would
# have caught an all-white or all-colour image.
tot = w * h
white_n = sum(1 for y in range(0, h, 4) for x in range(0, w, 4) if px(x, y) == WHITE)
sampled = len(range(0, h, 4)) * len(range(0, w, 4))
print(f"WHITEFRAC {white_n} {sampled}")
PY
)

dim=$(printf '%s\n' "$RES" | awk '/^DIM/{print $2"x"$3}')
check "image is 512x512 (got ${dim:-none})" "$([ "$dim" = "512x512" ] && echo 0 || echo 1)"

# --- 1. every shape is white -------------------------------------------------------------
# This is the assertion whose absence caused the retraction. If it ever fails, the prompt in
# probe-checklist.md is wrong and must change with it.
for q in top-left top-right bottom-left bottom-right; do
  line=$(printf '%s\n' "$RES" | awk -v q="$q" '$1=="SHAPE" && $2==q')
  got=$(printf '%s' "$line" | awk '{print $3}')
  rgb=$(printf '%s' "$line" | awk '{print $4}')
  check "$q: the SHAPE is white (rgb $rgb)" "$([ "$got" = white ] && echo 0 || echo 1)"
done

# --- 2. backgrounds are the colours the docs name, where the docs say they are ------------
for q in top-left top-right bottom-left bottom-right; do
  line=$(printf '%s\n' "$RES" | awk -v q="$q" '$1=="BG" && $2==q')
  name=$(printf '%s' "$line" | awk '{print $3}')
  got=$(printf '%s' "$line" | awk '{print $4}')
  rgb=$(printf '%s' "$line" | awk '{print $5}')
  check "$q: BACKGROUND is $name (rgb $rgb)" "$([ "$got" = match ] && echo 0 || echo 1)"
done

n=$(printf '%s\n' "$RES" | awk '/^DISTINCT/{print $2}')
check "the four backgrounds are distinct colours (got ${n:-0})" \
      "$([ "${n:-0}" = 4 ] && echo 0 || echo 1)"

wn=$(printf '%s\n' "$RES" | awk '/^WHITEFRAC/{print $2}')
ws=$(printf '%s\n' "$RES" | awk '/^WHITEFRAC/{print $3}')
# Between 5% and 60%: enough white that the shapes are real, enough colour that the
# backgrounds are. An all-white or all-coloured image fails both bounds.
check "white covers 5-60% of the image (${wn:-0}/${ws:-0} sampled)" \
      "$(python3 -c "import sys;w=${wn:-0};s=${ws:-1};sys.exit(0 if s and 0.05 <= w/s <= 0.60 else 1)" && echo 0 || echo 1)"

# --- 3. the docs must not describe the shapes as coloured ---------------------------------
# The original error in one grep: prose that pairs a colour word directly with a shape word
# reads as "the circle is red". The checklist and the generator must say BACKGROUND.
for f in "$HERE/../skills/build-adapter/reference/probe-checklist.md" "$HERE/../scripts/make-probe-image"; do
  base=$(basename "$f")
  check "$base tells the reader to ask for the BACKGROUND colour" \
        "$(grep -qi 'background colour\|background color\|coloured background\|colored background' "$f" && echo 0 || echo 1)"
done

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
