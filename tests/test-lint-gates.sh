#!/usr/bin/env bash
# Does each CI gate actually FIRE on the violation it claims to catch?
#
# Every gate in .github/workflows/lint.yml exists because something got through. But a gate
# is only evidence if it has been seen to fail; otherwise it is a green check mark asserting
# a property nobody tested. This repo has already shipped three gates that could not fail
# and one that fired on valid input, so "the gates are correct" is not a claim to take on
# trust — it is a thing to measure.
#
# Two bugs found by running the key gate rather than reading it, both in the SAME gate:
#
#   ^[^#]*-H "Authorization: Bearer
#     `[^#]*` cannot cross a '#', so any earlier '#' on the line hid the violation.
#
#   grep -rnE -- 'pattern' --include='*.md' ...
#     `--` ends OPTION parsing, not just pattern parsing, so every --include and --exclude
#     after it became a FILENAME. Five "No such file or directory" errors and an unfiltered
#     search. That gate was red against every possible tree, including a correct one.
#
# Neither is visible by reading. Both are obvious the moment the gate is executed against a
# tree that should fail it and a tree that should not.
#
# METHOD. Extract each step's `run:` body straight out of lint.yml — not a paraphrase of it,
# which would test a copy that can drift — and run it three times per gate:
#
#   1. clean tree            -> must exit 0   (it does not fire on correct input)
#   2. one injected violation-> must exit non-0 (it fires on the thing it is for)
#   3. after the revert      -> must exit 0   (the injection was the cause, not a side effect)
#
# Step 3 matters: without it, a gate that is simply always-red passes step 2 for the wrong
# reason. That is exactly how the `--` bug would have looked.
#
# Runs against a COPY of the tree, so an injection can never touch the working tree even if
# this script is interrupted between injecting and reverting.
#
# No credentials, no network, no vendor CLIs.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WF="$REPO/.github/workflows/lint.yml"

pass=0; fail=0; uncovered=0
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
note() { printf '        %s\n' "$1"; }

echo "CI gates fire on the violations they claim to catch"

