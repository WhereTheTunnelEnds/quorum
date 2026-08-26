---
description: "Build a verified Quorum adapter for a new provider — a local model (MLX, Ollama, LM Studio), another vendor's CLI, or any compatible endpoint."
argument-hint: "<provider name or CLI>"
---

Invoke the `add-provider` skill and follow it exactly.

The provider: $ARGUMENTS

The rule that governs this whole command: **probe first, write second.** Do not produce an
adapter from documentation or from what you know about the provider — run the six probes
and write the adapter from the measurements. If the provider is not installed or not
reachable on this machine, say so and stop rather than writing one for the user to test
later. An untested adapter that looks tested is worse than no adapter.

Finish by running `scripts/quorum-verify <name>`. If it does not pass, the adapter is not
done — and do not report it as done.
