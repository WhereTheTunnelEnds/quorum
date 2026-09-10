#!/usr/bin/env bash
# `quorum-claude-on` shipped with no test that ever ran it.
#
# It is the one installed tool that both HANDLES A CREDENTIAL and ENDS IN `exec claude`, so
# the two things worth proving are that the token reaches the child as environment and never
# as argv, and that the failure paths refuse rather than exec into a half-configured run.
#
# SECURITY.md claims "credentials never reach argv — anything on a command line is visible to
# `ps auxww` for every process running as you." For this tool that claim rests entirely on
# `exec claude "$@"` with the env file sourced rather than passed. Nothing tested it. The
# stub below is a `claude` that records its own argv and environment, which turns that claim
# into a measurement.
#
# Fully offline: QUORUM_ENDPOINT_DIR redirects the preset directory into a sandbox, so the
# real ~/.config/quorum/endpoints is never read, written, or overwritten, and `claude` is a
# stub on PATH -- no subscription is spent and no request leaves the machine.
#
#   ./tests/test-claude-on-presets.sh

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
ON="$REPO/scripts/quorum-claude-on"
pass=0; fail=0

check() { # check <description> <condition-result>
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

[ -x "$ON" ] || { echo "SKIP: $ON not executable"; exit 0; }

echo "quorum-claude-on presets and credential handling"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export QUORUM_ENDPOINT_DIR="$WORK/endpoints"
STUB="$WORK/bin"; mkdir -p "$STUB"

# A `claude` that reports what it was handed, instead of being Claude.
cat > "$STUB/claude" <<'STUBEOF'
#!/bin/sh
printf '%s\n' "$@" > "$ARGV_OUT"
env > "$ENV_OUT"
STUBEOF
chmod +x "$STUB/claude"
export ARGV_OUT="$WORK/argv" ENV_OUT="$WORK/env"

run() { PATH="$STUB:/usr/bin:/bin" "$ON" "$@" 2>&1; }

# --- no presets yet -----------------------------------------------------------------------
out=$(run --list); check "--list on an empty dir says so" "$(printf '%s' "$out" | grep -q '(no presets)' && echo 0 || echo 1)"

out=$(run nosuch -p hi); rc=$?
check "unknown preset -> non-zero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
printf '%s' "$out" | grep -q -- '--init nosuch'
check "unknown preset -> names the command that fixes it" $?

out=$(run --bogus); rc=$?
check "unknown option -> non-zero, not treated as a preset name" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

# --- --init -------------------------------------------------------------------------------
out=$(run --init demo); rc=$?
check "--init exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
check "--init created the preset file" "$([ -f "$QUORUM_ENDPOINT_DIR/demo.env" ] && echo 0 || echo 1)"

mode=$(ls -l "$QUORUM_ENDPOINT_DIR/demo.env" 2>/dev/null | cut -c1-10)
check "--init wrote it mode 600 (owner-only), got '$mode'" "$([ "$mode" = "-rw-------" ] && echo 0 || echo 1)"

grep -q 'MY_PROVIDER_KEY' "$QUORUM_ENDPOINT_DIR/demo.env"
check "the template references a key by variable, never a literal" $?

out=$(run --init demo); rc=$?
check "--init on an existing preset REFUSES (does not clobber a working config)" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"

check "--list now shows it" "$(run --list | grep -qx demo && echo 0 || echo 1)"

# --- the empty-token trap -----------------------------------------------------------------
# The template's AUTH_TOKEN expands from an unset variable. Sourcing it must fail loudly
# rather than exec into claude with an empty credential, which would surface as an opaque
# auth error from the endpoint rather than a configuration mistake here.
out=$(run demo -p hi); rc=$?
check "unset source variable -> refuses, does not exec" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)"
check "unset source variable -> claude was never invoked" "$([ ! -f "$ARGV_OUT" ] && echo 0 || echo 1)"

# --- a working preset, and where the token ends up -----------------------------------------
SECRET='sk-test-CANARY-4f3a9c'
cat > "$QUORUM_ENDPOINT_DIR/good.env" <<ENVEOF
ANTHROPIC_BASE_URL="https://example.invalid/anthropic"
ANTHROPIC_AUTH_TOKEN="$SECRET"
ANTHROPIC_MODEL="test-model"
ENVEOF
chmod 600 "$QUORUM_ENDPOINT_DIR/good.env"

run good -p "explain this repo" --allowedTools "Read,Glob,Grep" >/dev/null 2>&1
check "a valid preset execs claude" "$([ -f "$ARGV_OUT" ] && echo 0 || echo 1)"

grep -qx -- '-p' "$ARGV_OUT" 2>/dev/null
check "claude received the caller's own arguments" $?

# THE claim. Not "a key is not in argv by inspection" -- the child's real argv, measured.
grep -qF -- "$SECRET" "$ARGV_OUT" 2>/dev/null
check "the token is NOT in the child's argv (ps auxww cannot see it)" "$([ $? -ne 0 ] && echo 0 || echo 1)"

grep -qF -- "$SECRET" "$ENV_OUT" 2>/dev/null
check "the token IS in the child's environment (it was actually passed)" $?

grep -q 'ANTHROPIC_BASE_URL=https://example.invalid/anthropic' "$ENV_OUT" 2>/dev/null
check "the endpoint override reached the child" $?

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
