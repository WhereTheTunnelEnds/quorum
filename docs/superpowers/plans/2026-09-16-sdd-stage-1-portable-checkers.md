# SDD Stage 1 — Portable Checkers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make last-call's four SDD checkers repo-agnostic, so they pass or
truly-fail against quorum, 2ATracker and halves instead of failing for
last-call-specific reasons.

**Architecture:** A single optional `.sdd-config.json` at repo root supplies
the three things currently hardcoded: the canonical rules filename, the map of
agent entry points to their strategy, and the allowed spec-status vocabulary.
When the file is absent every default equals last-call's behaviour today, so
this change is invisible to last-call until someone writes a config.

**Tech Stack:** Python 3 standard library only. No pytest — this repo's
checkers carry built-in `--self-test`, and the plan follows that convention.

**Spec:** `docs/superpowers/specs/2026-09-16-sdd-template-design.md` (in
quorum)

## Global Constraints

- **The code changes land in last-call**, at
  `~/PycharmProjects/dive-bar-sim`, not in quorum. Only this plan and its
  spec live in quorum. Check `git remote get-url origin` before your first
  commit; it must end in `last-call.git`.
- **Standard library only.** No new dependencies. These run on three
  platforms including a Windows runner.
- **Every checker keeps a passing `--self-test`.** It is the template's
  entry requirement and `check_drift.py` will enforce it in Task 5.
- **Defaults must preserve today's behaviour exactly.** `make workflows` in
  last-call must stay green at every commit, with no `.sdd-config.json`
  present in that repo.
- **Never create a symlink in a test.** Windows runners lack the privilege
  (WinError 1314); this is why `evaluate()` is pure and takes an index dict.
- Git index mode for a symlink is `120000`; for a regular file `100644`.
- Run the whole gate with `make workflows` from the repo root.

---

### Task 1: The config loader

**Files:**
- Create: `tools/sdd_config.py`
- Test: self-test inside `tools/sdd_config.py`

**Interfaces:**
- Produces: `load(root=".") -> dict` returning keys `canonical` (str or
  None), `entrypoints` (dict path->strategy), `spec_statuses` (list of str).
  Never raises; a malformed file returns `(defaults, error_string)`.
- Produces: `DEFAULTS` dict, and `CONFIG_NAME = ".sdd-config.json"`.

- [ ] **Step 1: Write the failing self-test**

Create `tools/sdd_config.py` containing only this:

```python
#!/usr/bin/env python3
"""Per-repo settings for the SDD checkers, with last-call's values as defaults.

Three things were hardcoded across two checkers: the canonical rules
filename, which agent entry points a repo wants, and which status words a
spec may use. None of them are universal -- quorum uses a pointer file rather
than symlinks, 2ATracker's CLAUDE.md is independent content, halves has no
AGENTS.md at all, and quorum's specs say "design" where last-call's say
"proposed".

The file is optional. With no .sdd-config.json every value below equals
last-call's behaviour before this existed, so adding this module changes
nothing until a repo opts in.

Run: sdd_config.py --self-test
"""
import copy
import json
import os
import sys

CONFIG_NAME = ".sdd-config.json"

DEFAULTS = {
    "canonical": "AGENTS.md",
    "entrypoints": {
        "CLAUDE.md": "symlink",
        "GEMINI.md": "symlink",
        "AGENT.md": "symlink",
        ".cursorrules": "symlink",
        ".cursor/rules/last-call.mdc": "symlink",
    },
    "spec_statuses": [
        "proposed", "accepted", "in progress", "shipped", "superseded",
    ],
    # Which of those mean "work is still open". check_spec_freshness.py only
    # examines specs in this set, so a repo whose vocabulary is ["design"]
    # would have every spec silently skipped if this stayed hardcoded --
    # the precise failure that gate exists to prevent.
    "non_terminal_statuses": ["proposed", "accepted", "in progress"],
}

STRATEGIES = ("symlink", "pointer", "independent")


def load(root="."):
    raise NotImplementedError


def _self_test():
    checks = 0
    failures = []

    def expect(name, cond, detail=""):
        nonlocal checks
        checks += 1
        if not cond:
            failures.append(name + (": " + detail if detail else ""))

    cfg, err = load("/nonexistent-repo-path-for-self-test")
    expect("absent-config-yields-defaults",
           err is None and cfg == DEFAULTS,
           "got err=%r cfg-differs=%r" % (err, cfg != DEFAULTS))

    for f in failures:
        print("SELF-TEST FAIL: %s" % f, file=sys.stderr)
    if failures:
        print("\n%d/%d self-test assertion(s) failed." % (len(failures), checks),
              file=sys.stderr)
        return 1
    print("self-test: %d/%d assertions passed" % (checks, checks))
    return 0


if __name__ == "__main__":
    sys.exit(_self_test() if "--self-test" in sys.argv[1:] else 0)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 tools/sdd_config.py --self-test`
Expected: `NotImplementedError` traceback.

- [ ] **Step 3: Implement `load`**

Replace the `def load` stub with:

