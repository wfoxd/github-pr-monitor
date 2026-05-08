# github-pr-monitor

An agentic skill for interactive coding agents — terminal CLIs (Claude Code, Codex CLI, etc.), IDE extensions (Cursor, Cline, the Claude Code VS Code extension), or any other session where an agent is continuously available — that ships local changes through a GitHub pull request and iterates on review feedback automatically until the PR is shippable.

You run it once when your local work is done. The skill pushes, opens a PR, asks GitHub Copilot to review, and then **the agent itself** sits in a one-minute polling loop, triaging unresolved review threads, fixing the code, pushing again, and re-requesting review. The loop keeps going while there are blocking issues or low-risk nits the agent can confidently fix; it hands off to you the moment the only thing left is a judgement call or a pile of opinionated nits you might reasonably want to defer to a follow-up PR.

The only real requirement is that the agent is present and reasoning between polls — so this fits any interactive agent context, whether that's an IDE sidebar, a terminal session, or a chat-driven workflow. It is *not* designed for fire-and-forget background automation with no agent in the loop.

## What "done" means

The goal is a *shippable* PR, not one with every single reviewer thought resolved. The agent triages review threads into four buckets:

| Bucket | Example | What the agent does |
|---|---|---|
| **Blocker** | Real bug, failing test, missing error-handling, `CHANGES_REQUESTED` | Fixes and pushes |
| **Auto-fixable nit** | Missing null check, typo, missing docstring on public API, one-line uncovered branch | Fixes and pushes |
| **Deferrable nit** | Opinionated style tweak, rename in non-local scope, refactor that expands PR scope | Leaves the thread open and surfaces to you |
| **Needs user judgement** | Architectural direction, API shape, test strategy | Stops the loop and asks you |

When only deferrable nits remain, the agent stops and gives you three explicit options: fix them now (picked individually), merge as-is, or track as a follow-up PR. It never auto-merges.

## Why this exists

Shipping a PR these days is rarely "push and walk away." Reviewers (human or Copilot) leave comments; you fix them; new comments appear; repeat. That's a tight loop with a lot of context-switching, and most of the work is mechanical: read comment → make small change → push → wait → repeat.

This skill lets the agent drive that loop while you do something else, and surfaces back to you only when judgement is actually needed (a real design question, a stuck PR, an approval to merge).

## Design: the agent is the monitor

There's no background daemon. The "monitor" is the agent itself, sitting in a loop:

```
        ┌──────────────────────────────────────┐
        │  pr_check.sh  (one-shot status)      │
        └──────────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
   STATUS=WAITING   STATUS=REVIEW_PENDING   STATUS=CLEAN
        │                 │                 │
   sleep 60      fetch + triage threads   pr_status.sh
        │                 │              hand off to user
        └─►(loop)         ▼               (stop)
            ┌─────────┬─────────┬──────────────────┐
            ▼         ▼         ▼                  ▼
        blocker / auto-fix   deferrable nit   needs judgement
            │                     │                  │
       fix + push           leave open        stop + ask user
            │                     │                  │
            └─►(loop)       go to handoff       (wait for user)
```

A blocking shell-side wait would be the wrong fit for an interactive agent session: the user couldn't interject, the agent couldn't reason between polls, and any anomaly (Copilot never started, transient API error) would only get noticed when the script eventually returned. With the agent driving, every minute is a chance to narrate progress, notice stalls, take user input, and adjust. The cost is one short tool-call cycle per poll; the benefit is full agentic control.

## Prerequisites

| What | Why |
|---|---|
| `gh` CLI, authenticated (`gh auth status` ✓) | All GitHub interaction goes through it |
| `jq` | Helper scripts parse GraphQL JSON |
| Repo with a GitHub remote, on a feature branch | The skill won't push from `main`/`master` or detached HEAD |
| Copilot code review enabled on the repo *(optional)* | Without it, the PR still opens — Copilot review request fails with a warning, and the loop still works for any human reviewer's comments |

