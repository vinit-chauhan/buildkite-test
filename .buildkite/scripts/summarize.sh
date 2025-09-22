#!/usr/bin/env bash
set -euo pipefail
mkdir -p work/summary
buildkite-agent artifact download "work/*/result.json" work/summary >/dev/null 2>&1 || true

jq -s '
  ( . // [] ) as $arr
  | {
      total: ($arr | length),
      passed: ($arr | map(select(.status=="passed")) | length),
      failed: ($arr | map(select(.status=="failed")) | length),
      not_found: ($arr | map(select(.status=="not_found")) | length),
      results: $arr
    }
' work/summary/*.json 2>/dev/null > work/summary/report.json || echo '{"total":0,"results":[]}' > work/summary/report.json

echo "Summary:"
jq -C . work/summary/report.json || cat work/summary/report.json

# Optional: comment back to the issue using a GitHub token on the agent.
if [[ -n "${ISSUE_REPO:-}" && -n "${ISSUE_NUMBER:-}" && -n "${GITHUB_TOKEN:-}" ]]; then
  mapfile -t lines < <(jq -r '.results[] | "- \(.integration): \(.status)"' work/summary/report.json)
  {
    echo "elastic-package check summary for Issue #${ISSUE_NUMBER}:"
    printf "%s\n" "${lines[@]}"
  } > work/summary/comment.txt
  gh issue comment "$ISSUE_NUMBER" -R "$ISSUE_REPO" -F work/summary/comment.txt || true
fi

buildkite-agent artifact upload "work/summary/report.json"

