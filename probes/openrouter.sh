# OpenRouter — one key, many vendors' models, billed per token (not a subscription).
#
# Sourced by scripts/quorum-verify. See probes/README.md.
# Use `qt` instead of `timeout` so a hang surfaces as exit 124 under the shared deadline.
#
# There is no `openrouter` binary and there never will be — this is an HTTP endpoint. Do not
# test for one. `command -v openrouter` returning NOT FOUND proves nothing, the same trap
# that once made a panel report a working GLM as missing.
PROBE_PRECONDITION='[ -n "${OPENROUTER_API_KEY:-}" ]'
PROBE_PRECONDITION_DESC='OPENROUTER_API_KEY is not set — export it from ~/.zshenv'

_or_call() {  # $1 = model id, $2 = prompt file
  # The key reaches neither argv nor the disk: curl reads the header from a /dev/fd pipe.
  # Measured: with -H "Authorization: Bearer $KEY" the key is visible in `ps auxww` for the
  # life of the call; with a chmod 600 temp file it survives on disk whenever a signal lands
  # before the cleanup.
  #
  # Capture %{http_code} AND the body. Measured 2026-09-08, every failure below exits curl 0:
  #
  #   good call        -> 200, .choices[]
  #   bad model id     -> 400, "... is not a valid model ID"
  #   bad key          -> 401, "User not found."
  #   unroutable model -> 404, "No allowed providers are available for the selected model"
  #
  # So curl's exit status carries no information here and the status code carries all of it.
  _or_body=$(mktemp)
  _or_code=$(jq -n --rawfile p "$2" --arg m "$1" \
    '{model:$m, max_tokens:1024, messages:[{role:"user", content:$p}]}' \
  | qt curl -s -m 300 -o "$_or_body" -w '%{http_code}' \
      https://openrouter.ai/api/v1/chat/completions \
      -H @<(printf 'Authorization: Bearer %s\n' "${OPENROUTER_API_KEY:-}") \
      -H "content-type: application/json" \
      -d @-)
  _or_rc=$?
  if [ "$_or_code" = 200 ]; then
    # HTTP 200 is NOT sufficient. Measured on openai/gpt-5-nano with max_tokens=48: a 4,659
    # byte body, curl 0, HTTP 200, finish_reason "length", reasoning 924 chars — and
    # `.choices[0].message.content` EMPTY, because max_tokens is the budget for reasoning
    # PLUS content and the reasoning consumed all of it. Emitting only `.content` there
    # yields zero bytes, which quorum-verify would read as "the provider said nothing".
    # Say what actually happened instead.
    _or_fin=$(jq -r '.choices[0].finish_reason // "none"' "$_or_body" 2>/dev/null)
    _or_txt=$(jq -r '.choices[0].message.content // ""' "$_or_body" 2>/dev/null)
    if [ -n "$_or_txt" ]; then
      printf '%s\n' "$_or_txt"
      # Truncation is a well-formed success. Mark it; do not let it pass as a whole answer.
      [ "$_or_fin" = length ] && printf 'TRUNCATED: finish_reason=length\n'
    else
      printf 'EMPTY BODY TEXT: finish_reason=%s, reasoning=%s chars, completion_tokens=%s\n' \
        "$_or_fin" \
        "$(jq -r '.choices[0].message.reasoning // "" | length' "$_or_body" 2>/dev/null)" \
        "$(jq -r '.usage.completion_tokens // "?"' "$_or_body" 2>/dev/null)"
    fi
  else
    # Emit the status explicitly so a caller can tell an auth failure from an answer.
    printf 'HTTP %s: %s\n' "$_or_code" \
      "$(jq -r '.error.message // tostring' "$_or_body" 2>/dev/null || head -c 200 "$_or_body")"
  fi
  rm -f "$_or_body"
  return $_or_rc
}

probe_consult() {   # $1 = file containing the prompt
  _or_call "google/gemini-2.5-flash" "$1"
}

# Probe 4: a DELIBERATELY misconfigured call. A bad model id, which OpenRouter answers with
# HTTP 400 while curl still exits 0 — so neither the exit code nor emptiness discriminates,
# and the status line this function emits is what does.
probe_broken() {    # $1 = same
  _or_call "openrouter/does-not-exist-9x" "$1"
}

EXPECT_BROKEN_DESC="HTTP 400, raw body 132 bytes: {\"error\":{\"message\":\"... is not a valid model ID\",\"code\":400}}. curl exits 0 and stderr is empty, so the status code is the only signal; this probe converts it to a 63-byte \"HTTP 400: ...\" line on stdout — measured 2026-09-08"
BROKEN_MATCH="not a valid model ID|HTTP 400"
