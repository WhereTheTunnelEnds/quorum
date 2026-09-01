# GLM — Z.AI Coding Plan.
#
# There is no `glm` binary; the consult path is a direct HTTPS call. Never test for one.
#
# What DOES decide whether this provider is set up here is the key. Without this, an unset
# Z_AI_API_KEY surfaced as "no discriminator — broken and good calls are indistinguishable",
# which blames the adapter for a missing credential.
PROBE_PRECONDITION='[ -n "${Z_AI_API_KEY:-}" ]'
PROBE_PRECONDITION_DESC='Z_AI_API_KEY is not set — run: quorum-auth glm --set-key'

_glm_call() {  # $1 = model id, $2 = prompt file
  # The key must not reach the command line. Measured: with -H "Authorization: Bearer $KEY",
  # `ps auxww` shows the key to any process running as you.
  #
  # It must not reach the DISK either. This used to be a chmod 600 mktemp file passed as
  # -H @file, cleaned by an `rm -f` at the end of the function. This file is SOURCED, so a
  # source-time trap was rejected, and no per-call trap was ever added — leaving a window
  # spanning `curl -m 900`. Measured, SIGTERM mid-call: one file per interrupted run,
  # holding a live key, surviving indefinitely.
  #
  # `-H @<(...)` closes both. curl reads the header from a /dev/fd pipe: never in argv,
  # never on disk, so there is no cleanup to forget and no trap to get wrong in a sourced
  # file. Verified the header is still transmitted, that it stays out of argv, and that the
  # fd survives the extra exec through `qt`'s `timeout`.

  # These MUST match agents/glm-agent.md. A probe's job is to re-run the adapter's documented
  # invocation against the live provider, so a probe carrying different numbers certifies a
  # configuration nobody ships. It previously said 32000 and -m 120 while the adapter said
  # 64000 and -m 900.
  #
  # Understand what this probe does NOT prove: the canary asks for one token, so it passes at
  # any cap and any deadline. It cannot catch a bad limit. That is exactly how the adapter's
  # 8000 default survived three audits while returning zero characters on real questions.
  # Limits are validated by measuring real workloads, not here.
  # Capture %{http_code}. Discarding it is what let a MISSING CREDENTIAL pass verification:
  # with no key both probes get the same 401, and the only thing that made them look
  # different was that probe_consult piped through jq while probe_broken did not. The
  # "discriminator" was discriminating on the presence of a pipe, not on the provider.
  #
  # Both probes now go through this one function, so whatever they return is comparable by
  # construction. That is the property the discriminator check actually needs.
  _gl_body=$(mktemp)
  _gl_code=$(jq -n --rawfile p "$2" --arg m "$1" \
    '{model:$m, max_tokens:64000, messages:[{role:"user", content:$p}]}' \
  | qt curl -s -m 900 -o "$_gl_body" -w '%{http_code}' \
      https://api.z.ai/api/anthropic/v1/messages \
      -H @<(printf 'Authorization: Bearer %s\n' "${Z_AI_API_KEY:-}") \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d @-)
  _gl_rc=$?
  if [ "$_gl_code" = 200 ]; then
    # Select by type, never by index: content[0] is a thinking block on reasoning models.
    jq -r 'if .content then ([.content[] | select(.type=="text") | .text] | join(""))
           else (.error.message // tostring) end' "$_gl_body" 2>/dev/null
  else
    # Emit the status explicitly so a caller — and probe 5 — can tell an auth failure from
    # an answer. Measured: bad key 401, bad model id 400, curl exits 0 for both.
    printf 'HTTP %s: %s\n' "$_gl_code" \
      "$(jq -r '.error.message // tostring' "$_gl_body" 2>/dev/null || head -c 200 "$_gl_body")"
  fi
  rm -f "$_gl_body"
  return $_gl_rc
}

probe_consult() {
  _glm_call "glm-5.3" "$1"
}

# Documented failure: a bad model id, which the server answers with HTTP 400 while curl
# still exits 0. Neither the exit code nor emptiness can discriminate, so the text is what
# does — which is the point BROKEN_MATCH exists to prove.
#
# An earlier version deliberately threw the status away here "to mirror a naive adapter".
# That was wrong, and it produced a false PASS: with NO credential both probes return the
# same 401, and only the jq pipe on one side made them look different. A probe that passes
# when the provider is unusable is worse than no probe.
probe_broken() {
  _glm_call "glm-5.3[1m]" "$1"
}

EXPECT_BROKEN_DESC="HTTP 400, error object in the body (code 1214); curl still exits 0, so without %{http_code} only the body discriminates"
BROKEN_MATCH="does not exist|HTTP 400"
