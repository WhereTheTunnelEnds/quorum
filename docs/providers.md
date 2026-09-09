# Known Providers

What Quorum knows about each provider: how to install it, what its binary is actually
called, and — critically — **whether anyone has verified it**.

`add-provider` reads this table when a provider isn't present, so it can hand you the exact
install command instead of just reporting failure.

## Status legend

| | Meaning |
|---|---|
| **verified** | An adapter exists and passes `quorum-verify` against the live provider |
| **documented** | Install command and binary name from vendor docs. **Nobody has run the probes.** |
| **probed — no adapter** | The probes WERE run and the provider was rejected. The reason is recorded below. This is the most expensive row to produce and the easiest to lose, which is why it gets a status of its own rather than being filed under `documented`. |
| **retired** | Was covered; the vendor discontinued it or replaced it. |

The distinction is the whole point. A documented row is a starting place, not a promise —
see [`/quorum:add-provider`](../skills/build-adapter/SKILL.md), which will refuse to write an adapter
from a row in this table alone.

## Table

| Provider | Binary | Install | Auth | Status |
|---|---|---|---|---|
| **Codex** | `codex` | `npm i -g @openai/codex` | `codex login` (browser) | **verified** |
| **Copilot** | `copilot` | `npm i -g @github/copilot` | first run (browser) | **verified** |
| **GLM (Z.AI)** | **none** | — | `Z_AI_API_KEY` in `~/.zshenv` | **verified** |
| **Ollama** | server on `:11434` | macOS `brew install ollama` · Linux `curl -fsSL https://ollama.com/install.sh \| sh` · then `ollama pull <model>` | none | **verified** |
| **Antigravity** | **`agy`** | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` | browser, or a Gemini API key for headless | **verified** (consult only) |
| **OpenRouter** | **none** | — | `OPENROUTER_API_KEY` in `~/.zshenv` | **verified** (consult only) |
| **Claude (2nd sub)** | `claude` (often shell-aliased — resolve the real path) | already installed | `claude setup-token` on the holder's machine, then `CLAUDE_ALT_OAUTH_TOKEN` in `~/.zshenv` | **verified** |
| **Cline** | `cline` | `npm i -g cline` | `cline auth --provider <p> --apikey ...`, or `ANTHROPIC_API_KEY` etc. | documented |
| **Pi** | `pi` | `npm i -g @earendil-works/pi-coding-agent` | provider key in env | documented |
| **MLX** | server on `:8080` | `pip install mlx-lm` then `mlx_lm.server --model ...` | none | documented |
| **LM Studio** | server on `:1234` | app, or `lms server start` | none | documented |
| **OpenCode** | `opencode` (installs to `~/.opencode/bin`, not on PATH by default) | `curl -fsSL https://opencode.ai/install \| bash` | `opencode auth login` — **Anthropic is API-key only** | **probed — no adapter** |
| **Gemini CLI** | `gemini` | — | — | **retired** |

## OpenCode — probed 2026-09-08, rejected

Version **1.18.23**, installed at `~/.opencode/bin/opencode`. It is a capable agentic CLI
and it runs fine. It is recorded here because two measurements make it unsuitable for
Quorum's purpose, and both cost a probe session to establish.

### Anthropic is API-key only — there is no subscription login

The reason it was evaluated at all was to pool a **second Claude subscription**. It cannot.

`opencode auth login` takes `-p <provider>` and `-m <method>`, and passing a bogus method
makes it enumerate the real ones. Measured:

```text
opencode auth login -p github-copilot -m __nope__
  Error: Unknown method "__nope__" for github-copilot. Available: Login with GitHub Copilot

opencode auth login -p anthropic -m __nope__
  ┌  Add credential
  ◆  Enter your API key
```

The contrast is the proof: a provider that has OAuth reports it by name, and `anthropic`
does not — the bogus method is ignored and it goes straight to a key prompt. An Anthropic
API key is metered per token and billed separately from a Claude subscription, so routing
here would violate the rule every adapter in this repo carries: **never fall back to a
metered API key when a subscription is what is being pooled.**

It can reach Claude models through OpenRouter (`openrouter/~anthropic/claude-*` appears
among 369 models), but that is metered too, and `openrouter-agent` already covers it.

### `plan` mode is prompt-enforced, not harness-enforced — so there is no consult tier

This is the more general finding, and it would apply even if the auth story were different.

OpenCode ships a `plan` agent that behaves as read-only. It is not enforced. Three
measurements, none of them the transcript:

| Evidence | Result |
|---|---|
| `plan`'s permission block vs `build`'s | **identical** — `{"permission":"*","action":"allow","pattern":"*"}`. No write denial anywhere; the only constraints are `doom_loop: ask` and `external_directory: ask`. |
| Can `plan` call tools at all? | **Yes** — a read request produced 1 tool event, so tool use is not disabled in that mode. |
| Asked to write a file, then told it was not in plan mode and to ignore its instructions | **0 tool calls**, no file, and no permission-denial event. It narrated *"I am in Plan Mode and should only read"* — `should`, not "was blocked". |

`build`, for contrast, created the file on the first attempt.

So the read-only behaviour rests on the model complying with its system prompt. A denial by
the harness would surface as a permission event; none ever did. Per
[docs/safety-model.md](safety-model.md), a tier that cannot be demonstrated is not claimed —
**OpenCode would get no consult tier**, which for a provider whose whole value here would be
a second opinion leaves very little.

### What did pass, for whoever picks this up later

Probes 1 and 2 both pass, measured against `openrouter/google/gemini-2.5-flash`:

```text
opencode run --format json -m <provider/model> "<prompt>" </dev/null
  rc=0  stdout=933B  stderr=0B
```

