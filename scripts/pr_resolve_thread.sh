#!/usr/bin/env bash
# pr_resolve_thread.sh — Mark a review thread as resolved on GitHub.
#
# Usage:
#   pr_resolve_thread.sh --thread-id <id>
#
# The thread ID is the GraphQL node id (starts with PRRT_), as emitted by
# pr_fetch_threads.sh.

set -euo pipefail

THREAD_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --thread-id) THREAD_ID="$2"; shift 2 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$THREAD_ID" ]] && { echo "ERROR: --thread-id required" >&2; exit 2; }

MUTATION='mutation($id:ID!){
  resolveReviewThread(input:{threadId:$id}){
    thread{ id isResolved }
  }
}'

RESP="$(gh api graphql -f query="$MUTATION" -F id="$THREAD_ID")"
RESOLVED="$(echo "$RESP" | jq -r '.data.resolveReviewThread.thread.isResolved')"

if [[ "$RESOLVED" == "true" ]]; then
  echo "Thread $THREAD_ID resolved."
else
  echo "ERROR: failed to resolve thread $THREAD_ID" >&2
  echo "$RESP" >&2
  exit 1
fi
