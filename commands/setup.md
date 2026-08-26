---
description: "Guided first-run setup — check prerequisites, pick providers, authenticate, and prove each one actually works."
allowed-tools: Bash(quorum-setup --check), Bash(./scripts/quorum-setup --check), Bash(quorum-status), Bash(quorum-auth), Bash(quorum-auth:*)
---

Run `quorum-setup --check` (or `./scripts/quorum-setup --check`) and walk the user through
whatever it reports.

`--check` is the only mode you should run. The interactive wizard needs a real terminal —
your shell has no TTY, so an interactive run would hang until it times out, and any browser
login inside it could never be completed.

Reading the output:

- **Every provider is optional.** Missing ones are a normal state, not a broken install.
  Say which are ready before saying which are not.
- **The bold line under a missing provider is its install command.** Give the user that
  exact line; don't compose your own.
- **Never offer to run an installer or a login for them.** Vendor installers execute remote
  code and modify the machine; logins open a browser and bind a paid account. Both are the
  user's to run knowingly.
- **Never ask the user to paste a key, token, device code, or auth code into this
  conversation** — not even to check it. Anything pasted becomes transcript. If they offer,
  tell them not to. Nothing here needs it: setup proves success by making a real call.

If everything is already green, say so plainly and point them at `/quorum:panel`. Then note
that `quorum-verify --all` is the check to re-run after any provider CLI update, and
`quorum-flags` catches a renamed flag before it costs them an answer.
