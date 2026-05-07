#!/usr/bin/env bash
# pr_status.sh — High-level summary of a PR: reviews, threads, checks, mergeable.
#
# Usage:
#   pr_status.sh --pr <number>
#
# Output: KEY=VALUE lines on stdout; human-readable progress on stderr.

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
      url
      title
      state
      mergeable
      reviewDecision
      isDraft
      reviewThreads(first:100){ nodes{ isResolved isOutdated } }
      reviews(last:50){ nodes{ state author{ login } submittedAt } }
      commits(last:1){ nodes{ commit{ statusCheckRollup{ state } } } }
    }
  }
}'

RESP="$(gh api graphql -f query="$QUERY" -F owner="$OWNER" -F name="$NAME" -F pr="$PR")"
PR_DATA="$(echo "$RESP" | jq '.data.repository.pullRequest')"

URL="$(echo "$PR_DATA"      | jq -r '.url')"
TITLE="$(echo "$PR_DATA"    | jq -r '.title')"
STATE="$(echo "$PR_DATA"    | jq -r '.state')"
MERGEABLE="$(echo "$PR_DATA" | jq -r '.mergeable')"
DECISION="$(echo "$PR_DATA"  | jq -r '.reviewDecision // "none"')"
DRAFT="$(echo "$PR_DATA"     | jq -r '.isDraft')"
CHECKS="$(echo "$PR_DATA"    | jq -r '.commits.nodes[0].commit.statusCheckRollup.state // "none"')"
TOTAL_THREADS="$(echo "$PR_DATA"   | jq '.reviewThreads.nodes | length')"
UNRESOLVED="$(echo "$PR_DATA"      | jq '[.reviewThreads.nodes[] | select(.isResolved==false)] | length')"
LATEST_REVIEWS="$(echo "$PR_DATA"  | jq -r '.reviews.nodes
                                            | group_by(.author.login)
                                            | map(max_by(.submittedAt))
                                            | map("\(.author.login): \(.state)")
                                            | join(", ")')"

cat <<EOF
TITLE=$TITLE
URL=$URL
STATE=$STATE
DRAFT=$DRAFT
MERGEABLE=$MERGEABLE
REVIEW_DECISION=$DECISION
CHECKS=$CHECKS
THREADS_TOTAL=$TOTAL_THREADS
THREADS_UNRESOLVED=$UNRESOLVED
LATEST_REVIEWS=${LATEST_REVIEWS:-none}
EOF
