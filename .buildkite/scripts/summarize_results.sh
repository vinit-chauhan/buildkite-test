#!/usr/bin/env bash
set -euo pipefail

# Script to summarize all integration check results and update the GitHub issue

echo "=== Results Summary Script ==="
echo "Build: ${BUILDKITE_BUILD_NUMBER:-unknown}"
echo "Issue: #${ISSUE_NUMBER:-unknown} from ${ISSUE_REPO:-unknown}"

# Check required environment variables
missing_vars=()
[[ -z "${ISSUE_NUMBER:-}" ]] && missing_vars+=("ISSUE_NUMBER")
[[ -z "${ISSUE_REPO:-}" ]] && missing_vars+=("ISSUE_REPO")
[[ -z "${GITHUB_TOKEN:-}" ]] && missing_vars+=("GITHUB_TOKEN")

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "❌ Missing required environment variables:"
    printf '  - %s\n' "${missing_vars[@]}"
    exit 1
fi

echo "✅ All required variables present"

# Download all result artifacts
echo ""
echo "Downloading result artifacts..."

mkdir -p results

# Try to download artifacts if buildkite-agent is available
if command -v buildkite-agent >/dev/null 2>&1; then
    echo "Attempting to download artifacts using buildkite-agent..."
    if buildkite-agent artifact download "results/*.json" . 2>/dev/null; then
        echo "✅ Successfully downloaded artifacts"
    else
        echo "⚠️ No artifacts found to download, will check for local result files"
    fi
else
    echo "⚠️ buildkite-agent not available, checking for local result files"
fi

# Check if we have any results
if [[ ! -d results ]] || [[ -z "$(ls -A results 2>/dev/null)" ]]; then
    echo "❌ No result files found"
    exit 1
fi

echo "Found result files:"
ls -la results/

# Initialize summary data
TOTAL_INTEGRATIONS=0
PASSED_COUNT=0
FAILED_COUNT=0
RESULTS_JSON="[]"

# Process each result file
for result_file in results/*.json; do
    if [[ -f "$result_file" ]]; then
        echo "Processing: $result_file"
        
        INTEGRATION=$(jq -r '.integration' "$result_file")
        STATUS=$(jq -r '.status' "$result_file")
        MESSAGE=$(jq -r '.message // ""' "$result_file")
        
        echo "  Integration: $INTEGRATION"
        echo "  Status: $STATUS"
        
        # Add to summary
        RESULTS_JSON=$(echo "$RESULTS_JSON" | jq --arg integration "$INTEGRATION" \
                                                 --arg status "$STATUS" \
                                                 --arg message "$MESSAGE" \
                                                 --argjson result "$(cat "$result_file")" \
                                                 '. += [{"integration": $integration, "status": $status, "message": $message, "details": $result}]')
        
        ((TOTAL_INTEGRATIONS++))
        if [[ "$STATUS" == "passed" ]]; then
            ((PASSED_COUNT++))
        else
            ((FAILED_COUNT++))
        fi
    fi
done

echo ""
echo "Summary:"
echo "  Total integrations: $TOTAL_INTEGRATIONS"
echo "  Passed: $PASSED_COUNT"
echo "  Failed: $FAILED_COUNT"

# Generate summary report
SUMMARY_FILE="build-summary.json"
cat > "$SUMMARY_FILE" << EOF
{
  "build_number": "${BUILDKITE_BUILD_NUMBER:-}",
  "build_url": "${BUILDKITE_BUILD_URL:-}",
  "issue_number": "${ISSUE_NUMBER}",
  "issue_repo": "${ISSUE_REPO}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "total_integrations": $TOTAL_INTEGRATIONS,
  "passed_count": $PASSED_COUNT,
  "failed_count": $FAILED_COUNT,
  "success_rate": $(echo "scale=2; $PASSED_COUNT * 100 / $TOTAL_INTEGRATIONS" | bc -l 2>/dev/null || echo "0"),
  "results": $RESULTS_JSON
}
EOF

echo "Generated summary file: $SUMMARY_FILE"

# Create GitHub comment
echo ""
echo "Creating GitHub comment..."

# Install GitHub CLI if needed
if ! command -v gh >/dev/null 2>&1; then
    echo "Installing GitHub CLI..."
    
    # For Ubuntu/Debian
    if command -v apt-get >/dev/null 2>&1; then
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt update && sudo apt install gh -y
    else
        echo "❌ Cannot install GitHub CLI automatically"
        exit 1
    fi
fi

# Authenticate GitHub CLI
echo "${GITHUB_TOKEN}" | gh auth login --with-token

# Generate comment body
COMMENT_BODY="## 🔍 Integration Check Results

**Build:** [#${BUILDKITE_BUILD_NUMBER:-unknown}](${BUILDKITE_BUILD_URL:-})
**Timestamp:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')

### Summary
- **Total Integrations:** $TOTAL_INTEGRATIONS
- **Passed:** ✅ $PASSED_COUNT
- **Failed:** ❌ $FAILED_COUNT
- **Success Rate:** $(echo "scale=1; $PASSED_COUNT * 100 / $TOTAL_INTEGRATIONS" | bc -l 2>/dev/null || echo "0")%

### Detailed Results"

# Add each result to comment
while IFS= read -r result; do
    INTEGRATION=$(echo "$result" | jq -r '.integration')
    STATUS=$(echo "$result" | jq -r '.status')
    MESSAGE=$(echo "$result" | jq -r '.message')
    
    if [[ "$STATUS" == "passed" ]]; then
        ICON="✅"
    else
        ICON="❌"
    fi
    
    COMMENT_BODY="${COMMENT_BODY}
- ${ICON} **${INTEGRATION}**: ${MESSAGE}"

    # Add PR link if available
    PR_URL=$(echo "$result" | jq -r '.details.pr_url // empty')
    if [[ -n "$PR_URL" ]]; then
        COMMENT_BODY="${COMMENT_BODY} ([PR](${PR_URL}))"
    fi
    
done <<< "$(echo "$RESULTS_JSON" | jq -c '.[]')"

# Add footer
COMMENT_BODY="${COMMENT_BODY}

---
*This comment was automatically generated by [Buildkite](${BUILDKITE_BUILD_URL:-}) integration check pipeline.*"

# Write comment to file for debugging
echo "$COMMENT_BODY" > github-comment.md
echo "Generated comment (preview):"
echo "=========================================="
cat github-comment.md
echo "=========================================="

# Post comment to GitHub issue
echo ""
echo "Posting comment to GitHub issue..."

if gh issue comment "${ISSUE_NUMBER}" \
    --repo "${ISSUE_REPO}" \
    --body-file github-comment.md; then
    echo "✅ Comment posted successfully"
else
    echo "❌ Failed to post comment"
    exit 1
fi

# Upload summary as artifact if buildkite-agent is available
if command -v buildkite-agent >/dev/null 2>&1; then
    echo "Uploading summary artifacts..."
    buildkite-agent artifact upload "$SUMMARY_FILE"
    buildkite-agent artifact upload "github-comment.md"
    echo "✅ Summary artifacts uploaded"
else
    echo "⚠️ buildkite-agent not available, artifacts saved locally:"
    echo "  - $SUMMARY_FILE"
    echo "  - github-comment.md"
fi

# Set build status based on results
if [[ $FAILED_COUNT -eq 0 ]]; then
    echo ""
    echo "🎉 All integration checks passed!"
    exit 0
else
    echo ""
    echo "⚠️  Some integration checks failed, but PRs have been created for review."
    
    # Don't fail the build - we want to see the summary
    # The individual check failures will be visible in the results
    exit 0
fi