#!/usr/bin/env bash
# pr_push_update.sh — Commit any pending changes, push, re-request Copilot review.
#
# Usage:
#   pr_push_update.sh --pr <number> [--message "commit message"]
#
# Behaviour:
#   - If there are staged or modified-tracked changes and --message is given,
#     stages modified tracked files (NOT untracked) and commits. Any files the
#     caller has already `git add`ed (including new files they want included)
#     are committed too. Untracked files left in the working tree are ignored.
#   - The working-tree status is printed before committing so the caller can
#     see exactly what is going in.
#   - If there are uncommitted changes but no --message, errors out.
#   - If there is nothing to commit, just pushes (handles reply-only rounds).
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
#
# We intentionally do NOT `git add -A`: that would sweep up untracked files
# (stray .env, build artifacts, scratch notes) and commit them silently. We
# stage only modified-tracked files via `git add -u`; any untracked files the
# caller actually wants included should be `git add`ed before invoking this
# script — anything already staged is honoured.

HAS_STAGED=0; HAS_MODIFIED=0; HAS_UNTRACKED=0
git diff --cached --quiet || HAS_STAGED=1
git diff --quiet          || HAS_MODIFIED=1
[[ -n "$(git ls-files --others --exclude-standard)" ]] && HAS_UNTRACKED=1

if [[ "$HAS_STAGED" -eq 1 || "$HAS_MODIFIED" -eq 1 ]]; then
  if [[ -z "$MESSAGE" ]]; then
    echo "ERROR: uncommitted changes present but no --message provided" >&2
    git status --short >&2
    exit 1
  fi

  echo ">> Working-tree state before commit:" >&2
  git status --short >&2

  if [[ "$HAS_UNTRACKED" -eq 1 ]]; then
    echo ">> NOTE: untracked files above will NOT be committed. \`git add\` them first if you want them included." >&2
  fi

  echo ">> Staging modified tracked files and committing..." >&2
  git add -u
  git commit -m "$MESSAGE"
else
  echo ">> No tracked changes; nothing to commit." >&2
  if [[ "$HAS_UNTRACKED" -eq 1 ]]; then
    echo ">> NOTE: there are untracked files in the working tree that were NOT committed:" >&2
    git ls-files --others --exclude-standard >&2
    echo "   If any of these should be in the PR, \`git add\` them and call this script again." >&2
  fi
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
