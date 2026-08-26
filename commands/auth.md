---
description: "Diagnose and fix provider authentication — shows exactly what's missing and the one command that fixes each."
argument-hint: "[provider] [--fix]"
allowed-tools: Bash(quorum-auth), Bash(quorum-auth:*)
---

Run `quorum-auth $ARGUMENTS`
and report the result.

Then help the user through whatever it flagged:

- **Read the `fix:` line it printed.** It already contains the exact command. Don't invent
  a different one.
- **Never run an interactive login on the user's behalf without asking.** `codex login` and
  the first `copilot` run open a browser and bind their account. Tell them the command and
  let them run it, or confirm before using `--fix`.
- **Never ask the user to paste a key, token, device code, or one-time auth code into this
  conversation** — not even to "check" it. Anything pasted becomes transcript, which is
  stored and may be summarised or logged, and a leaked credential must then be rotated. If
  the user offers one, tell them not to.
- **Never ask for, echo, or store a key yourself.** `quorum-auth glm --set-key` reads it
  through a silent prompt so it never touches shell history or the transcript. Point them
  at that instead of taking the key into this conversation.
- **A missing provider is not an error.** Providers are independent and Quorum works with
  any subset. Say which ones are ready rather than framing an incomplete set as broken.

If the user is setting up for the first time, note that authentication is not the same as
working: finish with `quorum-verify --all`, which makes real calls.

If it is not on PATH, do not guess at a relative path — this command runs in the user's project, not in the Quorum clone. Tell them to run `scripts/install.sh` from wherever they cloned Quorum, and stop.
