# Field Notes

Every entry here was found by breaking something, not by reading documentation. Each one
cost real debugging time, and most of them are invisible failures — the command "succeeds"
and you get a wrong or empty answer that looks like an answer.

They're recorded in the shape that matters: **symptom → cause → fix**, plus how it was
measured, so you can tell a claim from a guess.

CLI behaviour changes. Entries measured against a specific version say so. Versions used
for the current round: **Codex 0.148.0**, **Copilot CLI 1.0.80**, **Claude Code 2.1.246**,
**Ollama 0.18.2**, **Antigravity CLI 1.1.21**. OpenRouter is an HTTP API with no client version; entries below name the model and date instead.
Re-run `scripts/quorum-verify --all` after any provider update — a flag that quietly got
renamed looks exactly like a model with nothing to say.

Format for new entries is at the bottom. PRs welcome — see [CONTRIBUTING.md](../CONTRIBUTING.md).

---

## Cross-cutting

### Piping destroys the exit code you are trying to measure

**Symptom.** A provider call is recorded as exit 0 and "working." It is neither.

**Cause.** `provider-cli ... | tail` reports the exit status of `tail`. Always 0.

**Fix.** Redirect to files and read `$?` immediately:
```bash
timeout 900 provider-cli ... >"$OUT" 2>"$ERR"; RC=$?
```

**How it was found.** By writing the wrong number into three adapter files first. The
Codex trusted-directory failure below was documented as `exit_code=0` because the
measurement command itself was piped through `tail`. Re-measured unpiped: exit 1.

> If you record only one thing from this document, record this one. It corrupts every
> other measurement you take.

### "Failures arrive as HTTP 200" — they do not, and five files said they did

**What the repo claimed.** That z.ai returns failures inside an HTTP 200, so the status line
is uninformative and you must classify on the body alone.

**Measured, just now:**

| Case | HTTP status | `curl` exit |
|---|---|---|
| bad model id (`glm-5.3[1m]`) | **400** | 0 |
| bad/expired key | **401** | 0 |

The status discriminates cleanly. What carries no information is **`curl`'s exit code**,
which is 0 for both — and that is the real lesson the sentence was reaching for.

**Why it mattered anywhere.** Runtime was unaffected: every adapter classifies on the body,
which is correct either way. The cost was in
`skills/build-adapter/reference/probe-checklist.md`, the table that teaches a *new* adapter
author the four failure shapes. It taught one this provider does not produce — so an author
following it would skip `%{http_code}` believing the status is useless, and lose the
cheapest, most reliable discriminator they had.

**The general lesson.** A wrong fact that costs nothing where it was written can still cost
something where it is copied. Docs that teach a *method* are load-bearing in a way that docs
describing a *symptom* are not.

### A check that fails when nothing is wrong

**Symptom.** `quorum-flags` reported `GONE --help — not in --help any more` and exited 1 on
a fully working machine.

**Cause.** Two things, and the second is the interesting one.

`--help` can never appear in its own output. No CLI lists `--help` inside `--help`, so any
tool that verifies flags against help text will report it missing forever.

It got into the checked set because the extractor scans an adapter for `<cli> ` anywhere and
pulls the flags off that line — so **prose mentioning a flag is indistinguishable from an
invocation using one.** A single sentence added that day, *"(default 5m0s, per `agy
--help`)"*, was enough.

**Fix.** Exclude `--help` and `--version` by name. The over-eager extraction stays, because
catching flags in examples and comments is where drift actually hides — but universal flags
have to be named as exceptions.

**Why this is worth a note rather than a quiet patch.** A gate that fires when nothing is
wrong is not a harmless annoyance. It teaches the reader that its output is noise, and the
next failure — a real one — gets the same shrug. That is the same reasoning behind refusing
`|| true` in CI, arriving from the opposite direction: a check that cannot fail and a check
that always fails are both checks nobody acts on.

Verified both ways after fixing, which is the standard any gate here has to meet: 0 missing
and exit 0 on a healthy machine, and `GONE` plus exit 1 when a flag is genuinely invented.

### The docs taught the one spelling that could not work

**Symptom.** `install.sh` finishes and prints, in one block:

```
/root/.local/bin is NOT on PATH. Add it in ...

