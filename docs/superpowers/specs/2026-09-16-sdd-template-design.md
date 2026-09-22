# A spec-driven development template, and why a gate has to travel with it

> **Private repo names are elided.** Stage 1 was validated against three
> repositories besides quorum. Quorum is public; those three are not, so they
> appear here as `game-repo`, `tracker-repo` and `third-repo`, and local paths
> as `~/projects/`. The substitution is mechanical and the measurements are
> unchanged — only the names are.
**Status:** in progress. 2026-09-16. Stage 1 shipped to last-call on
2026-09-17 as `451b563` (#207) and is green on Linux, macOS and Windows.
Stages 2 and 3 are unbuilt.

## The problem

Spec-driven development lapses silently. Not through carelessness — because
nothing checks it, and the things that look like they check it don't.

Measured in last-call on 2026-09-15:

```
last spec written:      2026-09-10  (chat-dialogue)
last plan written:      2026-09-08  (w2)
commits to main since:  65
```

Sixty-five commits in five days, no new specs, no new plans. Two specs still
marked `proposed` whose work had shipped. `check_spec_status.py` was green
throughout, and correctly so: it validates that the status is one of five
allowed words, and `proposed` is a perfectly valid word. Its own docstring
says it cannot do more.

The chat-dialogue spec is the worked example. It read `proposed` while
patrons had been speaking in the shipped game since #157. What had *not*
shipped was the mechanism the spec actually specified: `Dialogue.select_topic()`
exists at `sim/dialogue.gd:67` with no call site anywhere in `sim/`, and the
`patron_spoke` signal it describes does not exist at all. 165 of that file's
213 written lines are stranded. A stale status line was concealing an orphaned
subsystem, and every gate in the repo was green.

This recurred within a week of being written down. The same checker's
docstring records the previous instance verbatim: *"`bartender-verbs-design.md`
said 'proposed' with all seven of its work items already merged in PRs #11-#19,
because updating the status line is a step nobody's build fails without."*

So the practice does not fail because people stop believing in it. It fails
because nothing fails when it stops.

## What already exists

`tools/check_spec_freshness.py` was built, adversarially reviewed by three
models, and merged to last-call's `main` on 2026-09-16 (#192). It asks GitHub,
per header citation in a non-terminal spec, whether that issue closed as
completed after anyone last revisited the status claim. It runs in `make test`
on three platforms and is green.

This spec is about making that, and the scaffolding around it, installable
into a repo rather than copied by hand.

## Section 1 — What ships

A plugin repo, following quorum's proven shape: versioned releases, a test
suite, lint gates, and a deployed-matches-repo drift check.

```
.claude-plugin/{plugin.json,marketplace.json}
commands/{sdd-init,sdd-survey,sdd-adopt,sdd-enable,sdd-update,sdd-status}.md
templates/                                   what gets vendored
tools/sdd/                                   canonical checkers
tests/                                       quorum-style suite
```

Installed once at user scope; its commands operate on whatever repo you are
standing in.

What lands in a target repo:

```
docs/superpowers/specs/            + TEMPLATE.md   (adopted if present)
docs/superpowers/plans/            + TEMPLATE.md   (adopted if present)
docs/{TEAM,DECISIONS}.md
AGENTS.md                          roster, how work is picked up, DoD
.claude/agents/
  RULES.md, adversary.md, docs-worker.md         always
  <slice>-worker.md                              one per named slice
tools/sdd/
  check_spec_status.py
  check_spec_freshness.py
  check_agent_entrypoints.py
  check_drift.py
  .sdd-manifest.json               version + sha256 of every vendored file
  .sdd-config.json                 repo name, entry-point strategy, runner
.github/workflows/sdd.yml
```

**`sdd.yml` runs on `ubuntu-latest`, including in private repos.** The gates
are pure Python text-checking, so a self-hosted runner buys nothing; the gate
must still work when the k8s pool is having a bad night; and unattended jobs
on that pool have died silently for months at a time. A gate that cannot run
reads as a gate that passed.

## Section 2 — The gates

### What earns a place

A checker ships only if it reads spec-driven *artifacts* rather than the
project's subject matter. Measured against last-call's nine:

| ships | reads | state |
|---|---|---|
| `check_spec_status.py` | `docs/superpowers/specs/` | 227L, 8/8 self-test |
| `check_spec_freshness.py` | same | 708L, 26/26, live on main |
| `check_agent_entrypoints.py` | the agent roster | 187L, 6/6, needs parameterising |
| `check_drift.py` | the manifest | to build |

Staying behind: the balance gate (reads `balance_gate.gd`), the test-count
floor and release gate (read that repo's `ci.yml`), export and artifact
tooling. Those are last-call's subject matter wearing a checker's clothes.

### Every vendored checker must answer `--self-test`

Four of last-call's nine checkers have none — `check_milestone_criteria.py`
(1,238 lines, the largest, and it touches the network),
`check_test_count_floor.py`, `check_tree_untouched.py` and
`check_workflow_step_order.py`. This is in a repo whose Makefile states the
rule in its own words:

> A checker is the one kind of code whose failure mode is silence: if its
> parsing quietly stops matching, every spec passes and nothing says so.

It preaches the rule and complies five times out of nine. So the template
enforces it mechanically rather than in prose: `check_drift.py` refuses any
manifest entry whose checker does not return a passing self-test line.

This is also what excludes `check_milestone_criteria.py` from v1. Milestones
are not game-specific and it would otherwise qualify — it fails the
template's own entry requirement, which is the right reason to leave
something out.

A manifest sha256 proves the *file* did not drift. The self-test proves the
*behaviour* did not. Only the second one matters after a dependency upgrade.

### Hard versus soft is the contract

From the freshness gate's design, made template-wide:

- **Fail** only for what is knowably wrong.
- **Note and pass** for what could not be checked.
- **Never** print an unqualified all-clear when something went unverified.

Both failure modes appeared while building the freshness gate. Its first
draft printed `"no non-terminal spec names a header issue GitHub closed..."`
three lines below a note saying every citation was UNCONFIRMED. A later draft
hard-failed on any path git could not date — which would have failed the
build of anyone *writing* a new spec, since an uncommitted spec has no
history to date.

Get this backwards and you ship either a gate nobody can work alongside, or
one that cannot fail.

### A gate must also refuse to be quietly useless

`check_spec_freshness.py` dates a status line with `git blame`. In a
depth-1 clone, blame attributes every line to HEAD, so every spec reads as
freshly touched, nothing ever fires, and the gate prints its all-clear
forever. Measured in a real shallow clone carrying main's stale spec: it
printed exactly that.

The workflow already sets `fetch-depth: 0`, so this was never broken in CI.
It was worse than broken — correct by inheritance, from a line that exists
for `fetch-tags` and mentions nothing about blame. The checker now asks
`git rev-parse --is-shallow-repository` directly and says out loud that
nothing was checked.

Every gate in the template carries the same obligation: know the conditions
under which your own answer is meaningless, and say so instead of answering.

## Section 3 — Init and retrofit

### Init

A new repo starts compliant, so `/sdd-init` scaffolds and enables enforcement
the same day.

### Retrofit is the whole problem

Surveyed 2026-09-16, four repos, four different shapes:

| repo | `specs/` | agent entry points |
|---|---|---|
| game-repo | 6 | `AGENTS.md` 26KB + 4 symlinks to it |
| quorum | 1 | `AGENTS.md` 9KB + `CLAUDE.md` an 84-byte pointer |
| tracker-repo | 3 | `AGENTS.md` 1.7KB + `CLAUDE.md` 3.9KB, both real |
| third-repo | 3 | none |

**Adopt, never scaffold.** All four already have `docs/superpowers/specs/`.
That path is the superpowers convention, not last-call's invention, which
means this template standardises something four repos already do by accident.
Retrofit records what exists. It must never write a `TEMPLATE.md` over a
directory holding three real specs.

**The gate must be fixed before it is made universal.** Run today against
the three non-source repos, `check_agent_entrypoints.py` fails all three.
One failure is correct; two are the checker's own fault.

Against quorum it prints:

```
FAIL: .cursor/rules/last-call.mdc is missing.
```

Another project's name, asserted inside quorum. The string is hardcoded at
three sites in the checker.

One line above it:

```
FAIL: CLAUDE.md is committed as a regular file, not a symlink to AGENTS.md.
      A copy is a second source of truth and will drift.
```

For tracker-repo that is true — 3,958 bytes of independent architecture notes,
and creating a symlink would destroy them. For quorum it is false. Quorum's
`CLAUDE.md` reads *"See AGENTS.md. One copy, so the two cannot drift."* It is
not a copy; it is a pointer that exists to prevent the very drift the message
accuses it of. The checker cannot tell a pointer from a copy, so it
misdiagnoses a correct repo.

For third-repo it fails at the first hurdle: no `AGENTS.md` at all.

So the template recognises three legitimate strategies, declared in
`.sdd-config.json` rather than assumed:

| strategy | example | verified by |
|---|---|---|
| `symlink` | game-repo | file mode + link target |
| `pointer` | quorum | content references `AGENTS.md` |
| `independent` | tracker-repo | opt out; drift risk recorded |

and `<repo>.mdc` is parameterised from config.

### Retrofit is three staged commands, never one

1. **`/sdd-survey`** — reads only. Reports what exists, which entry-point
   strategy the repo already uses, and exactly what would change.
2. **`/sdd-adopt`** — writes manifest and config to match reality. Adds
   nothing the repo did not already have.
3. **`/sdd-enable`** — installs the gate in advisory mode (notes, exit 0),
   flipping to enforcing only once it is green.

A gate that turns a repo red on contact, when that repo was fine ten seconds
earlier, teaches people to bypass gates. This is why #192 shipped the
freshness gate and the spec fix that makes it pass in a single commit.

### The status vocabulary is not shared

This spec is itself an instance of the problem. Quorum's specs use
`**Status:** design, not implemented.` Last-call's `check_spec_status.py`
allows exactly five values — `proposed`, `accepted`, `in progress`,
`shipped`, `superseded` — and would reject quorum's on sight.

Neither vocabulary is wrong. So the allowed set belongs in
`.sdd-config.json`, seeded from what the repo already uses, not hardcoded in
the checker. `/sdd-survey` reports the existing vocabulary; `/sdd-adopt`
records it.

## What this does not do

- It does not check that a spec is *correct*, only that its status claim has
  not been outlived. The chat-dialogue spec's 165 orphaned lines were found
  by a person reading code, and no gate here would have found them.
- It does not enforce that specs get written. It makes it loud when the ones
  that exist go stale.
- `check_spec_freshness.py` assumes squash merges. A rebase or merge commit
  breaks the SHA-identity suppression — in the direction of over-reporting,
  never under-reporting, which is loud and fixable.

## Implementation order

This is too large for one implementation plan. Three stages, each of which
lands something usable on its own and can be abandoned without stranding the
one before it:

**Stage 1 — make the checkers portable. SHIPPED 2026-09-17, `451b563`.** No plugin, no commands. Parameterise
`check_agent_entrypoints.py` (remove the three hardcoded `last-call` sites,
add the three entry-point strategies, read `.sdd-config.json`), teach
`check_spec_status.py` to read its allowed vocabulary from config, and write
`check_drift.py` with the self-test requirement. Prove it by running all four
against quorum, tracker-repo and third-repo until each either passes or fails for a
true reason. Stage 1 is done when the two false failures documented above are
gone.

**Stage 2 — the plugin skeleton.** `.claude-plugin/`, the manifest format,
`tools/sdd/`, the test suite, `sdd.yml`. `/sdd-survey` only — the read-only
command — because it is the one that cannot damage anything and it is what
makes Stage 1's work visible.

**Stage 3 — the writing commands.** `/sdd-init`, `/sdd-adopt`, `/sdd-enable`,
`/sdd-update`, `/sdd-status`.

Stage 1 is the real work and the only stage whose value does not depend on
the others: portable checkers can be copied by hand into any repo, which is
what happens today anyway.

### What Stage 1 actually cost, recorded for Stage 2's estimate

Seven tasks, fifteen commits, eight defects found in review. Every one was
either in the plan's own reference code or emergent between two individually
correct changes — none came from an implementer misreading a brief. Two are
worth carrying forward as warnings:

- **`blob()` substituting U+FFFD for undecodable bytes** (correct) fed **a
  size check that re-encodes the decoded string** (correct), and together
  they failed a conforming 1024-byte file as "1026 bytes". Neither task's
  review could see it; only the whole-branch pass could.
- **An empty manifest made `check_drift.py` print "0 vendored file(s) …
  pass" and exit 0** — a gate that cannot fail, inside the one file whose
  docstring names silent success as its reason for existing.

The acceptance run also found that quorum passed **vacuously**: its specs are
all at status `design`, so zero were in scope, and the banner was
byte-identical to a run that examined two. That is why the freshness banner
now reports a count.

## Open questions

1. Where does the plugin repo live, and is it public? Quorum is public and
   forced to `ubuntu-latest` because the org runner group sets
   `allows_public_repositories: false`.
2. Does `check_milestone_criteria.py` earn a place in v2 if someone writes
   its self-test, or is it too tied to `docs/milestones.yml`?
3. Should `/sdd-enable` ever flip to enforcing automatically once green, or
   always require a human to make that call?

## A Stage 2 blocker found before Stage 2 started

**The plugin may not be able to find its own files.** `CLAUDE_PLUGIN_ROOT` is
the documented way for a plugin to reference its bundled content. It is
**unset**. Measured again on 2026-09-17 in a live session: `printenv
CLAUDE_PLUGIN_ROOT` returns nothing, while 419 files across the plugins
installed on this machine depend on it, and the official `plugin-dev`
validator checks for it. Quorum's own `docs/field-notes.md:499` records the
same measurement.

Quorum was right to call this low severity *for quorum*: its adapters inline
everything they need, so an unresolvable path costs a wasted turn and nothing
more. **It is not low severity here.** This template's entire purpose is to
put real Python files into someone else's `tools/sdd/`. A command that cannot
locate the bytes it is meant to copy does not degrade — it has no function.
Section 1 lists `tools/sdd/` as plugin payload and never says how those bytes
reach the target repo.

Three routes, to be decided before Stage 2 locks:

1. **Fetch pinned raw GitHub URLs.** Matches quorum's existing workaround and
   resolves from anywhere. Costs a network dependency in `/sdd-init`, and the
   pin has to be the released tag, not `main`, or the vendored copy and the
   manifest that describes it can disagree.
2. **Inline the checker source in the command body** and have it written out
   verbatim. No network, no path resolution — but the command files become
   enormous and the canonical source of a checker becomes prompt text, which
   is exactly the second-source-of-truth problem `check_agent_entrypoints.py`
   exists to prevent.
3. **Use `CLAUDE_PLUGIN_ROOT` with a fallback and a loud self-check.** Follows
   Section 2's note-and-pass contract: say out loud that the path could not be
   resolved rather than silently writing nothing. Note the fallback
   `planning-with-files` uses does not match the real cache layout
   (`cache/<marketplace>/<plugin>/<version>/`), so a wrong fallback is worse
   than none.

Route 1 is the current recommendation, because it is the only one where the
bytes that land in a repo are the bytes a released tag contains, and that is
what `check_drift.py` will hash.

**Related, and the same failure class this project keeps finding:** the
version appears in both `.claude-plugin/plugin.json` and `marketplace.json`
and must be bumped in lockstep. `claude plugin update` decides whether to
re-sync by comparing version **strings, not contents**, so a content change
shipped under an unchanged version is silently undeployable — it looks
updated and is not. Stage 2 needs a gate asserting the two versions match and
that a payload change carries a version bump.

## Carried into Stage 2 from Stage 1's reviews

4. **`REQUIRED` in `check_drift.py` is a lower bound only.** It names the
   four files that must be in the manifest, so shrinking coverage below them
   fails. Nothing makes it *grow*: a fifth checker vendored after that commit
   can still be dropped from the manifest silently, which is the same failure
   class the `REQUIRED` tuple was added to close. The symmetric assertion —
   `set(files) == set(required)` when run against the repo — would close it,
   and Stage 2 is where the vendored set stops being hardcoded anyway.

5. **The vendoring contract lives in a docstring.** `check_drift.py` decides
   a checker passed by looking for the literal string `"assertions passed"`
   in its stdout. Every current checker follows that convention and none
   reuses the phrase in a failure path — verified — but nothing enforces it,
   and a future checker that words success differently gets a false FAIL.
   If the template is going to vendor third-party checkers, this is a
   contract and belongs in the spec, not in a comment.

6. **Should `check_drift.py` cover itself?** It guards four files and is
   guarded by none, so a silent edit to the gate is the one change nothing
   notices. Not circular — you store its digest and any later edit fails
   until someone regenerates deliberately — but it costs a manifest
   regeneration in every commit that touches the gate, and there is a
   bootstrapping wrinkle: the regeneration script and the file being
   regenerated are the same file, so it needs a documented
   edit-then-regenerate-then-verify order rather than one atomic step.
   Note this does **not** subsume question 4: self-hashing would not have
   caught a shrunken manifest.

8. **A spec can go stale by a route the freshness gate cannot see, and one
   did, within an hour of the gate shipping.** The gate's premise is "a
   non-terminal spec whose *header* names an issue GitHub has closed". On
   2026-09-17 the darts spec sat at `accepted` with every deliverable built —
   `spread_deg()` and `throw_error()` in `sim/darts.gd`, dispersion wired into
   `world_sim.gd`, tracking issue #204 closed by PR #209. Both gates passed.
   `check_spec_status` passed because `accepted` is a valid word;
   `check_spec_freshness` examined the spec and found nothing, because its
   header cites only #66 — the issue that tracked the remaining work never
   appeared in the field the gate reads.

   This is not a bug. The gate never claimed to read spec bodies, and
   widening it to every `#N` anywhere in a spec would fire constantly on
   background references. It is a **boundary**, and Stage 2 should decide
   deliberately rather than discover it again: either accept that the header
   is the contract and say so in the template's own docs, or have
   `/sdd-init`'s spec template require a "tracking issues" field that the
   gate reads, so the evidence of completion lands somewhere a machine looks.
   The second is more work and is probably right, because the failure here
   was not that anyone forgot — it was that there was nowhere correct to put
   the information.

7. **A comment describes a generator that does not exist.**
   `check_drift.py` calls the manifest "generated JSON"; no generator is in
   the repo — the script lives only in the Stage 1 plan. Either ship the
   generator in Stage 2 or correct the comment.
