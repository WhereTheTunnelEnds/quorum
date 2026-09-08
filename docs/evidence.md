# Evidence

This repo asks contributors to paste measurements into a PR. It should hold itself to the
same bar, so this file states **how each non-obvious claim can be checked** — or admits when
it cannot be.

An adversarial audit of this repository raised exactly this: several recurring claims —
*"two agents were observed copying the fence"*, *"has already caused a panel to report a
working provider as missing"* — had **no artifact anywhere in the repo**. They may well be
true; there was nothing to check them against. That is a fair criticism of a project whose
whole argument is that measurements beat assertions.

## Provenance labels

| Label | Means |
|---|---|
| **Reproducible** | Run the command in the right-hand column. It re-measures the claim now. |
| **Observed** | The author saw it in a working session that is not in this repo. Weigh it as a report, not a measurement. |

The distinction matters because it is the same one the field notes ask of you: *mark
anything you did not personally observe as inferred.* An **Observed** claim is not worthless
— it is how most of these were found — but it cannot be re-checked, and it should never be
cited as if it could.

## Reproducible

| Claim | Stated in | Re-measure with |
|---|---|---|
| Codex exits 1 with **zero bytes** outside a trusted repo | field-notes | `quorum-verify codex` |
| Copilot's bad-flag error is **stderr, rc=1, 0 bytes stdout** | field-notes | `quorum-verify copilot` |
| z.ai reports a bad model id in the **body**, curl exits 0 | field-notes | `quorum-verify glm` |
| Ollama's unpulled-model failure is **HTTP 404**, curl exits 0 | field-notes | `quorum-verify ollama` |
| Antigravity's broken call is **rc=1, 0 bytes stdout** | field-notes | `quorum-verify antigravity` |
| OpenRouter reports a bad model id as **HTTP 400**, curl exits 0 | field-notes | `quorum-verify openrouter` |
| A reasoning model can return **HTTP 200 with empty `content`** when `max_tokens` is spent on reasoning | field-notes, openrouter-agent | `jq -n '{model:"openai/gpt-5-nano",max_tokens:48,messages:[{role:"user",content:"Explain in detail how a B-tree rebalances on insert."}]}' \| curl -s https://openrouter.ai/api/v1/chat/completions -H @<(printf 'Authorization: Bearer %s\\n' "$OPENROUTER_API_KEY") -H 'content-type: application/json' -d @- \| jq '{finish:.choices[0].finish_reason, len:(.choices[0].message.content\|length)}'` — expect `length` and `0` |
| `native_finish_reason` differs by upstream vendor for the identical condition | field-notes | run the command above against `google/gemini-2.5-flash` (`MAX_TOKENS`) and `openai/gpt-5-nano` (`max_output_tokens`); `finish_reason` is `length` for both |
| OpenRouter has **no tool loop**: it cannot write to the filesystem | openrouter-agent, safety-model | `d=$(mktemp -d); ` ask it to create `$d/probe3.txt`, then `ls "$d"` — expect an empty directory and `.choices[0].message.tool_calls` absent |
| Every flag the adapters use still exists | model-panel, adapters | `quorum-flags` |
| `quorum-flags` exits 0 on a healthy machine and 1 on a real drift | field-notes | `quorum-flags; echo $?`, then invent a flag in an adapter and re-run |
| The setup wizard completes without hanging | getting-started | `tests/drive-setup.exp n` — **spends quota**: quorum-setup always reaches quorum-auth, which makes a live z.ai call plus `copilot -p` and `agy --print` |
| `quorum-status` exits 0 when a provider is reachable, 1 when none are | — | `quorum-status; echo $?` |
| `quorum-verify` exits non-zero when it verified **nothing** | adapter-contract | `quorum-verify nosuchprovider; echo $?` |
| Codex names all four quadrants correctly when asked for the BACKGROUND colour | codex-agent, probe-checklist | 5 of 5 runs with the disambiguated prompt; the ambiguous form yields `white` or the quadrant colour, and both are correct |
| `prep-image` preserves colour through the PNG -> JPEG conversion | field-notes | decode the prepped JPEG (`sips -s format png`) and count distinct RGB values — the four probe colours survive |
| Each quadrant is a coloured BACKGROUND with a WHITE shape: red/circle TL, green/square TR, yellow/cross BR, blue/triangle BL | probe-checklist | `tests/test-probe-image.sh` — decodes the PNG and asserts every shape centre is (255,255,255) and every quadrant corner is the named RGB. Proven to fail on a recoloured shape, a swapped quadrant, and docs reverting to the ambiguous wording |
| `prep-image` fails cleanly with no converter present | porting docs | `tests/test-prep-image-no-converter.sh` |
| Ollama's `/v1` endpoint **discards** `options.num_ctx` while `/api/chat` honours it | field-notes | the entry states the measurement (prompt_tokens 32768 via /v1 vs prompt_eval_count 48071 via /api/chat) but does not carry runnable commands — treat it as Observed until it does |
| Antigravity's headless mode auto-denies `write_file` | safety-model, field-notes | `d=$(mktemp -d); cd "$d" && agy --add-dir "$d" -p "create a file test.txt containing X"` |
| Adapters declare no write tools | safety-model | CI, or `grep '^tools:' agents/*.md` |
| GLM reports a **truncated** answer as `error`, not `ok` | glm-agent, troubleshooting | ask GLM to count 1–400 at `max_tokens:600`; expect `stop_reason: max_tokens` with text. **Measured live:** `stop_reason=max_tokens`, 915 characters of text, content types `[thinking, text]` |
| GLM's 64000 / `-m 900` pair completes a 249 KB input | glm-agent | feed ~250 KB of source and ask for an exhaustive review; expect `end_turn` under 900 s |
| `quorum-status --json` stays valid JSON under hostile provider text | quorum-status | `tests/test-quorum-status-json.sh` |
| A command and a skill cannot share a name | field-notes | CI, or `for c in commands/*.md; do [ -d "skills/$(basename "$c" .md)" ] && echo COLLISION; done` |
| No API key is ever passed on a curl command line | field-notes | CI job "No API key passed on a command line" in `.github/workflows/lint.yml` -- run `act -j validate`, or read the gate and run it |
| No API key is ever written to a file | field-notes | CI job "No API key written to a file" in `.github/workflows/lint.yml`, proven able to fail by `tests/test-lint-gates.sh` (clean 0, violation 1, clean 0) |
| This repo's git history contains no credential-shaped string | release checklist | `tests/test-history-has-no-secrets.sh` — scans every blob on every ref, and proves it can fail by planting one in a throwaway clone |
| `quorum-sanitize` neutralises forged fence markers and strips C0/C1 | adapter-contract, all adapters | `tests/test-sanitize.sh` — 30 fixtures, each one a payload that defeated the previous implementation |
| The key is never **written** to disk at all | field-notes | `tests/test-key-never-on-disk.sh` — enumerates every site that could write one and interrupts a real call mid-flight. The old recipe here said "count files in `$TMPDIR` … delta 0", which was wrong twice: it measured `quorum-status` only, while four of seven sites still wrote a key file; and on macOS `mktemp` reads `DARWIN_USER_TEMP_DIR` and ignores an exported `$TMPDIR`, so the count watched an empty directory and reported delta 0 whatever happened |
| Two delegations never share a worktree or branch | delegate-task, safety-model | the name carries repo, provider, slug, date and an `mktemp -u` suffix; 100 rapid draws produced 100 distinct names |
| `install.sh` never destroys a file it did not create | field-notes | put a regular file at `~/.local/bin/quorum-status`, run `install.sh`, check its sha — it is REFUSED, and the install exits non-zero |
| Every ```bash block in the repo is valid bash | CONTRIBUTING | CI job "Every bash-fenced block is valid bash", or `tests/test-lint-gates.sh` |
| The plugin installs and every component is discovered | README | `claude plugin marketplace add <clone> && claude plugin install quorum@quorum && claude plugin details quorum@quorum` — expect Agents (5) and Skills (9) |
| Commands and skills share one namespace: 9 = 3 skills + 6 commands | field-notes | same command — Claude Code lists them together under "Skills" |
| The plugin route does NOT put Quorum's commands on PATH | field-notes | after installing the plugin only, `command -v quorum-sanitize` finds nothing; the adapters then refuse rather than returning empty |
| Quorum costs ~1,510 tokens of always-on context | README | `claude plugin details quorum@quorum` |
| GLM's live response shapes match what the adapters classify on | glm-agent | measured against api.z.ai: success `content:[thinking,text]` + `end_turn`; bad model -> HTTP 400 with `.error.message`; `max_tokens:600` -> `stop_reason=max_tokens` with 915 chars of text |
| `codex exec review -c sandbox_mode="read-only"` is accepted and takes effect | codex-agent | run it: codex's own banner prints `sandbox: read-only`, exit 0 |
| An adapter refuses rather than reporting `empty` when `quorum-sanitize` is missing | field-notes | `tests/test-adapter-blocks.sh` — all five, run with a PATH that lacks it |
| verify and delegate never write to the user's checkout, and surface it if the provider does | safety-model | `tests/test-worktree-tiers.sh` — all six blocks, with a shim that deliberately escapes the worktree |
| A failed `git worktree add` stops a delegation before the provider runs | safety-model, delegate-task | same test — the worktree's parent is made a regular file so the add genuinely fails |
| Each adapter's runnable block reaches the status its own table requires | adapter-contract, all adapters | `tests/test-adapter-blocks.sh` — extracts the real block from the adapter, runs it against a local mock across six outcomes, and applies the documented table |
| A hostile provider response cannot forge a status line through any adapter | field-notes, safety-model | same test — the fence marker and C1 controls must be gone from `$TEXT` in all five pipelines |
| Every CI gate fires on the violation it claims to catch | field-notes, CONTRIBUTING | `tests/test-lint-gates.sh` — every gate but two, three-phase (clean / injected / reverted); the two it cannot exercise are named in its own output |
| Provider-controlled stderr can forge the envelope's `status:` line unless sanitised | adapter-contract §4, all five adapters, quorum-verify | `tests/test-diagnostics-sanitized.sh` — renders a C1 CSI payload through an ECMA-48 interpreter and asserts it forges `status: ok` when raw and cannot when sanitised |

## Observed — reported, not reproducible from this repo

| Claim | Stated in | Why it cannot be re-run |
|---|---|---|
| A session reported GLM missing after `command -v glm` returned nothing | glm-agent, model-panel, getting-started | Happened in a separate session; no transcript is kept here. The *underlying fact* — that no `glm` binary exists — **is** reproducible: `command -v glm` returns nothing while `quorum-verify glm` passes. |
| Two adapters wrapped their envelope in a code fence | adapter-contract, all adapters | Agent transcripts are not artifacts of this repo. CI now enforces the resulting rule, which is the part that matters. |
| A panel run was terminated at the 600s background ceiling | model-panel | Depends on the caller's harness settings, not on this repo. |
| A panelist claimed "verified via search" and was wrong about a datasheet figure | model-panel, field-notes | A one-off observation about model behaviour; no fixture exists. |
| A vision model described items not present in an image | model-panel, field-notes | Same. |
| `agy --output-format json` was once rejected by `jq` | field-notes | **Did not reproduce.** Three later runs of the identical command produced valid single-line JSON. Demoted from Reproducible after this table's own spot-check caught it. Cause unknown. |

**None of these are load-bearing for safety.** Each motivates a rule that is enforced by
something checkable — the `command -v` anecdote motivates "run the documented invocation,"
which `quorum-verify` does; the code-fence anecdote motivates a rule CI now tests. If an
Observed claim were ever the *only* thing standing behind a safety guarantee, that would be
a defect, and it should be reported as one.

## Adding a claim

If you can make it reproducible, put the command in the first table. If you cannot, put it
in the second and say why. **Do not write an unlabelled anecdote** — a claim that sounds
measured but isn't is worse than no claim, because it spends credibility the repo earned
elsewhere.