Next:  quorum-setup
```

Running the second line gives `command not found`, exit 127 — because of the first line. On
macOS too, not just Linux.

**Cause.** Self-inflicted: `quorum-setup` fixes PATH itself, so `./scripts/quorum-setup`
works from the clone. The installer printed the one spelling that depends on the very thing
it had just said was missing.

**Three more of the same shape, all measured on a clean Debian container:**

- **`quorum-setup --check` hardcoded `env -i zsh -c` to test PATH visibility.** Where zsh is
  not installed that can only fail, so every Linux user was told "NOT visible to
  non-interactive shells" and handed a fix that also did nothing. And the test is wrong for
  bash in principle, not just in practice: bash reads nothing per-invocation, its mechanism
  is inheritance from `~/.profile`, and `env -i` destroys exactly that. A check that can
  only fail is as useless as one that can only pass.
- **`quorum-setup --check` exited 0 while reporting "not on PATH".** `--check && echo ready`
  printed *ready*. Third instance of this shape here: `quorum-verify` once exited 0 having
  verified nothing, `quorum-status` once exited 1 while reporting everything fine.
- **The manual install never produced the `/quorum:*` commands it promised.** User commands
  are namespaced by **subdirectory**, so `cp commands/*.md ~/.claude/commands/` yields
  `/status` and `/panel` — while the guide tells you to type `/quorum:status`. Verified on a
  live install: `~/.claude/commands/build.md` → `/build`,
  `~/.claude/commands/bench/plan_new_feature.md` → `/bench:plan_new_feature`. The plugin
  route gets the prefix from the plugin name; the manual route has to get it from a
  `quorum/` directory, which the docs never created.

**Also found in the same pass.** `quorum-auth --set-key` was TTY-gated from the start;
`--fix` was not — and `--fix` launches `codex login`, which opens a browser and blocks on
the callback. `commands/auth.md` advertises `--fix` and grants `Bash(quorum-auth:*)`, so an
agent could reach it with no terminal attached and hang, printing a real device code into
the transcript on the way. Now refused with exit 2 and instructions to run it yourself.

**The general lesson.** Instructions are code that executes in a human. Run the block you
wrote, in order, on a machine that is not yours — every one of these is invisible to
someone who already has a working install.

### The install worked perfectly, on the only machine it was ever run on

**Symptom.** A clean Debian container, following the documented install literally, ends up
with a PATH entry nothing reads and an API key stored in a file no shell on the machine loads.

**Cause.** Fifteen `~/.zshenv` references and five `brew install` references, hardcoded. zsh
was not installed in that container; `$SHELL` was `/bin/bash`. The advice was not wrong on
macOS — it was measured and correct there — it just could not be true anywhere else.

The worst instance was functional rather than cosmetic: `quorum-auth glm --set-key` **wrote
the key to `~/.zshenv`** and reported success. On bash that file is never read, so the key
was stored and invisible, and the failure surfaces later as "the key is set but the agent
says it is not" — the single hardest symptom in this repo to diagnose.

**Fix.** `scripts/quorum-lib.sh`, sourced by `install.sh`, `quorum-setup` and `quorum-auth`,
resolving three facts once:

- **Env file by shell.** zsh → `~/.zshenv` (read on every invocation, `.zshrc` skipped when
  non-interactive). bash → `~/.profile` (non-interactive bash reads *neither* `.bashrc` nor
  `.profile`, only `$BASH_ENV`, unset by default — but `.profile` is exported at login so
  children inherit it). Note this is not a filename swap; the mechanism differs.
- **Package manager by what is installed**, not by `uname`: a Mac can lack Homebrew and a
  container can be any distro.
- **`sudo` only when it applies.** The first version of this fix hardcoded `sudo apt-get`
  and failed in the very container that motivated it: `id -u` is 0 and no `sudo` binary
  exists, so the advice died with *"sudo: command not found"* — an error that sends the
  reader hunting for the wrong problem.

**Fix that came with it.** The test suite skips itself when `jq` or `python3` is absent, and
a skip exits 0. Correct on a contributor's laptop; wrong in CI, where every suite skipping
would have produced a green run that tested nothing. CI now fails on any `SKIP`.

**The general lesson.** "Works on my machine" hides inside *advice*, not just code. Every
default in this repo was measured — on one operating system, with one shell, by one person.
Ask which of your measurements were actually measurements of your own laptop.

### The `timeout` status that could never happen

**Symptom.** Three of five adapters documented a `timeout` status that no run could ever
produce. A slow provider was reported as a plain `error`, losing the *slow* vs *broken*
distinction the status exists to draw.

**Cause.** Nested deadlines, where the inner one always wins:

| Adapter | Invocation | What actually happens |
|---|---|---|
| ollama | `timeout 900 curl -sS -m 890` | curl's deadline fires **10 s early** → `RC=28` |
| antigravity | `timeout 900 agy --print-timeout 10m` | agy's fires first → `RC=1` + stderr `timeout waiting for response` |
| glm | `curl` inside a pipe | no `RC` captured at all; a timeout surfaces as `http_code=000` |

Each classification table checked only `RC = 124`, which is what the *outer* `timeout(1)`
returns — and the outer one never got to send its signal. Measured against a listener that
accepts and never responds: `RC=28`, `http_code=000`, stderr *"Operation timed out"*.

Codex and Copilot were clean, and the reason is instructive: they wrap a bare
`timeout 900 <cli>` with no inner deadline, so there is only one thing that can fire.

**A second bug in the same place.** `agy`'s consult block passed `--print-timeout 10m` and
its read-the-repo block omitted it — and the default is `5m0s`. The same mode ran with a
600-second deadline or a 300-second one depending on which block you copied.

**Fix.** Classify on the signature of whichever deadline actually fires, not the wrapper's.
Write every nested deadline explicitly rather than inheriting a default.

**The general lesson.** A status you document but cannot produce is worse than one you never
claimed: it reads as coverage. When two timeouts are nested, the shorter one is your real
timeout, and it is usually not the one you wrote in the adapter.

### A git worktree is not a sandbox

**Symptom.** A provider runs in a detached scratch worktree, reports *"the tests pass"*, and
`git -C "$WT" diff --stat` comes back empty. A tracked file in the user's real checkout has
been modified.

**Cause.** A worktree shares one `.git` with the main checkout, so anything running inside it
can walk home in a single command:

```bash
cd "$WT"
dirname "$(git rev-parse --path-format=absolute --git-common-dir)"   # the user's checkout
```

Measured with no model involved: writing there changed a tracked file's blob
(`f48a20db` → `9ad88bcd`), and `git -C "$WT" diff --stat` and `status --porcelain` both
stayed **empty**.

**Why the grant does not save you.** `--allow-tool 'shell(pytest)'` sounds narrow. pytest
imports `conftest.py` during collection, so the grant is to arbitrary repo-controlled Python
that never appears in the command string anyone inspects. Same for `make`, `npm test`, `tox`.
Confirmed end to end: Copilot, given the documented verify invocation, reported *"Yes, the
tests pass"* while its pytest run modified `config.ini` in the real tree, created a file
there, and wrote another above the repo.

**The check is string-level, not OS-level, and it says otherwise.** In the same session
`bash -c 'echo x > <absolute path outside cwd>'` was **refused** — after which Copilot
reported *"file access is confined to the current working directory… no escape occurred"* —
while `pytest` writing that same path was **allowed silently**. One process of indirection
defeats it.

**Codex is the control, and it held.** Identical payload, identical layout:

```
INTERNALERROR> PermissionError: [Errno 1] Operation not permitted:
'/.../usertree/.test-metrics.json'
```

That is the kernel, not a model. The difference between an OS sandbox and a permission
prompt is not a matter of degree.

**The shared `.git` is worse than the shared filesystem.** All measured, all invisible to
every documented check:

- `git config --local` set from the worktree lands in the **shared** config and reads back
  from the main repo immediately.
- The worktree's `hooks` path **is** the main repo's `.git/hooks`. A `post-commit` planted
  from inside the worktree survived `git worktree remove` and ran the next time the user made
  an ordinary commit in their own tree.
- `diff --stat` reports nothing for an **untracked** file — so a delegate that *adds* a
  module shows an empty diffstat as its review artifact.

**Fix.** Stop claiming isolation the worktree never provided. It gives **reviewability** and
**disposability**, both real and both useful; it does not give **containment** unless the
provider's sandbox is OS-enforced, which here means Codex alone. Check four things, not one:
worktree `status --porcelain`, the real tree's `status`, the shared `config --list --local`,
and the hooks directory. And say plainly that no git command detects a write to `$HOME` or
`/tmp`.

**The general lesson.** "Where the process runs" and "what the process can reach" are
different questions, and a `cd` only answers the first. Before trusting a boundary, ask what
enforces it — the kernel, or a string comparison one `exec` away from irrelevance.

### A truncated answer scored as a complete one

**Symptom.** GLM returns a long, confident, well-formed review of a large codebase. It is
cut off mid-sentence. The adapter reports `status: ok`.

**Measured.** A 152 KB input — the whole-subsystem read this provider is selected for —
asking for an exhaustive review:

| `max_tokens` | elapsed | `stop_reason` | output tokens | text |
|---|---|---|---|---|
| 32000 | 360 s | `max_tokens` | 32000 | 17,648 chars, cut off mid-review |
| 64000 | 579 s | `end_turn` | 51,678 | 39,013 chars, complete |

Two failures in one call:

1. **360 s exceeded the adapter's `-m 300`**, so curl killed it. Every other adapter in
   this repo allows 900 s. GLM alone allowed 300 — on the provider chosen for the largest
   inputs, where responses are longest. Raising `max_tokens` from 8000 to 32000 earlier the
   same day made this *worse*, by making answers longer.
2. **The classification table sent it to `ok`.** The rules covered
   `stop_reason == "max_tokens"` *with empty text* (the thinking-only case) but not with
   text present, so a truncated review fell through to `otherwise → ok`.

**What makes this the worst kind of bug here.** `docs/adapter-contract.md` §6b already named
it — *"a response that is truncated mid-sentence … classifies as `ok`"* — and prescribed the
defence: *"a `stop_reason` indicating a limit was hit, is not `ok`."* The contract was right
and the adapter did not implement it. A contract the adapters do not follow is
documentation, not a contract.

Note which adapter *did* get it right: `ollama-agent` carries a
`USED ≥ NEED → error — truncated` row, because it was generated by the probe workflow rather
than written by hand. The generated adapter followed the contract the hand-written one broke.

**Fix.** `-m 900`, matching every sibling. `stop_reason: "max_tokens"` with text present is
now `error — truncated`, with the partial text relayed as evidence rather than as an answer.

**The general lesson.** No constant is safe, because the input can always grow. Raising a
limit reduces how often you hit it and never removes the case, so the durable fix is
*detecting* the limit was hit. And when a fix makes outputs bigger, check what downstream
bound that pushes past — this one turned an empty-answer bug into a killed-call bug.

### A security fix that reached the scripts but not the docs

**Symptom.** `curl -H "Authorization: Bearer $KEY"` puts the key in argv, where `ps auxww`
shows it to every process running as you for the life of the call. This was found, fixed,
and verified at zero argv exposures — and then three more copies shipped insecure.

**What was missed.** The fix landed in `scripts/quorum-status`, `scripts/quorum-auth` and
`probes/glm.sh`. It did not land in `agents/glm-agent.md` (twice) or
`skills/model-panel/SKILL.md` — the markdown a model actually copies and runs, under a
heading reading *"Tested and working. Use these exactly."* The insecure form was in the
most-executed place in the repo while the repo believed the problem was solved.

**Why the search missed it.** Verification was `ps auxww` during a script run. That proves
the script is clean; it says nothing about a code block in a Markdown file that no test
executes. Grep for the *pattern* across every file type, not just the ones you can run.

**Fix.** All six sites moved to a `chmod 600` `mktemp` header file and `-H @file`, and CI
now rejects `-H "Authorization: Bearer` on any non-comment line in any `.md`, `.sh` or
`.yml`. That fix was correct about argv and created the leak documented in the next note —
the header file itself. Both are now gone; see below.

**The general lesson.** "Fixed" means every instance, and the instances you can execute are
the ones you will find. Ask what a fix's search method structurally cannot see. Related:
the same shape as the `max_tokens` default below — one fact in five files, corrected in three.

### The fix for the argv leak was a file holding the same key

**Symptom.** Keeping the key out of `argv` meant writing it to a `chmod 600` `mktemp` file
and passing `-H @file`. That closed the `ps auxww` hole and opened a quieter one: a live
credential on disk, removed only by an `rm -f` on the happy path. Any signal between the
write and the `rm` strands it. Measured with a sentinel key, `SIGTERM` mid-call:

```
before=2  after=3  delta=1
LEAKED -> /var/folders/.../T/tmp.F7vk7MIqj0  mode=600
         [Authorization: Bearer SENTINEL-KEY-DO-NOT-USE-a1b2c3d4]
```

Earlier, before any cleanup existed, two independent audits counted 110 and 241 such files
on the author's machine — one per invocation, 130 of 130 runs — outliving key rotation,
landing in backups, and on Linux sitting in `/tmp` until `systemd-tmpfiles` ages them out.

**What was missed.** `scripts/quorum-status` and `scripts/quorum-auth` were fixed with
`trap 'rm -f "$_hdr"' EXIT INT TERM HUP`, and the comment left at the fix site said *"The
adapters and probes already did this; the two shipped scripts did not."* The adapters did.
Four of seven sites did not:

| site | what was wrong |
|---|---|
| `probes/glm.sh` | no trap at all; the window spans `curl -m 900` |
| `skills/model-panel/SKILL.md` | trap covered `$PROMPT $REQ $BODY`; `$HDR` was created *after* it and never added — so three harmless files were signal-cleaned and the one holding the key was not |
| `docs/porting/openai-compatible.md` | `rm -f` only — and it is the copy-me template, so the defect propagates to every new provider |
| `agents/glm-agent.md` (2nd snippet) | `rm -f` only |

**Why the search missed it.** CI enforced half the rule. The gate forced the key *into* a
file and nothing ever forced it back out, so removal stayed a convention — and a convention
holds only where someone remembers it. The claim that the probes were already covered was
written from the fix author's memory rather than from an enumeration, which is the same
assumed-ground-truth failure this repo has now hit twice.

**A false negative worth keeping.** The first reproduction reported *no leak*. The harness
was wrong, not the code: on macOS `mktemp` with no template reads the
`DARWIN_USER_TEMP_DIR` confstr and **ignores an exported `$TMPDIR`**, so the check counted
files in an empty directory. `docs/evidence.md` had shipped that exact recipe as its proof.
A verification that cannot observe the thing it verifies always passes.

**Fix.** Delete the file, keep the reader. `-H @file` already accepted any path, so it is
handed a pipe instead: `-H @<(printf 'Authorization: Bearer %s\n' "$KEY")`. Not in `argv`,
not on disk, nothing to strand and no trap to remember. Verified at all seven sites — the
header is still transmitted, the key is absent from `argv`, and the fd survives the extra
`exec` through `qt`'s `timeout`. Needs bash or zsh; POSIX `sh` has no process substitution.
`tests/test-key-never-on-disk.sh` and a second CI gate now enforce it.

**The near-miss.** The first version of this fix used `curl --config <(printf 'header =
"Authorization: Bearer %s"\n' "$KEY")`, which works and would have shipped a quieter bug:
`--config` **unescapes** quoted values. Measured against the old `-H @file`, which is
byte-transparent:

| key | `-H @file` | `--config` quoted | `-H @<(...)` |
|---|---|---|---|
| `plain-abc123` | `plain-abc123` | `plain-abc123` | `plain-abc123` |
| `has"quote` | `has"quote` | `has` | `has"quote` |
| `has\backslash` | `has\backslash` | `hasbackslash` | `has\backslash` |

A key containing `"` or `\` would be silently truncated or mangled into an auth failure that
blames the provider. `quorum-auth --set-key` accepts whatever a user pastes, and the porting
template is copied to providers whose key alphabets nobody here controls. The unquoted config
form is worse: `header = Authorization: Bearer abc123` sets **no header at all**, with no
warning. Preferring the form that changes the fewest semantics — same `@file` reader, new
path — avoided all of it.

**The general lesson.** A security fix that *relocates* a secret inherits responsibility for
the new location's whole lifecycle. Ask what the fix created, not just what it removed — and
prefer the version with no failure mode to remember over the version with a rule that every
future call site has to honour.

### A command and a skill with the same name silently collide

**Symptom.** `/quorum:add-provider` returned the text *"Invoke the `add-provider` skill and
follow it exactly"* — an instruction to invoke itself. The six-probe workflow it was meant
to reach never ran, in any plugin install.

**Cause.** `commands/` and `skills/` auto-discover into ONE `plugin:name` namespace.
`commands/add-provider.md` and `skills/add-provider/` both resolved to
`quorum:add-provider`, and the command won. Invoking the bare skill name returns
`Unknown skill: add-provider`, so the skill had no reachable name at all.

**Why nothing caught it.** On disk both files were present and correct. Every in-repo
check passed — frontmatter, links, JSON, shellcheck. The collision only exists once the
plugin is *loaded*, so no amount of reading the repository could reveal it. It took a cold
`claude --plugin-dir` session listing its own available skills.

**Fix.** Renamed the skill to `build-adapter`, not the command, so the documented entry
point `/quorum:add-provider` still works. The other two pairs avoided this by luck of
naming — `panel`/`model-panel`, `delegate`/`delegate-task`. CI now rejects any
command/skill basename collision, and any command whose body names itself as the skill to
invoke.

**The general lesson.** Test the artifact as installed, not as authored. A packaging bug is
invisible from inside the package.

### `CLAUDE_PLUGIN_ROOT` is unset, so plugin files cannot reference their own repo

**Symptom.** Every adapter said *"Full spec: `docs/adapter-contract.md`"*. For anyone who
installed Quorum as a plugin, that path resolves against **their** project directory and
finds nothing. Measured from a plugin session: `ls docs/adapter-contract.md` →
`No such file or directory`.

**The obvious fix does not work.** `${CLAUDE_PLUGIN_ROOT}` is the documented way to
reference plugin-local files — 133 files across the plugins installed on this machine use
it, and the official `plugin-dev` validator checks for it. Measured under
`claude --plugin-dir`: `printenv CLAUDE_PLUGIN_ROOT` → **UNSET**. Do not assume it is
available; if you use it, supply a fallback, as `planning-with-files` does with
`${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/...}`.

**Fix.** Two parts. References in `agents/` and `skills/` are now absolute
`https://github.com/.../blob/main/...` URLs, which resolve from anywhere. And each adapter
now states that the link is background reading and everything needed is inlined — because
the deeper problem was that a model told to consult a file will go looking for it. An
adapter that *needs* a second file to behave correctly is already broken; the fix is for it
not to need one.

**Severity, honestly.** This was reported to me as a top-severity defect. It is not: the
contract — the classification table, the envelope, the neutralisation rule — is inlined in
every adapter, so they work standalone. It is a dangling cross-reference that wastes a turn,
not a broken adapter. Worth fixing, worth not overstating.

### `~/.zshrc` is invisible to agents

**Symptom.** An API key that plainly works in your terminal is unset inside a subagent, and
the provider reports auth failure.

**Cause.** `~/.zshrc` is read by *interactive* shells. Tool calls spawn non-interactive
ones, which read `~/.zshenv`.

**Fix.** Export credentials from `~/.zshenv`. Same idea on bash: `~/.bashrc` is skipped for
non-interactive shells.

### Vendor installers put PATH in the wrong file

**Symptom.** A CLI you just installed works when you type it and is "command not found" from
an agent, a cron job, or a launchd service — while `which` in your terminal happily prints
its path.

**Cause.** Installers append `export PATH=...` to `~/.zshrc` and `~/.bash_profile`, because
those are what an interactive user needs. Agents get a **non-interactive, non-login** shell,
which reads neither.

**Measured** (Antigravity CLI 1.1.21, whose installer logs
*"Appending PATH export to profile $HOME/.zshrc"* and reports
*"PATH verification: ~/.local/bin is correctly configured in active PATH environment"*):

| Shell | `command -v agy` |
|---|---|
| `zsh -lc` — login | found |
| `zsh -c` — non-interactive, non-login (**what agents get**) | **not found** |

The installer's own verification passed, because it checked the *active* environment — the
interactive one it was invoked from.

**Why it hides.** A Claude Code session launched from your terminal inherits that PATH, so
everything works until something starts from a cleaner context. Then it breaks with no
change to any config you touched.

**Fix.** Add it to `~/.zshenv` yourself; the installer will not:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshenv
```

**Generalise this.** After installing any provider CLI, verify it the way an agent will see
it, not the way you do:
```bash
env -i HOME="$HOME" zsh -c 'command -v <binary>'
```
If that prints nothing, the adapter will fail for reasons that have nothing to do with the
provider.

### Shell functions and aliases do not exist for agents

**Symptom.** A helper that works when you type it is "command not found" from an agent.

**Cause.** Same boundary. Functions and aliases live in the interactive shell's memory;
they are not on `PATH`.

**Fix.** Helpers that agents must call are **executables on `PATH`**, never shell functions.
Every script in `scripts/` is written this way on purpose.

Corollary worth knowing if you wrap `claude` in an alias carrying
`--dangerously-skip-permissions`: that alias does **not** apply to script- or agent-launched
sessions. Those get the real defaults, and any permission assumptions you made
interactively are wrong there.

### `jq`'s `// default` does not rescue an error

**Symptom.** A defensive-looking `jq -r '...  // 8192'` yields an **empty string**, and the
next line fails with `[: : integer expression expected` — leaking a bare shell error into an
adapter's output.

**Cause.** `//` is the *alternative* operator: it substitutes for `null` and `false` only.
A runtime error is not null — `.model_info | to_entries` on a missing key **throws**, jq
exits non-zero having printed nothing, and the default never applies. Error bodies are
exactly where the key is missing, so this fires only on the failure path.

**Fix.** Guard inside jq *and* validate in the shell, because the variable can still be
empty if jq dies:
```bash
V=$(jq -r '[((.model_info // {}) | to_entries[] | ...)][0] // empty' "$BODY" 2>/dev/null)
case "$V" in ''|*[!0-9]*) V=8192 ;; esac
```

**How it was found.** Building the Ollama adapter. The happy path and the classification
were both correct; only the failure path leaked, and it still produced the right final
status — which is the dangerous kind of correct, since testing the good case would never
have surfaced it.

### A missing binary proves nothing about a provider

**Symptom.** A panel reports a provider as unavailable while that provider is working fine.

**Cause.** `command -v <provider>` was used as an availability check. Not every provider
ships a CLI named after itself — GLM has **no `glm` binary at all** and is reached by
`curl`, `npx zai-cli`, or a wrapper script.

**Fix.** Availability is established by **running the documented invocation and reading the
result.** A real call is the only evidence that counts. Each adapter states its own
invocation path precisely because these are not uniform.

**How it was found.** A separate session ran `command -v glm`, got NOT FOUND, and reported
the provider as missing. It was answering normally the whole time.

**A second case, documented not measured:** Google's Antigravity CLI installs its binary as
**`agy`**, not `antigravity`. So `command -v antigravity` returns nothing on a machine where
it is installed and working. (Sourced from the CLI's own tool documentation; not yet
verified here, because it is not installed on the machine where these notes were written.)

**And a corollary for scripts:** check the *service*, not the binary. `ollama` can be
installed with nothing serving, and a remote `OLLAMA_BASE` has no local binary at all —
which is why `quorum-status` calls `/api/tags` instead of looking for a command.

---

## Codex (OpenAI / ChatGPT subscription)

### Zero bytes and nothing else, outside a trusted git repo

**Symptom.** `codex exec` returns completely empty. Relayed naively, reads as "the model had
nothing to say."

**Cause.** Outside a trusted git directory Codex refuses with *"Not inside a trusted
directory and --skip-git-repo-check was not specified."*

**Fix.** Pass `--skip-git-repo-check`. Harmless inside a repo, so keep it on for consults.

**Measured.** `exit_code=1`, `bytes_out=0` (unpiped).

### `-i/--image` is variadic and eats your prompt

**Symptom.** A 240-second hang, `exit=124`, zero output.

**Cause.** `-i` consumes *every following argument* as a filename. A trailing prompt string
is taken as a second image; Codex then waits on stdin that never arrives.

**Fix.** Pass the prompt through stdin with a trailing `-`:
```bash
echo "$QUESTION" | timeout 600 codex exec --sandbox read-only --skip-git-repo-check -i "$IMG" -
```

### `read-only` blocks test runners

**Symptom.** Verification tasks fail with sandbox denials on files nobody meant to change.

**Cause.** The sandbox is all-or-nothing per mode. `read-only` blocks *all* writes, and
test runners write caches, coverage data, and build artifacts.

**Fix.** Verify with `--sandbox workspace-write` pointed at a **detached scratch worktree**,
then assert the diffstat is empty. Never escalate the sandbox against the real tree.

---

## Copilot (GitHub subscription)

### `shell:` is not the shell-grant syntax

**Symptom.** *"Invalid --allow-tool value. Error: Invalid rule format: shell:echo hello"*,
and no answer.

**Cause.** `--allow-tool "shell:echo VERIFY_MODE_OK"` uses the colon form, which globs over
*tool names* and rejects a command with arguments.

**Fix.** Parenthesised, command name only: `--allow-tool 'shell(echo)'`, `'shell(pytest)'`,
`'shell(git)'`. **Verified:** `shell(echo)` executed and returned real output.

**Measured** (Copilot CLI 1.0.80): `exit_code=1`, **0 bytes on stdout**, 73 bytes on
stderr.

**Correction, and the reason it matters.** An earlier version of this note claimed the
usage error was printed on *stdout*, where a naive relay would report it as the model's
answer. `quorum-verify` contradicted that on its first run, and direct measurement
confirmed the verifier: the message goes to stderr.

The original observation was almost certainly real, and the reconciliation is the actual
lesson — **capturing with `2>&1` is what turns a stderr usage error into "the answer."**
Combine the streams and a clean `exit 1` with an empty stdout becomes an exit 0 with
error text in the body, which is indistinguishable from a reply. This is precisely why the
[adapter contract](adapter-contract.md#3-read-the-exit-code-unpiped) requires stdout and
stderr be captured to *separate* files.

### `-p` alone is not enough to run non-interactively

**Cause.** `-p` requires *some* tool grant to behave headlessly. Bare `-p` misbehaves.

**Fix.** Grant the narrowest set the question needs — `--allow-tool "read"` for a consult.

### It stalls waiting for a human

**Fix.** `--no-ask-user`. Without it, clarifying questions hang a non-interactive run to the
timeout.

### `--plan` and test runners are mutually exclusive

`--plan` is the strongest read-only guarantee here — it blocks edits and mutating shell in
the harness itself. That includes most test runners. So verify mode drops `--plan` and
relies on named allowlists instead, which is a genuinely weaker boundary. Prefer consult
whenever execution isn't needed.

---

## GLM (Z.AI Coding Plan)

### `curl` exits 0 on every failure, so its exit code tells you nothing

**Symptom.** The command succeeds, the body looks like JSON, and there is no answer in it.

**Cause.** `curl -s` returns 0 whenever it completed an HTTP transaction — **including 4xx
and 5xx**. Without `-w '%{http_code}'` the status is discarded and every failure looks like
a success at the shell level.

**Measured** (z.ai Anthropic-compatible endpoint):

| Case | HTTP | curl exit | Body |
|---|---|---|---|
| bad API key | **401** | 0 | `{"error":{"message":"token expired or incorrect","type":"401"}}` |
| bad model id (`glm-5.3[1m]`) | **400** | 0 | `{"type":"error","error":{"code":"1214",…}}` |
| thinking consumed `max_tokens` | **200** | 0 | valid response, **no text block at all** |
| server unreachable | — | **7** | empty |

**Correction.** An earlier version of this note claimed the first two arrive as HTTP 200.
They do not — both return correct status codes. The claim was never measured, and direct
measurement while auditing failure paths disproved it. The **third** row is the real
success-shaped failure, and it is why `status: empty` exists.

**Fix.** Capture body *and* status, and classify on all three signals — curl's own exit
code (7 = unreachable), the HTTP status, and the presence of `.error` in the body:

```bash
CODE=$(curl -s -m 900 -o "$BODY" -w '%{http_code}' …); RC=$?
```

**The general rule.** A transport that succeeded is not an operation that succeeded. Any
adapter built on `curl` must capture `%{http_code}`; any adapter built on a CLI must capture
the process exit code unpiped. Both are the same mistake wearing different clothes.

### `.content[0].text` is `null`

**Symptom.** A successful call that appears to return an empty answer.

**Cause.** GLM is a reasoning model. `content[0]` is a **thinking** block.

**Fix.** Always select by type, never by index:
```bash
jq -r '[.content[] | select(.type=="text") | .text] | join("")'
```

### A generous-sounding `max_tokens` still returned zero text

**Symptom.** A substantive question to GLM returns `status: empty`. A trivial one works.

**Cause.** `max_tokens` bounds thinking **and** output together, and reasoning is spent
first. Hard questions think more, so the harder the question the likelier the answer is
empty — the inverse of what you want.

**Measured** (glm-5.3, one analytical prompt, seven dimensions to cover):

| `max_tokens` | `stop_reason` | output tokens | text returned |
|---|---|---|---|
| 8000 | `max_tokens` | 8000 | **0 characters** |
| 32000 | `end_turn` | 13,194 | 20,077 characters |

**Fix.** 64000, and detect rather than tune. This line said **32000**, which the entry above measures as truncating a 152 KB input at 360 s with the answer cut off mid-review — the same mistake as the `8000+` it replaced, one revision later. This repo shipped 8000 as its documented default while its own adapter
described the failure mode — so every GLM consult on a hard question returned nothing, on
the provider chosen specifically for hard questions over large inputs.

**The general lesson.** A limit that only bites on your *intended* workload will pass every
smoke test. The canary probe in `quorum-verify` asks for one token and passes at any
setting. Size limits against the work you actually mean to do, not against the test.

### Thinking can consume the entire token budget

**Symptom.** `stop_reason: "max_tokens"` and no text block at all.

**Cause.** Reasoning tokens are spent first. A small `max_tokens` is exhausted before any
answer is emitted.

**Fix.** Detect it; do not tune it. **8000 is the value that CAUSES this**, and this line used to prescribe it — measured at 0 characters of text in 89 s, and 12000 and 20000 also returned 0. Use 64000 and treat `stop_reason: "max_tokens"` as a failure even when text is present. **Measured:** a real call returned
`content[0].type == "thinking"` and *no* text block until the budget was raised.

### Model ids carry no `[1m]` suffix

`glm-5.3[1m]` returns *modelCode: does not exist*. The correct id is `glm-5.3`. Auth is
fine when you see this — it's the model name.

### `zai-cli` interleaves log lines with the answer

**Symptom.** `INFO`/`DEBUG` records end up inside the relayed answer.

**Cause.** They're written to **stdout**, not stderr.

**Fix.** `2>&1 | grep -vE '^\[20'` before the text reaches the response envelope.

### The vision endpoint rejects ordinary phone photos

**Cause.** JPG/PNG only, ≤5MB. iPhone photos are HEIC and routinely exceed 20MB.

**Fix.** `scripts/prep-image` normalizes anything to a compliant JPEG. **Measured:** HEIC
input converts cleanly, and a 25MB PNG was reduced to 543KB at 1024px by the downscale loop
(two passes) against a 1MB cap.

---

## Ollama (local model server)

### The OpenAI-compatible endpoint silently ignores `num_ctx`

**Symptom.** A long prompt gets a fluent, confident answer that is subtly about the wrong
thing — and every signal says success: HTTP 200, `finish_reason: "stop"`, curl exit 0,
non-empty body.

**Cause.** Ollama exposes two chat endpoints. `/v1/chat/completions` (OpenAI-compatible)
**accepts `options.num_ctx` and discards it**, capping the prompt at the served window and
dropping the overflow without any error. The native `/api/chat` honours it.

**Fix.** Use native `/api/chat`, and set `num_ctx` explicitly on every call.

**Measured** (ollama 0.18.2, `llama3.2:3b`), same ~54,000-token prompt with a canary on
line 1, both sent `options:{num_ctx:65536}`:

| Endpoint | tokens processed | recovered the head canary? |
|---|---|---|
| `/v1/chat/completions` | `prompt_tokens: 32768` | no — answered *"The LETTERS E H I L O"* |
| `/api/chat` | `prompt_eval_count: 48071` | yes — `QUORUM_HEAD_CANARY_7742` |

**Truncation drops from the head**, so the beginning of the prompt is what disappears — the
system prompt and framing go first, and the trailing question still gets answered fluently.
That is why it reads as a real answer.

**Detect it** with `prompt_eval_count`: when Ollama truncates, it lands exactly on the
requested window. `prompt_eval_count >= num_ctx` is an exact test, and it is the *only*
machine-readable signal that this failure occurred.

### The served context is not the model's context, and raising it costs GB

**Symptom.** A model advertising 128k context truncates at a quarter of that.

**Cause.** `num_ctx` is a per-request/server setting, independent of what the model
supports. It is not raised to the model's maximum for you.

**Fix.** Set it per request, sized to the prompt — not maxed out, because the KV cache is
allocated for the whole window.

**Measured.** `llama3.2:3b` advertises `context length 131072`; the server served
**32768** by default with `OLLAMA_CONTEXT_LENGTH` unset. `ollama ps` shows the live value
in its `CONTEXT` column, and resident size grew **5.6 GB → 9.2 GB** going from `num_ctx`
32768 to 65536 on the same 3B Q4 model.

### Cold start looks exactly like a hang

**Measured.** First call after idle: **9s** (model load). Warm: **0.16s**. On a 3B model.
Set the deadline well above the cold-start cost for the largest model in use, or probe 2
records a load as a timeout.

### The two endpoints disagree on the shape of an error

**Cause.** Native `/api/chat` returns a **flat string** — `{"error":"model 'x' not found"}`.
`/v1/chat/completions` returns the OpenAI **nested object** — `{"error":{"message":...}}`.

**Fix.** Read defensively, or an error extraction written against one endpoint yields
`null` against the other and the failure reads as empty:
```bash
jq -r 'if (.error|type)=="string" then .error else (.error.message // "unknown") end'
```

**Measured.** Unpulled model id: **HTTP 404**, 57-byte body native / 120-byte nested on
`/v1` — and **curl exits 0 in both cases**. Classifying on exit code alone reports it as an
answer.

---

## Antigravity (`agy`)

### The binary is not named after the vendor

`command -v antigravity` returns nothing on a machine where it is installed and working.
The installed binary is **`agy`**. Same class as GLM having no binary at all — see
[the cross-cutting note](#a-missing-binary-proves-nothing-about-a-provider).

### Unauthenticated subcommands hang instead of failing

**Symptom.** `agy models` and `agy agents` produce nothing and never return.

**Cause.** Without credentials they wait rather than erroring. `--print` does fail fast on
the same machine, in the same state.

**Measured** (Antigravity CLI 1.1.21, logged out):

| Invocation | rc | stdout | stderr |
|---|---|---|---|
| `agy models` | **124** (timeout) | 0 | 0 |
| `agy agents` | **124** (timeout) | 0 | 0 |
| `agy --print "…"` | 1 | 0 | 107 — *"authentication required. Run 'agy' to log in"* |

**Fix.** Never use a subcommand as a liveness or auth check for this provider. Probe with a
short `--print` and a timeout. `quorum-auth` does exactly this, and treats a bare 124 with
no auth message as its own diagnosis — a half-finished login.

**Why it matters beyond `agy`.** A hang is the worst failure shape available: it consumes
the whole timeout, produces nothing to classify, and looks identical to a slow model. This
is what probe 2 exists to catch, and it is worth running against *every* subcommand an
adapter might call, not just the main one.

### `--output-format json` — validate before you parse

**What was observed, once.** A `--output-format json` run was rejected by `jq`:

```
jq: parse error: Invalid string: control characters from U+0000 through U+001F
    must be escaped at line 2, column 1
```

The payload spanned multiple lines, indicating a raw control character inside a string
value, which RFC 8259 forbids. Python's `json` module parsed the same bytes.

**It does not reproduce.** Three later runs of the identical command returned a single line
of 257 bytes with `\n` correctly escaped, and `jq` parsed all three. A deliberately
multi-line response also parsed. The cause of the original failure is **unknown** — it may
have been response-dependent or transient.

**Status: Observed, not Reproducible.** An earlier version of this note asserted the failure
as general behaviour and told adapter authors not to build on it. That was an overclaim from
a single observation, and this repo's own rule — *mark anything you did not personally
observe as inferred* — applies just as much to something observed **once** and generalised.
See [evidence.md](evidence.md).

**The useful conclusion survives, and it does not depend on the anecdote.** A documented
output format is a claim about a program, not a guarantee. Validate the bytes with the
parser you will actually use, on the failure path as well as the happy one, before an
adapter's classification depends on it:

```bash
agy -p "…" --output-format json | jq -e . >/dev/null || echo "not parseable — do not classify on it"
```

For `antigravity-agent` the exit code remains the discriminator, which is unaffected either
way — so nothing in this repo rested on the claim that turned out not to hold.

### The docs and the binary disagree about headless writes

**This one decides whether the consult tier is honest, so it is worth stating loudly.**

The official documentation says:

> *"Workspace file operations are auto-allowed, while actions like shell commands are
> soft-denied by default."*

**Measured behaviour is the opposite for writes.** On 1.1.21, asking headless `agy` to
create a file *inside* its own `--add-dir` workspace is refused:

> *"a tool required the `write_file` permission that headless mode cannot prompt for, so it
> was auto-denied."*

Confirmed both inside the workspace and outside it (`/tmp`).

**Why it matters.** This repo's read-only guarantee for `antigravity-agent` rests on that
auto-deny. It holds today and it is genuinely harness-enforced — the model tries and is
refused. But it rests on behaviour the vendor documents *differently*, so a future release
that matches the docs would silently turn a read-only tier into a writing one.

**Fix.** Re-run `quorum-verify antigravity` after any `agy` update, and treat probe 3 —
*try to write, then check the filesystem* — as a recurring check rather than a one-off.
Where a guarantee depends on undocumented behaviour, say so in the adapter instead of
letting the next reader assume the docs back it up.

### Permission rule syntax, for pre-approving specific tools

From the official docs — useful if you want a *narrower* grant than
`--dangerously-skip-permissions`, which is unconstrained:

```json
{ "permissions": {
    "allow": ["command(git)", "read_file(/var/log/app)", "write_file(src/)", "mcp(linter/*)"],
    "deny":  ["command(rm -rf)", "command(sudo)", "write_file(.git/)"],
    "ask":   ["command(*)"] } }
```

Note this file is **global**, not per-workspace: a rule added for one project applies to
every `agy` run on the machine, including Quorum's consult calls. That is why
`antigravity-agent` checks for `permissions.allow` before claiming read-only.

### Subcommand arguments are not free-form

`agy mcp list` returns rc=2 — *"unexpected argument"* — with a useful hint: prompts are read
only from `-p/--print`, `-i/--prompt-interactive`, or stdin. Check a subcommand's own
`--help` before assuming a positional argument is accepted.

### `--add-dir` is the workspace; the current directory is ignored

**Symptom.** Probe 3 "passes" — you ask `agy` to create `probe3.txt` in a scratch directory,
`ls` shows nothing, and you conclude writes are blocked. They were not. The file exists.

**Cause.** `agy` does not treat cwd as its workspace. With no `--add-dir` it works inside
`~/.gemini/antigravity-cli/scratch/` and writes there, whatever directory you launched it
from. The transcript even tells you so, in a `file://` link that is easy to skim past.

**Fix.** Always pass `--add-dir "$REPO"`, and when probing, check the location the output
actually names — not the one you assumed.

**Measured** (Antigravity CLI 1.1.21): run from `$(mktemp -d)` with `--sandbox -p "create
probe3.txt"` → rc=0, cwd empty, and `~/.gemini/antigravity-cli/scratch/probe3.txt` present
containing `WROTE`. With `--add-dir "$d"` the same prompt was auto-denied instead.

> The standing advice is *check the filesystem, not the transcript*. This is its sharper
> form: **check the filesystem the provider is actually using.** A cwd-based `ls` returning
> nothing is not evidence of a boundary if the provider was never working in cwd — it is a
> false pass, and it fails in the safe-looking direction.

### Headless mode is read-only by default — and the denial is shaped like success

**Symptom.** A consult call returns exit 0 and an empty body. Nothing indicates failure.

**Cause.** In `--print` mode any tool needing a permission that cannot be prompted for is
**auto-denied by the harness**. The model attempts the call, the CLI refuses, the turn ends
with no output. The explanation goes to stderr only.

**Fix.** Classify on stderr text *and* emptiness, never on `$?` alone:

```bash
grep -qE 'auto-denied|no output produced' "$ERR" && ST=error
```

**Measured** (1.1.21, scratch workspace via `--add-dir`):

| Tool | Result |
|---|---|
| `read_file` | allowed — rc=0, contents returned verbatim |
| `write_file` | **auto-denied** — rc=0, **0 bytes stdout**, 309 bytes stderr |
| `command` (shell) | **auto-denied** — rc=0, **0 bytes stdout**, 303 bytes stderr |

This is a genuine harness boundary rather than compliance — the model tried and was refused.
It is also the good news for this provider: consult is read-only *by default*, with reads
intact, which is what makes it useful on a real repository. The catch is that the denial is
indistinguishable from a successful empty answer unless you read stderr.

**Caveat worth stating.** The guarantee holds only while the user's **global**
`~/.gemini/antigravity-cli/settings.json` contains no `permissions.allow` entry — that is the
sole `settings.json` path in the binary, and there is no workspace-local override. An adapter
cannot scope permissions per run; it can only check the precondition.

### `--dangerously-skip-permissions` leaves the workspace, and `--sandbox` does not confine writes

**Symptom.** You reach for a worktree to contain a delegate run, and reason that `--add-dir`
plus `--sandbox` bounds the blast radius. Neither does.

**Cause.** `--add-dir` is a workspace *hint*, not a boundary, and `--sandbox` restricts the
*terminal*, not file writes — its own help text says so, and the measurement agrees.

**Measured** (1.1.21): with `--add-dir` pointed at a scratch directory and
`--dangerously-skip-permissions` set, asked to write `/tmp/quorum_escape_a.txt` → rc=0, file
created **outside the workspace**. Repeated with `--sandbox` added → same result. Separately,
`--sandbox` with permissions left alone produced *byte-identical* output to no `--sandbox` at
all (rc=0, 0 bytes stdout, same 309-byte stderr), confirming it is not what blocks writes.

**Consequence.** Antigravity gets a **consult-only** adapter. It has the capability for
verify and delegate but no way to bound it: no per-run command allowlist exists, and the
skip-permissions flag is unconfined. Per the safety model, an adapter may only claim a tier
it can enforce — so this one claims one.

### Three of five bad flag values are accepted silently

**Symptom.** A misconfigured call returns exit 0 and a fluent answer.

**Cause.** Only `--model` and `--effort` validate. The rest fall back to a default.

**Measured** (1.1.21, same canary prompt each time):

| Invocation | rc | stdout | stderr |
|---|---|---|---|
| `--model no-such-model-xyz` | **1** | 0 | 547 — *"invalid model selection"* |
| `--effort ludicrous` | **1** | 0 | 122 — *"valid: low, medium, high"* |
| `--mode nonsense` | 0 | canary | 74 — warning, **runs in default mode** |
| `--add-dir /nope/missing` | 0 | canary | **0** |
| `--output-format nonsense` | 0 | canary | **0** |

**Why it matters.** A typo in `--add-dir` is the dangerous row: the provider answers about a
repository it never opened, with no error on either stream. If a consult answer seems unaware
of files that plainly exist, check that path before believing the answer. It also means only
`--model`/`--effort` can serve as `probe_broken` — the other three cannot fail.

## OpenRouter (metered gateway)

### `max_tokens` is a budget for reasoning AND content, and reasoning is spent first

**Symptom.** A reasoning model returns HTTP 200, curl exit 0, and a 4,659-byte body — with
`.choices[0].message.content` **empty**. Every signal an adapter normally checks says
success. Classified naively it reports `empty`: *"the model had nothing to say."*

**Cause.** `max_tokens` caps reasoning tokens plus completion tokens together, and the
reasoning is generated first. A model that thinks past the cap never begins the answer. The
body is large because the *reasoning* is in it, so even a byte count on the response says
there is plenty of output.

**Fix.** Classify on `finish_reason` before emptiness, and keep the budget generous — unused
tokens are not billed:

```bash
FINISH=$(jq -r '.choices[0].finish_reason // "none"' "$BODY")
TEXT=$(jq -r '.choices[0].message.content // ""' "$BODY")
# finish_reason=length + empty TEXT  -> error "budget went to reasoning", NOT empty
```

Never relay the `reasoning` field in place of the answer. It is scratch work, and it reads
convincingly enough to be mistaken for a conclusion.

**Measured.** `openai/gpt-5-nano`, `max_tokens: 48`: HTTP 200, curl rc 0, body 4,659 bytes,
`finish_reason: "length"`, `reasoning` 924 characters, `reasoning_tokens: 234`,
`completion_tokens: 0`, `content` length **0**. The identical call at `max_tokens: 2000`:
`finish_reason: "stop"`, `content` 223 characters.

**Note what this sharpens.** The cross-cutting entry above establishes that z.ai does *not*
hide failures inside HTTP 200. Nor does OpenRouter — a bad model id is 400, a bad key 401,
an unroutable model 404, all cleanly discriminating. What arrives as 200 here is not a
failure but an **incomplete answer**, which is the harder case: there is no error object to
find, only a field that says the model stopped for the wrong reason.

### `native_finish_reason` is vendor-specific; `finish_reason` is not

**Symptom.** A truncation check works against one model and silently passes truncated
answers from another, with no code change between them.

**Cause.** OpenRouter returns two fields. `finish_reason` is normalised to the OpenAI
vocabulary (`stop`, `length`, …); `native_finish_reason` is passed through verbatim from
whichever upstream served the request. Which upstream serves a given model id is
OpenRouter's routing decision, not the caller's — so a check written against a native string
is correct for one vendor and wrong for the next, and the switch happens without warning.

**Fix.** Classify on `finish_reason`. Keep `native_finish_reason` and `.provider` for
diagnostics only.

**Measured.** The same truncation condition, same prompt, same `max_tokens`:
`google/gemini-2.5-flash` returned `native_finish_reason: "MAX_TOKENS"`;
`openai/gpt-5-nano` returned `"max_output_tokens"`. Both normalised to
`finish_reason: "length"`.

### HTTP 404 means "nothing will serve you this", not "no such model"

**Symptom.** A model id that exists in the catalogue, and is spelled correctly, returns 404.
The natural response — tell the user to check the spelling — sends them the wrong way.

**Cause.** 400 and 404 are different faults here. **400** `... is not a valid model ID` is a
malformed or retired id. **404** `No allowed providers are available for the selected model`
means the id is fine but no upstream will serve it to *this account*, usually because of the
account's data-policy/privacy settings or a region restriction. The fix is an account
setting at `https://openrouter.ai/settings/privacy`, not an edit to the request.

**Measured.** Bad id: HTTP 400, curl rc 0, 132-byte body. Unroutable id: HTTP 404, curl rc
0, 778-byte body. Bad key: HTTP 401, curl rc 0, 50-byte body, `"User not found."` — note
that message names the *user*, not the key, which reads like an account problem when it is
an authentication one. **curl exits 0 for all three.**

## Claude Code as a subprocess

### `claude -p` hangs on a permission prompt

**Symptom.** A headless run stalls until its timeout with no output.

**Cause.** `-p` is non-interactive. A permission prompt has nobody to answer it.

**Fix.** Pre-approve exactly what's needed:
```bash
claude -p "..." --allowedTools "Read,Glob,Grep,Bash" --disallowedTools "Write,Edit,NotebookEdit"
```

**Do not** reach for `--dangerously-skip-permissions` to unstick this. That grants write
access, silently converting a verification into an unreviewed delegation.

---

## Deploying the plugin

### `marketplace update` does not update the plugin, and `plugin update` compares versions

**Symptom.** A file is edited in the repo, `claude plugin marketplace update quorum` reports
success, and the deployed copy is unchanged. `claude plugin update quorum` then answers
*"already at the latest version (0.1.0)"* and also changes nothing. Everything reports
success; nothing is deployed.

**Cause.** Two separate things, and the names invite conflating them. `marketplace update`
refreshes marketplace **metadata** and never touches an installed plugin. `plugin update`
does re-sync the cache, but it decides whether to act by comparing **version strings** — not
file contents. With the version unchanged there is nothing it considers to do, however much
the source has changed.

**Fix.** Bump the version in `.claude-plugin/plugin.json` *and* the marketplace entry (they
must agree), then:

```bash
claude plugin marketplace update quorum   # refresh the metadata
claude plugin update quorum               # re-sync the installed copy
```

A content change with no version bump is not deployable. `tests/test-deployed-matches-repo.sh`
is what makes this visible instead of silent.

**Measured.** Adding `agents/openrouter-agent.md` and editing `skills/model-panel/SKILL.md`:
both update commands reported success at version 0.1.0 while the drift gate stayed red on
both files. After bumping to 0.2.0, `plugin update` reported *"updated from 0.1.0 to 0.2.0"*
and the gate went green.

**Note.** `claude` may be shell-aliased such that it swallows subcommands and starts a
session instead of running the CLI — `claude plugin marketplace update quorum` then returns
prose rather than output. Use `command claude` if that happens.

### The deployment check picked a version nothing was running

**Symptom.** With two versions in the plugin cache, the drift gate reported files as stale
that were byte-identical to the repo in the version actually installed.

**Cause.** It resolved the deployed copy with `ls -dt .../quorum/*/ | head -1` — newest
directory by mtime. An update left `0.1.0` and `0.2.0` with the **same mtime to the second**;
`ls -dt` broke the tie by name and returned `0.1.0`, which nothing executes.

**Fix.** Read Claude Code's own installation record rather than inferring from the
filesystem — `~/.claude/plugins/installed_plugins.json` carries `installPath` and `version`
per scope:

```bash
jq -r '(.plugins // {}) | to_entries[] | select(.key | test("^quorum@"))
       | .value[]? | .installPath // empty' ~/.claude/plugins/installed_plugins.json
