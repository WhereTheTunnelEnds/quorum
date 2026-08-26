---
description: "Show which model providers are reachable right now — live-checked, not guessed."
allowed-tools: Bash(quorum-status), Bash(./scripts/quorum-status)
---

Run `quorum-status` (or `./scripts/quorum-status` if it is not on PATH) and report the
result.

**Do not substitute a `command -v` check for this.** Not every provider ships a binary
named after itself — GLM has none at all — so a missing command proves nothing about
whether the provider is reachable. That mistake has already caused a working provider to
be reported as unavailable. Only a real call is evidence, which is what this script makes.

If a provider reports as unavailable, say what specifically is missing (not installed vs.
not logged in vs. key unset) and the one command that fixes it.
