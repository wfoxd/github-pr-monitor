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

REPO_FULL="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

echo ">> Requesting Copilot review..." >&2
bash "$(dirname "$0")/_request_copilot_review.sh" --pr "$PR_NUMBER" --repo "$REPO_FULL" || true

# --- Final parseable output ----------------------------------------------

echo "PR_NUMBER=$PR_NUMBER"
echo "PR_URL=$PR_URL"
