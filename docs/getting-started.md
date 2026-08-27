# Getting Started

Zero to a working multi-model panel. About 15 minutes if you already have the
subscriptions; less if you only want one provider.

**Every step ends with a command that proves it worked.** If a check doesn't print what
this guide says it should, stop there — the next step will not fix it, and
[troubleshooting.md](troubleshooting.md) is indexed by exactly these symptoms.

---

## The short version

```bash
git clone https://github.com/kourosh-forti-hands/quorum.git
cd quorum && ./scripts/install.sh && quorum-setup
```

`quorum-setup` runs everything below interactively and stops at each step that needs you.
Use `quorum-setup --check` any time for a non-interactive readiness report. The rest of this
page is the long form — read it if the wizard stalls, or if you'd rather do it by hand.

> **On Linux?** This guide says `~/.zshenv` throughout, because it was written on macOS
> where zsh is the default. On bash, use **`~/.profile`** — non-interactive bash reads
> neither `.bashrc` nor `.profile` per-invocation, but `.profile` is exported at login so
> agents inherit it. The scripts detect your shell and tell you the right file; only the
> prose here is zsh-flavoured. Full explanation:
> [troubleshooting.md](troubleshooting.md).

## 0. Decide what you're actually setting up

**Every provider is optional.** Quorum works with one; it gets more useful with three.
There is no configuration step that requires a provider you don't have.