```

**Why it matters more than the false positive it produced.** A wrong-but-red gate is
annoying. The same bug in the other direction is silent: had the stale `0.1.0` happened to
match the repo while the live `0.2.0` did not, the gate would have reported all-clear over
exactly the drift it exists to catch. **A deployment check that infers which artifact is
deployed is not a deployment check.**

**Measured.** `ls -ldT` on both directories: identical timestamps, `Sep 8 16:18:58 2026`.
`ls -dt | head -1` returned `0.1.0`; `claude plugin list` and `installed_plugins.json` both
said `0.2.0`.

## A second Claude subscription (`claude-alt`)

### `subtype` says "success" on a failed call — classify on `is_error`

**Symptom.** An authentication failure is relayed as an answer, with the error string sitting
inside the untrusted-output fence as though the model had said it.

**Cause.** `claude -p --output-format json` returns BOTH fields, and they disagree. Measured
with a deliberately invalid OAuth token:

```json
{"is_error": true, "subtype": "success",
 "result": "Failed to authenticate. API Error: 401 OAuth access token is invalid."}
```

`subtype` is the field whose name most invites you to classify on it, and it is the one that
lies. Note also that **stderr was 0 bytes** — an adapter reading only stderr sees a clean run.

**Fix.** `IS_ERR=$(jq -r '.is_error // true' "$OUT")`, and treat `true` as `error` regardless
of `subtype`. Default to `true` when the field is absent, so a malformed body fails closed.

**Measured.** Good call: `is_error:false, subtype:success, result:"PROBE_OK"`, exit 0. Bad
token: `is_error:true, subtype:success`, exit 1, stdout 1192B, stderr **0B**.

### Headless read-only IS enforced, and it is machine-visible

**Symptom.** None — this one is good news, recorded because the *evidence* is easy to miss
and the adjacent flag is a decoy.

**Cause.** `-p` is non-interactive, so a permission prompt has nobody to answer it and the
harness denies the tool call. The denial is recorded in `.permission_denials`, which makes
this the only shipped adapter whose read-only guarantee can be *verified from the output* of
an ordinary run rather than inferred.

**Measured**, asked to add an Installation section to a real README:

| invocation | README | `.permission_denials` |
|---|---|---|
| `-p` (default) | unchanged | **1** — `tool_name: "Edit"` |
| `-p --permission-mode plan` | unchanged | **0** — never attempted |
| `-p --dangerously-skip-permissions` | **written** | — |

Row 1 is the guarantee: the model *tried* and was *refused*. Row 3 proves the boundary is
real rather than a polite model. **Row 2 is the decoy** — `--permission-mode plan` adds
nothing to enforcement, it only stops the model attempting, which is the prompt-shaped
version of the same outcome. Reaching for it as the safety mechanism would be claiming a
guarantee from the wrong layer.

Contrast OpenCode, probed the same day: its `plan` agent also produced no file and no tool
calls, but its permission block is byte-identical to the fully-permissive one and no denial
event ever fires. Same observable behaviour, no enforcement underneath. **The denial event is
the difference between the two, and without checking it they look alike.**

### `jq`'s `//` treats `false` as absent, so a fail-closed default inverted the answer

