#!/usr/bin/env bash
# Every adapter must be checked by `quorum-auth`.
#
# This exists because it was NOT true. Seven adapters shipped; quorum-auth checked five.
# Running it printed "Everything requested is authenticated." while OPENROUTER_API_KEY and
# CLAUDE_ALT_OAUTH_TOKEN were never looked at — so a teammate following the documented
# onboarding path got a green all-clear over two providers that were not configured at all.
#
# That is the failure last-call's AGENTS.md calls "a guard that declines to run reports the
# same green as a guard that passed", inside quorum's own onboarding tool. A doc that points
# at a tool which lies is worse than no doc. The fix for the instance was two blocks; the fix
# for the CLASS is this test, which fails the moment an eighth adapter lands without one.
#
# Needs no credentials, no network, no vendor CLIs — it reads files.
#
#   ./tests/test-auth-covers-every-adapter.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
AUTH="$HERE/../scripts/quorum-auth"
AGENTS_DIR="$HERE/../agents"
pass=0; fail=0

check() { # check <description> <condition-result>
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

[ -r "$AUTH" ] || { echo "SKIP: $AUTH not readable"; exit 0; }
[ -d "$AGENTS_DIR" ] || { echo "SKIP: $AGENTS_DIR missing"; exit 0; }

echo "adapters vs quorum-auth coverage"

# `wants <name>` is how quorum-auth gates each provider block, and it is also what makes
# `quorum-auth <provider>` work for that name. Both properties come from the same line, so
# grepping for it tests the real mechanism rather than a naming convention.
covered() { # covered <provider-slug>
  grep -qE "wants[[:space:]]+$1( |;|\$|\))" "$AUTH"
}

found=0
for f in "$AGENTS_DIR"/*-agent.md; do
  [ -e "$f" ] || continue
  name=$(basename "$f" -agent.md)
  found=$((found+1))
  covered "$name"
  check "quorum-auth checks '$name'" $?
done

check "found at least one adapter to check" "$([ "$found" -gt 0 ] && echo 0 || echo 1)"

# quorum-setup is the OTHER onboarding surface, and it had the same hole: its PROVIDERS
# table listed six of the seven adapters, so `quorum-setup --check` walked a newcomer
# through every provider except claude-alt and never mentioned it existed. Same class,
# same fix, so guard it in the same place.
SETUP="$HERE/../scripts/quorum-setup"
if [ -r "$SETUP" ]; then
  for f in "$AGENTS_DIR"/*-agent.md; do
    [ -e "$f" ] || continue
    name=$(basename "$f" -agent.md)
    # The first entry shares its line with `PROVIDERS='`, so a bare ^ anchor misses it --
    # measured: this test reported codex uncovered when quorum-setup offers it correctly.
    grep -qE "^(PROVIDERS=')?$name\^" "$SETUP"
    check "quorum-setup offers '$name'" $?
  done
else
  echo "  note  quorum-setup not readable, skipping its half"
fi

# The reverse direction is deliberately NOT asserted. quorum-auth legitimately checks things
# that are not adapters -- `claude` is the session's own login, and `agy` is an alias for
# antigravity -- so requiring a 1:1 mapping would fail on correct code.

# A provider named in the summary but never probed is the original bug in miniature: the
# count of OK lines must be able to reach the number of adapters. Guard the arithmetic that
# produces "Everything requested is authenticated" -- it keys off `need`, which only `bad`
# increments, so a block that prints nothing at all still reads as success.
grep -q 'Everything requested is authenticated' "$AUTH"
check "summary line still present (it is what a silent gap renders as)" $?

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
