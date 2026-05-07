---
name: github-pr-monitor
description: Use this skill in an interactive coding agent (Claude Code in terminal or VS Code, Cursor, Cline, Codex CLI, etc.) once local code changes are ready to ship through a pull request. It pushes the branch, opens a PR, requests a GitHub Copilot code review, then has the agent itself act as the monitor — polling the PR every minute, reading unresolved review threads, fixing what it reasonably can, pushing again, and re-requesting review. The loop ends when there are no blocking issues left; any remaining nits the agent can't or shouldn't decide on unilaterally get surfaced to the user, who chooses whether to keep iterating, merge anyway, or leave them for a follow-up PR. Trigger this skill whenever the user says things like "open a PR and iterate on the review", "push this and have Copilot review it", "ship this and handle review comments", "monitor the PR", or any agentic ship-and-iterate workflow on GitHub. Designed for interactive agent contexts where a human is reachable between polls — not for fire-and-forget background automation.
---

# GitHub PR Monitor

An agentic workflow for shipping local changes through a pull request and iterating on review feedback automatically until the PR is in a shippable state.

"Shippable" is not the same as "every thread resolved." The goal is for the agent to clear everything that's clearly actionable and low-risk on its own — real bugs, easy style fixes, missing docs, trivial test additions — and to hand off to the user the moment a decision calls for human judgement (scope, taste, architecture, or feedback the agent disagrees with). A PR with a couple of deferred nits that the user has explicitly chosen to leave for a follow-up is a valid successful exit from this skill.

## Design: the agent is the monitor

This skill is built for IDE coding agents (Claude Code, Cursor, Cline, etc.) where the agent is always present and reasoning. There is no background daemon. The "monitor" is the agent itself, sitting in a loop that:

1. Calls `pr_check.sh` (a one-shot status query — fast, no blocking).
2. Reads the result and reasons about it.
3. Either acts (fixes review comments, pushes), waits (`sleep 60` then re-checks), or stops (shippable, error, or user interrupt).

This is much better than a script-driven blocking wait because the agent gets to think on every poll: it can narrate progress to the user, notice anomalies (e.g. Copilot never started reviewing), let the user interject, and adjust strategy on the fly. The cost is one short tool-call cycle per minute; the benefit is full agentic control.

## Prerequisites

Before invoking this skill, verify:

1. `gh` CLI is installed and authenticated (`gh auth status` succeeds).
2. `jq` is installed (used by helper scripts to parse GitHub API JSON).
3. The current directory is a git repo with a remote on GitHub.
4. The user is on a feature branch — not `main`, `master`, or detached HEAD.
5. The repository's organisation has GitHub Copilot code review enabled. If it does not, the `pr_create.sh` script will still create the PR and just print a warning that the Copilot review request failed; review threads from human reviewers are still handled the same way.

If any prerequisite is missing, stop and report it before proceeding. Do not try to install tools or change auth state without asking.

## End-to-end workflow

The agent should narrate progress to the user between phases, but otherwise drive the loop without prompting at every step.

### Phase 1 — Confirm local state is ready

Before pushing, run `git status` and `git log --oneline @{upstream}..HEAD 2>/dev/null || git log --oneline -5`. Show the user the pending commits / uncommitted changes and confirm the intended PR scope. If there are uncommitted changes the user wants included, commit them first with a meaningful message — never commit without surfacing what's being committed.

### Phase 2 — Push and open the PR

```bash
bash scripts/pr_create.sh \
  --title "<PR title>" \
  --body  "<PR body, can be multiline>" \
  --base  "<base branch, default: repo default branch>"
```

The script:
- Pushes the current branch (sets upstream if needed).
- Reuses an existing PR for this branch if one exists; otherwise creates one.
- Requests a GitHub Copilot review.
- Prints `PR_NUMBER=<n>` and `PR_URL=<url>` on the last lines.

Capture `PR_NUMBER` from the output — every subsequent script needs it.

If `--title`/`--body` are omitted the script falls back to `gh pr create --fill`. Prefer explicit title/body when the user has given you context about what the change does.

### Phase 3 — Run the polling loop (the agent IS the monitor)

This is the heart of the skill. The agent runs this loop directly — it is not delegated to a shell script.

**Each iteration:**

```bash
bash scripts/pr_check.sh --pr <PR_NUMBER>
```

This is fast (one GraphQL call) and prints `STATUS=...` plus context. Read the status:

