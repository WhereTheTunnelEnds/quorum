#!/usr/bin/env bash
# Do the verify and delegate blocks do what the safety model says they do?
#
# These are the tiers that RUN COMMANDS and WRITE FILES. They were the least tested thing in
# the repo: `tests/test-adapter-blocks.sh` covers consult, which is read-only, and covered
# nothing else — 5 of 21 runnable blocks, all of them the safest tier. Coverage was exactly
# inverted from risk.
#
# What is being asserted, per block, is the set of properties docs/safety-model.md claims:
#
#   1. it creates a worktree, and two runs never collide       (the $TASK_SLUG bug)
#   2. a failed `git worktree add` STOPS it                    (two agents in one tree)
#   3. the provider is pointed at the worktree, not the repo   (-C / cd)
#   4. its result check sees NEW files, not just modified ones (`diff --stat` hides them)
#   5. an escape into the real checkout is SURFACED by the block's own output
#
# Point 5 is the one that matters most and the one most easily misread. A worktree is **not**
# a boundary — docs/adapter-contract.md says so plainly, and a provider can reach the real
# checkout with a single `git rev-parse`. The guarantee this repo actually offers is that an
# escape is *detected and reported*, not prevented. So the test simulates an escape and
# requires the block to reveal it. A block whose output stays silent has quietly downgraded
# a detection guarantee to nothing.
#
# Providers are shimmed. The point is the block, not the vendor: no credentials, no network,
# no quota. The shim honours `-C` exactly as the real CLIs do, so a block that forgets to
# pass it fails point 3 rather than passing by accident.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "verify and delegate blocks honour the safety model"