| You have… | You get |
|---|---|
| A ChatGPT plan | Codex — deep focused debugging, repo-wide code review |
| A GitHub Copilot plan | Copilot — PR/issue/CI context nothing else can see |
| A Z.AI Coding Plan | GLM — 1M-token context, cheapest bulk work |
| None of the above | Add a local model (Ollama, MLX) — see [step 6](#6-optional-a-local-model) |

Skip any section below that doesn't apply. `quorum-status` will show the others as
unavailable, and that is a normal, working state — not an error.

---

## 1. Prerequisites

```bash
bash --version     # the one hard requirement — every Quorum script is #!/usr/bin/env bash
node --version     # v18+  (for the Codex and Copilot CLIs)
git --version
jq --version
curl --version
```

Missing anything:

```bash
# macOS
brew install jq git node coreutils

# Debian / Ubuntu
<your package manager> install jq git curl coreutils   # quorum-setup prints the exact
                                                       # command for THIS machine, with or
                                                       # without sudo as appropriate
# node: use nodejs.org or nvm
```

You do **not** need ImageMagick on macOS — `sips` is built in and is always preferred.
ImageMagick is only the Linux/BSD fallback for `prep-image`, which itself is needed only for
sending images to a panel. Skip it unless both apply.

**`coreutils` matters more than it looks on macOS.** It provides `timeout(1)`, which is how
Quorum detects a provider that hangs instead of answering. Without it, hang detection is
silently skipped — you'll see a warning, and a hung provider will look like a slow one.

**Check:**

```bash
command -v timeout gtimeout
```

Should print at least one path.

---

## 2. Install Quorum

**As a Claude Code plugin** — the parts Claude uses (agents, skills, commands):

```
/plugin marketplace add kourosh-forti-hands/quorum
/plugin install quorum@quorum
```

**Plus the helper scripts** — the parts your *shell* uses. Both halves are needed:

```bash
git clone https://github.com/kourosh-forti-hands/quorum.git
cd quorum
./scripts/install.sh
```

Clone it wherever you keep code — nothing below assumes a particular location, because
`install.sh` puts the commands on your `PATH` and every later step calls them by bare name.

That symlinks eight commands into `~/.local/bin`, so `git pull` updates them. If the script
says that directory isn't on your `PATH`, add it **in `~/.zshenv`, not `~/.zshrc`**:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshenv
```

> Why `~/.zshenv`: agents run in *non-interactive* shells, which never read `~/.zshrc`.
> Put it in the wrong file and everything works when you type it and nothing works when
> Claude runs it. This is the single most common setup failure.

**Check** (open a new terminal first):

```bash
quorum-status
```

You should get a provider table. Anything you haven't configured shows `--`, which is
correct at this point — nothing is set up yet. If you get `command not found`, the `PATH`
line didn't take.

Two rows will look "already done" and that is expected: **claude** reports logged in if you
are using Claude Code at all, and **ollama** reports OK if you happen to have its server
running. You may also see a `quorum-claude-on presets` section, which is covered in step 5.

At any point from here on, `quorum-auth` will tell you what's still unauthenticated and the
exact command that fixes each one. The rest of this guide is the long-form version of that.

**Prefer not to use the plugin?** Copy the pieces in directly:

```bash
mkdir -p ~/.claude/agents ~/.claude/skills ~/.claude/commands/quorum
cp    agents/*.md   ~/.claude/agents/
cp -r skills/*      ~/.claude/skills/
cp    commands/*.md ~/.claude/commands/quorum/      # note the quorum/ subdirectory
./scripts/install.sh
```

**`commands/quorum/`, not `commands/`.** User commands are namespaced by *subdirectory*.
Copy to `~/.claude/commands/` and you get `/status` and `/panel`; this guide tells you to
type `/quorum:status` and `/quorum:panel`, which only exist if the files sit in a `quorum/`
subdirectory. The plugin route gets that prefix from the plugin name instead.

The `mkdir -p` is not optional — on a machine where those directories do not yet exist,
`cp` fails with *"Not a directory"* and installs nothing. And `commands/` must be copied
too, or none of the `/quorum:*` commands this guide later tells you to run will exist.

---

## 3. Codex (ChatGPT subscription)

```bash
npm install -g @openai/codex
codex login          # opens a browser
```

**Check:**

```bash
codex login status
```

**Then prove it end-to-end** — this is the check that matters, because "logged in" and
"answers questions" are different claims:

```bash
quorum-verify codex
```

Want: `4 passed, 0 failed`.

> Don't use an API key here. `codex login` spends the ChatGPT subscription you already pay
> for; an API key bills separately, per token, and you find out on a statement.

---

## 4. Copilot (GitHub Copilot subscription)

```bash
npm install -g @github/copilot
copilot              # first run walks you through auth, then /exit
```

**Check:**

```bash
copilot --version
quorum-verify copilot
```

Want: `4 passed, 0 failed`.

Copilot's GitHub integration stays **read-only** in Quorum — it reads PRs, issues, CI runs,
and history, and never opens PRs or pushes under your name. See
[safety-model.md](safety-model.md).

---

## 5. GLM (Z.AI Coding Plan)

Get a key from [z.ai](https://z.ai), then let Quorum store it:

```bash
quorum-auth glm --set-key
```

It reads the key from a **hidden prompt**, so it never reaches your shell history or a
transcript; it writes to the right file for your shell; and it `chmod 600`s that file.

If you would rather do it by hand, do all three parts:

```bash
echo 'export Z_AI_API_KEY="your-key-here"' >> ~/.zshenv   # ~/.profile on bash
chmod 600 ~/.zshenv
```

**The `chmod` is not optional.** `umask` governs file *creation*; appending to a file that
already exists leaves its old mode alone. Measured: a `~/.zshenv` that predates the key
stays `-rw-r--r--`, world-readable, with a live API key in it. And note the `echo` puts the
key in your shell history — which is why `--set-key` exists.

Open a new terminal.

**Check:**

```bash
[ -n "$Z_AI_API_KEY" ] && echo "key is set" || echo "key is NOT set"
quorum-verify glm
```

Want: `4 passed, 0 failed`.

> There is **no `glm` command** and there never will be. GLM is reached by `curl`, by
> `npx zai-cli` for images, and by `quorum-claude-on` for agentic work. Running
> `command -v glm` returns nothing and proves nothing — it has already caused someone to
> report a perfectly working provider as missing.

**Optional — run Claude Code itself on GLM.** Useful for bulk work you don't want to spend
Claude quota on, and required for GLM's verify and delegate tiers.

```bash
quorum-auth glm --init-endpoint      # writes a working preset; contains no key
```

That is all you need. (`quorum-claude-on --init zai` writes a *blank* template for a
provider Quorum does not already know; run it only for a new endpoint, and note it refuses
to overwrite an existing file.) The preset it writes:

```bash
ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
ANTHROPIC_AUTH_TOKEN="${Z_AI_API_KEY:?set Z_AI_API_KEY in ~/.zshenv}"
ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.3"
ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.3"
ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-5-turbo"
ANTHROPIC_MODEL="glm-5.3"
CLAUDE_CODE_AUTO_COMPACT_WINDOW="1048576"
```

`ANTHROPIC_MODEL` is worth pinning: without it, a parent session running a `[1m]` context
variant leaks that suffix into the model id (`glm-5.3[1m]`). Measured as harmless through
this path, but the bare id is deterministic — and that exact suffix *is* fatal on a direct
API call.

**Check:**

```bash
quorum-claude-on zai -p "reply with OK" --allowedTools "Read"
```

**Want:** `OK` as the last line. Two warnings above it are **normal and expected**, not
failures:

```
⚠ claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set
[claude-code:unrecognized_model] {"model":"glm-5.3","query_source":"sdk"}
```

The first is Claude Code noting that this run points at a third-party endpoint — which is
the entire point. The second is it saying `glm-5.3` isn't a model *it* knows, which is also
correct. Both appear on every successful run. See
[troubleshooting.md](troubleshooting.md).

---

## 6. Optional: a local model

For privacy-bound work, offline use, or zero marginal cost.

```bash
/quorum:add-provider ollama
```

Your Claude probes the provider **on your machine** and writes an adapter from what it
measured — it will not write one from documentation, and it will stop and say so if the
provider isn't actually running.

Background reading: [Ollama](porting/ollama.md) · [MLX](porting/mlx.md) ·
[any OpenAI-compatible endpoint](porting/openai-compatible.md).

One honest expectation to set: a small local model usually makes a *panel* worse, not
better. Panels pay off through models being wrong in *different* ways, and a weak model
tends to be wrong more often and less independently. Route local models to privacy and bulk
work, not to tie-breaking hard calls.

---

## 7. Verify everything together

```bash
quorum-status                          # what's reachable
quorum-auth                            # what still needs auth, and the fix for each
quorum-verify --all   # does each one actually work
```

Those three answer different questions, in order: is it *there*, is it *authenticated*, does
it *work*. A provider can pass the first two and fail the third.

`quorum-verify --all` exits **non-zero** if anything failed *or* if it verified nothing at
all — so it's safe to put in a script. A tool that reports "all clear" after checking
nothing is the exact failure this project exists to prevent.

---

## 8. Your first panel

In Claude Code, in a real repo:

```
/quorum:panel  Should we move session storage from Redis to Postgres?
Constraints: 50k sessions, sub-10ms reads, one ops engineer.
```

Takes **2–10 minutes** — the panelists run concurrently, but they're full agents, not
autocomplete. What comes back:

- **Consensus** — what everyone agreed on
- **Split** — where they disagreed, attributed by name. *This is the part you're paying for.*
- **Outlier insight** — anything one model raised that survived scrutiny
- **Recommendation** — Claude's own call, formed before it read the others

If a panelist failed, you'll be told which and why. A consensus of two is a much weaker
claim than a consensus of four, and you can't tell the difference unless someone says so.

**Don't use a panel for routine work.** A full panel on a one-line fix is waste, and it
trains you to stop reaching for it when a decision actually is expensive.

---

## 9. Your first delegation

```
/quorum:delegate  Port the remaining tests in tests/legacy/ to the new fixture API.
Pattern to follow: tests/unit/test_auth.py. Done when pytest tests/legacy passes.
```

The delegate works in a **throwaway git worktree** on its own branch — never your working
tree. You get back a path, a branch, and a diffstat.

```bash
git worktree list
git -C ../.worktrees/<repo>/<provider>/<slug>-<pid>-<epoch> diff
```

Two rules worth internalising:

- **Read the diff, not the summary.** "All tests pass" is a claim. Run them yourself.
- **A vague brief is expensive.** The delegate can't see your conversation. Everything it
  needs must be in the brief, or you'll spend quota *and* review time on a diff you throw
  away.

Nothing is merged, pushed, or deleted without you asking.

---

## What to read next

| | |
|---|---|
| Something's broken | [troubleshooting.md](troubleshooting.md) |
| When to use which model | [model-panel skill](../skills/model-panel/SKILL.md) |
| What each tier can touch | [safety-model.md](safety-model.md) |
| Why this isn't a proxy | [why-delegation-not-proxying.md](why-delegation-not-proxying.md) |
| Every failure found the hard way | [field-notes.md](field-notes.md) |

## Uninstalling

```bash
./scripts/install.sh --uninstall
```

It removes only the symlinks that point into this clone. A same-named file that belongs to
something else is reported and left alone, and so is a symlink pointing at a different
Quorum clone.

It deliberately does **not** touch three things, and names them so you can decide:

- the PATH line, and any `Z_AI_API_KEY` export, in whichever shell file was used
- `~/.config/quorum/` — endpoint presets
- anything you copied into `~/.claude/agents`, `~/.claude/skills` or `~/.claude/commands/quorum`

The clone itself stays where it is; delete it separately.

**A note on that last one:** the manual copy documented above uses `cp -r`, which
**overwrites same-named files without warning and takes no backup**. `model-panel` and
`delegate-task` are generic enough to collide with skills you already have. Check first:

```bash
ls ~/.claude/skills ~/.claude/agents 2>/dev/null
```

and use `cp -rn` if you want existing files left alone.