```python
def load(root="."):
    """(config, error). Missing file is not an error -- it means "defaults"."""
    path = os.path.join(root, CONFIG_NAME)
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
    except FileNotFoundError:
        # deepcopy, not dict(): a shallow copy shares the nested entrypoints
        # dict and both status lists with the module-level constant, so one
        # caller doing cfg["entrypoints"]["X"] = ... would corrupt DEFAULTS
        # for every later load() in the process. Later tasks pass this config
        # around freely, which puts that trap directly in their path.
        return copy.deepcopy(DEFAULTS), None
    except (OSError, ValueError) as exc:
        # A broken config must not be read as "no config". Silently falling
        # back to defaults would make a typo look like a passing repo.
        return copy.deepcopy(DEFAULTS), "%s is unreadable (%s)" % (path, exc)

    if not isinstance(raw, dict):
        return copy.deepcopy(DEFAULTS), "%s must contain a JSON object" % path

    cfg = copy.deepcopy(DEFAULTS)
    if "canonical" in raw:
        cfg["canonical"] = raw["canonical"]
    if "spec_statuses" in raw:
        cfg["spec_statuses"] = list(raw["spec_statuses"])
    if "non_terminal_statuses" in raw:
        cfg["non_terminal_statuses"] = list(raw["non_terminal_statuses"])
    if "entrypoints" in raw:
        eps = raw["entrypoints"]
        if not isinstance(eps, dict):
            return copy.deepcopy(DEFAULTS), "%s: entrypoints must be an object" % path
        # Name the offending VALUE, not just the key. A message that says
        # "CLAUDE.md has a bad strategy" without quoting the typo makes the
        # reader go and look; quoting it makes the fix obvious.
        bad = {k: v for k, v in eps.items() if v not in STRATEGIES}
        if bad:
            return copy.deepcopy(DEFAULTS), (
                "%s: %s -- not one of %s"
                % (path,
                   "; ".join("%s declares strategy %r" % (k, v)
                             for k, v in sorted(bad.items())),
                   list(STRATEGIES)))
        cfg["entrypoints"] = dict(eps)
    return cfg, None
```

- [ ] **Step 4: Run it to verify it passes**

Run: `python3 tools/sdd_config.py --self-test`
Expected: `self-test: 1/1 assertions passed`

- [ ] **Step 5: Add the remaining assertions**

Insert these before the `for f in failures:` loop:

```python
    import tempfile

    def with_config(obj):
        d = tempfile.mkdtemp()
        with open(os.path.join(d, CONFIG_NAME), "w", encoding="utf-8") as fh:
            if isinstance(obj, str):
                fh.write(obj)
            else:
                json.dump(obj, fh)
        return d

    cfg, err = load(with_config({"entrypoints": {"CLAUDE.md": "pointer"}}))
    expect("entrypoints-replace-rather-than-merge",
           err is None and cfg["entrypoints"] == {"CLAUDE.md": "pointer"},
           "a repo that wants ONE entry point must not inherit five: %r"
           % (cfg["entrypoints"],))

    cfg, err = load(with_config({"spec_statuses": ["design"],
                                 "non_terminal_statuses": ["design"]}))
    expect("spec-statuses-override",
           err is None and cfg["spec_statuses"] == ["design"])
    expect("non-terminal-statuses-override",
           err is None and cfg["non_terminal_statuses"] == ["design"],
           "a repo whose only status is 'design' must not have every spec "
           "skipped by the freshness gate")
    expect("unspecified-keys-keep-defaults",
           cfg["canonical"] == "AGENTS.md")

    cfg, err = load(with_config("{not json"))
    expect("malformed-config-is-an-error-not-a-silent-default",
           err is not None and "unreadable" in err,
           "got %r" % (err,))

    cfg, err = load(with_config({"entrypoints": {"CLAUDE.md": "symlnk"}}))
    expect("unknown-strategy-is-rejected",
           err is not None and "symlnk" in err, "got %r" % (err,))

    cfg, err = load(with_config({"canonical": None, "entrypoints": {}}))
    expect("a-repo-may-declare-it-has-no-entry-points",
           err is None and cfg["canonical"] is None and cfg["entrypoints"] == {})

    # The returned config must be the caller's to mutate. None of the
    # assertions above touch a nested structure, which is exactly how a
    # shallow copy survived the first round of this task.
    before = copy.deepcopy(DEFAULTS)
    cfg, _ = load("/nonexistent-repo-path-for-self-test")
    cfg["entrypoints"]["CLAUDE.md"] = "MUTATED"
    cfg["spec_statuses"].append("MUTATED")
    expect("mutating-a-returned-config-does-not-corrupt-DEFAULTS",
           DEFAULTS == before,
           "load() handed out a reference into a process-wide singleton")
    again, _ = load("/nonexistent-repo-path-for-self-test")
    expect("a-later-load-is-unaffected-by-an-earlier-caller",
           again["entrypoints"]["CLAUDE.md"] == "symlink"
           and "MUTATED" not in again["spec_statuses"])
```

- [ ] **Step 6: Run to verify all pass**

Run: `python3 tools/sdd_config.py --self-test`
Expected: `self-test: 10/10 assertions passed`

- [ ] **Step 7: Wire into the Makefile and commit**

In `Makefile`, in the `workflows:` target, directly above the
`check_spec_status.py --self-test` line, add:

```makefile
	@$(PYYAML) tools/sdd_config.py --self-test
```

Run: `make workflows` — expected: exit 0.

```bash
git add tools/sdd_config.py Makefile
git commit -m "Per-repo config for the checkers, defaulting to today's behaviour"
```

---

### Task 2: Entry points come from config

