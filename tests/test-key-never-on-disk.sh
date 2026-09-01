#!/usr/bin/env bash
# Does the API key ever touch the disk?
#
# The bug this exists for. Keeping the key out of `argv` was done by writing it to a
# `chmod 600` mktemp file and passing `-H @file`. That closed the `ps auxww` leak and opened
# a different one: a file holding a live credential, removed only by an `rm -f` on the happy
# path. Any signal between the write and the rm strands it.
#
# Measured, with a sentinel key and `probes/glm.sh`'s own `_glm_call`, SIGTERM'd mid-call:
#
#     before=2  after=3  delta=1
#     LEAKED -> /var/folders/.../T/tmp.F7vk7MIqj0  mode=600
#              [Authorization: Bearer SENTINEL-KEY-DO-NOT-USE-a1b2c3d4]
#
# `scripts/quorum-status` and `scripts/quorum-auth` were fixed with
# `trap 'rm -f "$_hdr"' EXIT INT TERM HUP`, and the comment left behind at quorum-status
# said "The adapters and probes already did this; the two shipped scripts did not."
# The adapters did. `probes/glm.sh` never did, and neither did three other sites:
#
#     probes/glm.sh                      no trap at all; window spans `curl -m 900`
#     skills/model-panel/SKILL.md        trap covers $PROMPT $REQ $BODY; $HDR is created
#                                        AFTER it and never added, so the three harmless
#                                        files are signal-cleaned and the key file is not
#     docs/porting/openai-compatible.md  `rm -f` only -- and it is the copy-me template,
#                                        so the defect propagates to every new provider
#     agents/glm-agent.md (2nd snippet)  `rm -f` only
#
# Four of seven sites drifted because CI enforced only half the rule: the gate at
# lint.yml forces the key INTO a file and nothing ever forced it back out.
#
# So the rule this file enforces is not "remember the trap". It is stronger and has no
# failure mode to forget: the key is never written to a file at all. curl reads the header
# from `-H @<(...)`, a /dev/fd pipe. Verified transmitted and absent from argv:
#
#     > Authorization: Bearer SENTINEL-D-TEST-123456     (sent)
#     argv of the live curl process: no key              (safe)
#     key-bearing files in the temp dir: 0               (none, so nothing to strand)
#
# No credentials, no network, no vendor CLIs. The behavioural probe stubs `qt` with a
# sleep, so nothing leaves the machine.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
pass=0; fail=0
check() {
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo "the API key is never written to a file"

cd "$ROOT" || exit 1

# The temp dir mktemp ACTUALLY uses. On macOS `mktemp` with no template reads the
# DARWIN_USER_TEMP_DIR confstr and ignores an exported $TMPDIR, so a check that counts files
# in "$TMPDIR" watches an empty directory and reports a clean run no matter what happened.
# That false negative is why this helper exists instead of a bare "$TMPDIR".
real_tmpdir() {
  getconf DARWIN_USER_TEMP_DIR 2>/dev/null || printf '%s\n' "${TMPDIR:-/tmp}"
}
TD=$(real_tmpdir)
count_key_files() { grep -l '^Authorization: Bearer' "$TD"/tmp.* 2>/dev/null | wc -l | tr -d ' '; }

watches_right_dir() {
  local t rc=1
  t=$(mktemp)
  case "$t" in "$TD"*) rc=0 ;; esac
  rm -f "$t"
  return $rc
}
watches_right_dir
check "the temp dir this test watches is the one mktemp writes to" "$?"

# --- gate 1: no tracked file redirects a Bearer header into a path -------------------------
# Anchored on the redirect, not on the header text, so prose and comments that merely name
# `Authorization: Bearer` do not trip it -- that false positive is what made three earlier
# versions of the argv gate unusable (see docs/field-notes.md).
# The forbidden literal is assembled from two halves so it never appears whole in this
# file. Written out whole, this test would trip the gate it tests. The alternative --
# excluding this file from the gate in lint.yml -- would blind the gate to a real violation
# written here later, which is the same reasoning tests/test-lint-gates.sh already applies
# to its own injection. The comment lines above are safe because the gate ignores comments.
H='Auth'; H="${H}orization: Bearer"
PAT="^[^#]*${H}.*>[[:space:]]*\"?\\\$"

writers=$(git ls-files -z | xargs -0 grep -nE "$PAT" 2>/dev/null)
check "no tracked file writes an Authorization header into a file" \
      "$([ -z "$writers" ] && echo 0 || echo 1)"
[ -n "$writers" ] && printf '%s\n' "$writers" | sed 's/^/          /'

# --- gate 2: the gate can fail -------------------------------------------------------------
# A gate nobody has seen go red is a gate nobody knows the shape of.
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
printf 'printf "%s %%s\\n" "$KEY" > "$HDR"\n' "$H" > "$W/planted.sh"
planted=$(grep -nE "$PAT" "$W/planted.sh")
check "the gate FIRES on a planted key-to-file write (proves it can fail)" \
      "$([ -n "$planted" ] && echo 0 || echo 1)"
printf '# %s <value> > "$file"   -- prose about the old pattern\n' "$H" > "$W/comment.sh"
commented=$(grep -nE "$PAT" "$W/comment.sh")
check "the gate does NOT fire on a comment naming the old pattern" \
      "$([ -z "$commented" ] && echo 0 || echo 1)"

# --- gate 3: behavioural -- interrupt a real call, count what it stranded -------------------
# `qt` is stubbed with a sleep, standing in for the real `curl -m 900`, so this exercises the
# create-then-signal window without a network call.
if [ -r "$ROOT/probes/glm.sh" ]; then
  before=$(count_key_files)
  Z_AI_API_KEY="SENTINEL-KEY-TEST-DO-NOT-USE" bash -c '
    qt() { sleep 30; }
    . "'"$ROOT"'/probes/glm.sh"
    p=$(mktemp); echo hi > "$p"
    ( _glm_call "glm-5.3" "$p" ) & sub=$!
    sleep 2; kill -TERM $sub 2>/dev/null; wait $sub 2>/dev/null; rm -f "$p"
  ' >/dev/null 2>&1
  sleep 1
  after=$(count_key_files)
  check "an interrupted probe call strands no key file (before=$before after=$after)" \
        "$([ "$before" = "$after" ] && echo 0 || echo 1)"
  # Clean up whatever this test itself stranded, so a red run does not leave a sentinel
  # behind and does not poison the next run's `before` count.
  for f in $(grep -l '^Authorization: Bearer SENTINEL-KEY-TEST-DO-NOT-USE' "$TD"/tmp.* 2>/dev/null); do
    rm -f "$f"
  done
else
  echo "  SKIP: probes/glm.sh not readable"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
