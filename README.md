# Quorum — multi-model agents for Claude Code

*A quorum is the number of members that must be present for a decision to count.*

Pool the AI subscriptions you already pay for — **inside** Claude Code, with no proxy and
no API keys — by delegating to other vendors' coding CLIs as subprocesses. Ask three
independent models a hard question and reconcile where they disagree. Hand mechanical work
to a cheaper agent in a throwaway git worktree and review the diff. Add your own provider,
local or hosted, in a way that is *measured* rather than guessed.

```
/quorum:panel      is this migration plan safe to run against production?
/quorum:delegate   port the remaining 40 test files to the new fixture API
/quorum:add-provider  mlx
```

---

## The problem this actually solves

Getting another model into Claude Code is easy. Getting one whose failures you can *see* is
not.

Every vendor CLI fails in its own silent way. Codex outside a trusted git repo exits 1 with
**zero bytes** — relay that naively and it reads as "the model had nothing to say." Z.AI
returns `modelCode: does not exist` inside an **HTTP 200**, so `curl` exits 0 and everything
looks fine. A reasoning model's thinking can consume the entire token budget, returning a
successful response with **no answer in it**. Copilot rejects a malformed flag on stderr —
clean and detectable, right up until you capture with `2>&1` and it becomes something
shaped like a reply.

None of those are caught by "did the command succeed?" A thin wrapper around each CLI will
eventually tell you a model agreed with you when it never ran at all.

Quorum is the set of guardrails that makes that impossible, plus the adapters that were
built by walking into each of those failures first.

## What you get

| | |
|---|---|
| **3 verified adapters** | `glm-agent`, `codex-agent`, `copilot-agent` — every flag field-tested, every failure mode documented |
| **`model-panel`** | Fan a question to all three in parallel, then synthesize consensus, splits, and outliers |
| **`delegate-task`** | Hand over whole units of work; each runs in an isolated worktree you review as a diff |
| **`add-provider`** | Your Claude probes a new provider and writes a verified adapter for it — MLX, Ollama, another CLI, anything |
| **`quorum-verify`** | Re-runs the contract against live providers, so "verified" is a measurement, not a claim |
| **[Field notes](docs/field-notes.md)** | The failure catalogue, in symptom → cause → fix form |

## Install

**As a plugin** (recommended — one command, updates with `git pull`):

```
/plugin marketplace add kourosh-forti-hands/quorum
/plugin install quorum@quorum
```

Then put the helper scripts on `PATH`:

```bash
git clone https://github.com/kourosh-forti-hands/quorum.git
cd quorum && ./scripts/install.sh
```

**Or copy the pieces in manually** — everything here is plain markdown and shell:

```bash
cp agents/*.md    ~/.claude/agents/
cp -r skills/*    ~/.claude/skills/
./scripts/install.sh
```

Check what's reachable:

```bash
quorum-status
```

