# Porting: any OpenAI-compatible endpoint

Covers MLX, Ollama, LM Studio, llama.cpp, vLLM, OpenRouter, and most self-hosted servers.
Provider-specific notes: [mlx.md](mlx.md), [ollama.md](ollama.md).

> **Status: not verified by the author.** The pattern below is the one the built-in GLM
> adapter uses, adjusted for the OpenAI response shape. Run
> [`/quorum:add-provider`](../../skills/build-adapter/SKILL.md) to build and *measure* a real adapter
> on your machine. Corrections welcome — a verified adapter for any of these is the most
> useful PR this repo can receive.

## Choose the route first

Two routes, and picking the wrong one wastes an afternoon.

### Route A — a consult-only `curl` adapter (recommended)

Talk to the server directly. No shim, no extra process, works today. You get a **consult**
tier and nothing else — which for a local model is usually the whole truth anyway, since
most have no agentic harness, no sandbox, and no file-editing loop.

An adapter that offers only consult, honestly, is worth far more than one that claims three
tiers it cannot enforce.

> **Prefer the vendor's native endpoint over its OpenAI-compatible one where both exist.**
> The compatibility layer is a translation, and translations drop fields. Measured on
> ollama 0.18.2: `/v1/chat/completions` **accepts `options.num_ctx` and discards it**,
> capping the prompt at the served window and dropping the overflow — HTTP 200,
> `finish_reason: "stop"`, no error — while native `/api/chat` honoured the same value
> exactly (2048 requested → 2048 processed; via `/v1`, 32768).
>
> An OpenAI-compatible endpoint buys you portable *code*. It does not guarantee the server
> honours what you send. Verify the fields you depend on actually take effect —
> [field-notes.md](../field-notes.md) has the full measurement.

### Route B — an Anthropic-compatible shim, for verify and delegate

`scripts/quorum-claude-on` sets `ANTHROPIC_BASE_URL`, which requires the endpoint to speak
the **Anthropic Messages API** (`/v1/messages`). OpenAI-compatible servers do not. You need
a translating proxy in front — LiteLLM and claude-code-router are the usual choices.

**Verify the shim exposes `/v1/messages` before building on it**, and check it handles
streaming and tool-calling, because Claude Code uses both. This is the part that eats the
afternoon. Route A first; add Route B only if you actually need a local model editing files.

## Route A: the adapter shape

For Ollama specifically, use the native endpoint instead — see
[ollama.md](ollama.md). The OpenAI-compatible shape below applies to MLX, LM Studio,
llama.cpp, vLLM, and OpenRouter.

```bash
BASE="${LOCAL_LLM_BASE:-http://localhost:8080/v1}"    # MLX :8080 · LM Studio :1234
MODEL="${LOCAL_LLM_MODEL:?set LOCAL_LLM_MODEL}"

PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" <<'PROMPT_EOF'
<the question, with file contents inlined — a curl adapter has no machine access>
PROMPT_EOF

BODY=$(mktemp)
# The key goes on NEITHER the command line nor the disk. With
# -H "Authorization: Bearer $KEY" it sits in argv, where `ps auxww` shows it to every
# process running as you. Writing it to a chmod 600 file fixes argv and strands a live
# credential in the temp dir whenever a signal lands before the cleanup. `-H @<(...)` keeps
# the same `@file` reader and hands it a /dev/fd pipe: no argv, no file, nothing to clean up.
#
# Harmless for a local endpoint with no real key — but copy this adapter to a hosted
# OpenAI-compatible provider and the habit follows the code. It is the habit that matters,
# which is why the template models the safe one. Needs bash or zsh: `<(...)` is process
# substitution and POSIX `sh` does not have it.
CODE=$(jq -n --rawfile p "$PROMPT_FILE" --arg m "$MODEL" \
        '{model:$m, messages:[{role:"user", content:$p}], stream:false}' \
      | curl -s -m 900 -o "$BODY" -w '%{http_code}' "$BASE/chat/completions" \
          -H "content-type: application/json" \
          -H @<(printf 'Authorization: Bearer %s\n' "${LOCAL_LLM_KEY:-none}") \
          -d @-)

jq -r '.choices[0].message.content // .error.message // "no content"' "$BODY"
```

Three things differ from the Anthropic shape, and each has bitten someone:

| | Anthropic | OpenAI-compatible |
|---|---|---|
| Text location | `.content[] \| select(.type=="text")` | `.choices[0].message.content` |
| Auth header | `Authorization: Bearer` + `anthropic-version` | `Authorization: Bearer` only |
| Local auth | required | often ignored — but **send something**; some servers 401 on an absent header |

**Reasoning models.** If the model emits chain-of-thought, it may arrive in
`.choices[0].message.reasoning_content` (or inside `<think>` tags in `content`) rather than
where you expect. Same class of trap as GLM's thinking block at `content[0]` — an answer
that looks empty because you read the wrong field. Check the raw body once during probe 1
and write down where the text actually lives.

## Classification

Local servers fail differently from hosted ones. Measure yours; these are the usual shapes:

| Condition | status | Note |
|---|---|---|
| curl exit 7 / 28 | `error` | server not running, or wall-clock timeout |
| `CODE` ≠ 200 | `error` | 404 usually means the model name is not loaded |
| `.error` present | `error` | some servers return 200 with an error body |
| `.choices[0].message.content` empty/null | `empty` | context overflow, or reasoning ate the budget |
| otherwise | `ok` | |

**Context overflow is the local-model failure mode**, and it is measured, not theoretical:
servers silently truncate to the served window rather than erroring, so you get a confident
answer about a file the model saw a fragment of. Every success signal still says success.

Two defences, and use both:

1. **Find the real window during probe 1** and make the adapter refuse oversized inputs
   outright rather than quietly answering from a fragment.
2. **Check the reported prompt-token count against that window on every call.** If the
   server says it processed exactly the window size, assume truncation and return `empty`
   rather than relaying the answer. Ollama reports `prompt_eval_count`; OpenAI-compatible
   servers report `usage.prompt_tokens`.

A canary makes this testable: put a distinctive token on the first line of a long prompt and
ask the model to repeat it. If it cannot, the head was dropped.

## Is it worth adding?

Worth asking before you build it. A panel's value is **decorrelated failure** — vendors
being wrong in different ways. A small local model is not simply a cheaper large one; it
tends to be wrong more often *and* less independently, and a confidently wrong fourth
opinion makes a panel worse, not better.

Where local models genuinely earn their place:

- **Privacy** — code that must not leave the machine. This alone justifies it.
- **Bulk mechanical work** — classification, extraction, summarising many files, where
  volume matters more than depth and the output is checkable.
- **Offline** — no network, no subscription, no rate limit.
- **Zero marginal cost** — iterate without spending quota.

Where they don't: as an additional vote on a hard architecture call. Route those to models
that fail differently *and* well.
