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
| Every flag the adapters use still exists | model-panel, adapters | `quorum-flags` |
| `quorum-flags` exits 0 on a healthy machine and 1 on a real drift | field-notes | `quorum-flags; echo $?`, then invent a flag in an adapter and re-run |
| The setup wizard completes without hanging | getting-started | `tests/drive-setup.exp n` |
| `quorum-status` exits 0 when a provider is reachable, 1 when none are | — | `quorum-status; echo $?` |
| `quorum-verify` exits non-zero when it verified **nothing** | adapter-contract | `quorum-verify nosuchprovider; echo $?` |
| The probe image really is red-circle / green-square / yellow-cross / blue-triangle | probe-checklist | `make-probe-image` then open it |
| `prep-image` fails cleanly with no converter present | porting docs | `env -i HOME="$HOME" PATH=/usr/bin:/bin prep-image x.png` |
| Ollama's `/v1` endpoint **discards** `options.num_ctx` while `/api/chat` honours it | field-notes | see the two-curl comparison in that entry |
| Antigravity's headless mode auto-denies `write_file` | safety-model, field-notes | `cd $(mktemp -d) && agy -p "create a file test.txt containing X"` |
| Adapters declare no write tools | safety-model | CI, or `grep '^tools:' agents/*.md` |
| GLM reports a **truncated** answer as `error`, not `ok` | glm-agent, troubleshooting | ask GLM to count 1–400 at `max_tokens:600`; expect `stop_reason: max_tokens` with text |
| GLM's 64000 / `-m 900` pair completes a 249 KB input | glm-agent | feed ~250 KB of source and ask for an exhaustive review; expect `end_turn` under 900 s |
| `quorum-status --json` stays valid JSON under hostile provider text | quorum-status | `tests/test-quorum-status-json.sh` |
| A command and a skill cannot share a name | field-notes | CI, or `for c in commands/*.md; do [ -d "skills/$(basename "$c" .md)" ] && echo COLLISION; done` |
| No API key is ever passed on a curl command line | field-notes | CI, or `grep -rnE '^[^#]*-H "Authorization: Bearer' --exclude=field-notes.md .` |

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
