#!/usr/bin/env bash
# Does the glm adapter actually read back which model answered?
#
# Z.AI silently redirects a RETIRED model id to a different model and still returns HTTP 200
# with a correct answer and an identical response shape. Measured 2026-09-09: `glm-4.6` and
# `glm-4.5-air` are both answered by `glm-5.3-flash`; only a wholly unknown id returns 400.
# The adapter asks for `glm-5.3`, which is honoured today, so this is a trap that is armed
# rather than a bug that has fired -- the day that id retires, the panel starts recording a
# smaller flash model's opinion as GLM's. `quorum-flags` cannot catch it: that watches CLI
# flags, and this substitution involves no flag at all.
#
# WHY THIS TEST IS SHAPED THE WAY IT IS.
#
# Four vendors' coding agents were each given this exact task, independently, in separate
# worktrees. All four wrote a test that re-implemented the adapter's comparison INSIDE the
# test file and asserted against that copy. All four passed. All four "proved" the test could
# fail -- by breaking their own copy. Deleting the real `GOT_MODEL=` line from
# agents/glm-agent.md left every one of them green, at identical assertion counts:
#
#   codex 11 -> 11    copilot 10 -> 10    glm 13 -> 13    claude-alt 12 -> 12
#
# 46 assertions, four vendors, zero coverage of the thing they named. So this test runs the
# adapter's OWN bash block, extracted from agents/glm-agent.md at run time -- the same method
# tests/test-lint-gates.sh uses on lint.yml, and for the same stated reason: a paraphrase
# tests a copy that can drift. The check below is the real one or the test is worthless.
#
# Offline: `curl` is stubbed on PATH, so no network, no credential, no quota.
#
#   ./tests/test-glm-reports-answering-model.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
ADAPTER="$REPO/agents/glm-agent.md"
pass=0; fail=0

check() { # check <description> <condition-result>
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

[ -r "$ADAPTER" ] || { echo "SKIP: $ADAPTER not readable"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

echo "glm adapter reads back the model that answered"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

# --- extract the adapter's consult block, verbatim -----------------------------------------
# Anchored on the fence that CONTAINS `WANT_MODEL=`, so reordering the file cannot silently
# select a different block. If the anchor stops matching, that is a hard failure, not a skip:
# a test that quietly stops finding its subject reports the same green as one that passed.
start=$(awk '/^```bash$/{last=NR} /^WANT_MODEL=/{print last; exit}' "$ADAPTER")
end=$(awk -v s="${start:-0}" 'NR>s && /^```$/{print NR; exit}' "$ADAPTER")
if [ -z "$start" ] || [ -z "$end" ]; then
  echo "  FAIL  could not locate the consult block in $ADAPTER (anchor: a bash fence containing WANT_MODEL=)"
  echo; echo "0 passed, 1 failed"; exit 1
fi
BLOCK="$WORK/block.sh"
sed -n "$((start+1)),$((end-1))p" "$ADAPTER" > "$BLOCK"
check "located the adapter's consult block (lines $start-$end)" 0

grep -q '^GOT_MODEL=' "$BLOCK"
check "the block reads .model back into GOT_MODEL" $?

grep -q '^WANT_MODEL=' "$BLOCK"
check "the block declares WANT_MODEL once, as a variable" $?

# The request must be built FROM that variable. Hardcoding the id in the jq filter is the
# drift this guards: the request changes and the check keeps validating the retired name.
grep -q 'arg m "\$WANT_MODEL"' "$BLOCK"
check "the request is built from WANT_MODEL, not a second hardcoded id" $?

# --- run it, with curl stubbed -------------------------------------------------------------
# The stub writes a fixture to curl's `-o` target and prints an http code, which is exactly
# the contract the block depends on.
cat > "$BIN/curl" <<'STUB'
#!/bin/sh
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && cat "$FIXTURE" > "$out"
printf '%s' "${HTTP_CODE:-200}"
STUB
chmod +x "$BIN/curl"

# `${VAR-UNSET}`, NOT `${VAR:-UNSET}`. The colon form substitutes on empty as well as unset,
# so it reports UNSET for a variable that was correctly set to "" -- collapsing "the field was
# absent from the response" into "the adapter never ran". That is the same operator trap as
# jq's `//`, which is the alternative operator and fires on `false` too; it cost this repo a
# probe that reported every success as a failure. Measured here: with the colon, the
# absent-.model assertion could not distinguish a working adapter from a gutted one.
run_block() { # run_block <model-in-response> ; echoes "WANT|GOT"
  # Build the fixture with jq, not a heredoc. Measured while writing this: an unquoted
  # heredoc eats the quotes inside ${1:+,"model":"$1"} and emits `,model:glm-5.3` -- an
  # unquoted key and value, so jq parsed nothing and GOT_MODEL came back empty. The test
  # then "failed" for a reason with no connection to the adapter it was testing.
  if [ -n "$1" ]; then
    jq -n --arg m "$1" '{id:"msg_test",type:"message",role:"assistant",model:$m,
      content:[{type:"text",text:"OK"}],stop_reason:"end_turn"}' > "$WORK/fixture.json"
  else
    jq -n '{id:"msg_test",type:"message",role:"assistant",
      content:[{type:"text",text:"OK"}],stop_reason:"end_turn"}' > "$WORK/fixture.json"
  fi
  jq -e . "$WORK/fixture.json" >/dev/null || { echo "FIXTURE IS NOT VALID JSON" >&2; return 1; }
  FIXTURE="$WORK/fixture.json" \
  PATH="$BIN:$REPO/scripts:/usr/bin:/bin" \
  Z_AI_API_KEY=stub-not-a-real-key \
  bash -c 'set +u; . "$1" >/dev/null 2>&1; printf "%s|%s" "${WANT_MODEL-UNSET}" "${GOT_MODEL-UNSET}"' _ "$BLOCK"
}