**Symptom.** An adapter reports `status: error` and `is_error: true` over a correct,
complete answer, every time. The raw JSON from the very same invocation says
`is_error: false`.

**Cause.** The capture was `jq -r '.is_error // true'`, written to be fail-closed. jq's `//`
returns its right-hand side when the left is `null` **or `false`** — it is an
"alternative operator", not a null-coalesce. So the one value that matters most, a
successful call's `false`, was rewritten to `true` on every run.

```text
echo '{"is_error": false}' | jq -r '.is_error'          -> false
echo '{"is_error": false}' | jq -r '.is_error // true'  -> true
```

**Fix.** Ask whether the field is there, separately from what it says:

```bash
IS_ERR=$(jq -r 'if has("is_error") then (.is_error|tostring) else "MISSING" end' "$OUT")
```

`MISSING` is its own status row. "The provider failed" and "we could not read whether the
provider failed" are different faults, and a default that collapses them hides which one
happened — which is what the original `// true` was trying to express and got backwards.

**How it hid, and the lesson that cost the most.** It reproduces on every run through the
agent path and on none of mine, because my direct tests all ran bare `jq -r .is_error` —
**I was testing a different expression than the adapter shipped.** On that basis I twice
called it unreproducible, then diagnosed it as the relaying model inventing a value for a
placeholder. That diagnosis was wrong and was briefly committed to this file. The model had
faithfully reported what the shell computed.

