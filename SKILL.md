---
name: github-pr-monitor
description: Use this skill in an IDE coding agent (Claude Code, Cursor, Cline, etc.) once local code changes are ready to ship through a pull request. It pushes the branch, opens a PR, requests a GitHub Copilot code review, then has the agent itself act as the monitor — polling the PR every minute, reading any unresolved review threads, fixing the code, pushing again, and re-requesting review — looping until the PR has zero unresolved review threads. Trigger this skill whenever the user says things like "open a PR and iterate on the review", "push this and have Copilot review it", "monitor the PR until it's clean", "ship this and handle review comments", or any agentic ship-and-iterate workflow on GitHub. Designed for IDE contexts where the agent is continuously available — not for fire-and-forget background automation.
---

# GitHub PR Monitor

An agentic workflow for shipping local changes through a pull request and iterating on review feedback automatically until the PR is clean.

## Design: the agent is the monitor

This skill is built for IDE coding agents (Claude Code, Cursor, Cline, etc.) where the agent is always present and reasoning. There is no background daemon. The "monitor" is the agent itself, sitting in a loop that:

1. Calls `pr_check.sh` (a one-shot status query — fast, no blocking).
2. Reads the result and reasons about it.
3. Either acts (fixes review comments, pushes), waits (`sleep 60` then re-checks), or stops (PR is clean, error, or user interrupt).

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
| `REVIEW_PENDING`  | Unresolved review threads exist.                      | Jump to Phase 4 (fetch and address).               |
| `CLEAN`           | Zero unresolved threads, ≥1 review submitted.         | Jump to Phase 6 (done).                            |
| `ERROR`           | PR closed/merged, or API failure.                     | Surface to user; stop the loop.                    |

**Heartbeat to the user.** On every poll iteration in the `WAITING` state, output one short line of progress to the user — this is an IDE, they're watching. Example: `> Poll 3 (3 min elapsed): no reviews yet, will check again in 60s.` Do not spam status — one line per minute is plenty.

**Loop guards (to surface to user instead of grinding forever):**

- After **10 minutes** of `WAITING` with no reviews submitted at all, pause and ask the user: "Copilot hasn't started reviewing — is Copilot code review enabled on this repo? Want me to keep waiting or stop?" Sometimes Copilot takes 1–3 minutes; sometimes it never engages because the org doesn't have it enabled.
- After **60 minutes total** in the loop without convergence, surface to user — something is off.
- If the **same review thread comes back unresolved twice in a row** after the agent claimed to fix it: stop and ask. Either the fix didn't land, or it didn't satisfy the reviewer.
- More than **5 push-and-review rounds** without reaching `CLEAN`: surface and summarise what's been tried.
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

For each thread:

1. **Read the comment in full**, including thread context. Don't skim — reviewers often pack multiple suggestions into one comment.
2. **Decide how to respond.** Three valid outcomes:
   - **Apply the fix** — make the smallest code change that addresses the feedback.
   - **Decline with reason** — if the suggestion is wrong, out of scope, or conflicts with another constraint, post a reply explaining why (`pr_reply_thread.sh`) and resolve the thread. Don't silently ignore feedback.
   - **Ask the user** — if the feedback involves a judgement call (architectural direction, naming taste, scope), surface it and wait. Don't guess on substantive design decisions.
3. **Resolve the thread** once the fix is committed locally OR a reply explaining the decline has been posted:
   ```bash
   bash scripts/pr_resolve_thread.sh --thread-id <thread_id>
   ```

If a thread is `is_outdated: true`, the line it references no longer exists in the diff. Read the comment anyway — the underlying concern may apply elsewhere — but it's usually safe to resolve outdated threads with a brief reply if the issue has already been addressed by another change.

### Phase 5 — Push the fixes and re-request review

Once all threads in this round are addressed:

```bash
bash scripts/pr_push_update.sh --pr <PR_NUMBER> --message "Address review feedback: <short summary>"
```

The script:
- Stages and commits any uncommitted changes (skips if nothing to commit, which is fine — replies-only rounds are valid).
- Pushes the branch.
- Re-requests Copilot review (existing review state goes stale once new commits land).

Then return to Phase 3. The polling loop resumes.

### Phase 6 — PR is clean

When `pr_check.sh` reports `STATUS=CLEAN`:

1. Run `bash scripts/pr_status.sh --pr <PR_NUMBER>` for a final summary (review states, mergeable status, CI checks).
2. Tell the user the PR is ready and link to it.
3. **Do not auto-merge.** Merging is the user's call — even on a clean PR, they may want to wait for human approval, CI to finish, or coordinate the merge with other changes. Ask before merging.

## Heuristics for handling Copilot review specifically

GitHub Copilot's review tends to flag:

- **Style / readability nits** — apply when reasonable, but don't churn over pure preference.
- **Potential bugs** (null checks, off-by-one, missing error handling) — take seriously, verify the concern is real before fixing.
- **Test coverage gaps** — add tests when the suggestion identifies a genuinely uncovered branch.
- **Documentation** — apply for public API; defer for private internals unless the reviewer pushes back.

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
