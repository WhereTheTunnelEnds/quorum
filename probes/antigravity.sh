# Antigravity — Google, on an Antigravity subscription. Binary is `agy`, not `antigravity`.
#
# Sourced by scripts/quorum-verify. See probes/README.md.
# Use `qt` instead of `timeout` so a hang surfaces as exit 124 under the shared deadline.

# --add-dir is what sets the workspace; cwd is ignored entirely (measured — without it,
# agy works inside ~/.gemini/antigravity-cli/scratch/). A throwaway dir keeps verification
# side-effect free while still exercising the flag the adapter depends on.
# The binary this probe wraps. quorum-verify uses it to tell "you do not own this
# subscription" (fine, skip) apart from "the probe itself is broken" (a failure). A probe
# with no PROBE_BINARY can never be reported as "not installed".
PROBE_BINARY=agy

probe_consult() {   # $1 = file containing the prompt
  d=$(mktemp -d)
  qt agy --add-dir "$d" --disable-slash-commands -p "$(cat "$1")"
  rc=$?
  rmdir "$d" 2>/dev/null || true
  return $rc
}

# Probe 4: a DELIBERATELY misconfigured call. This is the point of the file — any wrapper
# can demonstrate a working call; an adapter is trustworthy only if it knows precisely what
# a failing one looks like, so it can report a failure instead of relaying it as an answer.
#
# A bad --model is used rather than a bad --mode, --add-dir, or --output-format because
# those three are SILENTLY IGNORED: each still returns rc=0 with the canary intact. Only
# --model and --effort fail loudly, so only they can serve as a discriminator.
probe_broken() {    # $1 = same
  d=$(mktemp -d)
  qt agy --add-dir "$d" --disable-slash-commands --model no-such-model-xyz -p "$(cat "$1")"
  rc=$?
  rmdir "$d" 2>/dev/null || true
  return $rc
}

EXPECT_BROKEN_DESC="exit 1, zero bytes on stdout, ~547 on stderr — 'Error: invalid model selection (--model \"no-such-model-xyz\" --effort \"\"): ... is not recognized as a known model' (Antigravity CLI 1.1.21)"

# Not needed: the exit code discriminates (good rc=0, broken rc=1).
#
# Note for whoever revisits this — the OTHER failure this provider has does NOT show up in
# the exit code. A tool blocked by headless permission auto-deny returns rc=0 with ZERO
# bytes on stdout and the explanation on stderr, which is why the adapter classifies on
# emptiness and on /auto-denied|no output produced/ as well as on $?.
# BROKEN_MATCH="<regex>"