Two rules survive it. Copy the exact line under test rather than retyping something
equivalent — a paraphrase is a different program. And when an adapter and its raw output
disagree, get both **from the same invocation**; two runs cannot show you a disagreement,
only a difference.

**It was in the probe too, and four green ticks hid it.** The same `// true` sat in
`probes/claude-alt.sh`, so `probe_consult` printed `FAILED is_error=true: PROBE_OK` — the
right answer, inside its own failure marker — while `quorum-verify claude-alt` reported
**4 passed, 0 failed**. Every check was individually true: exit code 0, non-zero byte count,
the canary present *within* that string, and the exit-code discriminator still separating
good from broken. A verifier that asks "did bytes come back containing the canary" cannot
see a probe that calls every success a failure.

`quorum-verify` now fails when the good call matches the probe's own `BROKEN_MATCH`, because
a success that looks like the documented failure is a contradiction rather than a pass.
Proven able to fail: with the bug reintroduced it reports
*"canary present, but the GOOD call matches BROKEN_MATCH"* and shows the offending line.

**Related but separate.** The same commit moved envelope rendering into the shell so the
model relays stdout verbatim instead of filling fields. That is worth keeping — it removes
an interpretation step — but it did **not** fix this bug, and should not be credited with
it. Removing `// true` fixed it.

