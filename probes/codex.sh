# Codex — OpenAI, on a ChatGPT subscription.

# The binary this probe wraps. quorum-verify uses it to tell "you do not own this
# subscription" (fine, skip) apart from "the probe itself is broken" (a failure). A probe
# with no PROBE_BINARY can never be reported as "not installed".
PROBE_BINARY=codex

probe_consult() {
  qt codex exec --sandbox read-only --skip-git-repo-check - < "$1"
}

# Documented failure: outside a trusted git repo and without --skip-git-repo-check, Codex
# refuses and emits nothing at all. Run from a scratch directory that is not a git repo.
probe_broken() {
  d=$(mktemp -d)
  ( cd "$d" && qt codex exec --sandbox read-only - < "$1" )
  rc=$?
  rmdir "$d" 2>/dev/null || true
  return $rc
}

EXPECT_BROKEN_DESC="exit 1 with zero bytes on stdout — 'Not inside a trusted directory'"
