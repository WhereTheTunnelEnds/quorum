# Ollama — a local model server on this machine. Free, offline, no API key.
#
# Talks to the NATIVE /api/chat endpoint, NOT /v1/chat/completions. The OpenAI-compatible
# endpoint silently ignores options.num_ctx and truncates an over-length prompt to the
# served window with no error signal — measured 32768 against a ~54k-token prompt, while
# native /api/chat processed 48071 of the same tokens. See docs/field-notes.md.
#
# Sourced by scripts/quorum-verify. See probes/README.md.
# Use `qt` instead of `timeout` so a hang surfaces as exit 124 under the shared deadline.

OLLAMA_BASE="${OLLAMA_BASE:-http://localhost:11434}"

# Resolved lazily: sourcing this file must not depend on the server being up.
_ollama_model() {
  if [ -n "${QUORUM_OLLAMA_MODEL:-}" ]; then printf '%s' "$QUORUM_OLLAMA_MODEL"; return 0; fi
  _om_tags=$(mktemp)
  qt curl -sS -m 10 -o "$_om_tags" "$OLLAMA_BASE/api/tags" 2>/dev/null
  jq -r '.models[0].name // empty' "$_om_tags" 2>/dev/null
  rm -f "$_om_tags"
}

# Mirrors the adapter: classify on HTTP status, not on curl's exit code. A 404 for an
# unpulled model arrives as curl exit 0, so exit code alone would call it a success.
_ollama_call() {   # $1 = model id, $2 = prompt file
  _oc_req=$(mktemp); _oc_body=$(mktemp)
  jq -n --rawfile p "$2" --arg m "$1" \
    '{model:$m, messages:[{role:"user",content:$p}], stream:false,
      options:{num_ctx:8192, temperature:0}}' > "$_oc_req"

  _oc_code=$(qt curl -sS -m 120 -o "$_oc_body" -w '%{http_code}' \
               "$OLLAMA_BASE/api/chat" -H 'content-type: application/json' -d @"$_oc_req")
  _oc_rc=$?

  if [ "$_oc_rc" != "0" ]; then                      # 124 = hang, 7 = server not running
    echo "curl exit $_oc_rc contacting $OLLAMA_BASE" >&2
    rm -f "$_oc_req" "$_oc_body"; return "$_oc_rc"
  fi
  if [ "$_oc_code" != "200" ]; then
    # Native endpoint returns a FLAT .error string; /v1 returns nested .error.message.
    echo "HTTP $_oc_code: $(jq -r 'if (.error|type)=="string" then .error
                                   else (.error.message // "unknown") end' "$_oc_body" 2>/dev/null)" >&2
    rm -f "$_oc_req" "$_oc_body"; return 1
  fi

  # Truncation is this provider's silent failure: an over-length prompt returns HTTP 200
  # with fluent prose about a fragment. prompt_eval_count landing on the window is the only
  # signal, so the probe checks it too rather than trusting a 200.
  _oc_used=$(jq -r '.prompt_eval_count // 0' "$_oc_body" 2>/dev/null)
  case "$_oc_used" in ''|*[!0-9]*) _oc_used=0 ;; esac
  if [ "$_oc_used" -ge 8192 ]; then
    echo "TRUNCATED: processed $_oc_used tokens against an 8192-token window" >&2
    rm -f "$_oc_req" "$_oc_body"; return 1
  fi

  jq -r '.message.content // empty' "$_oc_body" 2>/dev/null
  rm -f "$_oc_req" "$_oc_body"
  return 0
}

probe_consult() {
  _pc_model=$(_ollama_model)
  if [ -z "$_pc_model" ]; then
    echo "no model pulled, or server unreachable at $OLLAMA_BASE (try: ollama pull llama3.2:3b)" >&2
    return 1
  fi
  _ollama_call "$_pc_model" "$1"
}

# Probe 4: a model id that is not pulled — by far the most realistic Ollama failure, since
# models are pulled per-machine and an adapter configured elsewhere will name a missing one.
# The server answers HTTP 404 while curl still exits 0, so this is precisely the case where
# classifying on the exit code alone would relay a failure as an answer.
probe_broken() {
  _ollama_call "llama3.2:70b-does-not-exist" "$1"
}

EXPECT_BROKEN_DESC="HTTP 404 {\"error\":\"model '...' not found\"} (57-byte body); curl itself exits 0, so the adapter must classify on HTTP status. Measured on ollama 0.18.2"

# Not needed: the adapter converts a non-200 into a non-zero return, so the exit code is a
# real discriminator here. Left documented because the underlying curl exit is 0 either way.
# BROKEN_MATCH="not found|\"error\""
