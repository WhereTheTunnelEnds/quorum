# Porting: Ollama

> **Status: partially verified.** The server was reachable on the machine where this repo
> was built — `ollama 0.18.2`, `GET /api/tags` returned `{"models":[]}` — but **no model was
> pulled, so no completion was ever measured.** Everything about response shape below is
> from the OpenAI-compatible contract, not from observation. Build a real adapter with
> [`add-provider`](../../skills/add-provider/SKILL.md) and contribute it back.

Read [openai-compatible.md](openai-compatible.md) first; it carries the adapter shape.

## Serving

Ollama runs a background server on port `11434` and exposes two APIs:

| API | Path | Use |
|---|---|---|
| OpenAI-compatible | `/v1/chat/completions` | **Use this** — the shared adapter shape applies |
| Native | `/api/chat`, `/api/generate` | Ollama-specific fields; only if you need them |

```bash
ollama pull <model>
curl -s http://localhost:11434/api/tags | jq -r '.models[].name'   # what is actually loaded
```

That last command is worth putting in the adapter's failure path: a 404 from
`/v1/chat/completions` almost always means the model name is not pulled, and naming the
available models beats reporting "not found."

So `BASE="http://localhost:11434/v1"`.

## What to establish during probing

- **`num_ctx` is the real context limit, and it defaults small** — often far below what the
  model supports. Ollama truncates silently rather than erroring, so an oversized prompt
  produces a confident answer about a fragment. This is the single most important thing to
  measure. Set it explicitly in the Modelfile or per-request options, then make the adapter
  refuse anything larger.
- **Cold-start latency.** The first request after an idle period loads the model into
  memory and can take a long time. Measure it, then set the adapter's timeout above it, or
  probe 2 will report a hang that is really a load.
- **Where reasoning text lands** for thinking models — `reasoning_content`, or `<think>`
  tags inside `content`. Read one raw body before writing the extraction.

## Realistic tier expectations

Ollama is a **model server, not an agent** — no sandbox, no tool loop, no file editing.
**Consult only.** Do not write verify or delegate sections into an Ollama adapter; there is
nothing to enforce them with.

## A note on panel value

A small quantized local model as a fourth panelist can actively hurt: panels pay off through
*decorrelated* failure, and a weak model tends to be wrong more often and less
independently. Route local models to privacy-bound work and bulk mechanical tasks, not to
tie-breaking a hard architecture call. See the closing section of
[openai-compatible.md](openai-compatible.md).
