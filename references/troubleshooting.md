# Troubleshooting & background

Read this when something doesn't work or when you need to understand *why* the scripts do what they do.

## Authentication

All scripts assume `gh auth status` succeeds. If it doesn't:

- `gh auth login` for interactive login.
- For headless use, set `GH_TOKEN` to a PAT with `repo` scope.
- Token must have permission to push to the repo and request reviewers. For Copilot review specifically, the org also needs Copilot Enterprise / Copilot Pro+ with code review enabled at the org and repo level.

## Why GraphQL for review threads

GitHub's REST API for review comments (`/pulls/:n/comments`) doesn't expose thread resolution status. The "is this comment addressed?" signal lives only on the GraphQL `PullRequestReviewThread` type via `isResolved`. That's why `pr_check.sh`, `pr_fetch_threads.sh`, and `pr_resolve_thread.sh` all use GraphQL.

A practical implication: you'll see GraphQL node ids like `PRRT_kwDO...` (review thread) and `PRRC_kwDO...` (review comment) flowing through the scripts. They're opaque — pass them through verbatim.

## Why `pr_reply_thread.sh` translates the comment id

Replying to a thread uses the REST endpoint `POST /repos/{repo}/pulls/{pr}/comments/{comment_id}/replies`, which expects the *numeric* (databaseId) form of the comment id, not the GraphQL node id. The script handles the translation if you pass it a node id, but it's worth knowing if you debug this path.

## Re-requesting Copilot review after a new push

When new commits land on a PR, GitHub does **not** automatically re-trigger Copilot review. The previous review state stays attached to the old commit. You have to explicitly re-request the reviewer, which is why `pr_push_update.sh` calls `_request_copilot_review.sh` on every push.

### Why `gh pr edit --add-reviewer` doesn't work for Copilot

Copilot is a **Bot** type in GitHub's schema, not a User. `gh pr edit --add-reviewer Copilot` silently exits 0 without doing anything (it doesn't treat this as an error). The REST `requested_reviewers` endpoint returns HTTP 422 for bot accounts. Both approaches look like they worked but don't.

The correct path is the GraphQL `requestReviews` mutation with the `botIds` field (distinct from `userIds` and `teamIds`). Copilot's node id has a `BOT_...` prefix and must be passed as a bot id. `_request_copilot_review.sh` handles this, including a local cache so the node id doesn't need to be re-discovered on every call.

### Resolving Copilot's node id

The helper tries four sources in order:

1. **Cache** — `${XDG_CACHE_HOME:-~/.cache}/github-pr-monitor/copilot_node_id_<owner>_<name>` (written on first success)
2. **`suggestedReviewers`** on this PR — works before Copilot has submitted a review (typed as `User` in this context, uses `... on User { id login }`)
3. **`reviews` on this PR** — once Copilot has reviewed, its node id appears in past reviews (typed as `Bot`, uses `... on Bot { id login }`)
4. **Recent PRs on the repo** — last-resort scan of the repo's last 20 PRs for any Copilot review author id

If none of the four resolves an id, Copilot code review is likely not enabled on the repo. The PR remains open and human-reviewer threads still flow through the loop.

## Detecting a "clean" PR

`pr_check.sh` reports `STATUS=CLEAN` when both:
- The number of unresolved review threads is zero.
- At least one review has been submitted on the PR (otherwise "zero unresolved" is just "nobody has reviewed yet").

`reviewDecision` from the GraphQL query can be one of `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or `null`. The skill propagates this in `REVIEW_DECISION=` so the agent can decide whether to ping the user about an approval before merging.

## Why the loop lives in the agent, not in a script

Earlier drafts had a `pr_wait.sh` that polled internally and blocked for up to an hour. That was wrong for an interactive agent context. A blocking shell loop means:

- The user can't interject mid-wait without breaking the script.
- The agent can't reason between polls — it just gets one notification an hour later when the script finally returns.
- Anomalies (Copilot never started, weird transient errors) get noticed only at the end.
- The script's idea of "what to do next" is hardcoded in shell rather than in the agent's reasoning.

The current design — `pr_check.sh` as a one-shot, agent runs `sleep 60` between calls — costs one tool-call cycle per minute but gives the agent full control: it narrates progress, notices stalls, takes user input, and adjusts strategy on every poll. That's the whole point of an agentic skill.

## Common failure modes

**`gh auth status` fails mid-loop.** Tokens can expire. `pr_check.sh` will print `STATUS=ERROR` and a message; the agent should surface to the user rather than blindly retrying. A one-off transient error is fine to retry once on the next minute's poll.

**Push rejected (non-fast-forward).** Usually means someone (a maintainer, or Copilot via "commit suggested change") pushed to the branch from the GitHub UI. `pr_push_update.sh` does NOT auto-rebase; if the push fails, the agent should `git fetch && git pull --rebase`, resolve any conflicts with the user, then call `pr_push_update.sh` again.

**Same comment keeps coming back.** Either the fix didn't actually address the reviewer's point, or the change wasn't pushed, or a commit was amended without force-push. The skill's loop-termination rule catches this: if a thread reappears unresolved after the agent claimed to fix it, stop and surface to the user.

**Copilot keeps making the same nit-pick suggestion every round.** Sometimes Copilot will re-flag a style choice the agent declined. After two rounds of decline-with-reply, treat the suggestion as actively rejected and stop addressing it; surface to the user that Copilot disagrees but you've moved on.

**PR has merge conflicts.** GraphQL `mergeable` returns `CONFLICTING`. The skill doesn't auto-resolve conflicts — that needs human judgement. Surface and stop the loop.

## Rate limits

GraphQL queries against the GitHub API are rate-limited at ~5000 points/hour for authenticated tokens. Each query costs roughly 1 point. The agent polls once per minute = ~60 points/hour, well within budget even with several PRs running in parallel. The Copilot re-request adds one extra mutation + one verification query per push — negligible overhead.

## Manual escape hatch

If the loop misbehaves, the user can always:
- Open the PR in the browser, address comments by hand, push, and tell the agent "the PR is done" so it skips to `pr_status.sh` and stops.
- Just type a message to the agent — since the agent runs the loop itself between short `sleep 60` calls, the user can interject naturally between polls without killing anything.
