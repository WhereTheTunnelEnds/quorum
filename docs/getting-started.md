# Getting Started

Zero to a working multi-model panel. About 15 minutes if you already have the
subscriptions; less if you only want one provider.

**Every step ends with a command that proves it worked.** If a check doesn't print what
this guide says it should, stop there — the next step will not fix it, and
[troubleshooting.md](troubleshooting.md) is indexed by exactly these symptoms.

---

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
sudo apt install -y jq git curl coreutils
# node: use nodejs.org or nvm
```

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

That symlinks five commands into `~/.local/bin`, so `git pull` updates them. If the script
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

You should get a list of providers, all showing as unavailable. That's correct — nothing is
configured yet. If you get `command not found`, the `PATH` line didn't take.

**Prefer not to use the plugin?** Copy the pieces in directly:

```bash
cp agents/*.md ~/.claude/agents/
cp -r skills/* ~/.claude/skills/
```

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
cd ~/quorum && ./scripts/quorum-verify codex
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
cd ~/quorum && ./scripts/quorum-verify copilot
```

Want: `4 passed, 0 failed`.

Copilot's GitHub integration stays **read-only** in Quorum — it reads PRs, issues, CI runs,
and history, and never opens PRs or pushes under your name. See
[safety-model.md](safety-model.md).

---

## 5. GLM (Z.AI Coding Plan)

Get a key from [z.ai](https://z.ai), then — **`~/.zshenv`, not `~/.zshrc`**:

```bash
echo 'export Z_AI_API_KEY="your-key-here"' >> ~/.zshenv
```

Open a new terminal.

**Check:**

```bash
[ -n "$Z_AI_API_KEY" ] && echo "key is set" || echo "key is NOT set"
cd ~/quorum && ./scripts/quorum-verify glm
```

Want: `4 passed, 0 failed`.

> There is **no `glm` command** and there never will be. GLM is reached by `curl`, by
> `npx zai-cli` for images, and by `quorum-claude-on` for agentic work. Running
> `command -v glm` returns nothing and proves nothing — it has already caused someone to
> report a perfectly working provider as missing.

**Optional — run Claude Code itself on GLM.** Useful for bulk work you don't want to spend
Claude quota on:

```bash
quorum-claude-on --init zai
```

Then edit `~/.config/quorum/endpoints/zai.env`:

```bash
ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
ANTHROPIC_AUTH_TOKEN="${Z_AI_API_KEY:?set Z_AI_API_KEY in ~/.zshenv}"
ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.3"
ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.3"
ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-5-turbo"
CLAUDE_CODE_AUTO_COMPACT_WINDOW="1048576"
```

**Check:**

```bash
quorum-claude-on zai -p "reply with OK" --allowedTools "Read"
```

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
cd ~/quorum && ./scripts/quorum-verify --all   # does each one actually work
```

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

**Don't use a panel for routine work.** Four models on a one-line fix is waste, and it
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
git -C ../.worktrees/<branch> diff
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