command -v python3 >/dev/null 2>&1 || { echo "  SKIP: python3 not installed"; exit 0; }
[ -f "$WF" ] || { echo "  FAIL  no $WF"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
SANDBOX="$WORK/repo"
STEPS="$WORK/steps"
mkdir -p "$SANDBOX" "$STEPS"

# TRACKED FILES ONLY, because that is what actions/checkout gives CI. A plain `cp -R` of the
# working directory copies whatever else is lying around, and several gates scan the
# filesystem (grep -r, rglob) rather than `git ls-files` -- so the copy failed three gates
# that CI passes: an ignored logs/ directory of chat transcripts contains absolute home
# paths, dangling doc URLs and the literal Bearer-header string. All three were artefacts of
# the harness, not defects in the gates, and reporting them as gate failures would have sent
# someone hunting a bug that does not exist. A test environment that does not match the one
# being reproduced produces confident wrong answers.
( cd "$REPO" && git ls-files -z ) | while IFS= read -r -d '' f; do
  mkdir -p "$SANDBOX/$(dirname "$f")"
  cp "$REPO/$f" "$SANDBOX/$f" 2>/dev/null || true
done
# .git comes too: the stray-file gate reads `git ls-files`, and without an index it would
# report an empty file list and pass vacuously.
cp -R "$REPO/.git" "$SANDBOX/.git" 2>/dev/null || true

# --- extract every named step's run: body ------------------------------------------------
# Deliberately no PyYAML: it is not guaranteed on a contributor's machine, and a test that
# cannot run is not a test. The parser is indentation-based, which is fragile, so it
# self-checks: if the number of bodies extracted does not equal the number of `- name:`
# lines, the parser is wrong and this hard-fails rather than silently covering fewer gates.
# Under-extraction is the failure mode that would look like success.
python3 - "$WF" "$STEPS" <<'PY'
import pathlib, re, sys
wf, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
lines = wf.read_text().splitlines()
names = [l for l in lines if re.match(r'^      - name:', l)]
steps, i = [], 0
while i < len(lines):
    m = re.match(r'^      - name: (.+)$', lines[i])
    if not m:
        i += 1; continue
    name = m.group(1).strip()
    i += 1
    while i < len(lines) and not re.match(r'^        run: \|', lines[i]):
        if re.match(r'^      - ', lines[i]):
            break
        i += 1
    if i >= len(lines) or not re.match(r'^        run: \|', lines[i]):
        continue
    i += 1
    body = []
    while i < len(lines):
        l = lines[i]
        if l.strip() and not l.startswith('          '):
            break
        body.append(l[10:] if len(l) > 10 else '')
        i += 1
    steps.append((name, '\n'.join(body).rstrip() + '\n'))

if len(steps) != len(names):
    print(f"PARSER ERROR: {len(names)} named steps in the file, {len(steps)} bodies extracted")
    sys.exit(1)

slugs = []
for n, b in steps:
    slug = re.sub(r'[^a-z0-9]+', '-', n.lower()).strip('-')
    (out / f'{slug}.sh').write_text(b)
    slugs.append(f'{slug}\t{n}')
(out / 'INDEX').write_text('\n'.join(slugs) + '\n')
print(f"{len(steps)} gate bodies extracted")
PY
[ $? -eq 0 ] || { echo "  FAIL  could not extract gate bodies from lint.yml"; exit 1; }

run_gate() {  # run_gate <slug> ; echoes rc
  # `bash -e`, because GitHub Actions runs a `run:` block as `bash -e {0}`. Without -e the
  # bodies that rely on a failing command aborting the step keep going and exit 0 -- the
  # shell-syntax gate looked like it did not fire when in CI it does. Running the gate under
  # a different shell than CI uses tests a different program.
  ( cd "$SANDBOX" && bash -e "$STEPS/$1.sh" ) >"$WORK/out" 2>&1
  echo $?
}

# A gate is COVERED by naming it here with an injection that must trip it.
# inject_<slug> creates the violation; revert_<slug> undoes it.
# Anything in lint.yml with no inject_ function is reported as uncovered, out loud —
# a silent gap reads as "all gates verified" when it is not.

inject_validate_json_manifests()   { printf 'not json' > "$SANDBOX/.claude-plugin/zz-bad.json"; }
revert_validate_json_manifests()   { rm -f "$SANDBOX/.claude-plugin/zz-bad.json"; }

inject_manifests_name_every_adapter_that_ships() {
  printf -- '---\nname: zzprov-agent\n---\nbody\n' > "$SANDBOX/agents/zzprov-agent.md"; }
revert_manifests_name_every_adapter_that_ships() {
  rm -f "$SANDBOX/agents/zzprov-agent.md"; }

# The real failure shape: a placeholder read as two consecutive redirections. An earlier
# version of this injection used `if [ 1 = 1 ; then echo hi; fi` -- which PARSES, because the
# missing `]` is a runtime error, not a syntax one. The gate correctly reported no problem
# and the harness correctly reported the gate did not fire.
inject_every_bash_fenced_block_is_valid_bash() {
  printf '\n```bash\ntimeout 120 <invocation> >"$OUT" 2>"$ERR"\n```\n' >> "$SANDBOX/docs/troubleshooting.md"; }
revert_every_bash_fenced_block_is_valid_bash() {
  cp "$REPO/docs/troubleshooting.md" "$SANDBOX/docs/troubleshooting.md"; }

inject_quorum_s_own_commands_are_guarded_before_use() {
  printf '\n```bash\nIMG=$(prep-image "photo.png")\n```\n' >> "$SANDBOX/agents/ollama-agent.md"; }
revert_quorum_s_own_commands_are_guarded_before_use() {
  cp "$REPO/agents/ollama-agent.md" "$SANDBOX/agents/ollama-agent.md"; }

inject_shell_syntax()              { printf '#!/usr/bin/env bash\nif [ 1 = 1 ; then\n' > "$SANDBOX/scripts/zz-bad"; }
revert_shell_syntax()              { rm -f "$SANDBOX/scripts/zz-bad"; }

inject_agents_and_skills_have_valid_frontmatter() {
  perl -0pi -e 's/^name:.*\n//m' "$SANDBOX/agents/ollama-agent.md"; }
revert_agents_and_skills_have_valid_frontmatter() {
  cp "$REPO/agents/ollama-agent.md" "$SANDBOX/agents/ollama-agent.md"; }

inject_adapters_must_not_hold_write_tools() {
  perl -0pi -e 's/^tools:.*/$&, Write/m' "$SANDBOX/agents/ollama-agent.md"; }
revert_adapters_must_not_hold_write_tools() {
  cp "$REPO/agents/ollama-agent.md" "$SANDBOX/agents/ollama-agent.md"; }

inject_no_stray_files_allowlist() {
  ( cd "$SANDBOX" && printf 'x' > zz-stray.txt && git add zz-stray.txt >/dev/null 2>&1 ); }
revert_no_stray_files_allowlist() {
  ( cd "$SANDBOX" && git rm -q --cached zz-stray.txt >/dev/null 2>&1; rm -f zz-stray.txt ); }

inject_every_adapter_states_the_no_code_fence_rule() {
  perl -0pi -e 's/Do not wrap the envelope in a code fence/REMOVED BY TEST/' "$SANDBOX/agents/ollama-agent.md"; }
revert_every_adapter_states_the_no_code_fence_rule() {
  cp "$REPO/agents/ollama-agent.md" "$SANDBOX/agents/ollama-agent.md"; }

# A username that is NOT one of the allowed placeholders, so the gate must object.
# Split for the same reason as the Bearer header: written whole, this line is itself an
# absolute home path in a tracked .sh file, and the gate rightly fires on it.
inject_no_absolute_home_paths_or_personal_identifiers() {
  h='/ho'; h="${h}me/jdoe"
  printf '\nsee %s/quorum for details\n' "$h" >> "$SANDBOX/docs/troubleshooting.md"; }
revert_no_absolute_home_paths_or_personal_identifiers() {
  cp "$REPO/docs/troubleshooting.md" "$SANDBOX/docs/troubleshooting.md"; }

# Targets the PIPELINE, not the prose. The prose half was already enforced; the runnable
# half was the one that was missing from every adapter while the gate reported all-clear.
inject_every_adapter_neutralises_the_untrusted_output_delimiter() {
  perl -0pi -e 's/\| quorum-sanitize//g; s/quorum-sanitize < "\$OUT"/cat "\$OUT"/g' \
    "$SANDBOX/agents/ollama-agent.md"; }
revert_every_adapter_neutralises_the_untrusted_output_delimiter() {
  cp "$REPO/agents/ollama-agent.md" "$SANDBOX/agents/ollama-agent.md"; }

# The indented form is the one every adapter actually writes, and the form the second
# broken version of this gate silently missed.
inject_no_api_key_passed_on_a_command_line() {
  # Assembled from two halves so the forbidden literal never appears in THIS file. Written
  # out whole, the test would trip the gate it tests -- and the alternative, excluding
  # tests/ from the gate, would blind it to a real violation in a script under test. The
  # comment lines above are safe because the gate ignores comments; this line is not.
  h='Auth'; h="${h}orization: Bearer"
  printf '\n  -H "%s $KEY" \\\n' "$h" >> "$SANDBOX/agents/ollama-agent.md"; }
revert_no_api_key_passed_on_a_command_line() {
  cp "$REPO/agents/ollama-agent.md" "$SANDBOX/agents/ollama-agent.md"; }

inject_canonical_urls_point_at_files_that_exist() {
  # Split again: whole, this is a dangling canonical URL in a tracked file and the gate
  # fires on it. Three of the sixteen injections have to be assembled at runtime, which is
  # a good sign -- it means the gates match on content, not on a path allowlist.
  u='https://github.com/x/quorum/blob/'; u="${u}main/docs/no-such-file.md"
  printf '\n%s\n' "$u" >> "$SANDBOX/docs/troubleshooting.md"; }
revert_canonical_urls_point_at_files_that_exist() {
  cp "$REPO/docs/troubleshooting.md" "$SANDBOX/docs/troubleshooting.md"; }

# A nested path with a digit and an underscore: the shapes the first version of this gate
# could not match, and which hid a live violation.
inject_agents_and_skills_use_no_repo_relative_doc_references() {
  printf '\nsee `docs/porting/openai_v2.md` for more\n' >> "$SANDBOX/agents/ollama-agent.md"; }
revert_agents_and_skills_use_no_repo_relative_doc_references() {
  cp "$REPO/agents/ollama-agent.md" "$SANDBOX/agents/ollama-agent.md"; }

inject_no_command_and_skill_share_a_name() {
  first=$(ls -1 "$SANDBOX/commands"/*.md | head -1); n=$(basename "$first" .md)
  mkdir -p "$SANDBOX/skills/$n"; printf 'zz' > "$SANDBOX/skills/$n/SKILL.md"; echo "$n" > "$WORK/collide"; }
revert_no_command_and_skill_share_a_name() {
  rm -rf "$SANDBOX/skills/$(cat "$WORK/collide")"; }

inject_skill_and_command_bodies_do_not_delegate_to_themselves() {
  first=$(ls -1 "$SANDBOX/commands"/*.md | head -1); n=$(basename "$first" .md)
  printf '\nInvoke the `%s` skill.\n' "$n" >> "$first"; echo "$first" > "$WORK/selfref"; }
revert_skill_and_command_bodies_do_not_delegate_to_themselves() {
  f=$(cat "$WORK/selfref"); cp "$REPO/commands/$(basename "$f")" "$f"; }

inject_skills_named_by_a_command_actually_exist() {
  first=$(ls -1 "$SANDBOX/commands"/*.md | head -1)
  printf '\nInvoke the `no-such-skill-at-all` skill.\n' >> "$first"; echo "$first" > "$WORK/ghost"; }
revert_skills_named_by_a_command_actually_exist() {
  f=$(cat "$WORK/ghost"); cp "$REPO/commands/$(basename "$f")" "$f"; }

inject_links_to_local_files_resolve() {
  printf '\n[gone](./no-such-doc.md)\n' >> "$SANDBOX/docs/troubleshooting.md"; }
revert_links_to_local_files_resolve() {
  cp "$REPO/docs/troubleshooting.md" "$SANDBOX/docs/troubleshooting.md"; }

# --- gates deliberately NOT exercised, and why -------------------------------------------
# Named explicitly so the count below is honest about what it does and does not prove.
SKIP_TEST_SUITE="runs tests/*.sh, which includes THIS file — exercising it here recurses"
SKIP_SHELLCHECK="installs shellcheck with apt-get; covered by CI running it for real"

echo
while IFS=$'\t' read -r slug name; do
  [ -n "$slug" ] || continue
  case "$slug" in
    test-suite) printf '  --    %s\n' "$name"; note "not exercised: $SKIP_TEST_SUITE"; uncovered=$((uncovered+1)); continue ;;
    shellcheck) printf '  --    %s\n' "$name"; note "not exercised: $SKIP_SHELLCHECK"; uncovered=$((uncovered+1)); continue ;;
  esac

  if ! declare -f "inject_${slug//-/_}" >/dev/null 2>&1; then
    printf '  --    %s\n' "$name"
    note "NO INJECTION DEFINED — this gate is unproven; add inject_${slug//-/_}() to $(basename "$0")"
    uncovered=$((uncovered+1)); continue
  fi

  before=$(run_gate "$slug")
  if [ "$before" != 0 ]; then
    bad "$name — already fails on the clean tree (rc=$before)"
    note "$(tail -3 "$WORK/out" | tr '\n' ' ')"
    continue
  fi

  "inject_${slug//-/_}"
  during=$(run_gate "$slug")
  "revert_${slug//-/_}"
  after=$(run_gate "$slug")

  if [ "$during" = 0 ]; then
    bad "$name — did NOT fire on an injected violation"
  elif [ "$after" != 0 ]; then
    bad "$name — still fails after the revert (rc=$after); it is not the injection it detects"
    note "$(tail -3 "$WORK/out" | tr '\n' ' ')"
  else
    ok "$name — clean 0, violation $during, clean 0"
  fi
done < "$STEPS/INDEX"

echo
printf '%d passed, %d failed, %d gate(s) not exercised\n' "$pass" "$fail" "$uncovered"
[ "$fail" -eq 0 ]
