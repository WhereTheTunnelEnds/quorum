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
[the template](skills/add-provider/templates/adapter.md.template). Must satisfy
[the adapter contract](docs/adapter-contract.md): typed status envelope, untrusted-output
delimiters, separate stdout/stderr, and `tools: Bash, Read, Glob, Grep` — never `Write` or
`Edit`.

Only document tiers the provider can actually enforce. A consult-only adapter is a fine
adapter. A local model server has no sandbox and no tool loop; give it a consult tier and
leave the others out rather than inventing them.

**2. `probes/<name>.sh`** — from
[the template](skills/add-provider/templates/probe.sh.template). `probe_broken()` is the
part that matters. It must fail the way the adapter says it fails.

**3a. Passing output from `scripts/quorum-flags`** and a captured
`reference/flags/<name>.txt` — so the next person can see when the vendor renames something
out from under the adapter.

**3. Passing output from `scripts/quorum-verify <name>`** — paste it into the PR body,
including the provider's CLI version. This is the evidence.

**4. A field-notes entry**, if you hit anything surprising. Use the documented format and
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
quorum-status
scripts/quorum-verify --all      # costs a little quota on each provider
```

CI validates frontmatter, JSON, and shell syntax. It cannot validate that you ran anything —
that part is on your honour, and it is the part that matters.
