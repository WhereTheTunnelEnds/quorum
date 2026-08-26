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

The distinction is the whole point. A documented row is a starting place, not a promise —
see [add-provider](../skills/add-provider/SKILL.md), which will refuse to write an adapter
from a row in this table alone.

## Table

| Provider | Binary | Install | Auth | Status |
|---|---|---|---|---|
| **Codex** | `codex` | `npm i -g @openai/codex` | `codex login` (browser) | **verified** |
| **Copilot** | `copilot` | `npm i -g @github/copilot` | first run (browser) | **verified** |
| **GLM (Z.AI)** | **none** | — | `Z_AI_API_KEY` in `~/.zshenv` | **verified** |
| **Ollama** | server on `:11434` | `brew install ollama` then `ollama pull <model>` | none | **verified** |
| **Antigravity** | **`agy`** | `curl -fsSL https://antigravity.google/cli/install.sh \| bash` | browser, or a Gemini API key for headless | documented |
| **Cline** | `cline` | `npm i -g cline` | `cline auth --provider <p> --apikey ...`, or `ANTHROPIC_API_KEY` etc. | documented |
| **Pi** | `pi` | `npm i -g @earendil-works/pi-coding-agent` | provider key in env | documented |
| **MLX** | server on `:8080` | `pip install mlx-lm` then `mlx_lm.server --model ...` | none | documented |
| **LM Studio** | server on `:1234` | app, or `lms server start` | none | documented |
| **Gemini CLI** | `gemini` | — | — | **retired** |

## Is authentication a repeated chore?

**No. It is once per machine, and for some providers it can be scripted away entirely.**

Every provider stores credentials after the first login — `agy` writes
`~/.gemini/antigravity-cli/settings.json`, Codex and Copilot keep their own OAuth state.
You do not re-authenticate per session, per project, or per call.

| Provider | Browser login | Scriptable, no browser |
|---|---|---|
| GLM (Z.AI) | — | **yes** — `Z_AI_API_KEY` |
| Ollama | — | **yes** — no auth at all |
| Antigravity | one time | **yes** — `GEMINI_API_KEY` *(documented, unverified here)* |
| Codex | one time | ChatGPT subscription is OAuth-only; an API key bills separately |
| Copilot | one time | subscription is OAuth-only |

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
