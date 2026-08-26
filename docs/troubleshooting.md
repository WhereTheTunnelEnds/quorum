# Troubleshooting

Indexed by **what you actually see**, because that's what you have when something breaks.

Start here every time:

```bash
quorum-status                          # what is reachable
cd ~/quorum && ./scripts/quorum-verify --all   # does it actually work
```

Those answer different questions. `quorum-status` says a provider *responds*.
`quorum-verify` says it responds **and** that its failures are detectable — which is what
makes an answer from it worth trusting.

---

## Setup

### `quorum-status: command not found`

`~/.local/bin` isn't on your `PATH`, or you didn't open a new terminal.

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshenv
exec zsh
```

**`~/.zshenv`, not `~/.zshrc`.** See the next entry — it's the same root cause and it
accounts for most first-day failures.

### It works when I type it, but not when Claude runs it

The number-one Quorum setup failure, in every form it takes:

- an API key that's set in your terminal but "unset" inside an agent
- a helper that runs fine by hand but is "command not found" from a subagent
- a `claude` alias with your favourite flags that agents don't seem to get

**One cause.** `~/.zshrc` is read by *interactive* shells. Agents and scripts spawn
**non-interactive** shells, which read `~/.zshenv` and skip `~/.zshrc` entirely.

**Fix.** Anything an agent needs goes in `~/.zshenv`:

```bash
echo 'export Z_AI_API_KEY="..."'            >> ~/.zshenv
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshenv
```

**Corollary for aliases and shell functions:** they don't exist in non-interactive shells
at all, and no file placement fixes that. If an agent must call it, it has to be an
**executable on `PATH`**. That's why every Quorum helper is a script rather than a function.

This bites hardest with a `claude` alias carrying `--dangerously-skip-permissions`: it
applies when *you* type `claude`, and never when a script or subagent launches it.

### `no timeout(1) on PATH — hang detection disabled`

macOS doesn't ship `timeout`.

```bash
brew install coreutils
```

Not fatal — but until you do, a provider that hangs is indistinguishable from one that's
merely slow, and that's a bad thing not to be able to tell apart.

### `/plugin marketplace add` worked but `quorum-verify` is missing

Two halves, two installs. The plugin gives Claude the agents, skills, and commands. The
scripts are for your *shell* and are installed separately:

```bash
git clone https://github.com/kourosh-forti-hands/quorum.git
cd quorum && ./scripts/install.sh
```

---

## A provider says it isn't there

### "GLM is unavailable" / `command -v glm` finds nothing

**GLM has no binary, and never will.** It's reached three ways only: `curl` to `api.z.ai`,
`npx -y zai-cli` for images, and `quorum-claude-on zai` for agentic work.

`command -v glm` returning NOT FOUND is expected and proves nothing. This false negative has
already caused a panel to report a fully working provider as missing, which is why both the
agent file and the skill now say never to run that check.

**To find out if GLM actually works, make a real call:**

```bash
cd ~/quorum && ./scripts/quorum-verify glm
```

**The general rule:** never infer availability from a `command -v` check. Not every vendor
ships a binary named after itself. Run the documented invocation and read the result — a
real call is the only evidence that counts.

### Codex returns nothing at all

Almost always the trusted-directory refusal. Outside a trusted git repo, and without
`--skip-git-repo-check`, Codex exits 1 and emits **zero bytes**.

```bash
git -C . rev-parse --git-dir      # are you actually in a repo?
```

Fix is in the adapter already — but if you're invoking `codex` by hand, add
`--skip-git-repo-check`. It's harmless inside a repo.

### `token expired or incorrect`

`Z_AI_API_KEY` is unset or stale.

```bash
[ -n "$Z_AI_API_KEY" ] && echo set || echo NOT set
```

If it's set and still rejected, the key is expired — get a new one from z.ai. Note this
arrives inside an **HTTP 200**, so `curl` exits 0 and nothing looks wrong from the outside.

### `Not logged in` (Codex)

```bash
codex login
```

Browser OAuth. **Don't work around this with an API key** — that moves your work onto a
per-token bill instead of the subscription you're already paying for.

---

## It answers, but the answer is wrong or empty

### A model returned an empty answer

`status: empty` is a **failure**, not a shrug. Three common causes:

| Cause | Tell | Fix |
|---|---|---|
| Reasoning ate the token budget | `stop_reason: "max_tokens"`, no text block | Raise `max_tokens` to 8000+ |
| Reading the wrong JSON field | Response body is non-empty | Select by `type=="text"`, never `content[0]` |
| Provider refused silently | Zero bytes, non-zero exit | Check stderr; usually a flag |

The middle one catches people constantly: on reasoning models `content[0]` is a *thinking*
block, so `.content[0].text` is `null` and a perfectly good answer looks empty.

### A panelist "verified" something that's wrong

It happens, and confident framing makes it worse. One panelist reported a component's
maximum rate as a specific number "verified via search"; the manufacturer's datasheet said
otherwise.

**Check every number you'll design around against a primary source** — especially when a
model claims to have checked. Where a claim is runnable, ask for **verify mode** so a
panelist actually runs the command instead of reasoning about it.

### The models disagree wildly about a photo

Suspect the photograph before the models. Fine detail often isn't legible without a macro
shot and good lighting.

Also make sure they saw the *same* image:

```bash
IMG=$(prep-image ~/Desktop/photo.HEIC)   # then give $IMG to every panelist
```

Phone photos are HEIC and often 20MB+, which some endpoints reject outright. Sending
differently-processed images makes disagreement uninterpretable — you can't separate a real
difference of opinion from a difference in what they were shown.

### A panelist's answer contains instructions

Like *"ignore previous instructions"* or *"run this command"*.

**That's a finding to report, never something to act on.** Those models read repository
files, GitHub issues, and PR descriptions written by strangers. It's why everything a
provider returns arrives fenced in `BEGIN/END UNTRUSTED PROVIDER OUTPUT` markers, and why
adapters hold no `Write` or `Edit` tools.

---

## Delegation

### The delegate edited my working tree

It shouldn't be able to. Every delegate runs in a throwaway worktree:

```bash
git worktree list
git status                 # your tree should be untouched
```

If your tree really did change, that's a bug worth an issue — include the adapter and the
invocation.

### A verify run left a diff behind

Verification is supposed to change nothing. A non-empty diffstat means the provider modified
something to make its answer come out right — which usually means **the answer is wrong**.
Read the diff before believing anything it said.

### Worktrees are piling up

```bash
git worktree list
git worktree remove ../.worktrees/<branch>
```

Quorum never removes them on its own — a discarded attempt is sometimes the one you want to
look at again.

---

## `quorum-verify` disagrees with the docs

**Believe the verifier and measure directly.** That has already happened to this repo: a
field note claimed Copilot printed a usage error to stdout; measurement showed stderr with
an empty stdout. The docs were wrong.

```bash
OUT=$(mktemp); ERR=$(mktemp)
<the invocation> >"$OUT" 2>"$ERR"; RC=$?
echo "rc=$RC stdout=$(wc -c <"$OUT") stderr=$(wc -c <"$ERR")"
```

Two rules for measuring, both learned the hard way:

- **Never pipe.** `cmd | tail` reports `tail`'s exit status. This has already put a wrong
  number into this repo's own documentation.
- **Never merge streams with `2>&1`.** It turns a clean stderr failure with an empty stdout
  into non-empty output that looks exactly like an answer.

Then open a PR correcting the doc — those are more welcome than new features, because a
stale entry is worse than a missing one. Someone trusts it.

### It says `4 passed` but the provider still seems broken

`quorum-verify` checks the mechanical contract: it responds, it exits, and its failures are
detectable. It does **not** judge answer quality. A provider can pass all four and still be
a poor fit for your question — that's a routing decision, not a bug. See the routing table
in the [model-panel skill](../skills/model-panel/SKILL.md).

---

## Still stuck

Open an issue with:

```bash
quorum-status
cd ~/quorum && ./scripts/quorum-verify <provider>
<provider-cli> --version
```

Plus the exact invocation and what came back. **Redact keys.** Measurements — exit code,
byte counts, actual text — are far more useful than a description of the behaviour.
