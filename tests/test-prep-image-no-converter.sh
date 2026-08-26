#!/usr/bin/env bash
# Does prep-image fail CLEANLY when no image converter is installed?
#
# docs/evidence.md claimed this, and offered a re-check command that could not produce the
# result. Three independent reasons, all measured:
#
#   env -i HOME="$HOME" PATH=/usr/bin:/bin prep-image x.png
#
#   1. `prep-image` is not on that PATH        -> env: No such file or directory, rc=127
#   2. `x.png` does not exist                  -> the usage guard exits BEFORE the converter
#                                                 check is ever reached
#   3. `sips` lives at /usr/bin/sips           -> which that PATH includes, so the stated
#                                                 precondition "no converter present" is
#                                                 false on any Mac
#
# And the "fixed" form returned 1, which LOOKS like the claim confirmed — in the file whose
# entire purpose is that claims can be re-checked. A verification that passes for the wrong
# reason is worse than none.
#
# So the claim is tested here instead of described: a real file, and a PATH built to contain
# what the script needs and no converter.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PREP="$HERE/../scripts/prep-image"
pass=0; fail=0
check() {
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo "prep-image with no converter"

BIN=$(mktemp -d)/bin; mkdir -p "$BIN"
# Everything prep-image needs, and deliberately none of sips / magick / convert.
for t in bash sh mkdir mktemp cat head tr wc ls rm stat basename dirname printf readlink cut awk sed grep; do
  src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$BIN/$t" 2>/dev/null
done
for c in sips magick convert; do
  if PATH="$BIN" command -v "$c" >/dev/null 2>&1; then
    echo "  SETUP FAILED: $c is reachable from the stub PATH; the test would pass for the wrong reason"
    exit 1
  fi
done

IMGDIR=$(mktemp -d); IMG="$IMGDIR/real.png"
# A real file, so the usage guard is passed and the converter check is actually reached.
printf '\x89PNG\r\n\x1a\n' > "$IMG"; head -c 256 /dev/urandom >> "$IMG"
check "the stub PATH contains no converter" 0
check "the input file exists (so the usage guard is not what we measure)" "$([ -s "$IMG" ] && echo 0 || echo 1)"

out=$(env -i HOME="$HOME" PATH="$BIN" "$PREP" "$IMG" 2>&1)
env -i HOME="$HOME" PATH="$BIN" "$PREP" "$IMG" >/dev/null 2>&1
rc=$?

check "exits non-zero rather than pretending to succeed (rc=$rc)" \
      "$([ "$rc" != 0 ] && echo 0 || echo 1)"
check "names the missing dependency instead of failing obscurely" \
      "$(printf '%s' "$out" | grep -qi 'sips\|imagemagick\|magick\|convert' && echo 0 || echo 1)"
check "does not emit a path as though a file had been produced" \
      "$(printf '%s' "$out" | grep -q 'prepped' && echo 1 || echo 0)"

rm -rf "$BIN" "$IMGDIR"
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
