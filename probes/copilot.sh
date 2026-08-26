# Copilot — GitHub, on a Copilot subscription.

# The binary this probe wraps. quorum-verify uses it to tell "you do not own this
# subscription" (fine, skip) apart from "the probe itself is broken" (a failure). A probe
# with no PROBE_BINARY can never be reported as "not installed".
PROBE_BINARY=copilot

probe_consult() {
  qt copilot -p "$(cat "$1")" --plan -s --no-ask-user --allow-tool "read"
}

# Documented failure: the colon form of a shell grant is a glob over TOOL NAMES and cannot
# carry arguments. Note the message goes to STDERR with an empty stdout — which is a clean
# failure only if the adapter keeps the streams apart. Capture with 2>&1 and it becomes an
# exit-0-looking answer. See docs/field-notes.md.
probe_broken() {
  qt copilot -p "$(cat "$1")" --plan -s --no-ask-user --allow-tool "shell:echo hello"
}

EXPECT_BROKEN_DESC="exit 1, 0 bytes stdout; 'Invalid rule format' on stderr (Copilot CLI 1.0.80)"
