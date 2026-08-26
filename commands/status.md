---
description: "Show which model providers are reachable right now — live-checked, not guessed."
allowed-tools: Bash(quorum-status)
---

Run `quorum-status` and report the
result.

**Do not substitute a `command -v` check for this.** Not every provider ships a binary
named after itself — GLM has none at all — so a missing command proves nothing about
whether the provider is reachable. That mistake has already caused a working provider to
be reported as unavailable. Only a real call is evidence, which is what this script makes.

If a provider reports as unavailable, say what specifically is missing (not installed vs.
not logged in vs. key unset) and the one command that fixes it.

If it is not on PATH, do not guess at a relative path — this command runs in the user's project, not in the Quorum clone. Tell them to run `scripts/install.sh` from wherever they cloned Quorum, and stop.