It **live-checks** each provider. It does not test for a binary named after the vendor —
that is not a reliable signal, and it is how a working provider gets reported as missing.
See the [field notes](docs/field-notes.md#a-missing-binary-proves-nothing-about-a-provider).

## Requirements

Only what you actually intend to use — every provider is optional.

| Provider | Needs |
|---|---|
| Codex | `codex` CLI, `codex login` (ChatGPT subscription) |
| Copilot | `copilot` CLI (GitHub Copilot subscription) |
| GLM | `Z_AI_API_KEY` exported from `~/.zshenv` (Z.AI Coding Plan) |
| anything else | build it with `/quorum:add-provider` |

Plus `jq`, `curl`, `git`, and `bash`. `timeout(1)` is used for hang detection — macOS needs
`brew install coreutils`. Vision helpers use `sips` (macOS) or ImageMagick.

> Export keys from **`~/.zshenv`**, not `~/.zshrc`. Agents run in non-interactive shells,
> which never read `~/.zshrc`. A key that plainly works in your terminal but is "unset"
> inside an agent is almost always this.

## Bring your own provider

The three built-in adapters are examples of a pattern, not the point of the repo.

```
/quorum:add-provider mlx
```

Your Claude then runs [six probes](skills/add-provider/reference/probe-checklist.md)
against the provider **on your machine** and writes the adapter from what it measured:

1. Does it answer at all?
2. Does it exit without a TTY, or hang?
3. **Is its read-only mode enforced by the harness, or is it just asking nicely?**
4. **What does a deliberately broken call look like?**
5. Is a broken call distinguishable from a good one?
6. Can it see images, and how is the prompt passed alongside one?

Probe 4 is the one everybody skips and the only one that makes an adapter trustworthy — any
wrapper can demonstrate a working call.

Probe 3 decides the safety tier, and the rule is strict: **an adapter may only claim a tier
it can enforce.** If a provider's read-only mode turns out to be advisory, its consult tier
gets a disposable worktree instead. Degrade the mechanism, never the guarantee.

This is deliberately not a template you fill in from documentation. Any model can write a
plausible-looking adapter for any CLI; the result is a wrapper whose flags were guessed,
which fails silently the first time it matters. Starting points for common shapes:
[MLX](docs/porting/mlx.md) · [Ollama](docs/porting/ollama.md) ·
[any OpenAI-compatible endpoint](docs/porting/openai-compatible.md).

## Safety

Three tiers, each enforced by a harness or the OS — never by asking a model to behave.

| Tier | Read | Run commands | Write |
|---|---|---|---|
| **consult** | yes | no | no |
| **verify** | yes | named commands only | no — scratch worktree |
| **delegate** | yes | yes | **throwaway worktree only** |

Adapters hold `Bash, Read, Glob, Grep` and never `Write` or `Edit` — they relay text from
other vendors' models that may have read repository files, GitHub issues, and PR
descriptions written by strangers. Everything a provider returns arrives fenced in
`BEGIN/END UNTRUSTED PROVIDER OUTPUT` markers and is treated as **data, never
instructions**. An adapter that could edit files while reading attacker-influenced text
would be a confused deputy.

Full treatment: [safety-model.md](docs/safety-model.md).

## Why not a router or proxy?

Router-style tools point `ANTHROPIC_BASE_URL` at a local gateway and translate onward. That
works, and for what it does it is the right tool.

But a proxy operates at the HTTP layer, so it needs an API surface it can translate and
credentials it can replay. **It can swap a model; it cannot import a capability.** Copilot's
value here is not a chat endpoint — it is the GitHub integration, the awareness of your PRs
and CI, its own exploration subagent. None of that is reachable by replaying a token at a
completions URL, because none of it lives there.

Delegation invokes the vendor's actual agent, so its capabilities, its context window, and
**its sandbox** all come along. Quorum's tiers are assembled out of boundaries the vendors
built and test themselves.

The argument in full, including where Quorum proxies anyway and why:
[why-delegation-not-proxying.md](docs/why-delegation-not-proxying.md).

## What makes this different from a prompt collection

Every claim in here is a measurement.

`scripts/quorum-verify` re-runs the mechanical parts of the
[adapter contract](docs/adapter-contract.md) against live providers — reachability,
non-interactive exit, failure shape, and whether a broken call is distinguishable from a
good one at all:

```
$ quorum-verify codex
codex
  PASS  non-interactive exit (rc=0)
  PASS  reachability — canary returned (17 bytes)
  PASS  failure shape recorded — rc=1, 0 bytes on stdout
        documented: exit 1 with zero bytes on stdout — 'Not inside a trusted directory'
  PASS  discriminator: exit code (good=0 broken=1)
```

On its first run against a real provider it **contradicted this repo's own documentation** —
a note claimed Copilot printed a usage error to stdout; direct measurement showed stderr
with an empty stdout. The docs were wrong and were corrected, and the
[reconciliation](docs/field-notes.md#shell-is-not-the-shell-grant-syntax) turned out to be
the more useful lesson: capturing with `2>&1` is what converts a clean stderr failure into
something indistinguishable from an answer.

Run it after any provider CLI update. A flag that quietly got renamed looks exactly like a
model with nothing to say.

## Docs

| | |
|---|---|
| [adapter-contract.md](docs/adapter-contract.md) | What every adapter must guarantee |
| [safety-model.md](docs/safety-model.md) | The three tiers and what enforces them |
| [why-delegation-not-proxying.md](docs/why-delegation-not-proxying.md) | The architecture argument |
| [field-notes.md](docs/field-notes.md) | Every failure found by breaking something |
| [probe-checklist.md](skills/add-provider/reference/probe-checklist.md) | The six probes in detail |
| [porting/](docs/porting/) | MLX, Ollama, OpenAI-compatible endpoints |

## Contributing

A **verified** adapter for a provider nobody has covered — especially a local one — is the
most useful contribution this repo can receive. `/quorum:add-provider` does most of the
work; [CONTRIBUTING.md](CONTRIBUTING.md) covers what a submission needs.

Corrections to the field notes are equally welcome, and holding a higher bar than new
features: an entry that has gone stale is worse than a missing one, because it is trusted.

## License

MIT. See [LICENSE](LICENSE).
