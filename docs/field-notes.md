# Field Notes

Every entry here was found by breaking something, not by reading documentation. Each one
cost real debugging time, and most of them are invisible failures — the command "succeeds"
and you get a wrong or empty answer that looks like an answer.

They're recorded in the shape that matters: **symptom → cause → fix**, plus how it was
measured, so you can tell a claim from a guess.

CLI behaviour changes. Entries measured against a specific version say so. Versions used
for the current round: **Codex 0.148.0**, **Copilot CLI 1.0.80**, **Claude Code 2.1.246**.
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

### `~/.zshrc` is invisible to agents

**Symptom.** An API key that plainly works in your terminal is unset inside a subagent, and
the provider reports auth failure.

**Cause.** `~/.zshrc` is read by *interactive* shells. Tool calls spawn non-interactive
ones, which read `~/.zshenv`.

**Fix.** Export credentials from `~/.zshenv`. Same idea on bash: `~/.bashrc` is skipped for
non-interactive shells.

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

### Failures arrive inside HTTP 200

**Symptom.** `curl` exits 0, the body looks like JSON, and there is no answer in it.

**Cause.** The API returns `{"error":{"message":"token expired or incorrect"}}` and
`modelCode: does not exist` as ordinary 200 responses.

**Fix.** Capture body *and* status (`-o "$BODY" -w '%{http_code}'`), then classify on the
presence of `.error` as well as on the code. Curl's exit status tells you nothing here.

### `.content[0].text` is `null`

**Symptom.** A successful call that appears to return an empty answer.

**Cause.** GLM is a reasoning model. `content[0]` is a **thinking** block.

**Fix.** Always select by type, never by index:
```bash
jq -r '[.content[] | select(.type=="text") | .text] | join("")'
```

### Thinking can consume the entire token budget

**Symptom.** `stop_reason: "max_tokens"` and no text block at all.

**Cause.** Reasoning tokens are spent first. A small `max_tokens` is exhausted before any
answer is emitted.

**Fix.** Keep `max_tokens` generous — 8000+. **Measured:** a real call returned
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