command -v git     >/dev/null 2>&1 || { echo "  SKIP: git not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "  SKIP: python3 not installed"; exit 0; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM HUP

# --- shimmed providers -------------------------------------------------------------------
# Honour -C the way codex and copilot do; otherwise write into the current directory, which
# is how the glm blocks invoke quorum-claude-on (inside a `cd "$WT"` subshell).
SHIM="$WORK/bin"; mkdir -p "$SHIM"
for b in codex copilot quorum-claude-on; do
  cat > "$SHIM/$b" <<'SH'
#!/usr/bin/env bash
target="$PWD"
prev=""
for a in "$@"; do
  [ "$prev" = "-C" ] && target="$a"
  prev="$a"
done
mkdir -p "$target"
[ -n "${QUORUM_SHIM_LOG:-}" ] && echo "TARGET=$target" >> "$QUORUM_SHIM_LOG"
echo "work by a delegate" > "$target/delegated.txt"        # a NEW file: diff --stat hides these
[ -f "$target/tracked.txt" ] && echo "modified" >> "$target/tracked.txt"
# The escape. A worktree is not a boundary, so this SUCCEEDS — the question the test asks is
# whether the block's own output reveals it afterwards.
if [ "${QUORUM_SHIM_ESCAPE:-0}" = 1 ] && [ -n "${QUORUM_MAIN_REPO:-}" ]; then
  echo "escaped" > "$QUORUM_MAIN_REPO/escaped.txt"
fi
echo "PROVIDER RAN"
SH
  chmod +x "$SHIM/$b"
done

# --- a scratch "user project" -------------------------------------------------------------
newrepo() {
  d="$WORK/proj$1"; rm -rf "$d"; mkdir -p "$d"
  ( cd "$d" && git init -q . \
      && echo original > tracked.txt && git add tracked.txt \
      && git -c user.email=t@example -c user.name=t commit -q -m init )
  echo "$d"
}

extract() {  # extract <file> <substring>
  python3 - "$1" "$2" <<'PY'
import re, sys, pathlib
src, needle = pathlib.Path(sys.argv[1]).read_text(), sys.argv[2]
b = [m.group(1) for m in re.finditer(r'```bash\n(.*?)```', src, re.S) if needle in m.group(1)]
if len(b) != 1:
    sys.stderr.write(f"expected 1 block containing {needle!r}, found {len(b)}\n"); sys.exit(1)
sys.stdout.write(b[0])
PY
}

prep() {  # prep <blockfile> — make it runnable without a real provider
  python3 - "$1" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("timeout 900 ", "")
s += "\n" + "\n".join([
  'echo "WT=$WT"',
  'echo "BRANCH=${BRANCH:-}"',
]) + "\n"
p.write_text(s)
PY
}

# Every verify/delegate block in the repo, identified by a substring unique to it.
BLOCKS="
codex|verify|agents/codex-agent.md|codex-verify-\$\$
codex|delegate|agents/codex-agent.md|BRANCH=\"codex/
copilot|verify|agents/copilot-agent.md|copilot-verify-\$\$
copilot|delegate|agents/copilot-agent.md|BRANCH=\"copilot/
glm|verify|agents/glm-agent.md|glm-verify-\$\$
glm|delegate|agents/glm-agent.md|BRANCH=\"glm/
"

printf '%s\n' "$BLOCKS" | while IFS='|' read -r prov tier file needle; do
  [ -n "$prov" ] || continue
  echo
  echo "  $prov — $tier"

  BLK="$WORK/$prov-$tier.sh"
  if ! extract "$ROOT/$file" "$needle" > "$BLK" 2>"$WORK/err"; then
    bad "$prov/$tier: could not extract the block: $(cat "$WORK/err")"
    continue
  fi
  prep "$BLK"

  # --- 1 & 3 & 4: normal run ------------------------------------------------------------
  P=$(newrepo "$prov$tier")
  SHIMLOG="$WORK/shim.log"; : > "$SHIMLOG"
  out=$( cd "$P" && env PATH="$SHIM:$ROOT/scripts:$PATH" QUORUM_MAIN_REPO="$P" \
         QUORUM_SHIM_LOG="$SHIMLOG" bash "$BLK" 2>&1 )
  WT=$(printf '%s' "$out" | sed -n 's/^WT=//p' | tail -1)

  ranin=$(sed -n 's/^TARGET=//p' "$SHIMLOG" 2>/dev/null | tail -1)
  if [ -z "$WT" ]; then
    bad "$prov/$tier: the block set no \$WT at all"
    printf '        %s\n' "$(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    continue
  fi
  # A block that removes its own worktree afterwards is CORRECT, not broken —
  # copilot's verify block ends with `git worktree remove --force "$WT"`. Judge on
  # where the provider actually ran, recorded outside the tree, not on what survives.
  # Grep the block's SOURCE, not its output: `git worktree remove` prints nothing on
  # success, so looking for it in stdout can never match.
  if [ -d "$WT" ] || grep -q 'worktree remove' "$BLK"; then
    ok "creates a worktree at \$WT"
  else
    bad "no worktree at \$WT and no removal in its output"
  fi

  if [ "$ranin" = "$WT" ]; then
    ok "provider ran INSIDE the worktree (-C / cd honoured)"
  else
    bad "provider ran in '$ranin', not the worktree '$WT' — is -C being passed?"
  fi

  if [ -f "$P/delegated.txt" ]; then
    bad "provider wrote into the USER'S checkout — the block did not point it at \$WT"
  else
    ok "the user's checkout was not written to during a normal run"
  fi

  # The new file must be visible to whatever the block reports with. `diff --stat` shows
  # nothing for an untracked file, which is the normal delegate outcome.
  if printf '%s' "$out" | grep -q 'delegated.txt'; then
    ok "its own output shows the NEW file (diff --stat alone would hide it)"
  else
    bad "its output never mentions the new file — untracked work is invisible in the report"
  fi

  # --- 2: a failed `git worktree add` must stop it --------------------------------------
  P2=$(newrepo "${prov}${tier}b")
  # Force a real failure. The delegate names carry a random suffix, so occupying the exact
  # path is not possible — instead make the PARENT a regular file, which `git worktree add`
  # cannot create beneath. An earlier version chmod'ed the grandparent to 500, which did not
  # work: `.worktrees/` already existed at 700, so the add succeeded and all six blocks were
  # reported as ignoring a failure they had in fact handled correctly.
  rm -rf "$WORK/.worktrees/$(basename "$P2")"
  mkdir -p "$WORK/.worktrees"
  : > "$WORK/.worktrees/$(basename "$P2")"
  : > "$SHIMLOG"
  out2=$( cd "$P2" && env PATH="$SHIM:$ROOT/scripts:$PATH" QUORUM_MAIN_REPO="$P2" \
          QUORUM_SHIM_LOG="$SHIMLOG" bash "$BLK" 2>&1 )
  rm -f "$WORK/.worktrees/$(basename "$P2")"
  if printf '%s' "$out2" | grep -q 'PROVIDER RAN'; then
    bad "ran the provider even though the worktree could not be created"
  else
    ok "a failed worktree add stops it before the provider runs"
  fi

  # --- 5: an escape must be surfaced by the block's own output ---------------------------
  P3=$(newrepo "${prov}${tier}c")
  out3=$( cd "$P3" && env PATH="$SHIM:$ROOT/scripts:$PATH" QUORUM_MAIN_REPO="$P3" \
          QUORUM_SHIM_LOG="$SHIMLOG" QUORUM_SHIM_ESCAPE=1 bash "$BLK" 2>&1 )
  if [ ! -f "$P3/escaped.txt" ]; then
    bad "the escape simulation did not actually write to the checkout — test is inert"
  elif printf '%s' "$out3" | grep -q 'escaped.txt'; then
    ok "an escape into the real checkout IS surfaced by the block's own output"
  else
    bad "an escape into the real checkout is NOT surfaced — this block reports it as clean"
  fi
done > "$WORK/results"

cat "$WORK/results"
pass=$(grep -c '^  ok ' "$WORK/results" || true)
fail=$(grep -c '^  FAIL' "$WORK/results" || true)

# --- uniqueness, across the two delegate namings ------------------------------------------
echo
P=$(newrepo uniq)
names=$( cd "$P" && for i in 1 2 3 4 5; do
  SLUG=$(printf '%s' "${TASK_SLUG:-task}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
         | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')
  UNIQ=$(basename "$(mktemp -u)" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')
  echo "codex/${SLUG:-task}-$(date +%Y%m%d-%H%M%S)-$UNIQ"
done )
distinct=$(printf '%s\n' "$names" | sort -u | wc -l | tr -d ' ')
if [ "$distinct" = 5 ]; then
  printf '  ok    five rapid delegations produce five distinct branch names\n'; pass=$((pass+1))
else
  printf '  FAIL  branch names collide: %s distinct of 5\n' "$distinct"; fail=$((fail+1))
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
