# Probe files

One file per provider. `scripts/quorum-verify` sources these and runs the mechanical parts
of the [adapter contract](../docs/adapter-contract.md) against the live CLI.

A probe file declares two functions and up to two variables:

```sh
probe_consult()  # $1 = file containing the prompt. The documented, working invocation.
probe_broken()   # $1 = same. A DELIBERATELY misconfigured call.
EXPECT_BROKEN_DESC="human-readable description of the documented failure"
BROKEN_MATCH="regex"   # only when exit code and emptiness cannot discriminate
```

Write to stdout and stderr; do not pipe, and do not swallow the exit code — `quorum-verify`
reads all three. Use `qt` in place of `timeout` so a hang surfaces as exit 124 under the
shared deadline.

`probe_broken` is the point of the exercise. Any wrapper can demonstrate a working call;
what makes an adapter trustworthy is knowing precisely what a *failing* one looks like, so
it can be reported as a failure instead of relayed as an answer.
