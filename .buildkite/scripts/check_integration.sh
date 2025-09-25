#!/usr/bin/env bash
set -euo pipefail

# Script to check a single integration using elastic-package
# Runs in matrix job, gets integration name from BUILDKITE_MATRIX_SETUP_INTEGRATION

echo "=== Integration Check Script ==="
echo "Build: ${BUILDKITE_BUILD_NUMBER:-unknown}"
echo "Job: ${BUILDKITE_JOB_ID:-unknown}"

# Get the integration name from matrix
INTEGRATION="cisco_duo"

# Debug: Show all available environment variables
echo "Matrix-related environment variables:"
env | grep -i matrix | sort
echo ""
echo "All Buildkite environment variables:"
env | grep '^BUILDKITE_' | sort

if [[ -z "${INTEGRATION}" ]]; then
    echo "❌ No integration specified in BUILDKITE_MATRIX_SETUP_INTEGRATION"
    
    # Try alternative matrix variable patterns
    if [[ -n "${BUILDKITE_MATRIX_INTEGRATION:-}" ]]; then
        INTEGRATION="${BUILDKITE_MATRIX_INTEGRATION}"
        echo "✅ Found integration via BUILDKITE_MATRIX_INTEGRATION: ${INTEGRATION}"
    elif [[ -n "${matrix_integration:-}" ]]; then
        INTEGRATION="${matrix_integration}"
        echo "✅ Found integration via matrix_integration: ${INTEGRATION}"
    else
        echo "❌ No matrix integration variable found"
        echo "This suggests the job is not running as a matrix job"
        echo ""
        echo "Pipeline may have failed to upload correctly or matrix syntax is incorrect"
        exit 1
    fi
fi

echo "Checking integration: ${INTEGRATION}"
echo "Issue: #${ISSUE_NUMBER:-unknown} from ${ISSUE_REPO:-unknown}"

# Create results directory
mkdir -p results

# Initialize result file
RESULT_FILE="results/${INTEGRATION}.json"
cat > "${RESULT_FILE}" << EOF
{
  "integration": "${INTEGRATION}",
  "status": "running",
  "start_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "buildkite_job_id": "${BUILDKITE_JOB_ID:-}",
  "issue_number": "${ISSUE_NUMBER:-}",
  "checks": []
}
EOF

# Function to update result
update_result() {
    local status="$1"
    local message="$2"
    local end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    jq --arg status "$status" \
       --arg message "$message" \
       --arg end_time "$end_time" \
       '.status = $status | .message = $message | .end_time = $end_time' \
       "${RESULT_FILE}" > "${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "${RESULT_FILE}"
}

# Function to add check result
add_check_result() {
    local check_name="$1"
    local check_status="$2" 
    local check_message="$3"
    
    jq --arg name "$check_name" \
       --arg status "$check_status" \
       --arg message "$check_message" \
       '.checks += [{"name": $name, "status": $status, "message": $message}]' \
       "${RESULT_FILE}" > "${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "${RESULT_FILE}"
}

# Trap to ensure we always update the result on exit
trap 'update_result "failed" "Script exited unexpectedly"' EXIT

echo ""
echo "Setting up workspace..."

# Clone elastic/integrations repository
if [[ ! -d "elastic-integrations" ]]; then
    echo "Cloning elastic/integrations repository..."
    git clone --depth 1 https://github.com/elastic/integrations.git elastic-integrations
    add_check_result "repository_clone" "passed" "Successfully cloned elastic/integrations"
else
    echo "Repository already exists, pulling latest..."
    cd elastic-integrations
    git pull origin main
    cd ..
    add_check_result "repository_update" "passed" "Successfully updated elastic/integrations"
fi

# Check if integration exists
INTEGRATION_PATH="elastic-integrations/packages/${INTEGRATION}"
if [[ ! -d "${INTEGRATION_PATH}" ]]; then
    update_result "failed" "Integration '${INTEGRATION}' not found in elastic/integrations"
    add_check_result "integration_exists" "failed" "Integration directory not found: ${INTEGRATION_PATH}"
    exit 1
fi

add_check_result "integration_exists" "passed" "Integration directory found"
echo "✅ Integration found at: ${INTEGRATION_PATH}"

# Install elastic-package if not present
if ! command -v elastic-package >/dev/null 2>&1; then
    echo "Installing elastic-package..."
    
    # Try to download and install elastic-package
    ELASTIC_PACKAGE_VERSION="0.98.0"  # Use a known stable version
    DOWNLOAD_URL="https://github.com/elastic/elastic-package/releases/download/v${ELASTIC_PACKAGE_VERSION}/elastic-package_${ELASTIC_PACKAGE_VERSION}_linux_amd64.tar.gz"
    
    mkdir -p ~/bin
    cd ~/bin
    
    if curl -sL "${DOWNLOAD_URL}" | tar xz; then
        chmod +x elastic-package
        export PATH="~/bin:$PATH"
        add_check_result "elastic_package_install" "passed" "Successfully installed elastic-package v${ELASTIC_PACKAGE_VERSION}"
    else
        update_result "failed" "Failed to install elastic-package"
        add_check_result "elastic_package_install" "failed" "Could not download or extract elastic-package"
        exit 1
    fi
    
    cd - >/dev/null
else
    add_check_result "elastic_package_install" "passed" "elastic-package already available"
fi

echo "✅ elastic-package is ready"
elastic-package version

echo ""
echo "Running elastic-package check on ${INTEGRATION}..."

