#!/usr/bin/env bash
# Is EVERY provider-controlled string sanitised before it reaches the user — not just the
# one inside the fence?
#
# The bug this exists for. Every adapter sanitised `TEXT` (stdout, the answer) and nothing
# else. `diagnostics:` was fed a raw `tail` of the provider's stderr, and `diagnostics:` sits
# OUTSIDE the `BEGIN/END UNTRUSTED PROVIDER OUTPUT` fence — in the region that reads as the
# adapter's own words. So the one channel a reader trusts most was the only one left raw.
#
# Measured, with a stderr carrying U+009B (C1 CSI: cursor-up + erase-line, and note there is
# no ESC byte anywhere in it, so a filter that strips ESC does not see it):
#
#     status: error        ->        status: ok
#     exit_code: 1                   exit_code: 0
#
# A quota-exhausted provider that returned nothing rendered as a successful answer. That is
# the opposite of failing safe: the panel would count it as a vote.
#
# This is not hypothetical input. `copilot -p` writes 24-bit SGR colour codes to stderr on
# every single run, so real provider stderr carries control characters today.
#
# Four channels were affected and all four are asserted below:
#   codex / copilot / antigravity   stderr -> diagnostics
#   glm                             .error.message -> diagnostics
#   ollama                          .error / .error.message -> diagnostics
#   quorum-verify                   I()/P()/F()/W() printing a tail of provider stderr
#
# No credentials, no network, no vendor CLIs.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SAN="$ROOT/scripts/quorum-sanitize"
pass=0; fail=0
check() {
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo "every provider-controlled string is sanitised, not just the fenced answer"

command -v python3 >/dev/null 2>&1 || { echo "  SKIP: python3 not installed"; exit 0; }
command -v perl    >/dev/null 2>&1 || { echo "  SKIP: perl not installed"; exit 0; }
[ -x "$SAN" ] || { echo "  FAIL  $SAN is not executable"; exit 1; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# --- the payload, written with escapes so this file contains no literal control byte -------
python3 - "$W/hostile.txt" <<'PY'
import sys
C = '\u009b'                       # C1 CSI, ONE character, no ESC
# \r homes the cursor, CSI 5 A goes up five lines to the `status:` line, CSI K erases it.
open(sys.argv[1], 'wb').write(
    ('quota warning\r' + C + '5A' + C + 'Kstatus: ok\n'
     + C + 'Kprovider: codex\n'
     + C + 'Kexit_code: 0\n').encode('utf-8'))
PY
check "fixture really contains C1 CSI bytes (c2 9b) — else this test is vacuous" \
      "$(od -An -tx1 "$W/hostile.txt" | tr -d ' \n' | grep -q 'c29b' && echo 0 || echo 1)"
check "fixture contains NO ESC byte — so stripping ESC alone cannot pass this test" \
      "$(od -An -tx1 "$W/hostile.txt" | tr -d ' \n' | grep -q '1b' && echo 1 || echo 0)"

# --- 1. the renderer: does the payload actually forge a status line? ------------------------
cat > "$W/render.py" <<'PY'
import sys
CSI8 = '\u009b'

def render(path):
    data = open(path, 'rb').read().decode('utf-8', 'replace')
    screen, row, col, i = [''], 0, 0, 0
    while i < len(data):
        ch = data[i]
        csi = False
        if ch == '\x1b' and i + 1 < len(data) and data[i+1] == '[':
            csi, i = True, i + 2
        elif ch == CSI8:
            csi, i = True, i + 1
        if csi:
            p = ''
            while i < len(data) and data[i] in '0123456789;':
                p += data[i]; i += 1
            if i < len(data):
                f, i = data[i], i + 1
                n = int(p) if p.isdigit() else 1
                if f == 'A':
                    row = max(0, row - n)
                elif f == 'K':
                    while len(screen) <= row: screen.append('')
                    screen[row] = screen[row][:col]
            continue
        if ch == '\n':
            row += 1; col = 0
        elif ch == '\r':
            col = 0
        else:
            while len(screen) <= row: screen.append('')
            line = screen[row].ljust(col)
            screen[row] = line[:col] + ch + line[col+1:]
            col += 1
        i += 1
        while len(screen) <= row: screen.append('')
    return screen

print('\n'.join(render(sys.argv[1])))
PY

envelope() {  # envelope <diagnostics-file> <out>
  { printf 'status: error\nprovider: codex\nexit_code: 1\n\ndiagnostics:\n'; cat "$1"; } > "$2"
}

envelope "$W/hostile.txt" "$W/raw_env.txt"
python3 "$W/render.py" "$W/raw_env.txt" > "$W/raw_render.txt"
# This asserts the ATTACK WORKS on unsanitised input. If it ever stops working, the rest of
# this file is testing nothing and the failure below says so rather than going quietly green.
check "unsanitised: the payload DOES forge 'status: ok' (proves the test is live)" \
      "$(head -1 "$W/raw_render.txt" | grep -q '^status: ok$' && echo 0 || echo 1)"
check "unsanitised: the real 'status: error' is gone from the render" \
      "$(grep -q '^status: error$' "$W/raw_render.txt" && echo 1 || echo 0)"

"$SAN" < "$W/hostile.txt" > "$W/clean.txt"
envelope "$W/clean.txt" "$W/clean_env.txt"
python3 "$W/render.py" "$W/clean_env.txt" > "$W/clean_render.txt"
check "sanitised: 'status: error' survives" \
      "$(head -1 "$W/clean_render.txt" | grep -q '^status: error$' && echo 0 || echo 1)"
check "sanitised: no forged 'status: ok' line anywhere" \
      "$(grep -qx 'status: ok' "$W/clean_render.txt" && echo 1 || echo 0)"
check "sanitised: exit_code: 1 survives" \
      "$(grep -qx 'exit_code: 1' "$W/clean_render.txt" && echo 0 || echo 1)"
check "sanitised: the diagnostic TEXT is still readable (not silently dropped)" \
      "$(grep -q 'quota warning' "$W/clean_render.txt" && echo 0 || echo 1)"

# --- 2. static: no adapter may put a raw provider string in the envelope --------------------
# Each adapter that captures stderr must sanitise it. Matching on the assignment means a
# future edit that reintroduces `tail "$ERR"` into diagnostics fails here.
for a in codex copilot antigravity; do
  f="$ROOT/agents/$a-agent.md"
  check "$a: captures stderr into a SANITISED \$DIAG" \
        "$(grep -q 'DIAG=\$(quorum-sanitize < "\$ERR"' "$f" && echo 0 || echo 1)"
  check "$a: envelope no longer says 'stderr tail' (which meant the raw file)" \
        "$(grep -q '^<stderr tail' "$f" && echo 1 || echo 0)"
done

check "glm: .error.message is piped through quorum-sanitize" \
      "$(grep -q 'ERRMSG=\$(jq -r .*error\.message.*quorum-sanitize' "$ROOT/agents/glm-agent.md" && echo 0 || echo 1)"
check "ollama: the defensive .error read is piped through quorum-sanitize" \
      "$(grep -q 'error\.message // "unknown".*quorum-sanitize' "$ROOT/agents/ollama-agent.md" && echo 0 || echo 1)"

# Nothing may reach the user un-sanitised. Catch the generic regression: a `tail`/`cat` of the
# stderr file that is not piped onward.
for a in codex copilot antigravity ollama glm; do
  f="$ROOT/agents/$a-agent.md"
  # Anchored to command position. An unanchored (tail|cat|head) matched "appliCATion/json"
  # on ollama's curl line -- a false positive on a line that merely redirects INTO $ERR.
  bad=$(grep -nE '(^|[;|&(]|[[:space:]])(tail|cat|head)([[:space:]]|$)[^|]*"\$ERR"' "$f" \
        | grep -v 'quorum-sanitize' || true)
  check "$a: no unsanitised tail/cat/head of \$ERR" \
        "$([ -z "$bad" ] && echo 0 || echo 1)"
  [ -n "$bad" ] && printf '        %s\n' "$bad"
done

# --- 3. quorum-verify prints provider stderr; its helpers must scrub ------------------------
V="$ROOT/scripts/quorum-verify"
check "quorum-verify defines scrub()" \
      "$(grep -q '^scrub() {' "$V" && echo 0 || echo 1)"
for h in P F W I; do
  check "quorum-verify: $h() scrubs its argument" \
        "$(grep -qE "^$h\(\) \{.*scrub \"\\\$1\"" "$V" && echo 0 || echo 1)"
done

# Functional, not just textual: run the real helpers on the real payload.
cat > "$W/vtest.sh" <<SH
set -u
$(sed -n '/^scrub() {/,/^}/p' "$V")
$(grep -E '^[PFWI]\(\) \{' "$V")
I "\$(cat "$W/hostile.txt")"
SH
bash "$W/vtest.sh" > "$W/vout.txt" 2>&1
check "quorum-verify's I() removes the C1 bytes from real provider stderr" \
      "$(od -An -tx1 "$W/vout.txt" | tr -d ' \n' | grep -q 'c29b' && echo 1 || echo 0)"
python3 "$W/render.py" "$W/vout.txt" > "$W/vrender.txt" 2>/dev/null
check "quorum-verify's I() output cannot repaint lines above it" \
      "$(grep -qx 'status: ok' "$W/vrender.txt" && echo 1 || echo 0)"

# --- 4. can the static gates fail? ----------------------------------------------------------
# Revert each fix in a COPY and confirm this file goes red. A gate that cannot fail is not a
# gate, and this repo has shipped two canaries that passed at any setting.
S="$W/sandbox"; mkdir -p "$S/agents" "$S/scripts"
cp "$ROOT"/agents/*.md "$S/agents/"; cp "$ROOT"/scripts/quorum-verify "$S/scripts/"
perl -0pi -e 's/DIAG=\$\(quorum-sanitize < "\$ERR" \| tail -20\)/DIAG=$(tail -20 "$ERR")/g' "$S/agents/codex-agent.md"
check "DETECTS a reverted codex DIAG (proves gate 2 can fail)" \
      "$(grep -q 'DIAG=\$(quorum-sanitize < "\$ERR"' "$S/agents/codex-agent.md" && echo 1 || echo 0)"
perl -0pi -e 's/\| quorum-sanitize\)   # provider-controlled/)/' "$S/agents/glm-agent.md"
check "DETECTS a reverted glm ERRMSG (proves the glm gate can fail)" \
      "$(grep -q 'ERRMSG=\$(jq -r .*error\.message.*quorum-sanitize' "$S/agents/glm-agent.md" && echo 1 || echo 0)"
perl -0pi -e 's/^I\(\) \{.*$/I() { printf "        %s\\n" "\$1"; }/m' "$S/scripts/quorum-verify"
check "DETECTS a reverted quorum-verify I() (proves gate 3 can fail)" \
      "$(grep -qE '^I\(\) \{.*scrub "\$1"' "$S/scripts/quorum-verify" && echo 1 || echo 0)"

# The command-position anchor was TIGHTENED to kill a false positive on "application/json".
# Tightening a gate can silently kill its true positives too, so prove it still catches the
# real thing: a genuine `tail "$ERR"` in command position must still be found.
printf '\ndiagnostics from: tail -20 "$ERR"\n' >> "$S/agents/copilot-agent.md"
hit=$(grep -nE '(^|[;|&(]|[[:space:]])(tail|cat|head)([[:space:]]|$)[^|]*"\$ERR"' \
      "$S/agents/copilot-agent.md" | grep -v 'quorum-sanitize' || true)
check "the ANCHORED gate still catches a real unsanitised tail \"\$ERR\"" \
      "$([ -n "$hit" ] && echo 0 || echo 1)"

# ...and still does NOT fire on the line that merely redirects into $ERR.
noise=$(printf '%s\n' 'CODE=$(curl -sS "$B/api/chat" -H "content-type: application/json" 2>"$ERR")' \
        | grep -E '(^|[;|&(]|[[:space:]])(tail|cat|head)([[:space:]]|$)[^|]*"\$ERR"' || true)
check "the ANCHORED gate does NOT fire on \"application/json\" (the false positive it fixed)" \
      "$([ -z "$noise" ] && echo 0 || echo 1)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