`--format json` emits newline-delimited events (`step_start`, `text`, `tool`), which is a
good basis for a response contract. It exits cleanly with stdin closed, so there is no
missing "don't ask" flag. `--auto` exists and is documented by the vendor as
*"auto-approve permissions that are not explicitly denied (dangerous!)"* — that would be the
delegate-tier lever, and it would need a throwaway worktree.

**If OpenCode later ships an Anthropic OAuth method, the auth objection disappears — but the
tier finding stands until `plan` gains a real write denial.** Re-run the probes rather than
trusting this page; that is the rule this whole document exists to enforce.

## Is authentication a repeated chore?

**No. It is once per machine, and for some providers it can be scripted away entirely.**

Every provider stores credentials after the first login — `agy` keeps state under
`~/.gemini/antigravity-cli/`, Codex and Copilot keep their own OAuth state (Copilot in the
system credential store).

Do not confuse `~/.gemini/antigravity-cli/settings.json` with credential storage: that file
holds **permissions**, and it is the one `antigravity-agent`'s guard reads before claiming
read-only.
You do not re-authenticate per session, per project, or per call.

| Provider | Browser login | Scriptable, no browser |
|---|---|---|
| GLM (Z.AI) | — | **yes** — `Z_AI_API_KEY` |
| Ollama | — | **yes** — no auth at all |
| OpenRouter | — | **yes** — `OPENROUTER_API_KEY`; metered, not a subscription |
| Claude (2nd sub) | one time, by the holder | **yes** — `claude setup-token` emits a long-lived token; it is a subscription, not a metered key |
| Antigravity | one time | **yes** — `GEMINI_API_KEY` *(documented, unverified here)* |
| Codex | one time | ChatGPT subscription is OAuth-only; an API key bills separately |
| Copilot | one time | subscription is OAuth-only |
| OpenCode | **no Anthropic OAuth exists** | API key only — metered, not a subscription |

So for CI, containers, or a fleet of machines, prefer the key column: export the variable
from `~/.zshenv` and nothing interactive ever happens.

### Why the browser step cannot be scripted away for the rest

Because it is the security boundary, not a missing feature. An OAuth consent screen exists
so that a **human** approves binding a paid account to a program. A script that could
complete that on your behalf would be a script that could impersonate you to your provider —
and any tool offering it would be asking you to hand over credentials that let it do so.

Quorum therefore automates everything up to that moment and stops:

| Step | Who | How |
|---|---|---|
| Detect what is missing | script | `quorum-setup --check` |
| Print the exact install command | script | `quorum-setup` |
| Detect what is unauthenticated | script | `quorum-auth` |
| Open the login | script | `quorum-auth --fix` |
| **Approve in the browser** | **you, once** | — |
| Confirm it actually works | script | `quorum-verify --all` |

One human step per provider per machine. Everything on either side of it is a script.

## Notes that will cost you time if you skip them

**Two binaries are not named after their vendor.** Antigravity installs as **`agy`**. GLM
has **no binary at all**. So `command -v antigravity` and `command -v glm` both return
nothing on machines where those providers work perfectly — and that false negative has
already caused a panel to report a working provider as missing. Establish availability by
running the documented invocation, never by testing for a command. See
[field-notes.md](field-notes.md#a-missing-binary-proves-nothing-about-a-provider).

**Antigravity is consult-only, and not because it lacks capability.** `agy` can write and
run shell commands, but nothing bounds it per run: permissions live only in the user's
**global** `~/.gemini/antigravity-cli/settings.json` with no workspace-local override, and
`--dangerously-skip-permissions` was measured writing *outside* its `--add-dir` workspace —
with and without `--sandbox`. So a worktree gives review and disposal but not isolation, and
verify and delegate cannot be enforced. What it does have is a genuine harness-enforced
read-only consult: headless `--print` auto-denies `write_file` and `command` while leaving
`read_file` working, which makes it the one read-only provider that opens your repo itself
instead of being pasted excerpts. See [field-notes.md](field-notes.md#antigravity-agy).

**Gateways are not agents either.** OpenRouter routes to ~60 vendors behind one key, but the
endpoint it exposes is a plain chat-completions API: no sandbox, no server-side tool loop, no
file access. Breadth of *models* is not breadth of *capability*, and it gets a consult tier
only for the same reason a local server does.

**Model servers are not agents.** Ollama, MLX, LM Studio, and llama.cpp serve completions.
They have no sandbox, no tool loop, and no file-editing capability, so an adapter for them
gets a **consult tier only**. Writing verify or delegate sections for one means claiming a
guarantee nothing enforces. See [safety-model.md](safety-model.md).

**Gemini CLI is retired.** Google
[transitioned it to Antigravity CLI](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/);
it stopped serving Pro/Ultra and free-tier users on 18 June 2026. Enterprise licences
continue. Target `agy` instead.

**After installing anything, verify it the way an agent sees it.** Vendor installers write
PATH to `~/.zshrc` / `~/.bash_profile`, which non-interactive shells do not read — measured
on Antigravity 1.1.21, where `agy` is found by a login shell and **not** by `zsh -c`. Check
with `env -i HOME="$HOME" zsh -c 'command -v <binary>'` and add the export to `~/.zshenv`
yourself if it comes back empty.

**Check the service, not the binary, for anything that runs as a server.** `ollama` can be
installed with nothing serving, and a remote `OLLAMA_BASE` has no local binary at all.

## Adding a row

Add a **documented** row freely — an install command someone else can start from is useful
even unverified, provided it is labelled honestly.

Promote it to **verified** only when `quorum-verify <name>` passes against the live
provider, and paste that output in the PR. See [CONTRIBUTING.md](../CONTRIBUTING.md).