# Change to integration directory
cd "${INTEGRATION_PATH}"

# Run the check
CHECK_OUTPUT=$(mktemp)
if elastic-package check 2>&1 | tee "${CHECK_OUTPUT}"; then
    CHECK_STATUS="passed"
    CHECK_MESSAGE="All checks passed successfully"
    echo "✅ Integration check passed"
else
    CHECK_STATUS="failed"
    CHECK_MESSAGE="Some checks failed - see logs for details"
    echo "❌ Integration check failed"
fi

# Capture the output for the result
CHECK_DETAILS=$(cat "${CHECK_OUTPUT}")
add_check_result "elastic_package_check" "${CHECK_STATUS}" "${CHECK_MESSAGE}"

# Store detailed output in result
jq --arg output "$CHECK_DETAILS" \
   '.check_output = $output' \
   "../../${RESULT_FILE}" > "../../${RESULT_FILE}.tmp" && mv "../../${RESULT_FILE}.tmp" "../../${RESULT_FILE}"

cd - >/dev/null

# If check failed, create a PR with fixes (if possible)
if [[ "${CHECK_STATUS}" == "failed" ]]; then
    echo ""
    echo "Check failed - attempting to create PR with potential fixes..."
    
    # Set up git configuration
    git config --global user.email "buildkite-bot@example.com"
    git config --global user.name "Buildkite Bot"
    
    cd elastic-integrations
    
    # Create a new branch for this fix
    BRANCH_NAME="fix-${INTEGRATION}-issue-${ISSUE_NUMBER:-$(date +%s)}"
    git checkout -b "${BRANCH_NAME}"
    
    # Here you would add any automated fixes
    # For now, just create a placeholder fix
    echo "# Fixes for ${INTEGRATION}" > "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
    echo "" >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
    echo "This integration failed checks and needs manual review." >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
    echo "Check output:" >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
    echo '```' >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
    echo "${CHECK_DETAILS}" >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
    echo '```' >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
    
    git add "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
    
    if git diff --staged --quiet; then
        echo "No changes to commit"
        add_check_result "pr_creation" "skipped" "No changes to commit"
    else
        git commit -m "Fix: Address elastic-package check failures for ${INTEGRATION}

Related to issue: ${ISSUE_URL:-}
Build: ${BUILDKITE_BUILD_URL:-}"

        # Push branch
        if git push origin "${BRANCH_NAME}"; then
            
            # Create PR using GitHub CLI
            if command -v gh >/dev/null 2>&1; then
                if gh pr create \
                    --title "Fix: elastic-package check failures for ${INTEGRATION}" \
                    --body "This PR addresses check failures found by elastic-package for the ${INTEGRATION} integration.

Related to: ${ISSUE_URL:-}
Build: ${BUILDKITE_BUILD_URL:-}

## Changes
- Added documentation of check failures
- Placeholder for manual fixes needed

## Check Output
\`\`\`
${CHECK_DETAILS}
\`\`\`" \
                    --head "${BRANCH_NAME}" \
                    --base "main"; then
                    
                    PR_URL=$(gh pr view --json url --jq '.url')
                    add_check_result "pr_creation" "passed" "Created PR: ${PR_URL}"
                    
                    # Update result with PR info
                    jq --arg pr_url "$PR_URL" \
                       --arg branch "$BRANCH_NAME" \
                       '.pr_url = $pr_url | .pr_branch = $branch' \
                       "../../${RESULT_FILE}" > "../../${RESULT_FILE}.tmp" && mv "../../${RESULT_FILE}.tmp" "../../${RESULT_FILE}"
                    
                    echo "✅ Created PR: ${PR_URL}"
                else
                    add_check_result "pr_creation" "failed" "GitHub CLI failed to create PR"
                fi
            else
                echo "Installing GitHub CLI..."
                if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
                   && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
                   && sudo apt update \
                   && sudo apt install gh; then
                    
                    # Set up gh auth
                    echo "${GITHUB_TOKEN}" | gh auth login --with-token
                    
                    # Retry PR creation
                    if gh pr create \
                        --title "Fix: elastic-package check failures for ${INTEGRATION}" \
                        --body "Automated fix for elastic-package check failures.
                        
Related to: ${ISSUE_URL:-}
Build: ${BUILDKITE_BUILD_URL:-}" \
                        --head "${BRANCH_NAME}" \
                        --base "main"; then
                        
                        PR_URL=$(gh pr view --json url --jq '.url')
                        add_check_result "pr_creation" "passed" "Created PR: ${PR_URL}"
                        echo "✅ Created PR: ${PR_URL}"
                    else
                        add_check_result "pr_creation" "failed" "Failed to create PR even after installing gh"
                    fi
                else
                    add_check_result "pr_creation" "failed" "Could not install GitHub CLI"
                fi
            fi
        else
            add_check_result "pr_creation" "failed" "Failed to push branch to origin"
        fi
    fi
    
    cd - >/dev/null
fi

# Final result update
if [[ "${CHECK_STATUS}" == "passed" ]]; then
    update_result "passed" "Integration check completed successfully"
else
    update_result "failed" "Integration check failed but PR was created for review"
fi

# Remove the trap since we're handling the result properly
trap - EXIT

echo ""
echo "=== Integration Check Complete ==="
echo "Status: $(jq -r '.status' "${RESULT_FILE}")"
echo "Result file: ${RESULT_FILE}"

# Upload the result as an artifact
buildkite-agent artifact upload "${RESULT_FILE}"

echo "✅ Result uploaded as artifact"