### `env` cannot run a shell function

**Symptom.** A probe exits **127** and `quorum-verify` reports "probe is broken — a command
it depends on is missing", naming no command.

**Cause.** The invocation was `env -u ... VAR=val qt <binary>`. `qt` is a shell **function**
that `quorum-verify` defines; `env` execs a binary and cannot see functions, so it looked for
a program called `qt` and found none.

**Fix.** Put the function first: `qt env -u ... VAR=val <binary>`. `timeout` then runs `env`,
which runs the binary — and the deadline still applies to the whole thing.

**Measured.** Exit 127 with zero bytes on stderr. Worth noting `quorum-verify` handled it
correctly: it reported a *broken probe* rather than downgrading to "provider not installed",
which is the failure-rendered-as-normal-state shape this repo keeps finding.

## Epistemics of relayed answers

Two failure modes that no exit code will ever catch.

### "Verified" is not verification

A panelist asked about hardware specifications reported a component's maximum rate as one
value "**not** the higher figure sometimes misquoted — *verified via search*", and argued a
design decision from it. The manufacturer's datasheet gave the higher figure. The panelist
claiming verification was the one that was wrong, and the confident framing made the error
*more* persuasive than a hedge would have been.

**Rule.** Check every number you will design around against a primary source, regardless of
how confident a panelist sounds — and *especially* when one claims to have checked. Where a
claim is runnable, prefer verify mode over any assertion.