## Install

Unpack the skill into your agent's skills directory. Locations vary by client:

```bash
# Claude Code (per-user) — works for both the CLI and the VS Code extension
mkdir -p ~/.claude/skills
tar -xzf github-pr-monitor.tar.gz -C ~/.claude/skills/

# Or per-project
mkdir -p .claude/skills
tar -xzf github-pr-monitor.tar.gz -C .claude/skills/
```

Other agent clients (Cursor, Cline, Codex CLI, etc.) have their own skill / prompt-library conventions — drop `SKILL.md` and the `scripts/` directory wherever that client loads agent instructions from, and make sure the scripts stay executable.

After installing, restart your agent session or open a new one so the skill is picked up. Verify with a quick prompt like *"what skills do you have?"* — `github-pr-monitor` should show up.

## Usage

Once your local work is committed (or staged) and you're on a feature branch, just tell the agent what you want:

> *"Push this and have Copilot review it, monitor until it's clean."*

> *"Open a PR for these changes and iterate on the review feedback."*

> *"Ship this branch — handle Copilot's review comments automatically."*

The skill triggers on phrasing like that. A typical session looks like:

```
> Push this and have Copilot review it.

[agent] Local changes look good — 3 commits ahead of origin/main.
        Pushing branch and opening PR...
        PR #248 created: https://github.com/you/repo/pull/248
        Copilot review requested.

        Poll 1 (0 min elapsed): no reviews yet, will check again in 60s.
        Poll 2 (1 min elapsed): no reviews yet, will check again in 60s.
        Poll 3: 5 unresolved review thread(s) from Copilot — handling.

        Thread 1 (src/parser.py:42): Copilot flags a missing null check.
        Blocker — adding the check.
        Thread 2 (src/parser.py:91): Copilot suggests using a context
        manager. Auto-fixable nit — applying.
        Thread 3 (tests/test_parser.py:15): Copilot wants a test for the
        empty-input path. Auto-fixable — adding it.
        Thread 4 (src/parser.py:130): Copilot suggests renaming `x` to
        `parsed_value`. Declining (variable is local to a 3-line scope;
        rename adds noise). Replied and resolved.
        Thread 5 (src/parser.py:210): Copilot suggests extracting the
        validation block into a separate module. Deferrable — leaving
        unresolved for you to decide.

        Pushing blocker + auto-fix changes... re-requesting Copilot review.

        Poll 1: no new reviews yet. Poll 2: ...
        Poll 3: 1 unresolved thread left (the deferred refactor).
        No new blockers or auto-fixables — handing off.

[agent] PR #248 is in a shippable state: https://github.com/you/repo/pull/248
        - Blockers / auto-fixes: done
        - Mergeable: MERGEABLE
        - CI: SUCCESS

        Deferred nits (not applied, open threads):
        - src/parser.py:210 — extract validation into a separate module.
          Deferred because it expands the PR's scope.

        Three options:
        1. Apply the deferred refactor now (I'll handle it and loop once more).
        2. Merge as-is — the nit is acceptable to ship with.
        3. Track as a follow-up PR (I can draft the issue / TODO).

        Which would you like?
```

You can interject any time — the agent is just running short polls, so a message from you arrives between iterations naturally.

## Scripts

