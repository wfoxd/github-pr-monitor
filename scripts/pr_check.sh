#!/usr/bin/env bash
# pr_check.sh — One-shot poll of a PR's review state. No looping, no sleeping —
# the agent owns the loop. Designed for repeated invocation by an interactive
# coding agent (Claude Code, Cursor, Cline, etc.) once per polling interval.
#
# Usage:
#   pr_check.sh --pr <number>
#
# Output (parseable KEY=VALUE lines on stdout):
#   STATUS=REVIEW_PENDING   # unresolved review threads exist; agent should act
#   STATUS=CLEAN            # zero unresolved threads AND >=1 review submitted
#   STATUS=WAITING          # no reviews submitted yet; keep polling
#   STATUS=ERROR            # PR not OPEN, or API error
#   UNRESOLVED_COUNT=<n>
#   REVIEW_COUNT=<n>
#   REVIEW_DECISION=<APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED|null>
#   PR_STATE=<OPEN|CLOSED|MERGED>
#
# Stderr is reserved for human-readable progress; stdout for parseable output.

set -euo pipefail

PR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr) PR="$2"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$PR" ]] && { echo "ERROR: --pr required" >&2; exit 2; }

REPO_FULL="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
OWNER="${REPO_FULL%/*}"
NAME="${REPO_FULL#*/}"

QUERY='query($owner:String!,$name:String!,$pr:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$pr){
      state
      reviewDecision
      reviewThreads(first:100){
        nodes{ isResolved }
      }
      reviews(last:50){
        nodes{ state }
      }
    }
  }
}'

if ! RESP="$(gh api graphql -f query="$QUERY" \
               -F owner="$OWNER" -F name="$NAME" -F pr="$PR" 2>&1)"; then
  echo "STATUS=ERROR"
  echo "ERROR_MESSAGE=$RESP"
  exit 1
fi

STATE="$(echo "$RESP" | jq -r '.data.repository.pullRequest.state')"
UNRESOLVED="$(echo "$RESP" | jq '[.data.repository.pullRequest.reviewThreads.nodes[]
                                  | select(.isResolved==false)] | length')"
REVIEW_COUNT="$(echo "$RESP" | jq '.data.repository.pullRequest.reviews.nodes | length')"
DECISION="$(echo "$RESP" | jq -r '.data.repository.pullRequest.reviewDecision // "null"')"

echo "PR_STATE=$STATE"
echo "UNRESOLVED_COUNT=$UNRESOLVED"
echo "REVIEW_COUNT=$REVIEW_COUNT"
echo "REVIEW_DECISION=$DECISION"

if [[ "$STATE" != "OPEN" ]]; then
  echo "STATUS=ERROR"
  exit 0
fi

if [[ "$UNRESOLVED" -gt 0 ]]; then
  echo "STATUS=REVIEW_PENDING"
  exit 0
fi

if [[ "$REVIEW_COUNT" -gt 0 ]]; then
  echo "STATUS=CLEAN"
  exit 0
fi

echo "STATUS=WAITING"
