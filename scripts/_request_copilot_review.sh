#!/usr/bin/env bash
# _request_copilot_review.sh — Request or re-request a Copilot review on a PR.
#
# Usage (sourced or called as a subprocess):
#   bash scripts/_request_copilot_review.sh --pr <number> --repo <owner/name>
#
# Strategy:
#   1. Look up Copilot's GraphQL node id. Check in order:
#      a. Cache file ~/.cache/github-pr-monitor/copilot_node_id
#         (keyed per repo so cross-repo installs don't collide).
#      b. PR's suggestedReviewers (works before first review).
#      c. PR's existing reviews (works after first review, when Copilot
#         drops off suggestedReviewers).
#   2. Call the GraphQL requestReviews mutation with that node id.
#   3. Re-query reviewRequests to confirm it actually landed.
#   4. On success, persist the node id to the cache.
#
# Exits 0 on success, 1 if Copilot review request couldn't be confirmed.
# Human-readable progress on stderr; nothing on stdout.

set -euo pipefail

PR=""
REPO_FULL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)   PR="$2";        shift 2 ;;
    --repo) REPO_FULL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -z "$PR" ]]        && { echo "ERROR: --pr required" >&2; exit 2; }
[[ -z "$REPO_FULL" ]] && { echo "ERROR: --repo required" >&2; exit 2; }

OWNER="${REPO_FULL%/*}"
NAME="${REPO_FULL#*/}"

# Cache path — keyed by repo slug so installs across repos don't collide.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/github-pr-monitor"
CACHE_KEY="$(echo "$REPO_FULL" | tr '/' '_')"
CACHE_FILE="$CACHE_DIR/copilot_node_id_${CACHE_KEY}"

# --- Step 1: resolve Copilot's node id -----------------------------------

COPILOT_NODE_ID=""

# 1a. Try the cache first.
if [[ -f "$CACHE_FILE" ]]; then
  COPILOT_NODE_ID="$(cat "$CACHE_FILE")"
  echo ">> Using cached Copilot node id: $COPILOT_NODE_ID" >&2
fi

# 1b. suggestedReviewers — reliable before first review on a PR.
if [[ -z "$COPILOT_NODE_ID" ]]; then
  SUGGEST_QUERY='query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        suggestedReviewers{ reviewer{ id login } }
      }
    }
  }'
  COPILOT_NODE_ID="$(gh api graphql \
    -f query="$SUGGEST_QUERY" \
    -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
    | jq -r '
        .data.repository.pullRequest.suggestedReviewers[]
        | select(.reviewer.login == "copilot-pull-request-reviewer")
        | .reviewer.id' 2>/dev/null || true)"
  [[ -n "$COPILOT_NODE_ID" ]] && echo ">> Found Copilot node id via suggestedReviewers." >&2
fi

# 1c. Past reviews — fallback once Copilot has already reviewed (drops off suggestedReviewers).
if [[ -z "$COPILOT_NODE_ID" ]]; then
  REVIEWS_QUERY='query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        reviews(last:50){ nodes{ author{ id login } } }
      }
    }
  }'
  COPILOT_NODE_ID="$(gh api graphql \
    -f query="$REVIEWS_QUERY" \
    -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
    | jq -r '
        .data.repository.pullRequest.reviews.nodes[]
        | select(.author.login == "copilot-pull-request-reviewer")
        | .author.id' 2>/dev/null | head -1 || true)"
  [[ -n "$COPILOT_NODE_ID" ]] && echo ">> Found Copilot node id via past reviews." >&2
fi

if [[ -z "$COPILOT_NODE_ID" ]]; then
  echo ">> WARNING: could not resolve Copilot's node id. Copilot code review may not be enabled on this repo." >&2
  echo "   The PR is open and the loop will still work for any human reviewer's comments." >&2
  exit 1
fi

# --- Step 2: get the PR's own node id ------------------------------------

PR_NODE_ID="$(gh api graphql \
  -f query='query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){ pullRequest(number:$pr){ id } }
  }' \
  -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
  | jq -r '.data.repository.pullRequest.id')"

# --- Step 3: call requestReviews mutation --------------------------------

gh api graphql \
  -f query='mutation($prId:ID!,$userIds:[ID!]!){
    requestReviews(input:{pullRequestId:$prId,userIds:$userIds,union:true}){
      pullRequest{ id }
    }
  }' \
  -F prId="$PR_NODE_ID" \
  -F 'userIds[]='"$COPILOT_NODE_ID" \
  >/dev/null

# --- Step 4: verify it actually landed -----------------------------------

CONFIRMED="$(gh api graphql \
  -f query='query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        reviewRequests(first:10){
          nodes{ requestedReviewer{ ... on User{ login } } }
        }
      }
    }
  }' \
  -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
  | jq -r '
      .data.repository.pullRequest.reviewRequests.nodes[]
      | .requestedReviewer.login // empty
      | select(. == "copilot-pull-request-reviewer")' 2>/dev/null || true)"

if [[ "$CONFIRMED" == "copilot-pull-request-reviewer" ]]; then
  echo ">> Copilot review requested and confirmed." >&2
  mkdir -p "$CACHE_DIR"
  echo "$COPILOT_NODE_ID" > "$CACHE_FILE"
  exit 0
else
  echo ">> WARNING: requestReviews mutation ran but Copilot did not appear in reviewRequests." >&2
  echo "   The PR is open and the loop will still work for any human reviewer's comments." >&2
  exit 1
fi
