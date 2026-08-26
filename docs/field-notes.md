# Field Notes

Every entry here was found by breaking something, not by reading documentation. Each one
cost real debugging time, and most of them are invisible failures — the command "succeeds"
and you get a wrong or empty answer that looks like an answer.

They're recorded in the shape that matters: **symptom → cause → fix**, plus how it was
measured, so you can tell a claim from a guess.

CLI behaviour changes. Entries measured against a specific version say so. Versions used
for the current round: **Codex 0.148.0**, **Copilot CLI 1.0.80**, **Claude Code 2.1.246**,
**Ollama 0.18.2**, **Antigravity CLI 1.1.21**.
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

**Fix.** All six sites use a `chmod 600` `mktemp` header file and `-H @file`, and CI now
rejects `-H "Authorization: Bearer` on any non-comment line in any `.md`, `.sh` or `.yml`.

**The general lesson.** "Fixed" means every instance, and the instances you can execute are
the ones you will find. Ask what a fix's search method structurally cannot see. Related:
the same shape as the `max_tokens` default below — one fact in five files, corrected in three.

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

**Fix.** 32000. This repo shipped 8000 as its documented default while its own adapter
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
