#!/usr/bin/env bash
# pr_fetch_threads.sh — Emit unresolved review threads on a PR as a JSON array.
#
# Usage:
#   pr_fetch_threads.sh --pr <number>
#
# Output: JSON array on stdout. Each element:
#   {
#     "thread_id":  "PRRT_...",
#     "path":       "src/foo.py",
#     "line":       42,
#     "is_outdated": false,
#     "comments": [
#       { "id":"...", "author":"Copilot", "body":"...", "created_at":"..." }
#     ]
#   }

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
      reviewThreads(first:100){
        nodes{
          id
          isResolved
          isOutdated
          path
          line
          comments(first:50){
            nodes{ id author{ login } body createdAt }
          }
        }
      }
    }
  }
}'

gh api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
  | jq '[.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.isResolved == false)
         | {
             thread_id: .id,
             path: .path,
             line: .line,
             is_outdated: .isOutdated,
             comments: [.comments.nodes[] | {
               id: .id,
               author: .author.login,
               body: .body,
               created_at: .createdAt
             }]
           }]'
