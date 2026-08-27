# Porting: Ollama

> **Status: verified.** Measured against `ollama 0.18.2` with `llama3.2:3b` pulled.
> A working adapter exists at [`agents/ollama-agent.md`](../../agents/ollama-agent.md),
> with [`probes/ollama.sh`](../../probes/ollama.sh); `scripts/quorum-verify ollama` passes
> 4/4. The response shapes below are now observations, not contract-reading.
>
> **One recommendation in the original version of this file was wrong** and is corrected
> below: the OpenAI-compatible endpoint is *not* the one to use, because it silently
> ignores `num_ctx`. See [field-notes.md](../field-notes.md#ollama-local-model-server).

Read [openai-compatible.md](openai-compatible.md) first; it carries the adapter shape.

## Serving

Ollama runs a background server on port `11434` and exposes two APIs:

| API | Path | Use |
|---|---|---|
| Native | `/api/chat`, `/api/generate` | **Use this** — the only one that honours `num_ctx` |
| OpenAI-compatible | `/v1/chat/completions` | **Avoid.** Silently caps the prompt and discards the overflow |

**Measured**, same ~54k-token prompt, both sent `options:{num_ctx:65536}`: `/v1` processed
`prompt_tokens: 32768` and answered confidently from the fragment; `/api/chat` processed
`prompt_eval_count: 48071` and answered correctly. The OpenAI endpoint accepts `num_ctx`
and throws it away, with HTTP 200 and `finish_reason: "stop"` either way.

The shared shape in [openai-compatible.md](openai-compatible.md) still applies for
*classification*; only the endpoint and the field names differ:

| | `/v1/chat/completions` | `/api/chat` |
|---|---|---|
| Text | `.choices[0].message.content` | `.message.content` |
| Prompt tokens | `.usage.prompt_tokens` | `.prompt_eval_count` |
| Error | `.error.message` (nested) | `.error` (**flat string**) |

```text
ollama pull <model>
curl -s http://localhost:11434/api/tags | jq -r '.models[].name'   # what is actually loaded
```

That last command is worth putting in the adapter's failure path: a 404 almost always means
the model name is not pulled, and naming the available models beats reporting "not found."
**Measured:** HTTP 404, 57-byte body, and **curl exits 0** — so classify on HTTP status,
never on the exit code.

So `BASE="http://localhost:11434"`, with requests posted to `$BASE/api/chat`.

## What probing established

Measured on `ollama 0.18.2` / `llama3.2:3b`. Re-measure for your own model — the numbers
are model- and machine-specific, but the *shapes* generalise.

- **`num_ctx` is the real context limit, and it defaults far below the model's.** Measured:
  the model advertises `context length 131072`; the server served **32768**. Ollama
  truncates silently rather than erroring, so an oversized prompt yields a confident answer
  about a fragment. Set `num_ctx` per request and make the adapter **refuse** anything
  larger. Verify afterwards with `prompt_eval_count >= num_ctx`, which is an exact test and
  the only machine-readable signal that truncation happened.
- **Truncation drops from the head.** A canary on line 1 of a 54k-token prompt vanished
  while the trailing question was answered fluently — which is why the result reads as a
  genuine answer rather than a broken one.
- **Raising `num_ctx` costs memory.** Measured: **5.6 GB → 9.2 GB** resident going from
  32768 to 65536 on a 3B Q4 model. Size the window to the prompt; do not max it out.
- **Cold-start latency.** Measured: **9s** cold versus **0.16s** warm on a 3B model. Set the
  deadline above the cold-start cost or probe 2 records a model load as a hang.
- **Where reasoning text lands** for thinking models — `reasoning_content`, `.message.thinking`,
  or `<think>` tags inside `content`. *Not measured* — no thinking model was pulled. Read one
  raw body before writing the extraction.
- **Vision.** `/api/show` reports `.capabilities`; `llama3.2:3b` returns
  `["completion","tools"]`, i.e. no vision. Check it there before assuming an image path.

> A `tools` capability means the model can *emit* tool calls. Execution is entirely
> client-side and the server never touches the filesystem — which is what makes consult
> structurally safe here. An adapter that executed returned tool calls would give that away.

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
