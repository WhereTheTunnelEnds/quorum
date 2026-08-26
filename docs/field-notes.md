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
