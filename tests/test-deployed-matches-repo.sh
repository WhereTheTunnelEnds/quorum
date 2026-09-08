#!/usr/bin/env bash
# Does what RUNS match what is in this repo?
#
# The bug this exists for. Every other gate in this repo reads files under version
# control, and every one of them was green while the artifact that actually executed was
# months out of date and carried a vulnerability this repo had already fixed twice.
#
# Measured on the author's machine, 2026-09-08:
#
#   file                       repo   deployed   changed lines
#   agents/glm-agent.md         609        256            413
#   agents/copilot-agent.md     470        248            262
#   agents/codex-agent.md       401        204            229
#   agents/antigravity-agent.md 422        230            216
#   agents/ollama-agent.md      330        208            136
#   skills/model-panel/SKILL.md 294        239             87
#   skills/delegate-task/...     98         83             31
#   skills/build-adapter/...    224          -   NOT DEPLOYED
#
# ~1,374 lines of drift, and the deployed glm-agent matched no commit in the last twelve
# touching that file. What it actually ran was:
#
#   ~/.claude/agents/glm-agent.md:48   -H "Authorization: Bearer $Z_AI_API_KEY"
#
# — the original argv leak, the exact string the "No API key passed on a command line"
# gate rejects. CI was green the whole time because CI never looked at the deployment.
#
# Why it happened. The agents and skills had been hand-copied into ~/.claude/agents and
# ~/.claude/skills. `cp` is not a deployment mechanism: it has no version, no update path
# and no way to notice the source moved. scripts/install.sh never claimed to manage them
# ("~/.claude/agents, skills, commands/quorum   if you copied them there").
#
# The fix is to install through the plugin system, so there is one versioned artifact and
# `claude plugin marketplace update quorum` re-syncs it. That still leaves a COPY in the
# plugin cache, so this gate exists to assert the copy has not gone stale — and to fail
# loudly if hand-copies ever come back and start shadowing the plugin again.
#
# In CI there is no deployment to check, so this SKIPS rather than fails. A skip is
# reported out loud: a gate that silently passes when it examined nothing is the failure
# mode this whole file is about.
#
# No credentials, no network, no vendor CLIs.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
pass=0; fail=0; skipped=0
check() {
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}
note() { printf '        %s\n' "$1"; }

echo "what runs matches what is in this repo"

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# --- gate 1: no hand-copies shadowing the plugin -------------------------------------------
# These are the files that drifted. A plugin install supersedes them, so their presence
# means someone `cp`-ed again and the incident is repeating.
shadows=""
for f in "$ROOT"/agents/*.md; do
  b=$(basename "$f")
  [ -e "$CLAUDE_DIR/agents/$b" ] && shadows="$shadows agents/$b"
done
for d in "$ROOT"/skills/*/; do
  n=$(basename "$d")
  [ -e "$CLAUDE_DIR/skills/$n" ] && shadows="$shadows skills/$n"
