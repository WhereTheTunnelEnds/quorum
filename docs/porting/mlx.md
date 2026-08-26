# Porting: MLX (Apple silicon)

> **Status: not verified by the author** — MLX was not installed on the machine where this
> repo was built, so nothing here was measured. It is a starting point, not a field note.
> Build a real adapter with [`/quorum:add-provider`](../../skills/build-adapter/SKILL.md), which
> probes the provider on *your* machine, and please contribute it back.

MLX is Apple's array framework; `mlx-lm` serves models on Apple silicon with an
OpenAI-compatible HTTP API. Read [openai-compatible.md](openai-compatible.md) first — it
carries the adapter shape. This page is only the MLX-specific parts.

## Serving

```bash
pip install mlx-lm
mlx_lm.server --model mlx-community/<model> --port 8080
```

So `BASE="http://localhost:8080/v1"`.

Confirm before writing anything:

```bash
curl -s http://localhost:8080/v1/models | jq .
```

If that fails, the adapter cannot be written yet — no amount of prose substitutes for a
running server.

## What to establish during probing

- **The served context length.** MLX serves what you configure, not what the model card
  advertises. Oversized prompts may be silently truncated rather than rejected, which
  yields a confident answer about a file the model half-read. Find the real number and make
  the adapter refuse inputs above it.
- **Where the text actually is.** Reasoning models may put chain-of-thought in
  `reasoning_content`, or in `<think>` tags inside `content`. Read one raw response body
  before writing the `jq` extraction.
- **Whether an absent auth header 401s.** Local servers vary. Send a dummy bearer token.
- **First-token latency.** Model load on first request can take tens of seconds. Set the
  adapter's timeout from a measurement, not a guess, or probe 2 reports a hang that is
  really a cold start.

## Realistic tier expectations

`mlx_lm.server` is a **model server, not an agent.** There is no sandbox, no tool loop, no
file editing.

That means **consult only.** Do not write verify or delegate sections into an MLX adapter —
there is nothing to enforce them with. See
[safety-model.md](../safety-model.md): an adapter may only claim a tier it can enforce.

If you want a local model doing implementation work, that is Route B in
[openai-compatible.md](openai-compatible.md) — an Anthropic-compatible shim plus
`quorum-claude-on`, so Claude Code provides the harness and MLX provides only the tokens.
Verify the shim handles streaming and tool calls before trusting it.

## Where MLX genuinely wins

Privacy, offline work, and zero marginal cost — see the closing section of
[openai-compatible.md](openai-compatible.md). Code that cannot leave the machine is the
strongest case, and it is a good one.
