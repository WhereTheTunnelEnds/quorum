# Capability specs: declaring what a panel may do

**Status:** design, not implemented. 2026-09-09.

## The problem

Capability is not a parameter in Quorum today. It is baked into *which command you run*:

```
/quorum:panel     -> consult tier, all providers, fixed
/quorum:delegate  -> delegate tier, one provider
```

Two fixed workflows and no vocabulary for anything in between. There is no way to say
"consult these three, and let them run the test suite but not write", and no way to have
one provider implement while others review. No adapter accepts a caller-supplied
capability: each tier hardcodes its own flags (`--sandbox read-only`,
`--allowedTools "Read,Glob,Grep,Bash"`).

The cost of that is not expressiveness for its own sake. It is that Quorum's one
structural advantage -- driving several vendors' real harnesses at once -- currently
produces only "ask everyone the same question". The breadth is a feature list, not a
mechanism.

## Non-goals

- **Self-hosted parallel inference.** Out of scope. Local models are a privacy/offline
  path, not a breadth path.
- **A CRUD tool for the registry.** Editing a config file is editing a config file.
- **Semantic diff understanding.** Agreement mapping is structural (§7), not a model
  reasoning about whether two diffs "mean" the same thing.

## 1. Stages, roles, providers

Three levels, and each exists because the level below it cannot express something:

- **Stage** -- ordered. Stage N+1 sees stage N's output.
- **Role** -- a *job* plus the capability that job needs, declared once.
- **Providers** -- who staffs the role. Several may staff one role.

```yaml
name: harden-endpoint
stages:
  - name: implement
    role: implementer
    capability: {read: worktree, run: any, write: worktree}
    providers: [codex, copilot, glm, claude-alt]
    fan: independent

  - name: attack
    role: adversary
    capability: consult
    providers: {all: true, except_role: implementer}
```

A role is a job, not a provider. Declaring capability once per role rather than per
provider is what makes `{all: true, except_role: implementer}` expressible -- and that
expression is the enforcement of "never trust one model's output" (§6), rather than a
convention someone has to remember.

It is real YAML. An earlier draft wrote `providers: all except implementer`, which is prose
inside a YAML block: it parses as the string "all except implementer" and means nothing. A
reviewer caught it, and noted the registry example two sections down *was* valid YAML -- two
config languages in one document, which is the tell that the first one was never parsed.

Both existing commands are special cases: a panel is one stage of N consult roles; a
delegation is one stage of one delegate role.

## 2. The capability triple

Current tier names remain, as presets:

| preset | read | run | write |
|---|---|---|---|
| `consult` | repo | -- | -- |
| `verify` | worktree | *allowlist* | -- |
| `delegate` | worktree | any | worktree |

`capability: verify, run: ["pytest -q"]` covers the common case. Anyone needing finer
control writes the triple explicitly. Presets keep the existing vocabulary; the triple is
the escape hatch.

## 3. Three-state resolution

Every (provider, capability) pair resolves to exactly one of:

| state | meaning | example |
|---|---|---|
| **enforced** | boundary is below the process | codex `write: worktree` -- OS sandbox |
| **requested** | a convention the model can violate | copilot `write: worktree` -- measured writes reached the real checkout |
| **impossible** | the provider physically cannot | ollama `read: repo` -- no tool loop exists |

**`impossible` is a hard refusal at generation time.** Ollama and OpenRouter are chat
endpoints with no server-side tool loop; a spec asking them to read the repo must fail
loudly rather than degrade into a model inventing a file it never saw. That is the same
failure class as the probe that reported every success as a failure.

**`requested` is allowed, and stamped into the generated command** so the warning is
visible at use time rather than only at generation time.

This is the part no other multi-model tool can offer -- not for lack of imagination, but
because they all speak to one API shape. Quorum drives seven harnesses with genuinely
different enforcement, so it can say which of your intentions are load-bearing.

## 4. Adapters take a capability, and report what they applied

Each adapter gains a translation layer: the triple in, that vendor's flags out.

| provider | `read: repo` | `run: [...]` | `write: worktree` | mechanism |
|---|---|---|---|---|
| codex | `--sandbox read-only` | `--sandbox workspace-write` | `--sandbox workspace-write` | **OS** |
| copilot | `--plan` | named commands | *not contained* | harness |
| glm / claude-alt | `--allowedTools Read,Glob,Grep` | `+Bash` | `+Write,Edit` | harness |
| antigravity | headless `-p` auto-deny | **impossible** | **impossible** | harness |
| ollama / openrouter | **impossible** | **impossible** | **impossible** | no tool loop |