**Files:**
- Modify: `tools/check_agent_entrypoints.py:34-44` (constants), `:71-97`
  (`evaluate`), `:100-128` (`check`), `:131-177` (`self_test`)

**Interfaces:**
- Consumes: `sdd_config.load` from Task 1.
- Produces: `evaluate(entries, canonical_present, config)` — note the new
  third parameter; Task 3 extends its body further.

- [ ] **Step 1: Write the failing self-test**

In `self_test()`, replace the line building `good` with:

```python
    cfg = dict(sdd_config.DEFAULTS)
    good = {name: (SYMLINK_MODE, "AGENTS.md") for name in cfg["entrypoints"]}
    good[".cursor/rules/last-call.mdc"] = (SYMLINK_MODE, "../../AGENTS.md")
```

and add this case to `cases`:

```python
    # A repo that wants only CLAUDE.md must not be told four files are
    # missing. Measured against quorum, which uses no Cursor files at all
    # and was failing for four entry points it never asked for.
    one = {"canonical": "AGENTS.md",
           "entrypoints": {"CLAUDE.md": "symlink"},
           "spec_statuses": list(sdd_config.DEFAULTS["spec_statuses"])}
    cases.append(("only-configured-entrypoints-are-required",
                  evaluate({"CLAUDE.md": (SYMLINK_MODE, "AGENTS.md")}, True, one),
                  False))
```

Add `import sdd_config` beneath the existing imports.

- [ ] **Step 2: Run to verify it fails**

Run: `python3 tools/check_agent_entrypoints.py --self-test`
Expected: FAIL — `evaluate()` takes 2 positional arguments but 3 were given.

- [ ] **Step 3: Thread config through**

Change the signature and body of `evaluate`:

```python
def evaluate(entries, canonical_present, config):
    """Pure decision logic, so the self-test needs no repo and no symlinks."""
    problems = []
    canonical = config["canonical"]
    entrypoints = config["entrypoints"]
    if canonical is None or not entrypoints:
        return problems  # this repo has not adopted entry points; Task 4 reports it
    if not canonical_present:
        return ["%s is not tracked; it is what everything else points at."
                % canonical]
    for name, strategy in entrypoints.items():
        who = AGENT_FOR.get(name, "an agent")
        entry = entries.get(name)
        if entry is None:
            problems.append(
                "%s is missing. %s looks for it and would find no rules at all."
                % (name, who))
            continue
        mode, target = entry
        if mode != SYMLINK_MODE:
            problems.append(
                "%s is committed as a regular file (mode %s), not a symlink to "
                "%s. A copy is a second source of truth and will drift -- that "
                "has already happened once in this repo." % (name, mode, canonical))
            continue
        resolved = posixpath.normpath(
            posixpath.join(posixpath.dirname(name), target.strip()))
        if resolved != canonical:
            problems.append(
                "%s points at %s, not %s." % (name, resolved, canonical))
    return problems
```

Replace the `ENTRYPOINTS` constant with a name-to-agent lookup that no longer
drives the check:

```python
# Filename -> the agent that looks for it, for the error message only. Which
# files a repo actually wants comes from .sdd-config.json; this is just how
# to describe them.
AGENT_FOR = {
    "CLAUDE.md": "Claude Code",
    "GEMINI.md": "Gemini CLI",
    "AGENT.md": "Amp and others using the singular spelling",
    ".cursorrules": "Cursor (legacy location)",
}
```

Delete the `CANONICAL = "AGENTS.md"` constant and the
`".cursor/rules/last-call.mdc"` key. That is the first of the three
hardcoded sites.

- [ ] **Step 4: Update `check()` to load config**

Replace the body of `check`:

```python
def check(root="."):
    config, cfg_err = sdd_config.load(root)
    if cfg_err is not None:
        print("FAIL: %s" % cfg_err, file=sys.stderr)
        return 1
    canonical = config["canonical"]
    entrypoints = config["entrypoints"]
    if canonical is None or not entrypoints:
        print("agent entry points: not configured for this repo "
              "(no canonical file or no entry points in %s) -- NOT checked."
              % sdd_config.CONFIG_NAME)
        return 0

    wanted = list(entrypoints) + [canonical]
    entries, err = git_index(root, wanted)
    if err is not None:
        print("FAIL: could not read the git index in %s: %s" % (root, err),
              file=sys.stderr)
        return 1

    canonical_entry = entries.get(canonical)
    resolved = {}
    for name in entrypoints:
        e = entries.get(name)
        if e is None:
            continue
        mode, sha = e
        resolved[name] = (mode, blob(root, sha))

    problems = evaluate(resolved, canonical_entry is not None, config)
    if canonical_entry is not None and canonical_entry[0] == SYMLINK_MODE:
        problems.insert(0, "%s is itself a symlink; it must be the real file."
                        % canonical)

    if problems:
        for p in problems:
            print("FAIL: %s" % p, file=sys.stderr)
        return 1
    print("agent entry points: %d filename(s) satisfy their declared strategy "
          "against %s in git" % (len(entrypoints), canonical))
    return 0
```

Note `blob()` is now called for every present entry point, not only symlinks —
Task 3 needs the content of regular files to tell a pointer from a copy.