done
for f in "$ROOT"/commands/*.md; do
  b=$(basename "$f")
  [ -e "$CLAUDE_DIR/commands/quorum/$b" ] && shadows="$shadows commands/quorum/$b"
done
check "no hand-copied agents, skills or commands in $CLAUDE_DIR (the plugin owns these)" \
      "$([ -z "$shadows" ] && echo 0 || echo 1)"
[ -n "$shadows" ] && { for s in $shadows; do note "shadow: $CLAUDE_DIR/$s"; done
                       note "remove them; the plugin provides these. They do not auto-update."; }
# --- gate 2: the deployed plugin copy matches this repo ------------------------------------
# Resolve the copy Claude Code ACTUALLY RUNS, from its own installation record.
#
# This used to be `ls -dt "$CLAUDE_DIR"/plugins/cache/*/quorum/*/ | head -1` -- the newest
# cached version directory by mtime. Measured the first time a second version was installed:
# an update left 0.1.0 and 0.2.0 side by side with the SAME mtime to the second, `ls -dt`
# broke the tie by name and picked 0.1.0, and this gate spent its whole run comparing the
# repo against a version that nothing executes.
#
# That produced a false positive here, which is the harmless direction. The other direction
# is the one that matters: had the stale 0.1.0 happened to match the repo while the live
# 0.2.0 did not, the gate would have reported all-clear over exactly the drift it exists to
# catch. A deployment check that infers which artifact is deployed is not a deployment check.
#
# installed_plugins.json is where Claude Code records installPath and version per scope.
PLUGIN_DIR=""
INSTALLED_JSON="$CLAUDE_DIR/plugins/installed_plugins.json"
if [ -f "$INSTALLED_JSON" ] && command -v jq >/dev/null 2>&1; then
  PLUGIN_DIR=$(jq -r '(.plugins // {}) | to_entries[]
                      | select(.key | test("^quorum@"))
                      | .value[]? | .installPath // empty' "$INSTALLED_JSON" 2>/dev/null | head -1)
  [ -n "$PLUGIN_DIR" ] && PLUGIN_DIR="${PLUGIN_DIR%/}/"
fi
if [ -z "$PLUGIN_DIR" ]; then
  # No record to read. Fall back, but say out loud that the answer is now a guess -- a
  # silent fallback to the mechanism that was wrong is how the original bug survives a fix.
  PLUGIN_DIR=$(ls -dt "$CLAUDE_DIR"/plugins/cache/*/quorum/*/ 2>/dev/null | head -1)
  [ -n "$PLUGIN_DIR" ] && note "no installed_plugins.json entry — GUESSING the newest cached copy by mtime"
fi

if [ -z "$PLUGIN_DIR" ] || [ ! -d "$PLUGIN_DIR" ]; then
  printf '  --    quorum is not installed as a plugin here\n'
  note "nothing deployed to compare against — this gate examined NOTHING."
  note "on a dev machine: claude plugin marketplace add $ROOT && claude plugin install quorum@quorum"
  skipped=$((skipped+1))
else
  note "deployed copy: $PLUGIN_DIR"
  drifted=""
  for rel in agents/*.md skills/*/SKILL.md commands/*.md; do
    src="$ROOT/$rel"
    [ -f "$src" ] || continue
    if [ ! -f "$PLUGIN_DIR/$rel" ]; then drifted="$drifted $rel(missing)"; continue; fi
    cmp -s "$src" "$PLUGIN_DIR/$rel" || drifted="$drifted $rel"
  done
  check "every deployed agent, skill and command is byte-identical to this repo" \
        "$([ -z "$drifted" ] && echo 0 || echo 1)"
  if [ -n "$drifted" ]; then
    for d in $drifted; do note "stale: $d"; done
    # `marketplace update` refreshes marketplace METADATA and leaves the installed copy
    # untouched -- measured: it reported success while this gate stayed red. `plugin update`
    # is the one that re-syncs, and it compares VERSION STRINGS, not content: with the
    # version unchanged it answers "already at the latest version (0.1.0)" and keeps serving
    # a cache that no longer matches the repo. So a content change needs a version bump to
    # be deployable at all.
    note "re-sync with: claude plugin update quorum   (NOT 'marketplace update')"
    note "if it says 'already at the latest version', bump .claude-plugin/plugin.json"
    note "and the marketplace entry -- it compares versions, not file contents."
  fi
fi

# --- gate 3: the comparison can fail -------------------------------------------------------
# A gate nobody has watched go red is a gate whose shape nobody knows. Build a fake
# deployment that differs by one byte and confirm cmp notices.
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/agents"
cp "$ROOT/agents/glm-agent.md" "$W/agents/glm-agent.md"
cmp -s "$ROOT/agents/glm-agent.md" "$W/agents/glm-agent.md"
check "an identical deployment compares equal" "$?"
printf '\n# drift\n' >> "$W/agents/glm-agent.md"
cmp -s "$ROOT/agents/glm-agent.md" "$W/agents/glm-agent.md"
check "a one-line divergence is DETECTED (proves this gate can fail)" \
      "$([ $? -ne 0 ] && echo 0 || echo 1)"

echo
if [ "$skipped" -gt 0 ]; then
  printf '%d passed, %d failed, %d check(s) skipped (nothing deployed here)\n' "$pass" "$fail" "$skipped"
else
  printf '%d passed, %d failed\n' "$pass" "$fail"
fi
[ "$fail" = 0 ]
