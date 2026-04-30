#!/usr/bin/env bash
# pr_reply_thread.sh — Reply to a review thread on a PR.
#
# Usage:
#   pr_reply_thread.sh --pr <number> --comment-id <id> --body <text>
#
# --comment-id is the id of any existing comment in the thread to reply to;
# the easiest source is comments[0].id from pr_fetch_threads.sh.
#
# GitHub's REST endpoint for review-comment replies takes the numeric (REST)
# id of a comment, not the GraphQL node id. We translate via gh api.

set -euo pipefail

PR=""
COMMENT_ID=""
BODY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)         PR="$2";         shift 2 ;;
    --comment-id) COMMENT_ID="$2"; shift 2 ;;
    --body)       BODY="$2";       shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$PR" || -z "$COMMENT_ID" || -z "$BODY" ]] && \
  { echo "ERROR: --pr, --comment-id, and --body all required" >&2; exit 2; }

REPO_FULL="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# If COMMENT_ID looks like a GraphQL node id (non-numeric), resolve it to the REST databaseId.
if [[ ! "$COMMENT_ID" =~ ^[0-9]+$ ]]; then
  REST_ID="$(gh api graphql \
    -f query='query($id:ID!){ node(id:$id){ ... on PullRequestReviewComment { databaseId } } }' \
    -F id="$COMMENT_ID" | jq -r '.data.node.databaseId')"
  if [[ -z "$REST_ID" || "$REST_ID" == "null" ]]; then
    echo "ERROR: could not resolve $COMMENT_ID to a REST id" >&2; exit 1
  fi
  COMMENT_ID="$REST_ID"
fi

gh api -X POST "/repos/$REPO_FULL/pulls/$PR/comments/$COMMENT_ID/replies" \
  -f body="$BODY" >/dev/null

echo "Reply posted on comment $COMMENT_ID."