### Vision models name things that are not there

A model asked to judge a physical test described specific items that did not exist in the
test at all. Everything about the answer's form was correct; the content was invented.

**Rule.** Treat a confident description of fine detail as a hypothesis. Four models
disagreeing tells you far more than one model agreeing with itself — which is the argument
for a panel rather than a single opinion in exactly the cases where you can't check.

### A gate you have only read is a gate you have not tested

**Symptom.** CI is green. The gate it is green on cannot fire.

**Cause.** Two bugs in the *same* gate — the one forbidding an API key on a curl command
line — neither visible by reading it:

```
grep -rnE '^[^#]*-H "Authorization: Bearer' ...
```

`[^#]*` cannot cross a `#`, so **any** earlier `#` on the line hid the violation: a URL
fragment, a trailing shell comment. It also avoided matching its own definition only by
accident, because the pattern itself contains a literal `#` — reformatting that line would
have turned the gate red against the repo.

The repair was worse:

```
grep -rnE -- '-H "Authorization: Bearer' --include='*.md' --exclude=field-notes.md .
```

`--` ends **option** parsing, not just pattern parsing. Every `--include` and `--exclude`
after it became a *filename*. Five `No such file or directory` errors, an unfiltered
recursive search, and a gate that was red against every possible tree — including a correct
one. Use `-e` to introduce a pattern that starts with `-`.

A third attempt, `^[[:space:]]*[^#[:space:]].*-H "Authorization: Bearer`, missed the
ordinary indented `  -H "Auth…` form, because the leading `[^#[:space:]]` consumes the `-`
of `-H` and leaves nothing for the rest of the pattern. That is the form every adapter
actually writes, so the gate would have caught nothing real.

**Fix.** Stop encoding "is not a comment" in the search pattern. Match the dangerous text
plainly, then *filter* the hits whose line begins with a comment marker, anchoring on
`grep -n`'s own `file:line:` prefix. Two concerns, two commands, neither able to break the
other. Then **run it** — against a tree that must fail it and a tree that must not.

**Measured.** `tests/test-lint-gates.sh` extracts every `run:` body out of the workflow file
and executes each one three times: clean tree must exit 0, injected violation must exit
non-zero, and after the revert it must exit 0 again. The third run is what distinguishes a
working gate from a permanently-red one — without it, the `--` bug passes.

Every gate but two passes all three. The two are named in the harness output rather than
quietly omitted: the `shellcheck` step installs a package, and the `Test suite` step runs
`tests/*.sh`, which includes that file — exercising it would recurse.

A count would go stale the next time a gate is added, which is why the harness prints its
own, and prints `NO INJECTION DEFINED` for anything unproven.

### Reproduce in the environment you are reproducing

**Symptom.** The new gate harness reported three gates failing that CI passes.

**Cause.** It sandboxed the repo with `cp -R`, which copies the whole working directory.
Several gates scan the **filesystem** (`grep -r`, `rglob`) rather than `git ls-files`, so
they saw an ignored `logs/` directory of chat transcripts — full of absolute home paths,
dangling doc URLs and the literal `Authorization: Bearer` string. Every one of those three
"failures" was the harness, not the gate.

**Fix.** Populate the sandbox from `git ls-files`, which is what `actions/checkout` gives
CI. Separately, run each body under `bash -e`: GitHub Actions executes a `run:` block as
`bash -e {0}`, and without `-e` the shell-syntax gate kept going past its failing `bash -n`
and exited 0 — looking like a gate that does not fire, when in CI it does.

**Measured.** Same harness, 10 passed / 5 failed before the two fixes, 15 passed / 0 failed
after, with no change to any gate. A test environment that does not match the one being
reproduced produces confident wrong answers — and here it produced three of them at once.

### A rule that is not in the pipeline is not a rule

**Symptom.** Five adapters each carried the untrusted-output rule, a CI gate confirmed all
five carried it, and the rule ran in none of them.

**Cause.** The rule had two halves. The substitution half existed only as prose —
*"Substitute both markers out of the provider's stdout"* — with the concrete `sed` living in
`docs/adapter-contract.md`, which the adapters link to but do not inline. Measured:

```
grep -c 'sed -e' agents/*.md   ->  0 for all five
```

The strip half shipped as a literal command, but as a *fragment* with no input, no output
and no assignment, 95 to 313 lines below the line that captured the text:

```bash
# after substituting the markers, before the text enters the envelope
LC_ALL=C tr -d '\000-\010\013-\037\177'
```

The gate checked that each adapter *contained the string* `LC_ALL=C tr -d`. It did, so the
gate printed **"all adapters neutralise markers AND control characters"** — a sentence about
behaviour, backed by a check on text.

**Fix.** `scripts/quorum-sanitize`, on PATH, piped into every capture. One command, in the
pipe, testable. The gate now requires the command in an actual pipeline, and
`tests/test-sanitize.sh` runs 30 hostile fixtures through it.

**Measured.** Every fixture in that test is a payload that beat the old implementation.

**The general shape.** The audience for an adapter is a model, and the contract says to run
them on haiku-class models — the ones least able to reconstruct a correct `sed` from a
sentence. Anything you would be unhappy for a model to improvise belongs in a command, not
in prose beside one.

### One honouring terminal is enough

**Symptom.** An adapter emitted `status: error`. The user's screen said `status: ok`.

**Cause.** `U+009B` is the single-character CSI. Every byte after it is printable ASCII, so
the whole ANSI repertoire is reachable without using one byte the filter removed. The
filter was a byte-range `tr`, and `c2 9b` — the UTF-8 encoding — is not in any byte range it
covered, in any locale:

```
41 c2 9b 42   LC_ALL=C      -> 41 c2 9b 42    survives
              en_US.UTF-8   -> 41 c2 9b 42    survives
```

`docs/adapter-contract.md` had recorded this honestly and got it wrong anyway: *"a
UTF-8-encoded C1 control passes through — tmux renders it inert, but that was the only
emulator available to test."* A second emulator was tested. GNU screen 4.00.03 — the build
macOS ships at `/usr/bin/screen` — honours it. `CSI H` homes the cursor, `CSI K` erases the
line, and the forged `status: ok` lands on top of the real one.

**Fix.** Strip `U+0080`–`U+009F` after decoding. Decoding is not optional: extending the
byte range to `\200-\237` turns `e6 97 a5 e6 9c ac` into `e6 a5 e6 ac` — it corrupts every
multi-byte character it touches.

**Measured.** Rendered via `screen -X hardcopy`, so nothing reached the auditing terminal.
Before the fix, line 1 read `status: ok`; after, `status: error`.

**The general shape.** "I could only test one implementation" is a result, not a conclusion.
The honest hedge was recorded and then quietly leaned on as though it settled the question.

### The temp file that solved one problem and created another

**Symptom.** 110 files in the shared temp directory, each containing the live API key.

**Cause.** `quorum-status` and `quorum-auth` wrote the key to a `mktemp` header file
specifically to keep it out of `argv`, where `ps auxww` would show it. That part worked. The
file was then never deleted — no `rm`, no `trap`, on any path. One new file per invocation,
measured at 130 of 130 runs by one auditor and 241 files by another.

The adapters, the probes and the porting docs all cleaned up correctly. Only the two shipped
scripts did not, so the repo's documentation of the fix was more correct than its code.

**Fix.** `rm` after the call, plus `trap ... EXIT INT TERM HUP` — `probes/glm.sh` had the
`rm` and still leaked one when interrupted mid-request.

**Measured.** Five runs before: five new files. Five runs after: zero.

**The general shape.** A mitigation introduces its own lifecycle. Moving a secret out of one
place puts it in another, and the second place needs the same attention the first one got.
### The escape check that checked the wrong tree

**Symptom.** A delegate writes into the tree you are working in. The adapter reports a clean
run.

**Cause.** The escape check resolved the tree to inspect with:

```bash
MAIN=$(dirname "$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)")
git -C "$MAIN" status --porcelain
```