The envelope gains one line:

```
status: ok
capability: read=repo run=none write=none  enforced=os-sandbox
```

This turns §3 from a generation-time *claim* into a runtime *measurement*. Without it,
"codex is enforced, glm is requested" rests on `safety-model.md` -- a document, which can
drift from the flags the adapter actually passes, silently, every time any of seven
vendors ships a release. Same reasoning as `quorum-flags`: do not trust a static document
about someone else's CLI; check the live thing.

**What this line is NOT: proof.** An adapter reporting its own enforcement is
self-certification. A broken or lying adapter reports `enforced=os-sandbox` while enforcing
nothing, and no caller can tell by reading the envelope. The line records **which flags were
passed**, not **whether the boundary held** -- and those diverge exactly when it matters,
because a vendor can change behaviour while keeping the flag name.

This project has already met that failure: `docs/field-notes.md` records Antigravity's
*documented* behaviour being the opposite of its *measured* behaviour for writes, with the
read-only tier resting on the measured side. A release matching the docs would flip a
read-only tier to a writing one, and this envelope line would keep reporting the same string
throughout.

So the honest framing: the line is **attribution**, not assurance. It closes the gap between
`safety-model.md` and the flags the adapter actually passes -- a real gap, and a cheap one to
close. It does not close the gap between the flags and reality. Only §9.3's canary does that,
and §9.3 cannot run in CI. Anyone reading `enforced=os-sandbox` should read it as "this
adapter asked for an OS sandbox", never as "a write was attempted and refused".

## 5. Concurrency is a provider property

`providers: all` implies fan-out, but not every provider can be fanned out:

```yaml
ollama:     {max_concurrent: 1}   # MEASURED: shares 36GB with the mac-studio CI runner
codex:      {max_concurrent: 4}   # MEASURED: 2 parallel `codex exec`, both rc=0, distinct answers
copilot:    {max_concurrent: 4}   # MEASURED: 2 parallel sessions, both rc=0
claude-alt: {max_concurrent: 4}   # MEASURED: 2 parallel `claude -p`, both rc=0, distinct answers
glm:        {max_concurrent: 4}   # MEASURED: 2 parallel POSTs, both 200, distinct answers
openrouter: {max_concurrent: 8}   # someone else's compute
```

An earlier draft set every CLI provider to 1, reasoning that each owns "one CLI session".
That was asserted, not tested, and it is **measured false for all four**. It matters because
pinning every implementer to 1 collapses the fan-out this design exists to enable. Only
ollama is genuinely single-slot, and for a physical reason: 36GB of unified memory shared
with a CI runner.

**A note on how that measurement nearly went wrong.** The first claude-alt run returned
rc=127. `command -v claude` resolves to an *alias*, not a path; the adapter is right to use
`/usr/bin/which`. A 127 read as "concurrency refused" would have confirmed the wrong answer.
The GLM run then returned HTTP 200 with empty text on both calls, which looks like a
concurrency failure and is not: `max_tokens: 16` was consumed by a `thinking` block, so the
response contained no `text` block for the extractor to find. Both near-misses are the same
shape as v0.1.0's "An HTTP 200 can mean the answer never started".

## 6. Multi-provider implementation

Several providers may staff `implementer`. Each works independently -- separate worktree,
no shared context, same brief.

**This is not N-version programming, and an earlier draft of this document claimed it was.**
N-version programming relies on independent teams whose *design assumptions* differ, so
their bugs decorrelate. These implementers are transformer models trained on overlapping
public code and tuned against similar coding benchmarks. Their failures are correlated to
an unmeasured degree. Seven providers were asked to judge the analogy and returned
7/7 PARTIAL, unanimously naming shared architecture and overlapping training data; the
claim was asserted here with **zero measurement** behind it.

What survives is weaker and still useful: **multi-model consensus without guaranteed bug
decorrelation.** Convergence is evidence of *tractability* -- several models found the same
shape -- not evidence of correctness. Divergence marks where the models' priors differ,
which is often but not always where the problem is hard (§7).

