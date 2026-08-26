---
name: add-provider
description: Use when adding a new model provider to Quorum - wiring up a local model (MLX, Ollama, LM Studio, llama.cpp, vLLM), another vendor's coding CLI (Gemini, Cursor, Amp, Aider), or any OpenAI/Anthropic-compatible endpoint so it can be consulted and delegated to like the built-in ones. Probes the provider empirically, then writes an adapter from what was measured. Also use when an existing adapter broke after a CLI update.
---

# Add a Provider

Build a Quorum adapter for a provider on **this** machine, by measuring it rather than by
reading about it.

## The rule this skill exists to enforce

> **Do not write an adapter from documentation. Write it from measurements.**

Any model can produce a plausible-looking adapter for any CLI. The result is a wrapper
whose flags were guessed, which fails silently the first time it matters — and silent
failure is the exact thing Quorum's whole design is built to prevent. An adapter is worth
having only if someone ran the commands and wrote down what came back.

So the order is fixed: **probe first, write second.** If you cannot run the provider — it
isn't installed, there's no key, the machine is wrong — say so and stop. Do not produce an
adapter "for them to test later." An untested adapter that looks tested is worse than none.

## Step 0 — Establish the invocation surface

Ask the user, or find out, what kind of provider this is. The three shapes need different
adapters:

| Shape | Examples | Adapter reaches it via |
|---|---|---|
| **Agentic CLI** | Gemini CLI, Aider, Amp, Cursor CLI | the CLI's own headless/exec mode |
| **HTTP endpoint, no CLI** | Z.AI, OpenRouter, a hosted API | `curl` |
| **Local server** | MLX, Ollama, LM Studio, llama.cpp, vLLM | `curl` to localhost; see `docs/porting/` |

Then find the real entry point. **Do not assume a binary is named after its vendor** —
GLM has no `glm` command at all. `command -v` returning NOT FOUND proves nothing; it is
already responsible for one panel falsely reporting a working provider as missing.

Establish the invocation the vendor actually documents, then confirm it by running it.

## Step 0.5 — Read the **whole** flag surface first

Before probing, dump the complete help and read all of it:

```bash
<cli> --help
<cli> <subcommand> --help     # exec, chat, run — wherever the real work happens
```

Not the flags you expect to need — **all** of them. Copilot alone exposes around sixty, and
an adapter written from the obvious ones missed `--available-tools`, `--excluded-tools`,
`--output-format`, and `--secret-env-vars`, any of which changes how the adapter should be
built.

Four things to look for specifically, because they determine whether the adapter can exist
at all:

| Looking for | Typical spelling |
|---|---|
| Headless / one-shot | `-p`, `exec`, `--print`, `--json`, `--output-format` |
| Don't ask the user | `--no-ask-user`, `--yes`, `--non-interactive`, `--autopilot` |
| Sandbox / permission | `--sandbox`, `--plan`, `--allow-tool`, `--deny-tool`, `--mode` |
| Working directory | `-C`, `--cwd`, `--add-dir` |

Note the **variadic** ones (`<FILE>...`) as you go. A variadic flag will swallow a trailing
prompt and hang the run — that is probe 2's most common cause and it is visible in `--help`
before it costs you a timeout.

Then snapshot it, so drift is detectable later:

```bash
quorum-flags --capture      # writes reference/flags/<provider>.txt
```

## Step 1 — Run the six probes

Full detail, including what each result means: `reference/probe-checklist.md`.

Record the **measurement** for each — exit code, byte count, the actual text. Not "works"
or "seems fine."

| # | Question | Fails how |
|---|---|---|
| 1 | Does it answer at all? | Wrong entry point, no auth |
| 2 | Does it exit without a TTY? | Hangs to the timeout (exit 124) — missing a "don't ask" flag |
| 3 | Is read-only **harness**-enforced? | It writes the file anyway — the mode was advisory |
| 4 | **What does a broken call look like?** | You cannot report failures you cannot recognise |
| 5 | Is a broken call distinguishable from a good one? | Exit code, empty output, or error text — at least one must work |
| 6 | Images, and how is the prompt passed? | Optional; skip if the provider has no vision |

