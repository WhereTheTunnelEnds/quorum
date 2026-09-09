# A SECOND Claude Code subscription, reached through a long-lived OAuth token.
#
# Sourced by scripts/quorum-verify. See probes/README.md.
# Use `qt` instead of `timeout` so a hang surfaces as exit 124 under the shared deadline.
#
# There IS a `claude` binary, but it is commonly shell-aliased. Measured on the author's
# machine: the alias appends --remote-control, which takes an OPTIONAL value and therefore
# swallows the next word, so `claude plugin update` parsed as `--remote-control plugin` and
# started an interactive session instead. Resolve the real path.
PROBE_PRECONDITION='[ -n "${CLAUDE_ALT_OAUTH_TOKEN:-}" ] && [ -x "$(/usr/bin/which claude 2>/dev/null || printf %s "$HOME/.local/bin/claude")" ]'
PROBE_PRECONDITION_DESC='CLAUDE_ALT_OAUTH_TOKEN is not set (generate one with `claude setup-token`), or the claude binary is missing'

_ca_bin() { /usr/bin/which claude 2>/dev/null || printf '%s' "$HOME/.local/bin/claude"; }

_ca_call() {  # $1 = prompt file, rest = extra flags
  _ca_prompt=$(cat "$1"); shift
  # `env -u` on all three ambient credentials is load-bearing, not hygiene: any of them
  # overrides the OAuth token and routes the call to the WRONG account, with an
  # identical-looking result. The token goes through the environment, never argv.
  #
  # Measured 2026-09-08 — unlike the curl-based providers, the EXIT CODE is informative here:
  #
  #   good call   -> rc=0, is_error=false, subtype=success, .result holds the answer
  #   bad model   -> rc=1, stdout 1273B, stderr 84B "[claude-code:unrecognized_model]"
  #   bad flag    -> rc=1, stdout 0B (no JSON at all), stderr 42B "unknown option"
  #   bad token   -> rc=1, stdout 1192B, stderr 0B, is_error=true — and subtype="success"
  #
  # That last row is the trap: `subtype` reports success on a failed call, so anything
  # classifying on it reports an auth failure as an answer. Classify on `.is_error`.
  _ca_out=$(mktemp)
  # `qt` FIRST, then `env`. `qt` is a shell FUNCTION that quorum-verify defines, and `env`
  # execs a binary -- it cannot run a function, so `env ... qt ...` exits 127 "command not
  # found". Measured: that is exactly what happened, and quorum-verify correctly reported
  # "probe is broken" rather than "provider not installed".
  qt env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_BASE_URL \
      CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_ALT_OAUTH_TOKEN:-}" \
      CLAUDE_CONFIG_DIR="${QUORUM_CLAUDE_ALT_DIR:-$HOME/.claude-alt}" \
    "$(_ca_bin)" -p "$_ca_prompt" --output-format json "$@" >"$_ca_out" 2>/dev/null </dev/null
  _ca_rc=$?
  # rc first: a bad flag produces ZERO bytes of stdout, so jq has nothing to read and would
  # emit nothing — an error that vanishes.
  if [ "$_ca_rc" -ne 0 ] && [ ! -s "$_ca_out" ]; then
    printf 'FAILED rc=%s with no JSON on stdout (bad flag shape)\n' "$_ca_rc"
  # NOT `.is_error // true`. jq's `//` fires on `false` as well as `null`, so that form
  # rewrites a successful call's `false` into `true` and reports every good answer as
  # FAILED -- measured, this probe printed "FAILED is_error=true: PROBE_OK" while
  # quorum-verify still passed, because its reachability check counts bytes and does not
  # ask whether the bytes are an answer. See docs/field-notes.md.
  elif [ "$(jq -r 'if has("is_error") then (.is_error|tostring) else "MISSING" end' "$_ca_out" 2>/dev/null)" != false ]; then
    printf 'FAILED is_error=true: %s\n' "$(jq -r '.result // "no result field"' "$_ca_out" 2>/dev/null)"
  else
    jq -r '.result // ""' "$_ca_out" 2>/dev/null
  fi
  rm -f "$_ca_out"
  return $_ca_rc
}

probe_consult() {   # $1 = file containing the prompt
  _ca_call "$1"
}

# Probe 4: a DELIBERATELY misconfigured call. A bad model id, which exits 1 and names the
# fault on stderr while still writing JSON to stdout — so both the exit code and the text
# discriminate, and this probe reports the text because quorum-verify compares stdout.
probe_broken() {    # $1 = same
  _ca_call "$1" --model does-not-exist-9x
}

EXPECT_BROKEN_DESC="claude exits 1 with 1273B of raw JSON on stdout and 84B on stderr ('[claude-code:unrecognized_model]'); this probe reads .is_error and converts it to a 174-byte 'FAILED is_error=true: ...' line. Unlike the curl providers the EXIT CODE is informative here — measured 2026-09-08"
BROKEN_MATCH="FAILED|unrecognized_model|does-not-exist"
