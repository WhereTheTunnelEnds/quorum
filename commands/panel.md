---
description: "Fan a question out to every available provider in parallel (read-only), then synthesize their answers against your own."
argument-hint: "<the question or decision>"
---

Invoke the `model-panel` skill and follow it exactly.

The question: $ARGUMENTS

If no question was given, ask for one before dispatching anything — a panel on a vague
question produces four vague answers and costs quota on three subscriptions to do it.

Reminders that are easy to skip under time pressure:

- **Dispatch all panelists in a single message** so they run concurrently.
- **Form your own answer before reading theirs.** An anchored fourth opinion is not a
  fourth opinion.
- **Check each envelope's `status` before counting its vote.** `empty` is a failure, not
  an abstention.
- **Attribute every position by name.** Collapsing four perspectives into one anonymous
  voice destroys exactly what the panel was for.