**That widening makes `blob()` unsafe as written, so fix it in the same
step.** It runs `subprocess.run(..., text=True)`, which decodes UTF-8 with
strict errors. Until now it only ever saw symlink targets: short relative
paths, always decodable. Pointed at arbitrary file content, one bad byte
raises `UnicodeDecodeError` and the checker dies with a traceback instead of
a clean `FAIL:` line — on precisely the repos this stage exists to serve,
since a pointer file is a regular file. Add `errors="replace"` to that call:

```python
def blob(root, sha):
    # errors="replace" because this is no longer only called on symlink
    # targets. A replacement character cannot forge a valid target or the
    # canonical filename, so nothing downstream is weakened by it -- whereas
    # an undecodable byte would otherwise crash the run.
    out = subprocess.run(
        ["git", "-C", root, "cat-file", "blob", sha], capture_output=True,
        text=True, errors="replace"
    )
    return out.stdout if out.returncode == 0 else ""
```

Keep the existing comment above the `posixpath.normpath(posixpath.join(...))`
line in `evaluate()` — `# A symlink blob is its target, resolved relative to
the link's dir.` Task 3 edits that line, and the relative resolution is not
obvious cold.

- [ ] **Step 5: Fix the remaining self-test cases**

Every existing `evaluate(x, y)` call in `self_test()` becomes
`evaluate(x, y, cfg)`. There are six.

- [ ] **Step 6: Run to verify all pass**

Run: `python3 tools/check_agent_entrypoints.py --self-test`
Expected: `self-test: 7/7 assertions passed`

Run: `python3 tools/check_agent_entrypoints.py .`
Expected: exit 0, `agent entry points: 5 filename(s) satisfy...`

- [ ] **Step 7: Commit**

```bash
git add tools/check_agent_entrypoints.py
git commit -m "Which entry points a repo wants is the repo's business"
```

---

### Task 3: Pointer and independent strategies

**Files:**
- Modify: `tools/check_agent_entrypoints.py` — `evaluate()` from Task 2

**Interfaces:**
- Consumes: `evaluate(entries, canonical_present, config)` from Task 2, where
  `entries` maps path -> `(mode, blob_content)`.
- Produces: `POINTER_MAX_BYTES` constant.

- [ ] **Step 1: Write the failing self-tests**

Add to `cases` in `self_test()`:

```python
    # quorum: an 84-byte CLAUDE.md reading "See AGENTS.md. One copy, so the
    # two cannot drift." The old checker called this a drift-prone copy. It
    # is the opposite of one.
    ptr_cfg = {"canonical": "AGENTS.md",
               "entrypoints": {"CLAUDE.md": "pointer"},
               "spec_statuses": []}
    # The real file writes "AGENTS.md" as a markdown link. It is spelled
    # plainly here because quorum's own "Links to local files resolve" gate
    # scans inside fenced code blocks and would resolve it against this
    # plan's directory. The check is a substring test for the canonical
    # name, so both spellings exercise it identically.
    pointer = {"CLAUDE.md": ("100644",
                             "# Working on Quorum\n\n"
                             "See AGENTS.md. One copy, so the "
                             "two cannot drift.\n")}
    cases.append(("a-pointer-file-is-not-a-copy",
                  evaluate(pointer, True, ptr_cfg), False))

    # 2ATracker: 3958 bytes of independent architecture notes that never
    # mention AGENTS.md. Declared "pointer" by mistake, this must fail.
    fat = {"CLAUDE.md": ("100644", "# 2ATracker\n" + ("x" * 4000))}
    cases.append(("a-copy-declared-as-a-pointer-still-fails",
                  evaluate(fat, True, ptr_cfg), True))

    # ...and declared "independent", it is the repo's accepted risk.
    ind_cfg = {"canonical": "AGENTS.md",
               "entrypoints": {"CLAUDE.md": "independent"},
               "spec_statuses": []}
    cases.append(("independent-is-opt-out-not-failure",
                  evaluate(fat, True, ind_cfg), False))

    # A pointer that is short but never names the canonical file points
    # nowhere.
    mute = {"CLAUDE.md": ("100644", "# Notes\n\nnothing here\n")}
    cases.append(("a-short-file-that-names-nothing-is-not-a-pointer",
                  evaluate(mute, True, ptr_cfg), True))

    # A symlink where a pointer was declared is fine -- it is strictly
    # stronger, and failing it would punish a repo for being more correct.
    linked = {"CLAUDE.md": (SYMLINK_MODE, "AGENTS.md")}
    cases.append(("a-symlink-satisfies-a-pointer-declaration",
                  evaluate(linked, True, ptr_cfg), False))
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 tools/check_agent_entrypoints.py --self-test`
Expected: FAIL on `a-pointer-file-is-not-a-copy` — the current code rejects
any non-symlink.

- [ ] **Step 3: Implement the strategies**

Add the constant near `SYMLINK_MODE`:

```python
# A pointer refers the reader to the canonical file. A copy reproduces it.
# The discriminator is both signals together: it must name the canonical
# file AND be too small to be a second rulebook. Measured: quorum's pointer
# is 84 bytes and names AGENTS.md once; 2ATracker's independent CLAUDE.md is
# 3958 bytes and names it zero times.
POINTER_MAX_BYTES = 1024
```

Replace the body of the `for name, strategy in entrypoints.items():` loop:

