#!/usr/bin/env bash
# _request_copilot_review.sh — Request or re-request a Copilot review on a PR.
#
# Usage:
#   bash scripts/_request_copilot_review.sh --pr <number> --repo <owner/name>
#
# Strategy:
#   1. Resolve Copilot's GraphQL node id (BOT_... prefix). Check in order:
#      a. Cache file ~/.cache/github-pr-monitor/copilot_node_id_<repo-slug>
#      b. PR's suggestedReviewers (works before first review)
#      c. PR's past reviews (fallback once Copilot drops off suggestedReviewers)
#   2. Call requestReviews GraphQL mutation using the botIds field.
#   3. Verify by re-querying reviewRequests; warn if it didn't land.
#   4. On success, persist the node id to the cache.
#
# Exits 0 on success, 1 if Copilot review couldn't be confirmed.
# Progress on stderr; nothing on stdout.

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

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/github-pr-monitor"
CACHE_KEY="$(echo "$REPO_FULL" | tr '/' '_')"
CACHE_FILE="$CACHE_DIR/copilot_node_id_${CACHE_KEY}"

# --- Step 1: resolve Copilot's bot node id --------------------------------

COPILOT_NODE_ID=""

# 1a. Try the cache first.
if [[ -f "$CACHE_FILE" ]]; then
  COPILOT_NODE_ID="$(cat "$CACHE_FILE")"
  echo ">> Using cached Copilot node id: $COPILOT_NODE_ID" >&2
fi

# 1b. suggestedReviewers — Bot type, not User.
if [[ -z "$COPILOT_NODE_ID" ]]; then
  COPILOT_NODE_ID="$(gh api graphql \
    -f query='query($owner:String!,$name:String!,$pr:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$pr){
          suggestedReviewers{ reviewer{ ... on User{ id login } } }
        }
      }
    }' \
    -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
    | jq -r '
        .data.repository.pullRequest.suggestedReviewers[]
        | select(.reviewer.login == "copilot-pull-request-reviewer")
        | .reviewer.id' 2>/dev/null || true)"
  [[ -n "$COPILOT_NODE_ID" ]] && echo ">> Found Copilot node id via suggestedReviewers." >&2
fi

# 1c. Past reviews on this PR — works after first review, when Copilot
#     drops off suggestedReviewers.
if [[ -z "$COPILOT_NODE_ID" ]]; then
  COPILOT_NODE_ID="$(gh api graphql \
    -f query='query($owner:String!,$name:String!,$pr:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$pr){
          reviews(last:50){ nodes{ author{ ... on Bot{ id login } } } }
        }
      }
    }' \
    -F owner="$OWNER" -F name="$NAME" -F pr="$PR" \
    | jq -r '
        .data.repository.pullRequest.reviews.nodes[]
        | select(.author.login == "copilot-pull-request-reviewer")
        | .author.id' 2>/dev/null | head -1 || true)"
  [[ -n "$COPILOT_NODE_ID" ]] && echo ">> Found Copilot node id via this PR's past reviews." >&2
fi

# 1d. Any recent PR on the repo — last-resort for a brand-new PR when
#     suggestedReviewers is empty and no review exists yet on this PR.
if [[ -z "$COPILOT_NODE_ID" ]]; then
  COPILOT_NODE_ID="$(gh api graphql \
    -f query='query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        pullRequests(last:20,states:[OPEN,CLOSED,MERGED]){
          nodes{
            reviews(last:20){ nodes{ author{ ... on Bot{ id login } } } }
          }
        }
      }
    }' \
    -F owner="$OWNER" -F name="$NAME" \
    | jq -r '
        .data.repository.pullRequests.nodes[]
        | .reviews.nodes[]
        | select(.author.login == "copilot-pull-request-reviewer")
        | .author.id' 2>/dev/null | head -1 || true)"
  [[ -n "$COPILOT_NODE_ID" ]] && echo ">> Found Copilot node id via repo PR history." >&2
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

# --- Step 3: call requestReviews with botIds -----------------------------
#
# Copilot is a Bot, not a User — it must go in botIds, not userIds.

gh api graphql \
  -f query='mutation($prId:ID!,$botIds:[ID!]!){
    requestReviews(input:{pullRequestId:$prId,botIds:$botIds,union:true}){
      pullRequest{ id }
    }
  }' \
  -F prId="$PR_NODE_ID" \
  -F 'botIds[]='"$COPILOT_NODE_ID" \
  >/dev/null

# --- Step 4: verify it actually landed -----------------------------------

CONFIRMED="$(gh api graphql \
  -f query='query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        reviewRequests(first:10){
          nodes{ requestedReviewer{ ... on Bot{ login } ... on User{ login } } }
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
