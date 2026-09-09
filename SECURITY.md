# Security

Quorum runs other vendors' coding CLIs as subprocesses, handles API keys and OAuth tokens,
and relays model output back into a session that acts on it. Each of those is a place a
vulnerability could matter, so this file says how to report one and what the project already
claims to guarantee.

## Reporting a vulnerability

**Use [private vulnerability reporting](https://github.com/WhereTheTunnelEnds/quorum/security/advisories/new).**
Do not open a public issue for a security problem.

Please include: what you did, what happened, and what you expected. A minimal reproduction
is worth more than a description. If a credential of yours was exposed while finding it,
rotate it first — do not include it in the report.

This is a small project maintained in spare time. You should expect an acknowledgement
within a week, and honest communication about whether and when a fix is likely. There is no
bug bounty.

## What this project claims

These are the guarantees Quorum's design actually makes. A break in any of them is a
vulnerability worth reporting.

| Claim | Where it's enforced |
|---|---|
| **Credentials never reach argv.** Anything on a command line is visible to `ps auxww` for every process running as you. Keys go through the environment, or through curl's `-H @<(...)` reading from a `/dev/fd` pipe. | `tests/test-key-never-on-disk.sh` |
| **Credentials never reach disk.** No temp file holds a key, so no signal can strand one. | same |
| **Credentials never reach a transcript.** `--set-key` reads from a hidden prompt. No tool asks a user to paste a key, and the command docs forbid an agent from doing so. | `commands/auth.md`, `scripts/quorum-auth` |
| **Provider output is data, not instructions.** Every adapter fences provider text in an untrusted-output delimiter, neutralises forged delimiters, and strips control characters — an ANSI escape can otherwise repaint the `status:` line above it. | `scripts/quorum-sanitize`, `docs/adapter-contract.md` |
| **Consult tier cannot write.** Enforced by the provider's own harness, not by asking politely. | `docs/safety-model.md` |
| **Delegate tier writes only inside a throwaway worktree**, namespaced per repository so two delegations cannot land in one tree. | `skills/delegate-task/SKILL.md` |

`docs/safety-model.md` is the full version, including which tiers are enforced *below* the
process and which are not. Read it before assuming a tier contains something — of the shipped
adapters, exactly one has a write boundary enforced by the OS.

## What is out of scope

- **Vendor CLIs themselves.** Quorum invokes `codex`, `copilot`, `agy`, `claude` and others.
  A vulnerability in one of those belongs to that vendor. Report it to them.
- **A provider returning bad or malicious content.** That is expected, which is why output is
  fenced and treated as untrusted. A report is only interesting if the fence *failed*.
- **Spending your own money.** OpenRouter bills per token, and a panel that fans out to many
  providers costs more than one call. That is the documented design, not a flaw.
- **Anything requiring an attacker who already has your shell.** If they can run commands as
  you, they can read your env file directly; Quorum is not a boundary against that.

## If you find a leaked credential in this repository

Report it privately as above, and assume it is live. Removing a commit does not un-leak
anything that was ever pushed.