```python
    for name, strategy in entrypoints.items():
        who = AGENT_FOR.get(name, "an agent")
        if strategy == "independent":
            continue  # declared as its own document; drift accepted on record
        entry = entries.get(name)
        if entry is None:
            problems.append(
                "%s is missing. %s looks for it and would find no rules at all."
                % (name, who))
            continue
        mode, content = entry
        if mode == SYMLINK_MODE:
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(name), content.strip()))
            if resolved != canonical:
                problems.append(
                    "%s points at %s, not %s." % (name, resolved, canonical))
            continue
        if strategy == "symlink":
            problems.append(
                "%s is committed as a regular file (mode %s), not a symlink to "
                "%s. A copy is a second source of truth and will drift -- that "
                "has already happened once in this repo." % (name, mode, canonical))
            continue
        # strategy == "pointer"
        size = len(content.encode("utf-8"))
        if canonical not in content:
            problems.append(
                "%s is declared a pointer to %s but never names it, so a "
                "reader who opens it is not sent anywhere."
                % (name, canonical))
        elif size > POINTER_MAX_BYTES:
            problems.append(
                "%s is declared a pointer to %s but is %d bytes (limit %d). "
                "A file that large is a second rulebook that happens to cite "
                "the first, and it will drift." % (name, canonical, size,
                                                   POINTER_MAX_BYTES))
```

- [ ] **Step 4: Run to verify all pass**

Run: `python3 tools/check_agent_entrypoints.py --self-test`
Expected: `self-test: 12/12 assertions passed`

Run: `python3 tools/check_agent_entrypoints.py .`
Expected: exit 0 — last-call still uses all-symlinks and has no config.

- [ ] **Step 5: Commit**

```bash
git add tools/check_agent_entrypoints.py
git commit -m "A pointer is not a copy, and the checker can now tell"
```

---

### Task 4: Status vocabulary from config

**Files:**
- Modify: `tools/check_spec_status.py:27` (constant), `:52-98`
  (`check_spec`), `:101-111` (`main`), `:221-227` (entry block)

**Interfaces:**
- Consumes: `sdd_config.load` from Task 1.
- Produces: `check_spec(path, lines, allowed)` — new third parameter.

- [ ] **Step 1: Write the failing self-test**

Add to `_self_test()`:

```python
    # quorum's specs say "**Status:** design, not implemented." The extractor
    # splits at the first comma, so the value is "design" -- verified against
    # the real header. Neither vocabulary is wrong, so the allowed set is the
    # repo's to declare.
    expect(
        "a-repo-may-declare-its-own-vocabulary",
        ["# Spec\n", "\n", "**Status:** design, not implemented. 2026-09-09.\n"],
        (),
        allowed={"design"},
    )
    expect(
        "a-word-outside-the-declared-set-still-fails",
        ["# Spec\n", "\n", "**Status:** design\n"],
        ("not one of",),
        allowed={"proposed"},
    )
```

Change the local `expect` helper in `_self_test` to accept and forward the
keyword:

```python
    def expect(name, lines, needles, allowed=None):
        nonlocal checks
        checks += 1
        problems = check_spec("synthetic.md", lines,
                              allowed or ALLOWED_STATUSES)
        ...
```

(keep the existing body below that line unchanged, and add `allowed=None` to
every existing call site by leaving them as they are — the default covers
them).

- [ ] **Step 2: Run to verify it fails**

Run: `python3 tools/check_spec_status.py --self-test`
Expected: FAIL — `check_spec()` takes 2 positional arguments but 3 were given.

- [ ] **Step 3: Thread `allowed` through**

Change the signature to `def check_spec(path: str, lines: list, allowed) -> list:`
and replace both uses of `ALLOWED_STATUSES` inside it with `allowed`:

```python
    if status_value not in allowed:
        problems.append(
            f"{path}:{status_line_no}: `**Status:** {status_value}` is not "
            f"one of {sorted(allowed)}."
        )
```

Keep the module-level `ALLOWED_STATUSES` as the default — it is what
`sdd_config.DEFAULTS["spec_statuses"]` mirrors, and the self-test uses it.

- [ ] **Step 4: Load config in `main`**

```python
def main(path: str, allowed=None) -> int:
    if allowed is None:
        allowed = ALLOWED_STATUSES
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    problems = check_spec(path, lines, allowed)
```

and in the `if __name__ == "__main__":` block, above the `paths` line:

```python
    import sdd_config
    _cfg, _err = sdd_config.load(".")
    if _err is not None:
        print("FAIL: %s" % _err, file=sys.stderr)
        sys.exit(1)
    _allowed = set(_cfg["spec_statuses"])
    paths = sys.argv[1:] or ["docs/superpowers/specs/*.md"]
    sys.exit(max(main(p, _allowed) for p in paths))
```

- [ ] **Step 5: Run to verify all pass**

Run: `python3 tools/check_spec_status.py --self-test`
Expected: `self-test: 10/10 assertions passed`