`--git-common-dir` always points at the **primary** checkout. If you invoked Quorum from a
*linked worktree* — which this repo's own delegate flow actively encourages — `$MAIN` is not
the tree you are in. Measured, with the user sitting in a linked worktree and an escape
written there:

```
git -C "$MAIN" status --porcelain   ->  (empty)
git -C "$REPO" status --porcelain   ->  ?? escaped.txt
```

**Fix.** Check both, and skip the second when they are the same:

```bash
git -C "$REPO" status --porcelain
[ "$MAIN" != "$REPO" ] && git -C "$MAIN" status --porcelain
```

**How it was found.** By running `codex exec review` — a live call made to verify the flag
`-c sandbox_mode="read-only"`, since the previously documented `--sandbox read-only` exits 2
on that subcommand. The review flagged the linked-worktree case in the very change being
verified. The claim was then reproduced before anything was altered, because a confident
model is still a hypothesis; this file has an entry about exactly that.

It is worth naming what happened: the second-opinion mechanism this repo exists to provide
found a real bug in the repo, in a code path added the same day, that six parallel auditors
had not. That is the argument for the tool, made by the tool.

**Measured.** `tests/test-worktree-tiers.sh` now runs every verify and delegate block twice —
once from a primary checkout, once from a linked worktree. Reverting to the `$MAIN`-only
check turns six assertions red.

### A missing tool became an empty answer

**Symptom.** GLM returns HTTP 200 with a real answer. The adapter reports `empty`.

**Cause.** The consult pipeline ends `| quorum-sanitize`. With that command absent, the pipe
yields an empty string, and the classification table maps empty text to `empty` — *"usually
thinking-only; raise max_tokens"*. Measured live: `CODE=200`, `stop_reason=end_turn`,
`TEXT=""`.

The path that produces it is not exotic. **`/plugin marketplace add` installs the plugin
without running `scripts/install.sh`**, so on that route `quorum-sanitize` is not on PATH at
all, and *every* consult through *every* adapter returns empty with a plausible explanation
attached.

**Fix.** Refuse. Every block that pipes through it now checks first and exits with
`status: error — quorum-sanitize is not on PATH`, naming the installer. Relaying unsanitised
provider text is not an acceptable fallback, and neither is reporting a missing dependency
as a quiet answer about the model.

**Measured.** With the tool absent the block refuses and never reaches the API; with it
present, `CODE=200 TEXT=PONG`. Asserted for all five adapters.

**The general shape.** This is the same defect as `quorum-verify` reporting a broken probe as
"not installed, this is normal", and as `quorum-flags` exiting 0 having checked nothing: a
missing prerequisite rendered as an ordinary result. It keeps recurring because the empty
value is always a *valid-looking* member of the result type.
### The install path nobody had run

**Symptom.** None — which was the problem. `/plugin marketplace add` is the first command in
the README and it had never been executed, on the grounds that the repository is private.

**Cause.** That reasoning was wrong. `claude plugin marketplace add` takes **a path**, not
only a URL, so the whole route was testable from a local clone the entire time. It was also
briefly hidden by an alias: `claude` on this machine expands to
`claude --dangerously-skip-permissions …`, so `claude plugin --help` was being handled as a
*prompt* by a nested session rather than as a CLI invocation. `type -P claude` gives the real
binary and the subcommands appear.

**Measured**, from a fresh clone, install, inspect, then removed again:

```
Component inventory
  Skills (9)  add-provider, auth, build-adapter, delegate, delegate-task,
              model-panel, panel, setup, status
  Agents (5)  glm-agent, codex-agent, antigravity-agent, copilot-agent, ollama-agent
  Hooks (0)   MCP servers (0)   LSP servers (0)

Projected token cost
  Always-on:  ~1,510 tok   added to every session
```

Three things fall out of that, none of which was known before:

1. **The namespace merge is real and visible.** Nine "Skills" is three skills plus six
   commands. Claude Code lists them together, which is exactly why a command and a skill
   sharing a name makes one unreachable — the failure this repo already has a gate for, now
   confirmed from the outside rather than inferred.
2. **The plugin ships no `scripts/`.** `command -v quorum-sanitize` finds nothing after a
   plugin-only install. That is the route that produced the empty-answer bug, and it is
   confirmed to be a route real users take.
3. **Quorum costs ~1,510 tokens of always-on context**, and a five-provider panel spends
   roughly 45k on adapter bodies before calling anything. Worth stating plainly: thorough
   adapters are not free, and the README now says so.

**Fix.** Nothing to fix in the plugin itself — it installs and every component resolves. The
lesson is procedural: *"we cannot test that because the repo is private"* was an assumption,
not a measurement, and it survived several rounds of auditing unchallenged.
### The rule was applied to one channel out of four

**Symptom.** None. Every test passed, a live quota failure classified correctly as `error`,
and the panel named the failed provider and carried on — exactly as designed. The question
that found this was a plain one: *"are those failures handled gracefully?"*

**Cause.** `TEXT` — the provider's stdout, the thing inside the fence — went through
`quorum-sanitize` in all five adapters. Nothing else did. The stderr tail that fills
`diagnostics:` was raw. GLM's `.error.message` was raw, on the line directly *below* the
sanitised `TEXT` beside it. Ollama's `.error` was raw. `quorum-verify` printed a raw tail of
provider stderr through helpers that scrubbed nothing.

**And the raw channels were the dangerous ones.** `diagnostics:` sits *outside* the
`BEGIN/END UNTRUSTED PROVIDER OUTPUT` markers — in the region a reader takes to be the
adapter's own words. Text injected inside the fence is at least labelled as the provider's.
Text injected above it is not labelled at all. The whole apparatus was guarding the half that
was already marked untrusted.

**Measured.** A stderr carrying `U+009B` — the single-character C1 CSI, cursor-up plus
erase-line, containing **no ESC byte anywhere**, so a filter that strips `\033` never sees it:

```
status: error          rendered as        status: ok
exit_code: 1                              exit_code: 0
```

A quota-exhausted provider that returned nothing rendered as a successful answer, which a
panel counts as a vote. The one failure mode the status envelope exists to prevent.

Not a theoretical input class: **`copilot -p` writes 24-bit SGR colour codes to stderr on
every ordinary run.** Real provider stderr carries control characters today.

**Fix.** Sanitise every provider-controlled string that reaches a human, and classify on the
sanitised text so the classifier and the renderer cannot disagree. Enforced by
`tests/test-diagnostics-sanitized.sh`, including a proof that the payload really does forge a
status line on unsanitised input — otherwise the whole file could pass while testing nothing.

**The general shape, and it is the useful part.** A security rule gets written against the
channel that prompted it, then quietly means "that channel" forever. The audit that found
the C1 hole in `TEXT` fixed `TEXT` in five files and never asked *what else does a provider
control?* Ask that question about every mitigation: not "is the rule applied here?" but
"enumerate the places this rule must hold, then check each one." Three of the four sites had
been read many times during this campaign, by me and by six parallel auditors, and the raw
`tail "$ERR"` was sitting in plain sight in each of them.

While fixing it I wrote a gate matching `(tail|cat|head)` unanchored, which fired on
`appliCATion/json` in Ollama's curl line. A gate that fires on valid input teaches people to
bypass it — the anchored version is asserted both ways, that it still catches a real
`tail "$ERR"` and that it no longer fires on the false positive.

### I scored a correct answer as a failure

**Symptom.** The vision probe looked non-deterministic. Codex named the quadrant colours
correctly on 7 runs out of 11 and answered `white` for all four on the other 4. Same image,
same md5, same prompt, same flags.

**Cause, and it was not the model.** The probe image is four **coloured quadrant
backgrounds, each with a WHITE shape drawn on it**. `scripts/make-probe-image` says so, in
the docstring of the function that draws them:

```python
"""White shape inside each quadrant: circle, square, triangle, cross."""
```

So the checklist's prompt — *"answer in the form `top-left: <colour> <shape>`"* — never said
**which** colour, and both answers were right:

- `white circle` — the colour of the *shape*
- `red circle` — the colour of the *quadrant*, the shorthand the rest of the docs use

I picked one reading, scored the other as a failure, and published a one-in-three failure
rate that did not exist. What exposed it was another provider answering more precisely than
either: antigravity said *"White circle on a red background."*

**Fix.** Disambiguate the prompt. Do not run it five times.

> Each quadrant has a coloured BACKGROUND with a white SHAPE drawn on it. For each quadrant
> answer on its own line in the form `top-left: <background colour> <shape>`.

**Measured:** 5 of 5 correct with the disambiguated prompt, against 7 of 11 with the
ambiguous one. The variance is gone because it was never in the model.

**What actually went wrong.** The measurements were sound — same file, same md5, counted
runs, ruled out the file format, ruled out `prep-image`, decoded the JPEG to confirm the
pixels really were coloured. Every one of those was true and none of them was the question.
I scored the answers against a ground truth I had assumed from a table in the docs, when the
program that generates the image states it in a docstring. Careful measurement of the wrong
quantity is still wrong, and the rigour around it makes it more persuasive, not less.

The previous version of this entry claimed a 36% vision failure rate and changed the
checklist to require a majority of five runs. Both were wrong; both are reverted. This file
records what was believed and not only what turned out to be true, so the retraction stays
here rather than being quietly deleted.

**The finding that does survive.** A probe whose prompt admits two correct answers cannot be
scored, and running it more times does not fix that — it launders the ambiguity into a rate.
Check ground truth against the thing that *generates* it, not against prose describing it.

---

## Adding an entry

```markdown
### Short symptom-shaped title

**Symptom.** What you see, from the caller's side.

**Cause.** What is actually happening.

**Fix.** The exact invocation that works.

**Measured.** Exit code, byte count, or response body — unpiped. Say if you inferred it.
```

Mark anything you did not personally observe as inferred. The value of this file is that
its claims are measurements, and one guess wearing the same formatting devalues all of them.

**And say how it can be re-checked.** [evidence.md](evidence.md) lists every non-obvious
claim in this repo alongside the command that re-measures it — or admits that it cannot be
re-measured and is a report rather than a measurement. Add your entry to whichever table
fits. An unlabelled anecdote is worse than no claim, because it spends credibility the rest
of the file earned.
