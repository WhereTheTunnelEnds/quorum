# GLM — Z.AI Coding Plan.
#
# There is no `glm` binary; the consult path is a direct HTTPS call. Never test for one.

_glm_call() {  # $1 = model id, $2 = prompt file
  jq -n --rawfile p "$2" --arg m "$1" \
    '{model:$m, max_tokens:8000, messages:[{role:"user", content:$p}]}' \
  | qt curl -s -m 120 https://api.z.ai/api/anthropic/v1/messages \
      -H "Authorization: Bearer ${Z_AI_API_KEY:-}" \
      -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d @-
}

probe_consult() {
  # Select by type, never by index: content[0] is a thinking block on reasoning models.
  _glm_call "glm-5.3" "$1" \
    | jq -r 'if .content then ([.content[] | select(.type=="text") | .text] | join("")) else (.error.message // tostring) end'
}

# Documented failure: a bad model id. z.ai returns it inside an HTTP 200, so curl exits 0
# and the body is non-empty — neither exit code nor emptiness can discriminate. This is
# exactly the case BROKEN_MATCH exists for.
probe_broken() {
  _glm_call "glm-5.3[1m]" "$1"
}

EXPECT_BROKEN_DESC="HTTP 200 with an error object in the body ('modelCode: does not exist'); curl exits 0"
BROKEN_MATCH="does not exist|\"error\""
