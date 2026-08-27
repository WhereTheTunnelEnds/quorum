#!/usr/bin/env bash
# Does this repo's GIT HISTORY contain anything credential-shaped?
#
# Making a repo public exposes every blob ever committed, not the current tree. A key that
# was committed and then deleted is still there, reachable by SHA, forever. `git log -p` is
# not a search and reading the diff of 62 commits is not a check.
#
# Two assertions, and the second is the one that makes the first mean anything:
#
#   1. the real history is clean
#   2. the scanner DETECTS a planted secret in a blob whose file no longer exists in HEAD
#
# Without (2) this is a green check mark that would look identical if the regexes were
# broken — the same object as a canary that passes at any setting, which this repo has
# already shipped twice.
#
# It reports LOCATIONS ONLY: pattern name, blob SHA, path, and the match's LENGTH. A secret
# scanner that prints the secret has published it into a log, which is the thing it exists
# to prevent.
#
# Note on CI: actions/checkout is shallow by default, so there the history is one commit
# deep. The script says so rather than reporting full coverage it does not have.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
pass=0; fail=0
check() {
  if [ "$2" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo "git history contains no credential-shaped strings"

command -v python3 >/dev/null 2>&1 || { echo "  SKIP: python3 not installed"; exit 0; }
command -v git     >/dev/null 2>&1 || { echo "  SKIP: git not installed"; exit 0; }

SCAN=$(mktemp -t scanhist.XXXXXX.py)
trap 'rm -f "$SCAN"' EXIT
cat > "$SCAN" <<'PY'
import re, subprocess, sys, collections, os

# Written as patterns, never as example values, so this file cannot itself become a match.
PATTERNS = [
    ("anthropic key",     re.compile(rb'sk-ant-[A-Za-z0-9_\-]{20,}')),
    ("openai key",        re.compile(rb'sk-(?:proj-)?[A-Za-z0-9]{32,}')),
    ("github token",      re.compile(rb'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}')),
    ("google api key",    re.compile(rb'AIza[A-Za-z0-9_\-]{30,}')),
    ("aws access key",    re.compile(rb'AKIA[0-9A-Z]{16}')),
    ("slack token",       re.compile(rb'xox[abprs]-[A-Za-z0-9-]{10,}')),
    ("private key block", re.compile(rb'-----BEGIN [A-Z ]*PRIVATE KEY-----')),
    ("jwt",               re.compile(rb'eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.')),
    # Z.AI / GLM keys are hex-dot-alnum. Tight enough not to match a bare git SHA in prose.
    ("zai-style key",     re.compile(rb'\b[0-9a-f]{32}\.[A-Za-z0-9]{16,}\b')),
]

repo = sys.argv[1]
def git(*a):
    return subprocess.run(['git','-C',repo,*a], capture_output=True)

shallow = git('rev-parse','--is-shallow-repository').stdout.strip() == b'true'
depth = git('rev-list','--all','--count').stdout.strip().decode() or '0'

names = {}
for line in git('rev-list','--all','--objects').stdout.decode('utf-8','replace').splitlines():
    sha, _, path = line.partition(' ')
    if path:
        names.setdefault(sha, set()).add(path)

allsha = [l.split()[0] for l in git('rev-list','--all','--objects').stdout.decode('utf-8','replace').splitlines() if l.strip()]
out = subprocess.run(['git','-C',repo,'cat-file','--batch'],
                     input=('\n'.join(allsha) + '\n').encode(), capture_output=True).stdout

hits, blobs, i = collections.defaultdict(list), 0, 0
while i < len(out):
    nl = out.find(b'\n', i)
    if nl == -1: break
    h = out[i:nl].split()
    if len(h) < 3:
        i = nl + 1; continue
    sha, typ, size = h[0].decode(), h[1].decode(), int(h[2])
    body = out[nl+1:nl+1+size]
    i = nl + 1 + size + 1
    if typ != 'blob': continue
    blobs += 1
    for name, pat in PATTERNS:
        for m in pat.finditer(body):
            hits[name].append((','.join(sorted(names.get(sha, {'<unnamed>'}))), sha[:8], len(m.group(0))))

print(f"COVERAGE commits={depth} blobs={blobs} shallow={'yes' if shallow else 'no'}")
for name, rows in hits.items():
    for paths, sha, length in rows:
        # Location and length only. Never the value.
        print(f"HIT {name} blob={sha} len={length} path={paths}")
sys.exit(1 if hits else 0)
PY

# --- 1. the real history --------------------------------------------------------------
real=$(python3 "$SCAN" "$REPO" 2>&1); rc=$?
cov=$(printf '%s\n' "$real" | grep '^COVERAGE' || true)
printf '        %s\n' "$cov"
check "no credential-shaped strings anywhere in this repo's history" "$rc"
if [ "$rc" != 0 ]; then
  printf '%s\n' "$real" | grep '^HIT' | sed 's/^/        /'
  echo "        (locations only — inspect them yourself; nothing is printed here)"
fi

case "$cov" in
  *shallow=yes*)
    printf '        %s\n' "NOTE: shallow clone — only the fetched commits were scanned, not the full history."
    printf '        %s\n' "      For a real pre-release check run this on a full clone (fetch-depth: 0)." ;;
esac

# --- 2. can it fail? ------------------------------------------------------------------
# A throwaway clone, a planted value, then DELETE the file and commit again — so the
# scanner must reach a blob that HEAD no longer references. Values are constructed from
# repeated characters so no credential-shaped literal exists in this file.
T=$(mktemp -d)
git clone -q "$REPO" "$T/probe" 2>/dev/null
if [ -d "$T/probe/.git" ]; then
  python3 - "$T/probe/planted.txt" <<'PY'
import sys
open(sys.argv[1], 'w').write(
    "a = sk-ant-" + "A" * 40 + "\n"
    "b = ghp_"    + "B" * 36 + "\n"
    "c = AIza"    + "C" * 35 + "\n"
    "d = "        + "d" * 32 + ".EEEEEEEEEEEEEEEE\n")
PY
  git -C "$T/probe" add planted.txt >/dev/null 2>&1
  git -C "$T/probe" -c user.email=t@example -c user.name=t commit -q -m planted >/dev/null 2>&1
  git -C "$T/probe" rm -q planted.txt >/dev/null 2>&1
  git -C "$T/probe" -c user.email=t@example -c user.name=t commit -q -m removed >/dev/null 2>&1

  gone=0; [ -e "$T/probe/planted.txt" ] && gone=1
  check "the planted file is absent from HEAD (so this tests history, not the tree)" "$gone"

  planted=$(python3 "$SCAN" "$T/probe" 2>&1); prc=$?
  n=$(printf '%s\n' "$planted" | grep -c '^HIT' || true)
  check "the scanner FAILS on a planted secret (rc=$prc, $n pattern hit(s))" \
        "$([ "$prc" != 0 ] && [ "$n" -ge 4 ] && echo 0 || echo 1)"
  check "it reports a length, never a value" \
        "$(printf '%s\n' "$planted" | grep '^HIT' | grep -q 'AAAAA\|BBBBB\|CCCCC' && echo 1 || echo 0)"
else
  check "could not clone the repo to run the detection proof" 1
fi
rm -rf "$T"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