| `STATUS=`         | What it means                                         | What the agent does                                |
| ----------------- | ----------------------------------------------------- | -------------------------------------------------- |
| `WAITING`         | No reviews submitted yet. Copilot hasn't started.     | Run `sleep 60`, then poll again. See heartbeat note below. |
| `REVIEW_PENDING`  | Unresolved review threads exist.                      | Jump to Phase 4 (fetch, triage, and address what you can). |
| `CLEAN`           | Zero unresolved threads, ≥1 review submitted.         | Jump to Phase 6 (hand off).                        |
| `ERROR`           | PR closed/merged, or API failure.                     | Surface to user; stop the loop.                    |

**Heartbeat to the user.** On every poll iteration in the `WAITING` state, output one short line of progress to the user — this is an IDE, they're watching. Example: `> Poll 3 (3 min elapsed): no reviews yet, will check again in 60s.` Do not spam status — one line per minute is plenty.

**Loop guards (to surface to user instead of grinding forever):**

- After **10 minutes** of `WAITING` with no reviews submitted at all, pause and ask the user: "Copilot hasn't started reviewing — is Copilot code review enabled on this repo? Want me to keep waiting or stop?" Sometimes Copilot takes 1–3 minutes; sometimes it never engages because the org doesn't have it enabled.
- After **60 minutes total** in the loop without convergence, surface to user — something is off.
- If the **same review thread comes back unresolved twice in a row** after the agent claimed to fix it: stop and ask. Either the fix didn't land, or it didn't satisfy the reviewer.
- More than **5 push-and-review rounds** without the blocker/auto-fixable queue emptying: surface and summarise what's been tried. (Rounds where the only remaining items are deferrable nits are a successful exit, not a loop failure — go to Phase 6.)
- User interrupt at any time: stop and respond to the user.

**Polling cadence.** Once per minute by default (`sleep 60`). The agent may shorten the first interval to ~20s — Copilot review often appears within a minute of PR creation — but stick to 60s after that to avoid burning rate-limit budget.

### Phase 4 — Fetch and address review threads

When `pr_check.sh` reports `STATUS=REVIEW_PENDING`:

```bash
bash scripts/pr_fetch_threads.sh --pr <PR_NUMBER> > /tmp/pr_threads.json
```

This emits a JSON array of unresolved threads. Each looks like:

```json
{
  "thread_id": "PRRT_kwDO...",
  "path": "src/foo.py",
  "line": 42,
  "is_outdated": false,
  "comments": [
    { "id": "...", "author": "Copilot", "body": "Consider using a context manager here.", "created_at": "..." }
  ]
}
```

**Triage first.** Before doing any work, read every thread and sort it into one of four buckets:

- **Blocker** — correctness bugs, security issues, broken tests, missing error handling on real failure modes, or anything the reviewer explicitly flags as `CHANGES_REQUESTED`. The agent should fix these.
- **Auto-fixable nit** — small, obviously-right improvements the agent can apply with high confidence and little risk: a missing null check the reviewer spotted, a typo in a docstring, adding a docstring to a public function, a trivially better variable name in a narrow scope, a one-liner test for an uncovered branch. Fix these in the same round.
- **Deferrable nit** — style / readability / refactor suggestions that are reasonable but opinionated, cover ground outside the PR's stated scope, or would add meaningful churn. Don't auto-apply; collect these and hand them to the user in Phase 6 so they can choose: fix now, merge as-is, or track as a follow-up.
- **Needs user judgement** — architectural direction, naming taste in a broad scope, API shape, test strategy, anything where the agent doesn't have enough context to make the call confidently. Surface immediately, don't guess.

For each thread, once you've decided the bucket:

1. **Read the comment in full**, including thread context. Don't skim — reviewers often pack multiple suggestions into one comment.
2. **Act according to the bucket:**
   - **Blocker / auto-fixable nit** — make the smallest code change that addresses the feedback.
   - **Deferrable nit** — leave the thread unresolved for now and remember it for the Phase 6 handoff list. Don't close it and don't apply a partial fix.
   - **Needs user judgement** — stop the loop, show the user the comment and what you'd do, ask how they want to handle it before continuing.
   - **Declining** (suggestion is wrong, based on a hallucinated API, or conflicts with a deliberate choice) — post a reply explaining why (`pr_reply_thread.sh`) and resolve the thread. Don't silently ignore feedback.
3. **Resolve the thread** once the fix is committed locally OR a reply explaining the decline has been posted. Do NOT resolve deferrable-nit threads — leaving them open is the signal that they're outstanding work.
   ```bash
   bash scripts/pr_resolve_thread.sh --thread-id <thread_id>
   ```

