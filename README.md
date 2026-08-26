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
returns `modelCode: does not exist` with **`curl` exiting 0**, so the exit code says everything
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
| **5 verified adapters** | `glm-agent`, `codex-agent`, `copilot-agent`, `ollama-agent`, `antigravity-agent` — every flag field-tested, every failure mode documented |
| **`model-panel`** | Fan a question to every available provider in parallel, then synthesize consensus, splits, and outliers |
| **`delegate-task`** | Hand over whole units of work; each runs in an isolated worktree you review as a diff |
| **`add-provider`** | Your Claude probes a new provider and writes a verified adapter for it — MLX, Ollama, another CLI, anything |
| **`quorum-verify`** | Re-runs the contract against live providers, so "verified" is a measurement, not a claim |
| **`quorum-setup`** | Guided first run: prerequisites, PATH, provider choice, auth, then proof |
| **`quorum-auth`** | Diagnoses what's unauthenticated and gives the one command that fixes each |
| **`quorum-flags`** | Checks every flag the adapters depend on still exists in the live CLI |
| **[Field notes](docs/field-notes.md)** | The failure catalogue, in symptom → cause → fix form |

## Install

> **New here?** [**getting-started.md**](docs/getting-started.md) is a step-by-step
> walkthrough from zero to your first panel, with a check after every step. This section is
> the short version.

**As a plugin** (recommended — one command, updates with `git pull`):

```
/plugin marketplace add kourosh-forti-hands/quorum
/plugin install quorum@quorum
```

Then put the helper scripts on `PATH` and run the guided setup:

```bash
git clone https://github.com/kourosh-forti-hands/quorum.git
cd quorum && ./scripts/install.sh
quorum-setup          # prerequisites -> providers -> auth -> a real call to each
```

`quorum-setup` walks you through it and stops at each thing you need to do yourself. It
never asks for a key or an auth code — installs and logins are printed for **you** to run,
because vendor installers execute remote code, logins bind your paid accounts, and anything
pasted into an agent chat becomes transcript.

**Or install the pieces manually** — everything here is plain markdown and shell:

```bash
git clone https://github.com/kourosh-forti-hands/quorum.git
cd quorum

mkdir -p ~/.claude/agents ~/.claude/skills ~/.claude/commands/quorum
cp    agents/*.md   ~/.claude/agents/
cp -r skills/*      ~/.claude/skills/
cp    commands/*.md ~/.claude/commands/quorum/      # note the quorum/ subdirectory
./scripts/install.sh
```

Three things about that block, each of which broke for someone:

- **The clone is part of it.** This branch needs the repository too — it is not an
  alternative to fetching the code, only to installing it as a plugin.
- **`commands/quorum/`, not `commands/`.** User commands are namespaced by **subdirectory**,
  so copying to `~/.claude/commands/` gives you `/status` and `/panel` — *not* the
  `/quorum:status` and `/quorum:panel` this guide tells you to type. Verified on a live
  install: `~/.claude/commands/build.md` → `/build`, while
  `~/.claude/commands/bench/plan_new_feature.md` → `/bench:plan_new_feature`. The plugin
  route gets the prefix from the plugin name; the manual route has to get it from the
  directory.
- **`mkdir -p` is not optional.** Where those directories do not exist, `cp` fails with
  *"Not a directory"* and installs nothing.

Both halves are needed: the plugin is what Claude uses, the scripts are what your shell
uses. Then check what's reachable:

```bash
quorum-status
```

Anything missing? `quorum-auth` names the exact fix for each, and `/quorum:auth` walks you
through it inside Claude Code.

`quorum-status` makes a **real call** wherever a real call is the only evidence: GLM gets an
API request, Ollama gets a `/api/tags` fetch, Claude gets a credential check.

It does use `command -v` for the three providers that genuinely ship a binary named after
themselves — `codex`, `copilot`, `agy` — so a stub implementing only `--version` will be
reported as OK. That is a presence check, not an auth check, and the table says `installed`
rather than `logged in` for `agy` for exactly that reason. Use `quorum-auth` for
authentication and `quorum-verify` for "does it actually work".