Run: `python3 tools/check_spec_status.py docs/superpowers/specs/*.md`
Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add tools/check_spec_status.py
git commit -m "The status vocabulary belongs to the repo, not the checker"
```

---

### Task 4b: The freshness gate's non-terminal set

Found by the pre-flight scan, not present in the first draft of this plan.
`check_spec_freshness.py` hardcodes `NON_TERMINAL_STATUSES` at line 23 and
tests against it at lines 72 and 257. A repo whose vocabulary is `["design"]`
has every spec fall outside that set, so the gate skips them all and prints
its all-clear. That is the same silent-skip failure the gate was built to
stop, one level up.

**Files:**
- Modify: `tools/check_spec_freshness.py:23` (constant), `:72`
  (`evaluate`), `:257` (`check_spec`), and the `main()` entry block

**Interfaces:**
- Consumes: `sdd_config.load` from Task 1, key `non_terminal_statuses`.
- Produces: `evaluate(..., non_terminal=None)` and
  `check_spec(path, lines, slug, shallow=False, non_terminal=None)`, both
  defaulting to the module constant so existing callers are unaffected.

- [ ] **Step 1: Write the failing self-test**

Add to `_self_test()`:

```python
    # A repo whose vocabulary is ["design"] must still be checked. Before
    # this, "design" was outside NON_TERMINAL_STATUSES and every such spec
    # was skipped in silence.
    problems, unconfirmed = evaluate(
        "design", [52], {52: ("2026-09-14T02:28:19Z", "completed")},
        "2026-09-11T00:00:00+00:00", CHAT_SHA, closers({52: {OTHER_SHA}}),
        non_terminal={"design"})
    expect(
        "a-repos-own-non-terminal-vocabulary-is-honoured",
        len(problems) == 1 and "#52" in problems[0],
        "got %r" % (problems,),
    )
    problems, _ = evaluate(
        "design", [52], {52: ("2026-09-14T02:28:19Z", "completed")},
        "2026-09-11T00:00:00+00:00", CHAT_SHA, closers({52: {OTHER_SHA}}))
    expect(
        "the-default-set-is-unchanged-for-last-call",
        problems == [],
        "'design' is not one of last-call's non-terminal words",
    )
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 tools/check_spec_freshness.py --self-test`
Expected: FAIL — `evaluate()` got an unexpected keyword argument
`non_terminal`.

- [ ] **Step 3: Thread the set through**

In `evaluate`, add the parameter and use it:

```python
def evaluate(status, citations, state_by_number, spec_touch_iso,
             spec_touch_sha, closers_fn=None, non_terminal=None):
```

and replace its guard. Note `is None`, **not** `or`: an empty set is a repo
saying "we have no concept of unfinished work, do not run this gate", and a
truthiness test would discard that and silently substitute last-call's words
— the same silent override this task exists to close.

```python
    if non_terminal is None:
        non_terminal = NON_TERMINAL_STATUSES
    if status not in non_terminal:
        return problems, unconfirmed
```

In `check_spec`, add `non_terminal=None` to the signature, replace the
guard at line 257:

```python
    if non_terminal is None:
        non_terminal = NON_TERMINAL_STATUSES
    if status not in non_terminal or not citations:
        return [], []
```

Same `is None` reasoning as above. Put the default at the top of each
function rather than inline in the condition, so the two sites cannot drift.

and forward it at the `evaluate(...)` call:

```python
    problems, unconfirmed = evaluate(
        status, citations, state_by_number, touch, touch_sha, closers_fn,
        non_terminal)
```

- [ ] **Step 4: Load it in `main`**

In `main(argv)`, beside the existing shallow check:

```python
    import sdd_config
    _cfg, _cfg_err = sdd_config.load(".")
    if _cfg_err is not None:
        print("FAIL: %s" % _cfg_err, file=sys.stderr)
        return 1
    non_terminal = set(_cfg["non_terminal_statuses"])
