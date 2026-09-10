#!/usr/bin/env bash
# Does `quorum-flags` actually notice when a vendor removes a flag?
#
# quorum-flags is the drift detector: it exists because "an adapter is a set of assumptions
# about someone else's CLI", and when `--no-ask-user` becomes `--non-interactive` the adapter
# does not error in a way anyone notices -- it hangs, or returns nothing, which is
# indistinguishable from a model with nothing to say.
#
# It shipped with ZERO tests. A drift detector nobody has watched detect drift is the same
# object as the probe that reported success as failure: a green light asserting a property
# no one measured. Worse here, because its own header documents a bug where
# `quorum-flags && echo current` printed "current" on a machine that checked nothing.
#
# METHOD. Put stub vendor CLIs on a scrubbed PATH. The stub IS the vendor's --help output,
# so drift is simulated exactly -- a flag present in one run and absent in the next -- with
# no network, no credentials, and no real CLI installed. `providers()` decides a provider is
# installed by running `help_for` for real, so a stub on PATH is indistinguishable from the
# genuine article, which is the property that makes this testable at all.
#
# Three cases, and the third is the one that already went wrong in production:
#   1. every flag present  -> exit 0, nothing missing
#   2. one flag removed    -> non-zero, and it NAMES the flag
#   3. no CLI installed    -> non-zero. "I checked nothing" must never exit 0.
#
#   ./tests/test-flags-detects-drift.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
FLAGS="$REPO/scripts/quorum-flags"
pass=0; fail=0

check() { # check <description> <condition-result>
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

[ -x "$FLAGS" ] || { echo "SKIP: $FLAGS not executable"; exit 0; }

echo "quorum-flags detects drift"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"; mkdir -p "$STUB"

# Scrubbed PATH: the real codex/copilot/claude/agy must not be reachable, or the result
# depends on what happens to be installed on the machine running the test. (Same reason
# a scrubbed PATH makes quorum-verify skip the nvm-installed copilot.)
run() { PATH="$STUB:/usr/bin:/bin" "$FLAGS" check 2>&1; }

make_stub() { # make_stub <flags...>  -- writes a `codex` whose --help lists exactly these
  { printf '#!/bin/sh\n'
    printf 'for f in %s; do echo "  $f"; done\n' "$*"
  } > "$STUB/codex"
  chmod +x "$STUB/codex"
}

# --- 3. nothing installed ---------------------------------------------------------------
# Done FIRST, while $STUB is still empty, because it is the case that already shipped broken.
out=$(run); rc=$?
check "no provider CLI installed -> non-zero exit (not a silent pass)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
printf '%s' "$out" | grep -q 'no flags were checked'
check "no provider CLI installed -> says so out loud" $?

# --- 1. every flag present ---------------------------------------------------------------
make_stub --sandbox --skip-git-repo-check --full-auto --model --cd
out=$(run); rc=$?
check "all flags present -> exit 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
printf '%s' "$out" | grep -q 'GONE'
check "all flags present -> reports nothing GONE" "$([ $? -ne 0 ] && echo 0 || echo 1)"
printf '%s' "$out" | grep -qE '[1-9][0-9]* present'
check "all flags present -> actually checked something (non-zero 'present')" $?

# --- 2. one flag removed ------------------------------------------------------------------
# --sandbox is the codex adapter's read-only boundary. If it vanished and this stayed green,
# the adapter would go on passing a flag the CLI ignores -- the failure mode that matters.
make_stub --skip-git-repo-check --full-auto --model --cd
out=$(run); rc=$?
check "a removed flag -> non-zero exit" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
printf '%s' "$out" | grep -q -- '--sandbox'
check "a removed flag -> names the flag that vanished" $?
printf '%s' "$out" | grep -q 'GONE'
check "a removed flag -> marks it GONE" $?

# --- `--list` is a documented subcommand, and it had no coverage either ------------------
# It reports the provider's CURRENT surface rather than comparing against the adapter, so it
# must show a flag the adapter does not use. Without this, --list could return nothing at all
# and every assertion above would still pass.
listed=$(PATH="$STUB:/usr/bin:/bin" "$FLAGS" --list codex 2>&1)
printf '%s' "$listed" | grep -q -- '--full-auto'
check "--list reports a flag the adapter never asked about" $?
printf '%s' "$listed" | grep -q -- '--sandbox'
check "--list omits the flag the stub stopped advertising" "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