Four is the ceiling, not seven -- `delegate` needs a tool loop, so antigravity, ollama and
openrouter cannot implement. All of them can review.

**Containment: this conflicts with a stated project rule.** The README says an adapter may
only claim a tier it can enforce, and that a worktree is not a sandbox. Of the four possible
implementers only Codex has a write boundary below the process, so staffing `implementer`
with copilot, glm or claude-alt claims a tier they cannot enforce and then leans on
worktrees, which the README explicitly disqualifies as a boundary. That is circular.

Resolution: multi-provider `implementer` requires explicit opt-in per spec
(`uncontained_implementers: true`) and the generator prints which providers are uncontained.
Codex-only implementation needs no opt-in. This does not make it safe; it makes the
violation deliberate and visible instead of buried in a design document.

## 7. Reconciliation: the agreement map

N attempts are only worth running if comparing them is cheaper than reading them. The
output is not N diffs; it is a map of where they agreed.

Structural, not semantic:

1. Normalise each diff -- strip whitespace, sort hunks by file and anchor.
2. Group by touched path, then by hunk anchor.
3. Report per file: how many of N touched it, and whether their hunks are equivalent
   after normalisation.

```
sim/pour.gd        4/4 touched   4/4 equivalent    <- converged; skim
sim/bac.gd         4/4 touched   2/2 split         <- the hard part; read this
tools/check.py     1/4 touched                     <- one model went somewhere alone
```

You read the divergences and the singletons. Convergence is the part you can skim, and it
is most of a typical change. That inversion -- N attempts costing *less* review than one --
is the entire justification for running N.

Deliberately not semantic. A model asked whether two diffs "mean the same thing" is one
more unverified opinion, and this document exists partly to avoid adding those.

## 7b. Partial failure, and what a stage actually hands on

Two gaps a review found, both of which would have surfaced as confusing behaviour rather
than an error.

**A stage does not fail because a provider did.** With four implementers, one timing out or
exhausting quota is normal, not exceptional. The rule:

- A stage **succeeds** if at least `min_success` roles returned `status: ok` (default 2 for
  a multi-provider stage, 1 for single).
- Below that, the stage **fails and the run stops.** It does not proceed with one
  implementation and a reconciliation that cannot reconcile anything.
- Failed roles are **named in the output**, never silently dropped.

**The agreement map must report the denominator it actually had.** If four were dispatched
and three returned, the map says `3/4 dispatched, 3 compared` -- never `3/3`. A map that
renormalises silently turns a partial run into what looks like full agreement, which is the
same shape as this project's `quorum-flags` bug: a tool that checked nothing reporting
success.

**`quorum-auth` readiness is not a dispatch guarantee.** It proves a credential worked at
generation time. Auth can be revoked, a service can be down, a request can time out. The
registry answers "who could be dispatched", never "who will succeed".

**How a diff becomes the next stage's input.** `delegate-task` produces a worktree and a
diff; `model-panel` consumes a text question and requires every panelist to get identical
wording. Those contracts do not compose on their own, and the earlier draft simply said
"stage N+1 sees stage N's output" without saying what that means. It means: the diff is
serialised as text -- `git diff` output plus a list of untracked files, since a delegate that
*adds* a file shows an empty diffstat -- and inlined identically into every reviewer's
prompt. Reviewers get text, not worktree paths, which keeps the consult tier's read-only
contract intact and lets ollama and openrouter review despite having no machine access.

## 8. Registry

`~/.config/quorum/panel.yml`, matching where `quorum-claude-on` already keeps endpoint
presets.

```yaml
# Single-model providers are NOT listed here. quorum-auth already makes a real call per
# provider, so codex / copilot / glm / claude-alt / antigravity are discovered, not declared.
# Only the multi-model providers need entries, because nothing can guess which of
# OpenRouter's ~435 models you want.
panelists:
  - {provider: openrouter, model: poolside/laguna-s-2.1}           # code-specialised lab
  - {provider: openrouter, model: deepseek/deepseek-v4-flash-0731} # $0.07/Mtok, 1.31M ctx
  - {provider: openrouter, model: cohere/north-mini-code:free}     # free
  - {provider: openrouter, model: x-ai/grok-4.20-multi-agent}      # 2.0M ctx tier
  - {provider: ollama,     model: llama3.2:3b}                     # privacy/offline, 1 slot
```