What it never does is infer *absence* from a missing binary. GLM ships no `glm` command at
all, and `command -v glm` returning nothing has already caused a working provider to be
reported as missing. See the
[field notes](docs/field-notes.md#a-missing-binary-proves-nothing-about-a-provider).

## Requirements

Only what you actually intend to use — every provider is optional.

Full list of known providers, install commands, and which are verified vs merely
documented: [docs/providers.md](docs/providers.md).

| Provider | Needs |
|---|---|
| Ollama | `ollama` + a pulled model. **No account, no key, no subscription** |
| Codex | `codex` CLI, `codex login` (ChatGPT subscription) |
| Copilot | `copilot` CLI (GitHub Copilot subscription) |
| GLM | `Z_AI_API_KEY` exported from `~/.zshenv` (Z.AI Coding Plan) |
| Antigravity | `agy` CLI, one browser login (Antigravity subscription). **Consult only** |
| anything else | build it with `/quorum:add-provider` |

Plus `jq`, `curl`, `git`, and `bash`. `timeout(1)` is used for hang detection — macOS needs
`brew install coreutils`.

**Nothing else is required.** Image normalization (`prep-image`, needed only if you send
images to a panel) uses `sips`, which ships with macOS. ImageMagick is the fallback for
Linux and BSD, where there is no `sips` — install it only if you actually want visual
panels there. With neither present, `prep-image` exits 1 with a one-line explanation and
every other part of Quorum is unaffected.

> Export keys from **`~/.zshenv`**, not `~/.zshrc`. Agents run in non-interactive shells,
> which never read `~/.zshrc`. A key that plainly works in your terminal but is "unset"
> inside an agent is almost always this — it is the most common setup failure by a wide
> margin, and [troubleshooting.md](docs/troubleshooting.md) opens with it.

## Bring your own provider

The built-in adapters are examples of a pattern, not the point of the repo.

```
/quorum:add-provider mlx
```

`ollama-agent` was built exactly this way — by a Claude that had never seen this repo's
development, running the probes on a real machine. It passes `quorum-verify` 4/4, and along
the way it **found and corrected an error in these docs**: the porting guide recommended
Ollama's OpenAI-compatible endpoint, which silently discards `options.num_ctx` and truncates
long prompts with no error signal. The native endpoint honours it. That correction is now in
the [field notes](docs/field-notes.md), measured.

Your Claude then runs [six probes](skills/build-adapter/reference/probe-checklist.md)
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

Three tiers — and **only one of them is enforced by anything stronger than a convention.**
That distinction is the most important thing on this page.

| Tier | Read | Run commands | Write | Enforced by |
|---|---|---|---|---|
| **consult** | yes | no | no | the provider's own sandbox / plan mode — real |
| **verify** | yes | named commands only | **Codex: no. Copilot, GLM: yes, it can** | Codex: OS sandbox. Others: an allowlist |
| **delegate** | yes | yes | yes | nothing, except Codex |

**A git worktree is not a sandbox.** It gives you *reviewability* and *disposability*, both
genuinely useful — it does not give you containment. Code running inside a worktree finds
your real checkout in one command, because they share a `.git`:

```bash
dirname "$(git rev-parse --path-format=absolute --git-common-dir)"
```

Measured: Copilot, given the documented verify invocation with `--allow-tool 'shell(pytest)'
--deny-tool write`, reported *"Yes, the tests pass"* while its pytest run modified a tracked
file in the real checkout. `shell(pytest)` sounds narrow; pytest imports `conftest.py` during
collection, so it is a grant to arbitrary repo-controlled code. Under the identical payload
**Codex failed closed with a kernel `PermissionError`**, because its boundary is an OS
sandbox rather than a check on the command string.

So: route work to `codex-agent` when you need containment. Use the others the way you would
run a stranger's build script — in a copy you are willing to lose. Full detail and the
post-run checks that actually catch this: [docs/safety-model.md](docs/safety-model.md).

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
| [**getting-started.md**](docs/getting-started.md) | **Start here** — zero to a working panel, step by step |
| [**troubleshooting.md**](docs/troubleshooting.md) | Indexed by what you actually see when it breaks |
| [adapter-contract.md](docs/adapter-contract.md) | What every adapter must guarantee |
| [safety-model.md](docs/safety-model.md) | The three tiers and what enforces them |
| [why-delegation-not-proxying.md](docs/why-delegation-not-proxying.md) | The architecture argument |
| [field-notes.md](docs/field-notes.md) | Every failure found by breaking something |
| [evidence.md](docs/evidence.md) | How to re-check every claim here — and which ones you can't |
| [probe-checklist.md](skills/build-adapter/reference/probe-checklist.md) | The six probes in detail |
| [providers.md](docs/providers.md) | Every known provider: binary, install, auth, verified-or-not |
| [porting/](docs/porting/) | MLX, Ollama, OpenAI-compatible endpoints |

## Contributing

A **verified** adapter for a provider nobody has covered — especially a local one — is the
most useful contribution this repo can receive. `/quorum:add-provider` does most of the
work; [CONTRIBUTING.md](CONTRIBUTING.md) covers what a submission needs.

Corrections to the field notes are equally welcome, and holding a higher bar than new
features: an entry that has gone stale is worse than a missing one, because it is trusted.

## License

MIT. See [LICENSE](LICENSE).
