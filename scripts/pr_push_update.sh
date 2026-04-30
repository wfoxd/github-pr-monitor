#!/usr/bin/env bash
# pr_push_update.sh — Commit any pending changes, push, re-request Copilot review.
#
# Usage:
#   pr_push_update.sh --pr <number> [--message "commit message"]
#
# Behaviour:
#   - If there are uncommitted changes and --message is given, stages all and commits.
#   - If there are uncommitted changes but no --message, errors out.
#   - If there are no uncommitted changes, just pushes (handles reply-only rounds).
#   - Always pushes and re-requests Copilot review at the end.

set -euo pipefail

PR=""
MESSAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)      PR="$2";      shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$PR" ]] && { echo "ERROR: --pr required" >&2; exit 2; }

# --- Commit if there are changes -----------------------------------------

if ! git diff --quiet || ! git diff --cached --quiet; then
  if [[ -z "$MESSAGE" ]]; then
    echo "ERROR: uncommitted changes present but no --message provided" >&2
    git status --short >&2
    exit 1
  fi
  echo ">> Staging and committing changes..." >&2
  git add -A
  git commit -m "$MESSAGE"
else
  echo ">> No uncommitted changes; nothing to commit." >&2
fi

# --- Push only if local is ahead of remote -------------------------------

LOCAL="$(git rev-parse @)"
REMOTE="$(git rev-parse '@{upstream}' 2>/dev/null || echo "")"

if [[ -z "$REMOTE" ]]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  echo ">> No upstream set; pushing with -u..." >&2
  git push -u origin "$BRANCH"
elif [[ "$LOCAL" != "$REMOTE" ]]; then
  echo ">> Pushing commits to remote..." >&2
  git push
else
  echo ">> Remote is up to date; skipping push." >&2
fi

# --- Re-request Copilot review -------------------------------------------
#
# Once new commits land, the previous Copilot review state is stale. Re-request
# so it reviews the new diff. Skip silently if Copilot isn't available.

REPO_FULL="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

if gh pr edit "$PR" --add-reviewer Copilot >/dev/null 2>&1; then
  echo ">> Copilot re-review requested." >&2
elif gh api -X POST "/repos/$REPO_FULL/pulls/$PR/requested_reviewers" \
       -f 'reviewers[]=copilot-pull-request-reviewer' >/dev/null 2>&1; then
  echo ">> Copilot re-review requested." >&2
else
  echo ">> WARNING: could not re-request Copilot review (continuing anyway)." >&2
fi
