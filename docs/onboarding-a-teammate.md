# Onboarding a teammate

For a second or third person joining a repo that already uses Quorum.

The mechanics of each provider live in [getting-started.md](getting-started.md) and are not
repeated here. **One copy, so the two cannot drift.** This file is about the part that is
different when there is more than one of you: whose credentials, what is never shared, and
how each person proves their own setup actually works.

---

## The rule: everyone runs their own Quorum, on their own accounts

There is no shared install, no shared key, no team token. Each person clones Quorum, installs
it on their own machine, and authenticates **every provider against their own account**.

This is not bureaucracy, and it is not about trust:

- **Subscriptions are per-seat.** Codex spends a ChatGPT subscription, Copilot a GitHub one,
  Antigravity a Google one, GLM a Z.AI Coding Plan. Sharing one person's login to spend their
  seat is what those agreements exist to prohibit, and the account that gets suspended is the
  lender's, not the borrower's.
- **A shared key cannot be rotated quietly.** One leak means every person's work stops until
  everyone re-authenticates. Separate credentials fail separately.
- **Usage becomes attributable.** When a panel burns through an OpenRouter balance, you can
  see whose key did it. With one shared key you cannot.

The one thing that *is* deliberately pooled is capacity, and it is pooled by **adding
accounts, not by sharing them** — see [the second Claude subscription](#the-second-claude-subscription)
below.

---

## What each person does

Work through [getting-started.md](getting-started.md) start to finish. It covers
prerequisites, install, and all seven providers with a check after each.

Two things to know before starting:

**Every provider is optional, and nobody needs all seven.** Quorum works with one. A panel of
three independent models is already most of the value; the eighth opinion is not what makes
it useful. If a teammate has no ChatGPT subscription, they skip Codex — that is a normal
setup, not a broken one.

**Authentication is not the same as working.** Finish with both:

```bash
quorum-auth          # is every provider configured?
quorum-verify --all  # does every provider actually answer?
```

`quorum-auth` makes a real call per provider. `quorum-verify` makes four, and checks that a
*broken* call is distinguishable from a working one — which is the property adapters actually
depend on. Want `4 passed, 0 failed` per provider you set up.

> `quorum-auth` printing "Everything requested is authenticated" over providers it never
> checked is a real bug that shipped here — it covered five of seven adapters while reporting
> a clean bill of health. `tests/test-auth-covers-every-adapter.sh` now fails if an adapter
> is added without a check in both `quorum-auth` and `quorum-setup`. Mentioned because it is
> exactly the kind of green you should distrust: **ask what it would have taken for it to be
> red.**

---

## The second Claude subscription

This is the one provider that only makes sense with more than one person, and the one most
likely to be set up wrong in a way that looks right.

`claude-alt` runs Claude Code as a subprocess against a **different** Claude subscription, so
a panel can spend that person's quota instead of the session's. The token comes from
`claude setup-token`.

**The trap:** `setup-token` mints a token for whoever is currently signed in. Run it while
signed in as yourself and you get a perfectly valid token — for the account you already have.
Every check passes, `quorum-verify claude-alt` reports `4 passed`, and the panel pools one
subscription with itself. Nothing is gained and nothing complains.

So: **sign in as the second account first**, then mint the token.

Whoever owns that subscription runs `claude setup-token` **themselves, in their own
terminal**, and puts the result in their own env file. It is their credential; it does not
need to reach anyone else, including whoever set up the repo.

---

## Things that must not happen

**Never paste a key, token, device code, or one-time auth code into a chat with an agent** —
not to "check" it, not even into this one. Anything pasted becomes transcript, which is
stored and may be summarised or logged, and a credential that reaches a transcript has to be
rotated. Every tool here is built so it never needs to happen:

- `quorum-auth glm --set-key` and `quorum-auth openrouter --set-key` read from a hidden
  prompt. The key never touches shell history, the terminal, or a transcript.
- Interactive logins (`codex login`, first `copilot` run, `agy`) open a browser. **Run them
  yourself.** An agent should tell you the command, not run it for you — it binds a paid
  account to a machine.
- Keys live in your shell env file at mode `600`, referenced as `${VAR}`. Never in a repo
  file, never in a command line. Anything on a command line is visible to `ps auxww` for
  every process running as you.

**Never commit a credential to the project.** Quorum reads everything from the environment
for this reason. If one does land in a commit, rotate it — removing the commit does not
un-leak it.

---

## Coordinating once everyone is set up

Quorum is per-person; the repo is shared. Coordination between people is a separate concern
and belongs in the project's own `TEAM.md` — typically vertical feature ownership, and
whichever files everyone's work collides in. Quorum does not manage that and should not try.

What Quorum does add to a team is worth stating plainly:

| | |
|---|---|
| **More opinions per decision** | A panel spanning several vendors is harder to fool than one model asked twice |
| **More capacity** | Each person's subscriptions add to the pool; `claude-alt` makes a second Claude subscription usable from one session |
| **Delegation that composes** | Each delegate works in its own worktree on its own branch, so two people's agents cannot land in the same tree |

And what it does not: Quorum has no opinion about who owns which feature, no lock, and no
scheduler. Two people can still delegate conflicting work. That is what `TEAM.md` and CI
are for.

---

## If something does not work

Run `quorum-auth` first — it names the provider and prints the exact command that fixes it.
Then [troubleshooting.md](troubleshooting.md).

A provider that is missing is not a broken install. Say which ones are ready before saying
which are not.