If a thread is `is_outdated: true`, the line it references no longer exists in the diff. Read the comment anyway — the underlying concern may apply elsewhere — but it's usually safe to resolve outdated threads with a brief reply if the issue has already been addressed by another change.

**If a round produces only deferrable nits and no blockers/auto-fixables,** skip Phase 5 entirely and go straight to Phase 6. There is nothing to push, and re-requesting review would just generate another round of the same nits.

### Phase 5 — Push the fixes and re-request review

Once all threads in this round are addressed:

```bash
bash scripts/pr_push_update.sh --pr <PR_NUMBER> --message "Address review feedback: <short summary>"
```

The script:
- Stages modified tracked files and commits them along with anything already staged (skips if nothing to commit, which is fine — replies-only rounds are valid). Untracked files are *not* swept up automatically — if the agent has created new files that belong in the PR, `git add` them first before calling this script.
- Prints `git status --short` before committing so you can see what's going in.
- Pushes the branch.
- Re-requests Copilot review (existing review state goes stale once new commits land).

Then return to Phase 3. The polling loop resumes.

### Phase 6 — Hand off to the user

Reach this phase when any of these are true:
- `pr_check.sh` reports `STATUS=CLEAN` (everything resolved, at least one review submitted).
- The only unresolved threads left are **deferrable nits** — blockers and auto-fixable items are all done.
- A **needs-user-judgement** thread has paused the loop and you're asking for direction.

Steps:

1. Run `bash scripts/pr_status.sh --pr <PR_NUMBER>` for a final summary (review states, mergeable status, CI checks).
2. Tell the user the current state and link to the PR. Be explicit about what's done and what isn't:
   - List any **deferrable nits** you chose not to auto-apply, one line each with the file/line and a short paraphrase of the suggestion. Say *why* you deferred (scope, churn, opinionated).
   - Surface any **needs-user-judgement** thread with enough context for them to decide.
   - If everything really is resolved, just say so.
3. For any outstanding items, offer the user three explicit options:
   - **Fix now** — they pick which nits to apply; the agent handles them and loops once more.
   - **Merge as-is** — the remaining nits are acceptable to ship with. (The agent still does not auto-merge; see below.)
   - **Follow-up PR** — note the deferred items (e.g. a TODO list or a tracking issue); proceed to merge consideration.
4. **Do not auto-merge.** Merging is always the user's call — even on a fully clean PR, they may want to wait for human approval, CI to finish, or coordinate with other changes. Ask before merging.

## Heuristics for handling Copilot review specifically

Mapping Copilot's common comment types onto the Phase-4 triage buckets:

- **Potential bugs** (null checks, off-by-one, missing error handling) → **blocker or auto-fixable nit**. Take seriously; verify the concern is real (Copilot sometimes imagines bugs that aren't there) before applying.
- **Test coverage gaps** → **auto-fixable nit** when the uncovered branch is genuinely reachable and the test is small; **deferrable nit** when writing the test would balloon the PR.
- **Documentation** → **auto-fixable nit** for public API; **deferrable nit** for private internals unless the reviewer explicitly pushes back.
- **Style / readability nits** → **deferrable nit** by default. Only auto-apply when the improvement is obvious and the change is one line. Pure preference fixes are a classic source of churn — leave them for the user to accept or drop.
- **Rename / refactor suggestions** → **deferrable nit** unless the scope is truly local (three-line function, etc.). Broader renames are **needs user judgement**.

When Copilot's suggestion is clearly wrong (it sometimes hallucinates APIs or misreads context), reply explaining why and resolve the thread. Don't apply incorrect "fixes" just to make the reviewer go away. If Copilot re-flags the same nit after a decline-with-reply, treat it as actively rejected on the second occurrence and move on; tell the user.

## Quick reference of scripts

| Script | Purpose |
|---|---|
| `scripts/pr_create.sh` | Push branch, open PR, request Copilot review |
| `scripts/pr_check.sh` | One-shot poll of PR review state — agent calls this in its loop |
| `scripts/pr_fetch_threads.sh` | Dump unresolved review threads as JSON |
| `scripts/pr_resolve_thread.sh` | Mark a review thread resolved |
| `scripts/pr_reply_thread.sh` | Post a reply on a review thread |
| `scripts/pr_push_update.sh` | Commit + push + re-request review |
| `scripts/pr_status.sh` | High-level PR state (reviews, checks, mergeable) |

For deeper detail on the GitHub APIs used and common failure modes, see `references/troubleshooting.md`.
