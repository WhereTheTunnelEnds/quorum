# Why Delegation, Not Proxying

There are two ways to get another vendor's model into Claude Code. Quorum uses the less
obvious one, for reasons worth stating plainly — including the cases where the other one
is better, and where Quorum uses it internally.

## The obvious approach: swap the endpoint

Claude Code honours `ANTHROPIC_BASE_URL`. Point it at a local gateway, have the gateway
translate and forward to whatever backend you like, and Claude Code is now driving a
different model. This is what router-style tools do —
[claude-code-router](https://github.com/musistudio/claude-code-router) is the best-known
example, and current versions can import the OAuth credentials that Claude Code and Codex
have already stored locally, so this reaches subscriptions and not only metered API keys.

It genuinely works, and for what it does it is the right tool.

## What it cannot reach

A proxy operates at the HTTP layer. It needs two things: **an API surface it can
translate**, and **credentials it can replay.**

Some providers have neither. GitHub Copilot's value in this context is not a chat
endpoint — it is the *agent*: the GitHub MCP integration, awareness of your PRs, issues, CI
runs, and repo conventions, plus its own read-only exploration subagent. None of that is
reachable by replaying a token at a completions URL, because none of it lives there. It
lives in the CLI.

That is the general shape of the limitation. **Proxying swaps a model. It cannot import a
capability.** Wherever a vendor's differentiator is the harness around the model — its
sandbox, its tool integrations, its repo indexing, its review subcommand — an endpoint swap
leaves that behind by construction.

## The approach Quorum takes

Don't redirect Claude Code's HTTP calls. **Spawn the vendor's own CLI as a subprocess.**

```bash
echo "$QUESTION" | codex exec --sandbox read-only --skip-git-repo-check -
```

The subprocess authenticates however it likes — OAuth token, keychain entry, device flow,
whatever the vendor built. You never touch its credentials, never translate its wire
format, and never track its API changes. And you get the *whole agent*, not a decapitated
model: its sandbox, its tools, its context window.

Four consequences follow, and they are the actual argument:

**1. Capabilities come along.** Copilot's GitHub context, Codex's `exec review`, GLM's 1M
window — all of it arrives intact, because you invoked the thing that has it.

**2. Each provider brings its own sandbox.** This inverts a cost into a feature. A proxy
gives you one agent with one permission model, so *your* session's permissions govern
everything. Delegation means each provider is confined by the boundary its own vendor
built and tested — `--sandbox read-only`, `--plan`, tool allowlists. Quorum's
[three tiers](safety-model.md) are assembled out of those.

**3. Context stays separate.** A panelist reasons in its own window and returns a
conclusion. Your session pays for the question and the answer, not the thinking in between.
This is what makes a four-model panel affordable at all, and it's why the 1M-context
provider can hold a whole subsystem your session cannot.

**4. Disagreement becomes real.** Asking one model the same question three times mostly
reproduces one blind spot three times. Vendors' failure modes are only weakly correlated.
Four genuinely independent agents disagreeing is a signal; one agent sampled four times is
noise wearing a costume.

## What it costs

Honest ledger:

| | Proxying | Delegating |
|---|---|---|
| Granularity | Per-request | Per-task |
| Latency | Milliseconds | Process spawn; a panel takes 2–10 min |
| Shared conversation | Yes | **No — every brief must be self-contained** |
| Vendor capabilities | Lost | Preserved |
| Sandbox | Yours | Each vendor's own |
| Failure modes | One | **One per provider, each silent in its own way** |

Rows three and six are the real costs. A delegate cannot see your session, so a vague brief
produces a diff you throw away — which costs more than doing the work yourself. And every
CLI you add is a new set of ways to fail quietly, which is why this repo has an
[adapter contract](adapter-contract.md) and a [field-notes log](field-notes.md) instead of
a handful of one-line wrappers.

## Where Quorum proxies anyway

Consistency would be a poor reason to use the wrong tool, so: the endpoint swap is exactly
right when you want a *known-good agentic loop* running on *cheaper tokens*. Claude Code
itself is a very good harness. Running it against a non-Anthropic model keeps the harness
and changes the economics.

That is what `scripts/quorum-claude-on` does — sets `ANTHROPIC_BASE_URL` and the model
mapping, then execs `claude`. The GLM adapter uses it for its verify and delegate tiers,
because GLM ships no coding CLI of its own and Claude Code is a better harness than one
we'd write.

So the design isn't proxy-versus-delegate as a matter of principle. **Delegation is the
outer layer**, because it's the only one that reaches whole agents. The endpoint swap is a
technique used *inside* an adapter, where a provider offers a model but no harness worth
having.