An earlier draft of this section stated the rule and then listed all five single-model
providers by hand in the example immediately below it -- contradicting itself in adjacent
lines. Two reviewers found it independently. The example above is the rule as written.

**Single-model providers are not listed by hand.** They come from `quorum-auth`'s
readiness check, which already makes a real call per provider. A second hand-maintained
list of which providers exist is exactly the drift
`tests/test-auth-covers-every-adapter.sh` was written to stop.

Model choice is per question for the multi-model providers, so only those need explicit
entries. Selection criterion is **decorrelated failure, not benchmark rank**: a second
frontier model from a lab already reachable adds a vote, not information. Paying OpenRouter
for openai, google, anthropic or z-ai models buys a seat already owned.

## 9. Testing

Per this repo's rule, a gate nobody has watched fail is not evidence.

**9.1 `impossible` refuses.** Feed a spec asking ollama to write. Assert non-zero, and
that the message names the reason (no tool loop).

**9.2 `providers: all` cannot check nothing.** If the registry resolves to zero reachable
panelists, exit non-zero. Directly from `quorum-flags`' own scar tissue: `quorum-flags &&
echo current` printed `current` on a machine that verified nothing.

**9.3 The canary write.** For every provider declaring `write: none`, dispatch a task that
explicitly instructs it to create a canary file, then check the filesystem AND the model's
own transcript:

```
codex    canary absent   + transcript shows a blocked attempt   -> enforced
copilot  canary PRESENT                                          -> correctly labelled requested
glm      canary PRESENT                                          -> correctly labelled requested
antigravity canary absent + transcript shows a DENIAL record     -> enforced
```

**The filesystem alone proves nothing, and an earlier draft of this section relied on it
alone.** "Canary absent" has two causes that look identical from outside: the boundary
refused the write, or the model read its own instructions and never attempted one. Only the
first is enforcement. So the test requires *evidence of an attempt* in the provider's own
output -- an error, a refusal, a permission-denial record -- and reports **inconclusive**
rather than "enforced" when the model simply declined. Claude-alt is the easiest case here:
it records denials in `.permission_denials`, which is machine-readable.

The test asserts the **classification**, not that everyone is safe. A provider labelled
`enforced` that lets the canary through is a regression. One labelled `requested` that blocks
it has improved, and the table is stale in your favour.

**9.3 CANNOT RUN IN CI, and that is a real limitation, not a footnote.** It needs all vendor
CLIs installed, every credential live, and real quota spent, and its expected result differs
per provider. CI has none of that. So the single test that would catch a vendor silently
changing its enforcement is the one test that never gates a merge.

| test | runs in CI? |
|---|---|
| 9.1 `impossible` refuses | yes -- pure resolution logic, no network |
| 9.2 `all` cannot check nothing | yes |
| 9.3 canary write | **no** -- needs live vendors, credentials and quota |
| 9.4 concurrency limits | yes, with stub providers |
| 9.5 agreement mapping deterministic | yes -- fixed inputs |

Four of five gate merges. 9.3 is a **manual verification run after any vendor update**, and
calling it a test alongside the others would repeat this project's own documented mistake of
letting a check that declines to run report the same green as a check that passed.

**9.4 Concurrency limits hold.** Assert two ollama roles never run at once.

**9.5 Agreement mapping is deterministic.** Same N diffs in, same map out. Feed known
inputs including the degenerate cases: all identical, all different, one empty.

## 10. Open questions

1. ~~Where do generated commands live?~~ **Answered: neither -- do not cache them.**
   Plugin-owned needs a version bump on every generation, because `claude plugin update`
   compares version strings and not file contents, so a generated command silently fails to
   deploy. User-owned leaves a stale command in `~/.claude/commands/` that still carries the
   old capability envelope after the spec changes -- a permissions bug the design cannot
   detect. Both options are broken, which is the signal that caching is the mistake. Derive
   the invocation from the spec at run time instead.
2. **Does `fan: independent` need a shared-context variant?** Independence is the point,
   so probably not, but a "second opinion with the first one visible" mode is cheaper and
   sometimes what you want.
3. **Cost ceiling.** Four implementers plus six reviewers is ten dispatches. Subscriptions
   absorb it; OpenRouter bills per token. A spec-level budget cap may be needed.
