#!/usr/bin/env bash
# pr_create.sh — Push the current branch, open (or reuse) a PR, request Copilot review.
#
# Usage:
#   pr_create.sh [--title TITLE] [--body BODY] [--base BASE]
#
# Output (last lines, parseable):
#   PR_NUMBER=<n>
#   PR_URL=<url>
#
# Exits non-zero on failure. Copilot review-request failure is a warning, not a failure.

set -euo pipefail

TITLE=""
BODY=""
BASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="$2"; shift 2 ;;
    --body)  BODY="$2";  shift 2 ;;
    --base)  BASE="$2";  shift 2 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- Sanity checks --------------------------------------------------------

command -v gh >/dev/null || { echo "ERROR: gh CLI not installed" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. Run 'gh auth login'." >&2; exit 1; }

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository" >&2; exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" == "HEAD" ]]; then
  echo "ERROR: detached HEAD — check out a feature branch first" >&2; exit 1
fi

# Determine default base branch if not given
if [[ -z "$BASE" ]]; then
  BASE="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || echo main)"
fi

if [[ "$BRANCH" == "$BASE" ]]; then
  echo "ERROR: you are on the base branch ($BASE); switch to a feature branch first" >&2; exit 1
fi

# --- Push ----------------------------------------------------------------

echo ">> Pushing branch $BRANCH..." >&2
if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
  git push
else
  git push -u origin "$BRANCH"
fi

# --- Reuse or create PR --------------------------------------------------

EXISTING_PR="$(gh pr list --head "$BRANCH" --state open --json number,url --limit 1)"
PR_NUMBER="$(echo "$EXISTING_PR" | jq -r '.[0].number // empty')"
PR_URL="$(echo "$EXISTING_PR" | jq -r '.[0].url // empty')"

if [[ -n "$PR_NUMBER" ]]; then
  echo ">> Reusing existing PR #$PR_NUMBER ($PR_URL)" >&2
else
  echo ">> Creating new PR against $BASE..." >&2
  if [[ -n "$TITLE" ]]; then
    PR_URL="$(gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "${BODY:-}")"
  else
    PR_URL="$(gh pr create --base "$BASE" --head "$BRANCH" --fill)"
  fi
  PR_NUMBER="$(echo "$PR_URL" | grep -oE '[0-9]+$')"
  echo ">> Created PR #$PR_NUMBER" >&2
fi

# --- Request Copilot review ----------------------------------------------
#
# Method 1: gh pr edit --add-reviewer Copilot (newer gh versions)
# Method 2: REST API requested_reviewers endpoint
# Both can fail if the org doesn't have Copilot code review enabled — that is
# a warning, not a fatal error.

echo ">> Requesting Copilot review..." >&2

REPO_FULL="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
COPILOT_OK=0

if gh pr edit "$PR_NUMBER" --add-reviewer Copilot >/dev/null 2>&1; then
  COPILOT_OK=1
elif gh api -X POST "/repos/$REPO_FULL/pulls/$PR_NUMBER/requested_reviewers" \
       -f 'reviewers[]=copilot-pull-request-reviewer' >/dev/null 2>&1; then
  COPILOT_OK=1
fi

if [[ "$COPILOT_OK" -eq 1 ]]; then
  echo ">> Copilot review requested." >&2
else
  echo ">> WARNING: could not request Copilot review automatically." >&2
  echo "   The PR is open and the loop will still work for any reviewer's comments." >&2
  echo "   Possible causes: org has not enabled Copilot code review, or repo lacks the entitlement." >&2
fi

# --- Final parseable output ----------------------------------------------

echo "PR_NUMBER=$PR_NUMBER"
echo "PR_URL=$PR_URL"