The skill is one `SKILL.md` (the agent's instructions) plus bash scripts the agent calls. Everything is shell + `gh` + `jq` — no Python, no daemons, no global state.

| Script | Purpose |
|---|---|
| `scripts/pr_create.sh` | Push branch, open PR, request Copilot review |
| `scripts/pr_check.sh` | One-shot poll of PR review state — agent calls this each minute |
| `scripts/pr_fetch_threads.sh` | Dump unresolved review threads as JSON for the agent to address |
| `scripts/pr_resolve_thread.sh` | Mark a review thread resolved on GitHub |
| `scripts/pr_reply_thread.sh` | Post a reply on a review thread (used when declining a suggestion) |
| `scripts/pr_push_update.sh` | Commit + push fixes + re-request review |
| `scripts/pr_status.sh` | High-level PR state (reviews, threads, checks, mergeable) |
| `scripts/_request_copilot_review.sh` | Internal helper called by `pr_create.sh` and `pr_push_update.sh` — resolves Copilot's GraphQL node id (cached in `${XDG_CACHE_HOME:-$HOME/.cache}/github-pr-monitor/`) and calls the `requestReviews` mutation |

The seven public scripts each support `--help`. Output is parseable `KEY=VALUE` lines on stdout; human-readable progress goes to stderr. They're independently usable from a shell if you want to script around them. The `_request_copilot_review.sh` helper is internal and not designed to be called directly.

## Loop guards

The agent doesn't grind forever. It surfaces back to the user when:

- **10 minutes** of `WAITING` with no reviews submitted at all — Copilot may not be enabled on the repo, worth confirming.
- **60 minutes** total in the loop without convergence.
- The **same review thread comes back unresolved twice** after the agent claimed to fix it — usually means the fix didn't satisfy the reviewer.
- **More than 5 push-and-review rounds** without the blocker / auto-fix queue emptying. (Rounds where the only new items are deferrable nits aren't a loop failure — the agent hands off instead.)
- A thread needs **user judgement** (architecture, API shape, taste calls in broad scope) — the agent stops mid-loop and asks.
- **`STATUS=ERROR`** — PR closed, merge conflicts, auth lapse, etc.
- **You interrupt** — just type a message; the agent stops the loop and responds.

The agent also never auto-merges. Even on a clean PR, merging is your call.

## Things the agent will *not* do silently

- Commit code without showing you what's being committed.
- Apply a Copilot suggestion that's clearly wrong just to make the reviewer go away. It replies declining-with-reason and resolves the thread instead.
- Auto-apply opinionated style / refactor suggestions. Those land in the "deferrable nit" bucket and come back to you for a decision.
- Make architectural / naming / scoping decisions on your behalf — those get surfaced as a question.
- Resolve merge conflicts. They need human judgement; the loop stops and you're surfaced to.
- Auto-merge — even when the PR is fully clean.

## Troubleshooting

See [`references/troubleshooting.md`](references/troubleshooting.md) for:

- Why the scripts use GraphQL instead of the simpler REST endpoints
- Why `pr_reply_thread.sh` translates between GraphQL and REST comment ids
- Re-requesting Copilot review after a new push (GitHub doesn't auto-retrigger)
- Common failure modes (push rejected, conflicts, mid-loop auth lapses)
- Rate-limit budget for the polling cadence
- Manual escape hatches

## File layout

```
github-pr-monitor/
├── README.md                  # This file
├── SKILL.md                   # Agent instructions — loaded into context when the skill triggers
├── scripts/
│   ├── pr_create.sh
│   ├── pr_check.sh
│   ├── pr_fetch_threads.sh
│   ├── pr_resolve_thread.sh
│   ├── pr_reply_thread.sh
│   ├── pr_push_update.sh
│   ├── pr_status.sh
│   └── _request_copilot_review.sh  # Internal helper; not called directly
└── references/
    └── troubleshooting.md     # Loaded by the agent on demand when something goes wrong
```

`SKILL.md` is what the agent reads to know how to drive the workflow; `README.md` (this file) is what you read to decide whether to use the skill and how to set it up. They're intentionally different audiences.

## Does it need to run in an IDE?

No. Any interactive agent session works — a terminal CLI like Claude Code or Codex CLI, an IDE extension, a web-based agent chat, or even a long-running SSH session with an agent attached. The only thing that *doesn't* work is fully unattended background automation: the design depends on the agent being present to reason between polls and to surface judgement calls back to a human. If nobody is watching, there is no one to say "yes, merge it" or "Copilot's wrong on this one, override it."
