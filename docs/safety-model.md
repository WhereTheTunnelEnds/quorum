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
| Antigravity | headless `-p` auto-denying any permission it cannot prompt for | Harness refusal — **not** `--sandbox`, which does nothing here |
| GLM | Direct HTTPS call to the Messages API | No machine access at all |
| Ollama | Direct HTTP call to a local model server | No machine access at all; **no harness of any kind** |
| OpenRouter | Direct HTTPS call to a chat-completions gateway | No machine access at all; no server-side tool loop |

Two of those are worth dwelling on, because their enforcement story is the least obvious:

**Antigravity** is the only one whose read-only comes from a *refusal* rather than a flag.
Measured: `--sandbox` produces byte-identical output with and without it, while headless
`-p` refuses `write_file` outright. The model tries and is denied. That guarantee can be
overridden by a global allow-rule, so its adapter checks for one and refuses to run rather
than quietly claiming a boundary it no longer has.

**Ollama** has no sandbox, no tool loop, and no file-editing capability at all — so it is
read-only by *absence*, and gets a consult tier only. That is why its adapter has no verify
or delegate section: there would be nothing to enforce them with.

**OpenRouter** is the same shape, and worth stating separately because its breadth invites
the opposite assumption: it can reach agentic *models*, but it is not an agentic *harness*.
It will emit tool-call requests if a request supplies a `tools` array, and executing one is
entirely the client's choice — so its adapter never sends that array, and read-only by
absence holds. Measured: asked to write a file into a scratch directory, it replied that it
could not, `tool_calls` was absent, and the directory stayed empty.

Note what the GLM row means in practice: it has no filesystem, so **you must inline file
contents** into the prompt. Anything it says about your codebase is inference from what you
pasted. That is a real limitation, not a formality — and it is the reason tier 2 exists.

## Tier 2 — verify

The provider may execute **named** commands. Whether it can also write to your tree depends
entirely on the provider, and for two of the three the honest answer is **yes, it can.**

Use it when the disagreement turns on something runnable: *does this test actually fail?*
*What does this script print?* A panelist that ran the command outranks three that reasoned
about it.

### Naming a command is not bounding what it does

This is the load-bearing fact of tier 2, and an earlier version of this document had it
wrong. `--allow-tool 'shell(pytest)'` grants **whatever pytest does**, and pytest runs
repo-controlled Python before it runs a single test: `conftest.py` is imported during
collection. The same is true of `make`, `npm test`, and `tox`. The grant narrows what the
model may *launch*. It does not bound what the launched process may *touch*.

And a worktree does not close that gap, because a worktree can trivially find its way home.
Measured, in a plain shell with no model involved:

```bash
cd "$WT"
dirname "$(git rev-parse --path-format=absolute --git-common-dir)"   # -> the user's checkout
```

**Verified end to end.** A `conftest.py` resolving the path that way modified a *tracked*
file in the real tree (`config.ini`, sha `bc8c1e0b` → `85e2b91e`), created
`.test-metrics.json` there, and wrote `OUTSIDE_REPO.txt` above the repo — while Copilot,
run with `--allow-tool 'shell(pytest)' --deny-tool write` and pointed at the worktree,
reported *"Yes, the tests pass"* and mentioned no write at all. The documented diffstat
check came back empty.

### Which boundaries are real

| Provider | Boundary | Real? |
|---|---|---|
| **Codex** | OS sandbox (`--sandbox`), enforced below the process | **Yes** |
| **Copilot** | permission check on the shell command *string* | **No** |
| **GLM / any Claude-Code-based tier** | tool allowlist in the harness | **No** |

Codex is not on that list by reputation. Given the identical payload and worktree layout it
failed closed, from the kernel:

```
INTERNALERROR> PermissionError: [Errno 1] Operation not permitted:
'/.../usertree/.test-metrics.json'
```

Copilot's check is string-level, which is a different thing entirely. Measured in one
session: `bash -c 'echo x > /abs/path/outside'` was **refused** — after which Copilot
reported *"file access is confined to the current working directory… no escape occurred"* —
while `pytest` writing that same path was **allowed, silently**. One level of process
indirection defeats it. There is a second, weaker layer above that: a crude payload with a
visible `warm-cache` target in a Makefile *was* refused, because the model read it and
judged it malicious. That is model judgement, not enforcement, and it also operates on
strings.

