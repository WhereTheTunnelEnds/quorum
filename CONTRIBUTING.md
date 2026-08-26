# Contributing

The most useful contribution is **a verified adapter for a provider nobody has covered** —
especially a local one (MLX, llama.cpp, vLLM) or another vendor's coding CLI. Second most
useful: a correction to something in [field-notes.md](docs/field-notes.md) that has gone
stale.

## The one rule

> **Everything in this repo is a measurement. Do not submit anything you did not run.**

A plausible adapter is worse than no adapter, because it *looks* tested. Someone will route
a real decision through it and get a confident answer from a model that never ran. If you
cannot run the provider, open an issue describing it instead — that's genuinely useful, and
honest.

## Submitting an adapter

`/quorum:add-provider <name>` does most of this. A complete submission is four things:

**1. `agents/<name>-agent.md`** — from
[the template](skills/build-adapter/templates/adapter.md.template). Must satisfy
[the adapter contract](docs/adapter-contract.md): typed status envelope, untrusted-output
delimiters, separate stdout/stderr, and `tools: Bash, Read, Glob, Grep` — never `Write` or
`Edit`.

Only document tiers the provider can actually enforce. A consult-only adapter is a fine
adapter. A local model server has no sandbox and no tool loop; give it a consult tier and
leave the others out rather than inventing them.

**2. `probes/<name>.sh`** — from
[the template](skills/build-adapter/templates/probe.sh.template). `probe_broken()` is the
part that matters. It must fail the way the adapter says it fails.

**3. Passing output from `scripts/quorum-flags`** and a captured
`reference/flags/<name>.txt` — so the next person can see when the vendor renames something
out from under the adapter.

**4. Passing output from `scripts/quorum-verify <name>`** — paste it into the PR body,
including the provider's CLI version. This is the evidence.

**5. A field-notes entry**, if you hit anything surprising. Use the documented format and
mark anything you inferred rather than observed.

## Submitting a field note

Format is at the [bottom of the file](docs/field-notes.md#adding-an-entry). Requirements:

- **Symptom → cause → fix**, in that order. The symptom comes first because that is what
  the next person will be searching for.
- **A measurement**: exit code, byte count, or response body — taken **unpiped**.
  `cmd | tail` reports `tail`'s status and has already corrupted one entry in this file.
- **The CLI version** you measured against. These change.
- Say explicitly if something is inferred rather than observed. One guess wearing the same
  formatting as a measurement devalues every other entry.
- **Add it to [evidence.md](docs/evidence.md)** — either with the command that re-measures
  it, or in the Observed table with why it cannot be. This repo asks you to paste output
  into a PR; it holds its own prose to the same bar.

Corrections are held to the same bar and are more welcome than additions. If `quorum-verify`
disagrees with a document, the verifier is usually right — measure directly, then fix the
document. That has already happened once, and the correction was more instructive than the
original note.

## Style

The prose here is deliberately explanatory rather than terse. These files are read by models
at dispatch time, and an instruction that says *why* is followed far more reliably than one
that only says what — especially when the model is under pressure to take a shortcut. When
you document a flag, document what goes wrong without it.

Keep the safety language exact. "Enforced" means the harness or the OS refuses. If the
provider merely complies, say **prompt-enforced** and route the tier through a worktree.
That distinction is what everything downstream trusts.

## Not in scope

- **Adapters that act outwardly on a user's accounts** — opening PRs, pushing branches,
  commenting on issues. Read-only GitHub access is in; writing under someone's name is a
  per-task permission a human grants in person.
- **Anything that widens a sandbox to make a task work.** A denial is a finding to report,
  not an obstacle to route around.
- **Fallbacks from an expired subscription to a metered API key.** Report the auth failure;
  don't move the user's work onto a per-token bill without them knowing.

## Testing your change

```bash
./scripts/install.sh
quorum-setup --check             # readiness, non-interactive
scripts/quorum-verify --all      # real calls; costs a little quota on each provider
scripts/quorum-flags             # do the flags the adapters use still exist?
```

**If you touched `quorum-setup`, `quorum-auth`, or `install.sh`, drive the interactive path
too** — `--check` exercises none of it:

```bash
tests/drive-setup.exp            # yes to everything
tests/drive-setup.exp n          # no to everything
```

That test exists because driving the wizard under a real pty found a hang that produced no
output and had to be killed at 400s. It was invisible in review: both code paths read fine.

The suite in `tests/` needs no credentials, no network and no vendor CLIs — it forces every
provider unreachable and serves its own hostile fake provider. Run it:

```bash
for t in tests/*.sh; do bash "$t"; done
```

### If you add a CI gate, add the proof that it fires

CI runs seventeen gates, and each one exists because something got through. A gate nobody
has watched fail is not evidence — it is a green check mark asserting a property nobody
tested. This repo has shipped three gates that could not fail and one that fired on valid
input, and the API-key gate carried two separate bugs that were invisible on the page: a
character class that could not cross a `#`, and a `--` that silently turned every
`--include` into a filename.

So `tests/test-lint-gates.sh` extracts each `run:` body straight out of `.github/workflows/lint.yml`
and runs it three times — clean tree must pass, an injected violation must fail, and after
the revert it must pass again. That third run is what separates a working gate from a
permanently-red one.

**Adding a gate means adding an `inject_<slug>` and `revert_<slug>` to that file.** Without
one, the harness prints your gate as `NO INJECTION DEFINED — this gate is unproven` and
says so in its own summary line. It will not quietly count it as covered.

Three injections have to assemble their forbidden string at runtime, because written out
whole they would trip the gate they test. That is the system working: the gates match on
content, not on a path allowlist.

CI still cannot validate that you *ran* the things above — that part is on your honour, and
it is the part that matters.
