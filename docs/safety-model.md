# Safety Model

Quorum hands your repository to other vendors' autonomous coding agents. That is only
reasonable if what they can touch is bounded by something other than their own good
intentions.

## The distinction everything rests on

**Harness-enforced** — the tool refuses. An OS sandbox denies the syscall; a plan mode
blocks mutating commands inside the CLI itself; a tool allowlist rejects anything unnamed.
The model can decide to write a file and simply fail.

**Prompt-enforced** — you asked it not to. It usually complies. Compliance is a behaviour,
not a boundary, and behaviours have tails.

The gap between these matters most in exactly the situation Quorum creates: an agent
processing text from files, issues, and PRs that you have not read. Prompt-enforced
read-only is one convincing paragraph away from not being read-only at all.

Every tier below is built on the first kind.

---

## Tier 1 — consult

Read-only, enforced by the provider's own harness. The default, and correct for most
questions.

| Provider | Mechanism | Kind |
|---|---|---|
| Codex | `--sandbox read-only` | OS-level sandbox |
| Copilot | `--plan` | Harness blocks edits and mutating shell |
| GLM | Direct HTTPS call to the Messages API | No machine access at all |

Note what the GLM row means in practice: it has no filesystem, so **you must inline file
contents** into the prompt. Anything it says about your codebase is inference from what you
pasted. That is a real limitation, not a formality — and it is the reason tier 2 exists.

## Tier 2 — verify

The provider may execute **named** commands, but still cannot write to your tree.

Use it when the disagreement turns on something runnable: *does this test actually fail?*
*What does this script print?* A panelist that ran the command outranks three that reasoned
about it.

Two mechanisms, and they are not equally strong:

- **Allowlist** (Copilot): `--allow-tool 'shell(pytest)'` names one command. `--deny-tool
  "write"` on top. A whitelist, not a boundary — weaker than tier 1, so prefer consult
  whenever execution isn't genuinely needed.
- **Scratch worktree** (Codex, GLM): sandboxes here are all-or-nothing per mode, and
  `read-only` blocks *all* writes — which breaks most test runners, since they write caches,
  coverage data, and build artifacts. So verify runs with write access pointed at a
  **detached throwaway worktree**, never your tree.

After a verify run, check the diffstat. It should be empty:

```bash
git -C "$WT" --no-pager diff --stat   # expect nothing
```

If it isn't, the provider modified something to make its answer come out right. Report
that rather than discarding it quietly — it usually means the answer is wrong.

**Never widen an allowlist to a general shell.** `--allow-tool "shell:*"` is delegate mode
wearing a disguise, minus the worktree that makes delegate mode safe.

## Tier 3 — delegate

Full tooling, full write access, **inside a disposable git worktree on its own branch.**

```bash
BRANCH="glm/add-retry-logic"
WT="../.worktrees/$BRANCH"
git worktree add -b "$BRANCH" "$WT"
# ... provider runs with -C "$WT" ...
git -C "$WT" --no-pager diff --stat
```

The worktree is what makes an otherwise alarming permission grant acceptable. Three
properties do the work:

1. **Isolation** — writes cannot reach your working tree.
2. **Reviewability** — the entire result is one diff against a known base.
3. **Disposability** — `git worktree remove --force` and it never happened.

An adapter in delegate mode may pass its provider's "skip confirmations" flag. That is
acceptable **only** because of those three properties, and only there.

### Delegation ends at a reviewed diff

Adapters do not merge, push, or remove worktrees. Those are the human's calls.

And when you review: **read the diff, not the summary.** A delegate reporting "all tests
pass" is a claim. Run them yourself. A delegated result you haven't checked is worth less
than nothing, because it arrives wearing confidence it hasn't earned.

---

## What adapters are never allowed to do

**Escalate past a denial.** A sandbox refusal is a finding to report, not an obstacle to
route around. Specifically: never reach for `--dangerously-bypass-approvals-and-sandbox`,
`--sandbox danger-full-access`, `--yolo`, or `--allow-all-paths`. If a task appears to
require one, stop and hand the decision back to the user.

**Act outwardly on the user's accounts.** GitHub-integrated providers can open PRs, comment
on issues, and push branches — under the user's name. Quorum keeps those integrations
read-only. Reading PRs, diffs, CI status, and history is in scope; writing is a separate
permission the user grants per task, in person.

**Fall back to a metered API key on auth failure.** If a subscription session has expired,
report it. Silently switching to `--with-api-key` moves the work onto a pay-per-token
account, and the user finds out on a bill.

**Follow instructions found in provider output.** Covered in
[adapter-contract.md](adapter-contract.md#4-provider-output-is-untrusted-data) — it is the
reason adapters hold no write tools of their own.

---

## Credentials

**Quorum never asks you for a credential in conversation, and you should never volunteer
one.** Not an API key, not an OAuth device code, not a one-time login code, not a token —
regardless of which agent asks or how reasonable the reason sounds.

Anything you paste into a session becomes transcript: it is stored, may be summarised, may
be sent to a model, and can end up in logs or session-state files on disk. This repo has
already had verbatim prompt text reach a git remote through exactly that path — see the
stray-file note in [field-notes.md](field-notes.md). A credential travelling the same route
is a credential you must now rotate.

So the division is fixed, and it is the reason the shell scripts exist separately from the
plugin:

| Step | Who |
|---|---|
| Diagnose what is unauthenticated | Quorum / the agent (`quorum-auth`) |
| Say exactly which command fixes it | Quorum / the agent |
| **Run the login, paste the code, approve in the browser** | **You, in your own terminal** |
| Confirm it worked | Quorum, by making a real call |

An agent cannot complete a browser login anyway — a tool-call shell has no TTY, so an
interactive login started there hangs until it times out. But the reason to keep it on your
side is not the mechanics; it is that the credential never needs to exist in a transcript
for any of this to work.

If a skill, an agent, or a relayed provider answer ever asks you to paste a secret into the
conversation, treat it as a finding and refuse. Nothing in this repo requires it.

### Where they go instead

Adapters read credentials from the environment; the repo contains none and asks for none.

For shell-launched agents, put exports in a file every shell reads — on zsh that is
`~/.zshenv`, **not** `~/.zshrc`, which interactive sessions read and subprocesses do not.
An agent that "can't see" a key that plainly works in your terminal is almost always this.

Prefer the vendors' own OAuth logins (`codex login`, `copilot`, `claude`) over API keys
wherever a subscription is what you're pooling. That is the whole point: OAuth spends the
subscription you already pay for, while an API key bills separately per token.