# 1. the id is honoured -- GOT_MODEL must equal WANT_MODEL
r=$(run_block "glm-5.3"); w=${r%%|*}; g=${r##*|}
check "honoured id: WANT_MODEL resolved (got '$w')" "$([ "$w" = "glm-5.3" ] && echo 0 || echo 1)"
check "honoured id: GOT_MODEL read back as '$g'" "$([ "$g" = "glm-5.3" ] && echo 0 || echo 1)"
check "honoured id: they match, so no diagnostics is correct" "$([ "$w" = "$g" ] && echo 0 || echo 1)"

# 2. the measured substitution -- a different model answered
r=$(run_block "glm-5.3-flash"); w=${r%%|*}; g=${r##*|}
check "substituted: GOT_MODEL read back as '$g'" "$([ "$g" = "glm-5.3-flash" ] && echo 0 || echo 1)"
# Assert the ACTUAL value, not merely inequality: "UNSET" is also != "glm-5.3", so an
# inequality check alone goes green against an adapter that never read anything back.
check "substituted: mismatch is detectable and GOT is the substituted id" \
  "$([ "$w" != "$g" ] && [ "$g" = "glm-5.3-flash" ] && echo 0 || echo 1)"

# 3. .model absent entirely -- must be empty, never the string "null"
r=$(run_block ""); g=${r##*|}
# Must be SET-AND-EMPTY, never UNSET. Accepting UNSET here would let this assertion pass
# against an adapter whose readback line was deleted entirely -- measured: it did, until
# this was tightened. "The field was absent" and "the code never ran" are different facts
# and the test has to be able to tell them apart.
check "absent .model: GOT_MODEL is set and empty, not UNSET (got '$g')" \
  "$([ "$g" = "" ] && echo 0 || echo 1)"

# --- the assertion the four delegated attempts all failed ----------------------------------
# Break the REAL adapter in a scratch copy and confirm the extraction notices. Without this,
# every check above passes against an adapter with no readback at all -- measured, four times.
SCRATCH="$WORK/glm-broken.md"
perl -0pe 's/^GOT_MODEL=.*\n//m' "$ADAPTER" > "$SCRATCH"
bstart=$(awk '/^```bash$/{last=NR} /^WANT_MODEL=/{print last; exit}' "$SCRATCH")
bend=$(awk -v s="${bstart:-0}" 'NR>s && /^```$/{print NR; exit}' "$SCRATCH")
sed -n "$((bstart+1)),$((bend-1))p" "$SCRATCH" > "$WORK/broken-block.sh"
grep -q '^GOT_MODEL=' "$WORK/broken-block.sh"
check "removing GOT_MODEL from the adapter IS detected (proves this file tests the adapter)" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
