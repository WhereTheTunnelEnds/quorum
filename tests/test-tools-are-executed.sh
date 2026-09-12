#!/usr/bin/env bash
# Which installed commands does the suite actually RUN, as opposed to merely read?
#
# lint.yml has a gate asserting every tool in install.sh's TOOLS is "reached by a test".
# That gate is honest about its own limit -- it checks a test holds a PATH to the tool, not
# that it executes it -- but the number it produces (9/9) was quoted in a release note and a
# PR as though it settled coverage. It does not.
#
# Measured 2026-09-11 by replacing each tool with a logging shim and running the suite:
#
#   quorum-sanitize  212 calls    quorum-flags       4 calls
#   quorum-status      9 calls    prep-image         2 calls
#   quorum-claude-on   8 calls    make-probe-image   1 call
#   quorum-setup       0          quorum-auth        0        quorum-verify  0
#
# Six of nine. The three with zero all make live network calls, so they cannot run in an
# offline suite -- a real constraint, not neglect. quorum-setup is genuinely driven by
# tests/drive-setup.exp under a pty, which this loop excludes because it is .exp and costs
# quota. quorum-verify is copied into a sandbox by test-diagnostics-sanitized.sh and read,
# never executed.
#
# So this file replaces an assertion with a measurement. It re-runs that experiment and
# fails if the set of executed tools changes in either direction:
#   - a tool that was executed stops being executed  -> coverage silently regressed
#   - a tool that was NOT executed starts being      -> good news, and the list below is stale
#
# Offline, no credentials, no vendor CLIs -- it runs the same suite CI already runs.
#
#   ./tests/test-tools-are-executed.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SELF=$(basename "$0")
pass=0; fail=0

check() { # check <description> <condition-result>
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

# The measured expectation. Change these ONLY with a fresh measurement, never to make the
# test pass -- a list edited to match reality it did not verify is the thing this replaces.
EXPECT_RUN="quorum-status quorum-flags quorum-claude-on quorum-sanitize prep-image make-probe-image"
EXPECT_NOT_RUN="quorum-setup quorum-auth quorum-verify"

echo "installed commands: executed by the suite, or only read?"

command -v git >/dev/null 2>&1 || { echo "  SKIP: git not installed"; exit 0; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
SB="$WORK/repo"; mkdir -p "$SB"

# TRACKED FILES ONLY -- what actions/checkout gives CI. Copying the live tree would drag in
# whatever happens to be lying around and make the result depend on the developer's machine.
( cd "$REPO" && git archive HEAD ) | tar -x -C "$SB" 2>/dev/null \
  || { echo "  SKIP: could not export a clean tree"; exit 0; }

TOOLS=$(grep -m1 '^TOOLS=' "$SB/scripts/install.sh" | cut -d'"' -f2)
LOG="$WORK/invocations.log"; : > "$LOG"

shimmed=0
for t in $TOOLS; do
  [ -f "$SB/scripts/$t" ] || continue
  mv "$SB/scripts/$t" "$SB/scripts/$t.real"
  printf '#!/bin/sh\necho "%s" >> "%s"\nexec "%s/scripts/%s.real" "$@"\n' \
    "$t" "$LOG" "$SB" "$t" > "$SB/scripts/$t"
  chmod +x "$SB/scripts/$t"
  shimmed=$((shimmed+1))
done
check "shimmed every installed tool ($shimmed)" "$([ "$shimmed" -gt 0 ] && echo 0 || echo 1)"

# Run the suite inside the sandbox, excluding THIS file -- it would recurse.
for f in "$SB"/tests/test-*.sh; do
  [ "$(basename "$f")" = "$SELF" ] && continue
  ( cd "$SB" && bash "$f" ) >/dev/null 2>&1
done

was_run() { grep -qx "$1" "$LOG" 2>/dev/null; }

# Capture the status BEFORE building the description. Writing
#   was_run "$t"; check "... ($(grep -cx ...))" $?
# reads $? from the command substitution inside the description, not from was_run -- so every
# row passes regardless. Measured while writing this: with quorum-flags forced to zero calls,
# its row still printed `ok ... (0 calls)`, and only the aggregate count below caught it.
for t in $EXPECT_RUN; do
  was_run "$t"; rc=$?
  n=$(grep -cx "$t" "$LOG" 2>/dev/null); n=${n:-0}
  check "$t is executed by the suite ($n calls)" "$rc"
done

for t in $EXPECT_NOT_RUN; do
  was_run "$t"; rc=$?
  check "$t is NOT executed (network-bound; still only read)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
done

# The count is the headline anyone quotes, so assert it directly rather than leaving it to
# be inferred from the rows above.
ran=0; for t in $TOOLS; do was_run "$t" && ran=$((ran+1)); done
total=$(echo "$TOOLS" | wc -w | tr -d ' ')
check "executed $ran of $total installed commands (expected 6 of 9)" \
  "$([ "$ran" = 6 ] && [ "$total" = 9 ] && echo 0 || echo 1)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
