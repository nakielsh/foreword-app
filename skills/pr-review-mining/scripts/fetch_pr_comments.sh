#!/usr/bin/env bash
# Fetch PR review comments for a given timeframe and reviewer.
# Output: /tmp/pr_review_<tag>/{prs.json, pr_<num>.json, reviews_<num>.json, issue_<num>.json}
#
# Usage:
#   fetch_pr_comments.sh <timeframe> [reviewer]
#   timeframe: 1m|3m|6m|1y (default 6m)
#   reviewer:  GitHub login (default: current authenticated user)
#
# Requires: gh CLI authenticated, jq, run inside a git repo with a GitHub remote
#           (or set REPO=owner/name in env).
set -euo pipefail

TIMEFRAME="${1:-6m}"
REVIEWER="${2:-}"

# resolve timeframe → ISO date
case "$TIMEFRAME" in
  1m) MONTHS=1 ;;
  3m) MONTHS=3 ;;
  6m) MONTHS=6 ;;
  1y) MONTHS=12 ;;
  *) echo "unknown timeframe: $TIMEFRAME (use 1m|3m|6m|1y)" >&2; exit 1 ;;
esac

if date -v-1m +%Y-%m-%d >/dev/null 2>&1; then
  SINCE=$(date -v-"${MONTHS}"m +%Y-%m-%d)
else
  SINCE=$(date -d "${MONTHS} months ago" +%Y-%m-%d)
fi

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
REVIEWER="${REVIEWER:-$(gh api user --jq .login)}"

OUT="/tmp/pr_review_${TIMEFRAME}"
mkdir -p "$OUT"

echo "repo:      $REPO"
echo "reviewer:  $REVIEWER"
echo "since:     $SINCE"
echo "out:       $OUT"
echo

# 1. PR list (open + closed; --state=all is rejected by gh)
gh search prs --repo "$REPO" --reviewed-by="$REVIEWER" --updated=">=$SINCE" \
  --limit 200 --state=open \
  --json number,title,author,state,createdAt > "$OUT/_open.json"

gh search prs --repo "$REPO" --reviewed-by="$REVIEWER" --updated=">=$SINCE" \
  --limit 200 --state=closed \
  --json number,title,author,state,createdAt > "$OUT/_closed.json"

jq -s 'add | unique_by(.number)' "$OUT/_open.json" "$OUT/_closed.json" > "$OUT/prs.json"
rm "$OUT/_open.json" "$OUT/_closed.json"

# Drop PRs authored by the reviewer themselves and bots
jq --arg user "$REVIEWER" '
  map(select(
    .author.login != $user and
    (.author.is_bot // false) == false and
    (.author.login | test("(?i)dependabot|renovate|github-actions") | not)
  ))
' "$OUT/prs.json" > "$OUT/prs.filtered.json"
mv "$OUT/prs.filtered.json" "$OUT/prs.json"

PR_NUMS=$(jq -r '.[].number' "$OUT/prs.json")
COUNT=$(echo "$PR_NUMS" | wc -l | tr -d ' ')
echo "PRs to mine: $COUNT"

# 2. comment streams per PR
for PR in $PR_NUMS; do
  gh api "repos/$REPO/pulls/$PR/comments" --paginate \
    --jq '.[] | {pr: '"$PR"', user: .user.login, path: .path, line: (.line // .original_line), body: .body, created: .created_at}' \
    > "$OUT/pr_${PR}.json"

  gh api "repos/$REPO/pulls/$PR/reviews" \
    --jq '.[] | select(.body != "") | {pr: '"$PR"', user: .user.login, state: .state, body: .body, created: .submitted_at}' \
    > "$OUT/reviews_${PR}.json"

  gh api "repos/$REPO/issues/$PR/comments" \
    --jq '.[] | {pr: '"$PR"', user: .user.login, body: .body, created: .created_at}' \
    > "$OUT/issue_${PR}.json"
done

# 3. summary
TOTAL_INLINE=$(cat "$OUT"/pr_*.json 2>/dev/null | wc -l | tr -d ' ')
TOTAL_REVIEW=$(cat "$OUT"/reviews_*.json 2>/dev/null | wc -l | tr -d ' ')
TOTAL_ISSUE=$(cat "$OUT"/issue_*.json 2>/dev/null | wc -l | tr -d ' ')
echo
echo "fetched:"
echo "  inline review comments: $TOTAL_INLINE"
echo "  review summary bodies:  $TOTAL_REVIEW"
echo "  issue (top-level):      $TOTAL_ISSUE"
echo
echo "files in $OUT/"
