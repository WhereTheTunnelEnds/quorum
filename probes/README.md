# Probe files

One file per provider. `scripts/quorum-verify` sources these and runs the mechanical parts
of the [adapter contract](../docs/adapter-contract.md) against the live CLI.

A probe file declares two functions and up to four variables:

```sh
probe_consult()  # $1 = file containing the prompt. The documented, working invocation.
probe_broken()   # $1 = same. A DELIBERATELY misconfigured call.
EXPECT_BROKEN_DESC="human-readable description of the documented failure"
BROKEN_MATCH="regex"   # only when exit code and emptiness cannot discriminate

PROBE_BINARY="codex"   # the command this provider is invoked as, if it has one
PROBE_PRECONDITION='[ -n "${SOME_KEY:-}" ]'          # is this provider configured here?
PROBE_PRECONDITION_DESC='SOME_KEY is not set — run: ...'
```

**`PROBE_BINARY` is not optional in practice.** `quorum-verify` uses it to tell "you have not
installed this provider" (a normal state — providers are optional, so it warns and skips)
from "the probe itself is broken" (a real failure). A probe written without it, for a binary
that is absent, reports:

```
FAIL  probe is broken — a command it depends on is missing
      this probe declares no binary, so it can never be 'not installed'
```

rc=1. Neither this file nor `probe.sh.template` used to mention the variable, so a
contributor following the template exactly produced that, then — per `CONTRIBUTING.md` —
pasted it into their PR.

**`PROBE_PRECONDITION`** covers providers with no binary at all: GLM and OpenRouter need an
API key, Ollama needs a running server. Without it, an unconfigured provider showed a red `FAIL` on the first
command the README tells a new user to run, and — with an Ollama server down — three green
`PASS`es for calls that never happened.

Write to stdout and stderr; do not pipe, and do not swallow the exit code — `quorum-verify`
reads all three. Use `qt` in place of `timeout` so a hang surfaces as exit 124 under the
shared deadline.

`probe_broken` is the point of the exercise. Any wrapper can demonstrate a working call;
what makes an adapter trustworthy is knowing precisely what a *failing* one looks like, so
it can be reported as a failure instead of relayed as an answer.