```

and pass `non_terminal` at the `check_spec(path, lines, slug, shallow)` call
site, making it `check_spec(path, lines, slug, shallow, non_terminal)`.

- [ ] **Step 5: Run to verify all pass**

Run: `python3 tools/check_spec_freshness.py --self-test`
Expected: `self-test: 28/28 assertions passed`

Run: `python3 tools/check_spec_freshness.py docs/superpowers/specs/*.md`
Expected: exit 0, unqualified banner.

- [ ] **Step 6: Commit**

```bash
git add tools/check_spec_freshness.py
git commit -m "A repo's own idea of unfinished work is the repo's to declare"
```

---

### Task 5: check_drift.py and the self-test requirement

**Files:**
- Create: `tools/check_drift.py`
- Create: `tools/.sdd-manifest.json`
- Modify: `Makefile` (`workflows:` target)

**Interfaces:**
- Consumes: nothing from earlier tasks except that the four checkers exist
  and answer `--self-test`.
- Produces: `verify(manifest, root)` returning a list of problem strings.

- [ ] **Step 1: Write the manifest**

Create `tools/.sdd-manifest.json`. Generate the hashes rather than typing
them:

```bash
cd ~/PycharmProjects/dive-bar-sim
python3 - <<'PY'
import hashlib, json
files = ["tools/sdd_config.py", "tools/check_spec_status.py",
         "tools/check_spec_freshness.py", "tools/check_agent_entrypoints.py"]
m = {"version": 1, "files": {}}
for f in files:
    m["files"][f] = hashlib.sha256(open(f, "rb").read()).hexdigest()
open("tools/.sdd-manifest.json", "w").write(json.dumps(m, indent=2) + "\n")
print(json.dumps(m, indent=2))
PY
```

- [ ] **Step 2: Write the failing self-test**

Create `tools/check_drift.py`:

```python
#!/usr/bin/env python3
"""Every vendored checker must still be the file we vendored, and still work.

A manifest sha256 proves the FILE did not drift. It says nothing about
whether the code still does its job after a Python upgrade or a dependency
change. A checker's failure mode is silence: if its parsing quietly stops
matching, everything passes and nothing says so.

So this asserts both, and the second is the one that matters. Four of this
repo's nine checkers have no self-test at all, which is why the template
makes answering --self-test the price of being vendored rather than a
recommendation in a document.

Run: check_drift.py [repo_root]
     check_drift.py --self-test
"""
import hashlib
import json
import os
import subprocess
import sys

MANIFEST = "tools/.sdd-manifest.json"


def verify(manifest, root="."):
    raise NotImplementedError


def _self_test():
    checks = 0
    failures = []

    def expect(name, cond, detail=""):
        nonlocal checks
        checks += 1
        if not cond:
            failures.append(name + (": " + detail if detail else ""))

    missing = {"version": 1, "files": {"tools/does_not_exist.py": "0" * 64}}
    problems = verify(missing, ".")
    expect("a-vendored-file-that-vanished-is-a-problem",
           len(problems) == 1 and "missing" in problems[0].lower(),
           "got %r" % (problems,))

    for f in failures:
        print("SELF-TEST FAIL: %s" % f, file=sys.stderr)
    if failures:
        print("\n%d/%d self-test assertion(s) failed." % (len(failures), checks),
              file=sys.stderr)
        return 1
    print("self-test: %d/%d assertions passed" % (checks, checks))
    return 0


def main(argv):
    if "--self-test" in argv:
        return _self_test()
    root = argv[0] if argv else "."
    try:
        with open(os.path.join(root, MANIFEST), encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, ValueError) as exc:
        print("FAIL: cannot read %s (%s)" % (MANIFEST, exc), file=sys.stderr)
        return 1
    problems = verify(manifest, root)
    for p in problems:
        print("FAIL: %s" % p, file=sys.stderr)
    if problems:
        return 1
    print("sdd drift: %d vendored file(s) match their recorded hash and pass "
          "their own self-test" % len(manifest["files"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 3: Run to verify it fails**

Run: `python3 tools/check_drift.py --self-test`
Expected: `NotImplementedError` traceback.

- [ ] **Step 4: Implement `verify`**

```python
def verify(manifest, root="."):
    problems = []
    for rel, want in sorted(manifest.get("files", {}).items()):
        path = os.path.join(root, rel)
        try:
            data = open(path, "rb").read()
        except OSError:
            problems.append("%s is in the manifest but missing from the tree."
                            % rel)
            continue
        got = hashlib.sha256(data).hexdigest()
        if got != want:
            problems.append(
                "%s has drifted from its recorded hash (%s != %s). Either the "
                "edit was intended and the manifest needs regenerating, or it "
                "was not." % (rel, got[:12], want[:12]))
            continue
        out = subprocess.run([sys.executable, path, "--self-test"],
                             capture_output=True, text=True,
                             stdin=subprocess.DEVNULL)
        if out.returncode != 0 or "assertions passed" not in out.stdout:
            problems.append(
                "%s matches its hash but its --self-test did not pass. A "
                "checker whose own tests fail is not evidence of anything; "
                "output was: %s"
                % (rel, (out.stdout + out.stderr).strip().splitlines()[-1:]))
    return problems
```

- [ ] **Step 5: Run to verify it passes**

Run: `python3 tools/check_drift.py --self-test`
Expected: `self-test: 1/1 assertions passed`

- [ ] **Step 6: Add the two assertions that carry the point**

Insert before the `for f in failures:` loop:

```python
    import tempfile

    tmp = tempfile.mkdtemp()
    silent = os.path.join(tmp, "silent_checker.py")
    with open(silent, "w", encoding="utf-8") as fh:
        fh.write("import sys\nsys.exit(0)\n")   # exits 0, proves nothing
    digest = hashlib.sha256(open(silent, "rb").read()).hexdigest()
    problems = verify({"version": 1, "files": {"silent_checker.py": digest}}, tmp)
    expect("a-checker-with-no-self-test-is-refused-even-at-the-right-hash",
           len(problems) == 1 and "self-test" in problems[0],
           "this is the template's entry requirement: got %r" % (problems,))

    edited = os.path.join(tmp, "edited.py")
    with open(edited, "w", encoding="utf-8") as fh:
        fh.write("print('self-test: 1/1 assertions passed')\n")
    problems = verify({"version": 1, "files": {"edited.py": "0" * 64}}, tmp)
    expect("a-hash-mismatch-is-reported-before-the-self-test-is-trusted",
           len(problems) == 1 and "drifted" in problems[0],
           "got %r" % (problems,))
```

- [ ] **Step 7: Run and verify**

Run: `python3 tools/check_drift.py --self-test`
Expected: `self-test: 3/3 assertions passed`

Run: `python3 tools/check_drift.py .`
Expected: exit 0, `sdd drift: 4 vendored file(s) match...`

- [ ] **Step 8: Wire into the Makefile and commit**

Add to the `workflows:` target, after the `sdd_config.py --self-test` line:

```makefile
	@$(PYYAML) tools/check_drift.py --self-test
	@$(PYYAML) tools/check_drift.py .
```

Run: `make workflows` — expected exit 0.

```bash
git add tools/check_drift.py tools/.sdd-manifest.json Makefile
git commit -m "A hash proves the file; only a self-test proves the behaviour"
```

---

### Task 6: Prove it against the three other repos

This task writes no product code. It is the acceptance criterion from the
spec, and it is where a false failure would still be hiding.

**Files:**
- Create: `/tmp/sdd-stage1/quorum.sdd-config.json` (scratch, not committed)
- Create: `/tmp/sdd-stage1/2atracker.sdd-config.json` (scratch)

- [ ] **Step 1: Confirm last-call is unchanged with no config**

```bash
cd ~/PycharmProjects/dive-bar-sim
test ! -e .sdd-config.json && echo "no config present, as intended"
make workflows && echo "LAST-CALL STILL GREEN"
```

Expected: exit 0. If this fails the defaults are wrong, not the other repos.

- [ ] **Step 2: quorum — the two false failures must be gone**

```bash
mkdir -p /tmp/sdd-stage1
cat > /tmp/sdd-stage1/quorum.sdd-config.json <<'JSON'
{
  "canonical": "AGENTS.md",
  "entrypoints": { "CLAUDE.md": "pointer" },
  "spec_statuses": ["design", "proposed", "accepted", "in progress",
                    "shipped", "superseded"]
}
JSON
cp /tmp/sdd-stage1/quorum.sdd-config.json ~/quorum/.sdd-config.json
cd ~/quorum
python3 ~/PycharmProjects/dive-bar-sim/tools/check_agent_entrypoints.py .
python3 ~/PycharmProjects/dive-bar-sim/tools/check_spec_status.py docs/superpowers/specs/*.md
```

Expected: both exit 0. Specifically, **neither** of these may appear:
- any mention of `last-call` in quorum's output
- `CLAUDE.md is committed as a regular file`

- [ ] **Step 3: 2ATracker — the one true failure must remain expressible**

```bash
cat > /tmp/sdd-stage1/2atracker.sdd-config.json <<'JSON'
{ "canonical": "AGENTS.md", "entrypoints": { "CLAUDE.md": "independent" } }
JSON
cp /tmp/sdd-stage1/2atracker.sdd-config.json ~/PycharmProjects/2ATracker/.sdd-config.json
cd ~/PycharmProjects/2ATracker
python3 ~/PycharmProjects/dive-bar-sim/tools/check_agent_entrypoints.py .
```

Expected: exit 0 — `independent` is a declared opt-out.

Now prove the checker still objects when the claim is false:

```bash
cat > .sdd-config.json <<'JSON'
{ "canonical": "AGENTS.md", "entrypoints": { "CLAUDE.md": "pointer" } }
JSON
python3 ~/PycharmProjects/dive-bar-sim/tools/check_agent_entrypoints.py .
```

Expected: exit 1, with the reason **"never names it"** — not the size
reason. 2ATracker's `CLAUDE.md` mentions `AGENTS.md` zero times, so the
content check rejects it before the byte-count check is ever reached.
Verified against the real file while writing this plan.

If it exits 0, the discriminator is broken and Task 3 is not done. If it
exits 1 citing the byte limit instead, either the two checks are in the wrong
order or that file has been rewritten since 2026-09-16 — see the Known gap
below.

- [ ] **Step 4: halves — no entry points at all**

```bash
cd ~/PycharmProjects/halves
printf '{ "canonical": null, "entrypoints": {} }\n' > .sdd-config.json
python3 ~/PycharmProjects/dive-bar-sim/tools/check_agent_entrypoints.py .
```

Expected: exit 0 and the words `NOT checked` in the output. A silent exit 0
here is a failure of this task — an unadopted repo must say it was not
checked, per the spec's hard/soft contract.

- [ ] **Step 5: Clean up the scratch configs**

```bash
rm -f ~/quorum/.sdd-config.json \
      ~/PycharmProjects/2ATracker/.sdd-config.json \
      ~/PycharmProjects/halves/.sdd-config.json
for d in ~/quorum ~/PycharmProjects/2ATracker ~/PycharmProjects/halves; do
  git -C "$d" status --short | grep -q . && echo "DIRTY: $d" || echo "clean: $d"
done
```

Expected: all three clean. These repos were borrowed as test fixtures and
must be left exactly as found.

- [ ] **Step 6: Record the result in the spec**

In quorum, append to
`docs/superpowers/specs/2026-09-16-sdd-template-design.md` under
`## Implementation order`, inside the Stage 1 paragraph, a line stating the
date Stage 1 was proven and against which repos. Commit that to quorum
separately from the last-call commits.

---

## Self-Review

**Spec coverage.** Stage 1 of the spec names four deliverables: parameterise
`check_agent_entrypoints.py` (Tasks 2-3), config-driven status vocabulary
(Task 4), `check_drift.py` with the self-test requirement (Task 5), and
proof against three repos (Task 6). The config file the first three depend on
is Task 1. `check_spec_freshness.py` was originally listed as needing no
change, on the grounds that it hardcodes nothing repo-specific. That was
false and the pre-flight scan caught it: `NON_TERMINAL_STATUSES` at line 23
is a third hardcoded vocabulary, and a repo that does not use last-call's
words has every spec silently skipped. Task 4b closes it.

**Not covered here, deliberately:** the plugin skeleton, `sdd.yml`, and every
`/sdd-*` command are Stage 2 and 3.

**Known gap.** Task 6 uses three real repos as fixtures and depends on their
current contents. If 2ATracker's `CLAUDE.md` is rewritten to be under 1024
bytes and to mention `AGENTS.md`, Step 3's negative case stops proving
anything. It would then need a synthetic fixture instead.