**Probe 4 is the one that matters.** Everything else confirms the happy path, which anyone
can get right. Deliberately break the call — wrong flag, wrong model id, wrong directory —
and write down exactly what comes back.

**Measure unpiped.** `provider ... | tail` reports `tail`'s exit status, which is how a
failing call gets recorded as a working one. Redirect to separate files:

```bash
OUT=$(mktemp); ERR=$(mktemp)
timeout 120 <invocation> >"$OUT" 2>"$ERR"; RC=$?
echo "rc=$RC stdout=$(wc -c <"$OUT") stderr=$(wc -c <"$ERR")"
```

**Keep stdout and stderr apart, including now.** Some CLIs print usage errors to stderr and
exit non-zero — a clean, detectable failure. Capture with `2>&1` and that same failure
becomes non-empty output that looks exactly like an answer.

## Step 2 — Choose the safety tier from probe 3, not from hope

This is the step where an adapter becomes trustworthy or merely optimistic.

- **Probe 3 passed** (the harness refused the write) → the provider gets a real
  **consult** tier using that flag.
- **Probe 3 failed** (the file appeared) → the mode is prompt-enforced. It is *not*
  read-only. The consult tier runs in a **detached scratch worktree** instead.

> **Degrade the mechanism, never the guarantee.** An adapter may only claim a tier it can
> enforce. Writing "read-only" over a mode that merely asks nicely is the one failure this
> repo cannot tolerate, because every downstream user trusts that word.

Same reasoning for **verify** (named-command allowlist, or a scratch worktree) and
**delegate** (throwaway worktree on its own branch, always). See `docs/safety-model.md`.

## Step 3 — Write the three files

Copy the templates, then fill them from your notes — never from memory of the docs.

1. **`agents/<name>-agent.md`** — from `templates/adapter.md.template`.
   Frontmatter needs `name`, a `description` saying when to route here and what the
   provider is *uniquely* good for, `tools: Bash, Read, Glob, Grep` (never `Write` or
   `Edit`; the adapter reads attacker-influenceable text and must not be able to act on
   it), and a small `model:` — an adapter is plumbing.

2. **`probes/<name>.sh`** — from `templates/probe.sh.template`. This is what makes the
   adapter re-checkable after a vendor update. `probe_broken()` encodes probe 4.

3. **A `docs/field-notes.md` entry** — but only for genuine surprises. Anything that cost
   you more than one attempt to get right will cost the next person the same. Use the
   documented format, and mark anything you inferred rather than observed.

## Step 4 — Prove it

```bash
scripts/quorum-verify <name>      # does it work?
scripts/quorum-flags              # do the flags it depends on still exist?
```

It re-runs the mechanical probes against the live provider. **If it does not pass, the
adapter is not finished** — do not report success. When it contradicts something you
believed, the verifier is usually right; measure directly and correct the document. That
has already happened once to this repo's own docs, and the correction is in the field notes.

Then test the routing end-to-end: dispatch a real question through the new agent and check
that a well-formed envelope comes back — `status`, diagnostics, delimiters.

## Step 5 — Report what you actually established

State plainly which tiers are enforced and by what mechanism, which probes passed, and what
you could **not** verify. A provider with no harness-level read-only mode is still usable
via worktree isolation — but the user needs to know that is what they have.

Offer to contribute it back: `CONTRIBUTING.md` covers submitting an adapter, and a verified
one for a provider nobody has covered yet is the most useful PR this repo can receive.

## Common shapes

- **Local models (MLX, Ollama, LM Studio, llama.cpp, vLLM)** — usually an
  OpenAI-compatible server on localhost, so consult is a `curl` adapter. They typically
  have **no agentic harness**, which means no native read-only mode and no verify or
  delegate tier. That is fine — say so rather than inventing one. Start from
  `docs/porting/openai-compatible.md`.
- **Another vendor's coding CLI** — closest to the built-in three. Find its headless flag,
  its "don't ask the user" flag, and its sandbox flag, in that order.
- **A hosted API** — mirror `agents/glm-agent.md`. Watch for providers that return errors
  inside HTTP 200; classify on the body, not the status code.