**So: for Copilot and GLM, tier 2 is a convention, not a containment boundary.** Treat a
verify run from either as *code you have not read has run on your machine with your
permissions*. If that is not acceptable for the task, use Codex, or use consult.

### Checking afterwards, and what checking cannot tell you

The old advice here was one command, and it misses most of what matters:

```bash
git -C "$WT" --no-pager diff --stat    # NOT sufficient on its own
```

It reports nothing for an untracked file — so a delegate that *adds* a module shows an empty
diffstat as its review artifact — nothing for writes outside the worktree, and nothing for
anything under `.git`. Use all four:

```bash
git -C "$WT"   status --porcelain      # untracked files too, not just modifications
git -C "$MAIN" status --porcelain      # did it reach the real tree?
git -C "$MAIN" config --list --local   # `git config --local` from a worktree writes HERE
ls -la "$(git -C "$WT" rev-parse --path-format=absolute --git-path hooks)"
```

That last one is not paranoia. A worktree's `hooks` path **is the main repository's hooks
directory** — they share one `.git`. Measured: a `post-commit` hook planted from inside the
worktree was invisible to all three `status`/`diff` commands above, and then ran when the
user made an ordinary commit in their own tree. `git config --local core.pager` set from the
worktree reads back immediately from the main repo the same way. Neither is tracked content,
so no diff will ever show them.

And state the limit plainly: **no git command detects a write to `$HOME`, `/tmp`, or
`~/.gitconfig`.** If you need that guarantee, you need an OS sandbox, which means Codex.

**Never widen an allowlist to a general shell.** `--allow-tool "shell:*"` is delegate mode
wearing a disguise — and note that an unqualified `Bash` in a Claude-Code allowlist is the
same thing by another name, since `Bash` is a superset of `Write` and `Edit`.

## Tier 3 — delegate

Full tooling, full write access, **inside a disposable git worktree on its own branch.**

```bash
UNIQ=$(basename "$(mktemp -u)" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')
BRANCH="glm/add-retry-logic-$UNIQ"                # unique: two delegations must not collide
REPO=$(git rev-parse --show-toplevel)
WT="$(dirname "$REPO")/.worktrees/$(basename "$REPO")/$BRANCH"
git worktree add -b "$BRANCH" "$WT" || exit 1    # unchecked, two agents share one tree
# ... provider runs with -C "$WT" ...
git -C "$WT" --no-pager diff --stat
git -C "$WT" status --porcelain                  # --stat cannot see new files
```

The worktree is what makes an otherwise alarming permission grant tolerable. It buys three
properties — but only two of them unconditionally, and the missing one is the one people
assume:

1. **Isolation** — **conditional, and usually absent.** Writes cannot reach your working
   tree *only* where the sandbox is OS-enforced. **Codex: yes. Copilot and every
   Claude-Code-based delegate: NO.** A worktree changes the working directory; it is not a
   boundary, and reading it as one is the single most consequential misunderstanding this
   document can leave you with. Code
   running in it can resolve your real checkout in one command, and the shared `.git` gives
   it your hooks and your config as well. Demonstrated above in tier 2, and it applies with
   more force here, where the grant is full write access rather than one named command.
2. **Reviewability** — the result is one diff against a known base, *provided you look at
   untracked files too*. `diff --stat` alone does not show a newly added file.
3. **Disposability** — `git worktree remove --force` and it never happened. This one is
   unconditional, and for non-sandboxed providers it is most of what you are actually
   getting.

An adapter in delegate mode may pass its provider's "skip confirmations" flag. For Codex
that is backed by an enforced boundary. For the others it is backed by reviewability and
disposability alone — so delegate to them the way you would run a stranger's build script:
in a copy you are willing to lose, on a machine whose `$HOME` you have not bet on the
outcome.

If you want a delegate that genuinely cannot touch your tree, that is Codex, and the
difference is not a matter of degree.

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
