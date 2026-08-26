# GLM — Z.AI Coding Plan.
#
# There is no `glm` binary; the consult path is a direct HTTPS call. Never test for one.

_glm_call() {  # $1 = model id, $2 = prompt file
  # The key goes in a header FILE, never on the command line. Measured: with
  # -H "Authorization: Bearer $KEY", `ps auxww` shows the key to any process running as
  # you. curl reads @file, so it never reaches argv. Created per call because this file is
  # SOURCED — setup at source time would run before quorum-verify is ready and leak on exit.
  _gl_hdr=$(mktemp); chmod 600 "$_gl_hdr"
  printf 'Authorization: Bearer %s\n' "${Z_AI_API_KEY:-}" > "$_gl_hdr"

  # 32000 here on purpose, while the adapter uses 64000. This is a reachability canary with
  # a one-word prompt: the cap only has to be large enough not to truncate a short answer,
  # and a bigger one would neither be exercised nor prove anything. A deliberate difference,
  # not drift — and note that this probe passing at ANY cap is exactly why the adapter's
  # 8000 default survived three audits.
  jq -n --rawfile p "$2" --arg m "$1" \
    '{model:$m, max_tokens:32000, messages:[{role:"user", content:$p}]}' \
  | qt curl -s -m 120 https://api.z.ai/api/anthropic/v1/messages \
      -H @"$_gl_hdr" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d @-
  _gl_rc=$?
  rm -f "$_gl_hdr"
  return $_gl_rc
}

probe_consult() {
  # Select by type, never by index: content[0] is a thinking block on reasoning models.
  _glm_call "glm-5.3" "$1" \
    | jq -r 'if .content then ([.content[] | select(.type=="text") | .text] | join("")) else (.error.message // tostring) end'
}

# Documented failure: a bad model id. The server answers HTTP 400, but this probe does not
# capture %{http_code} — so from the shell's view curl exits 0 with a non-empty body, and
# neither the exit code nor emptiness can discriminate. That is exactly what BROKEN_MATCH
# is for, and it mirrors how a naive adapter would see it.
#
# The ADAPTER does capture the status (see agents/glm-agent.md) and classifies on it. Do not
# "fix" this probe to match: its job is to prove the text discriminator works even when the
# status is thrown away, which is the situation an adapter author will actually be in.
probe_broken() {
  _glm_call "glm-5.3[1m]" "$1"
}

EXPECT_BROKEN_DESC="HTTP 400, error object in the body (code 1214); curl still exits 0, so without %{http_code} only the body discriminates"
BROKEN_MATCH="does not exist|\"error\""
