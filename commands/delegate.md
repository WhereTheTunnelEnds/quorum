---
description: "Hand a whole task to Codex, Copilot, or GLM in an isolated worktree, then review the diff."
argument-hint: "<the task> [to codex|copilot|glm]"
---

Invoke the `delegate-task` skill and follow it exactly.

The task: $ARGUMENTS

If a provider was named, route there. Otherwise choose using the skill's routing table and
say why you chose it.

Before dispatching, write a **self-contained** brief: goal, constraints, files involved,
and how to verify it is done. The delegate cannot see this conversation — everything it
needs must be in the brief. This is where a delegation succeeds or wastes its quota.

After it returns: check the envelope `status`, read the actual diff, run the tests
yourself, and report the worktree path and diffstat. Do not merge, push, or delete the
worktree.
