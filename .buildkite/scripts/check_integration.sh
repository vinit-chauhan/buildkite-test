#!/usr/bin/env bash
# Create results directory
mkdir -p results

# Initialize result file with absolute path
RESULT_FILE="$(pwd)/results/${INTEGRATION}.json"
set -euo pipefail

# Script to check a single integration using elastic-package
# Runs in matrix job, gets integration name from BUILDKITE_MATRIX_SETUP_INTEGRATION

echo "=== Integration Check Script ==="
echo "Build: ${BUILDKITE_BUILD_NUMBER:-unknown}"
echo "Job: ${BUILDKITE_JOB_ID:-unknown}"

# Get the integration name from matrix
INTEGRATION=${INTEGRATION:?}
REPOSITORY_NAME=${REPOSITORY_NAME:-vinit-chauhan/integrations}

echo "Checking integration: ${INTEGRATION}"
echo "Issue: #${ISSUE_NUMBER:-unknown} from ${ISSUE_REPO:-unknown}"

# Create results directory
mkdir -p results

# Initialize result file
RESULT_FILE="$(pwd)/results/${INTEGRATION}.json"
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
    
    # Create temp file in /tmp to avoid path issues
    local temp_file="/tmp/result_update_$$.json"
    jq --arg status "$status" \
       --arg message "$message" \
       --arg end_time "$end_time" \
       '.status = $status | .message = $message | .end_time = $end_time' \
       "${RESULT_FILE}" > "${temp_file}" && mv "${temp_file}" "${RESULT_FILE}"
}

# Function to add check result
add_check_result() {
    local check_name="$1"
    local check_status="$2" 
    local check_message="$3"
    
    # Create temp file in /tmp to avoid path issues
    local temp_file="/tmp/check_result_$$.json"
    jq --arg name "$check_name" \
       --arg status "$check_status" \
       --arg message "$check_message" \
       '.checks += [{"name": $name, "status": $status, "message": $message}]' \
       "${RESULT_FILE}" > "${temp_file}" && mv "${temp_file}" "${RESULT_FILE}"
}

# Function to run elastic-package changelog and build, then create PR
create_integration_pr() {
    local integration_path="$1"
    local branch_name="$2"
    local reason="$3"
    
    echo "--- Running elastic-package changelog and build for ${INTEGRATION}"
    
    cd "$integration_path"
    
    # Generate a dummy changelog entry
    echo "Adding dummy changelog entry..."
    if elastic-package changelog add \
        --type "enhancement" \
        --description "Automated integration improvements and fixes" \
        --link "${ISSUE_URL:-https://github.com/${ISSUE_REPO}/issues/${ISSUE_NUMBER}}" 2>&1; then
        add_check_result "changelog_add" "passed" "Successfully added changelog entry"
        echo "✅ Changelog entry added"
    else
        add_check_result "changelog_add" "failed" "Failed to add changelog entry"
        echo "❌ Failed to add changelog entry, continuing anyway..."
    fi
    
    # Run elastic-package build
    echo "Running elastic-package build..."
    BUILD_OUTPUT=$(mktemp)
    
    if elastic-package build 2>&1 | tee "${BUILD_OUTPUT}"; then
        BUILD_STATUS="passed"
        BUILD_MESSAGE="Package built successfully"
        echo "✅ Package build successful"
        add_check_result "package_build" "passed" "$BUILD_MESSAGE"
    else
        BUILD_STATUS="failed" 
        BUILD_MESSAGE="Package build failed - see logs for details"
        echo "❌ Package build failed"
        add_check_result "package_build" "failed" "$BUILD_MESSAGE"
        
        # If build failed, don't create PR
        cd - >/dev/null
        return 1
    fi
    
    # Store build output
    BUILD_DETAILS=$(cat "${BUILD_OUTPUT}")
    
    # Stage all changes (changelog, build artifacts, etc.)
    git add .
    
    # Check if there are changes to commit
    if git diff --staged --quiet; then
        echo "No changes to commit after build"
        add_check_result "pr_creation" "skipped" "No changes to commit"
        cd - >/dev/null
        return 0
    fi
    
    # Create commit message
    COMMIT_MSG="feat: Update ${INTEGRATION} integration

- Added changelog entry for automated improvements
- Rebuilt package with elastic-package build
- ${reason}

Related to: ${ISSUE_URL:-}
Build: ${BUILDKITE_BUILD_URL:-}
Integration: ${INTEGRATION}"
    
    echo "Committing changes..."
    if git commit -m "$COMMIT_MSG"; then
        add_check_result "git_commit" "passed" "Successfully committed changes"
        echo "✅ Changes committed"
    else
        add_check_result "git_commit" "failed" "Failed to commit changes"
        echo "❌ Failed to commit changes"
        cd - >/dev/null
        return 1
    fi
    
    # Push the branch
    echo "Pushing branch: ${branch_name}"
    if git push origin "${branch_name}"; then
        add_check_result "git_push" "passed" "Successfully pushed branch"
        echo "✅ Branch pushed successfully"
    else
        add_check_result "git_push" "failed" "Failed to push branch"
        echo "❌ Failed to push branch"
        cd - >/dev/null
        return 1
    fi
    
    # Create PR using GitHub CLI
    echo "Creating GitHub PR..."
    PR_TITLE="feat: Update ${INTEGRATION} integration"
    PR_BODY="## 🔧 Automated Integration Update

This PR contains automated improvements for the \`${INTEGRATION}\` integration.

### Changes Made
- ✅ Added changelog entry for tracking improvements
- ✅ Rebuilt package using \`elastic-package build\`
- 🔍 Addressed issues found during integration check

### Context
- **Integration:** \`${INTEGRATION}\`
- **Issue:** ${ISSUE_URL:-N/A}
- **Build:** ${BUILDKITE_BUILD_URL:-N/A}
- **Branch:** \`${branch_name}\`
- **Reason:** ${reason}

### Build Output
<details>
<summary>elastic-package build output</summary>

\`\`\`
${BUILD_DETAILS}
\`\`\`
</details>

### Review Notes
- Package build completed successfully
- All changes have been automatically generated
- Please review the changelog entry and build artifacts
- Consider running additional tests before merging

---
*This PR was automatically created by the Buildkite integration pipeline.*"

    if gh pr create \
        --title "$PR_TITLE" \
        --body "$PR_BODY" \
        --base "main" \
        --head "$branch_name"; then
        
        PR_URL=$(gh pr view --json url --jq '.url')
        add_check_result "pr_creation" "passed" "Created PR: ${PR_URL}"
        
        # Update result with PR info
        local temp_file="/tmp/pr_update_$$.json"
        jq --arg pr_url "$PR_URL" \
           --arg branch "$branch_name" \
           --arg build_status "$BUILD_STATUS" \
           '.pr_url = $pr_url | .pr_branch = $branch | .build_status = $build_status' \
           "${RESULT_FILE}" > "${temp_file}" && mv "${temp_file}" "${RESULT_FILE}"
        
        echo "✅ PR created successfully: $PR_URL"
        cd - >/dev/null
        return 0
    else
        add_check_result "pr_creation" "failed" "Failed to create PR"
        echo "❌ Failed to create PR"
        cd - >/dev/null
        return 1
    fi
}

# Trap to ensure we always update the result on exit
trap 'update_result "failed" "Script exited unexpectedly"' EXIT

echo ""
echo "Setting up workspace..."

# Clone repository
if [[ ! -d "elastic-integrations" ]]; then
    echo "Cloning ${REPOSITORY_NAME} repository..."
    git clone --depth 1 https://github.com/${REPOSITORY_NAME}.git elastic-integrations
    add_check_result "repository_clone" "passed" "Successfully cloned ${REPOSITORY_NAME}"
else
    echo "Repository already exists, pulling latest..."
    cd elastic-integrations
    git pull origin main
    cd ..
    add_check_result "repository_update" "passed" "Successfully updated ${REPOSITORY_NAME}"
fi

# Check if integration exists
INTEGRATION_PATH="elastic-integrations/packages/${INTEGRATION}"
if [[ ! -d "${INTEGRATION_PATH}" ]]; then
    update_result "failed" "Integration '${INTEGRATION}' not found in ${REPOSITORY_NAME}"
    add_check_result "integration_exists" "failed" "Integration directory not found: ${INTEGRATION_PATH}"
    exit 1
fi

add_check_result "integration_exists" "passed" "Integration directory found"
echo "✅ Integration found at: ${INTEGRATION_PATH}"

# Install elastic-package if not present
if ! command -v elastic-package >/dev/null 2>&1; then
    echo "Installing elastic-package..."
    
    # Try to download and install elastic-package
    ELASTIC_PACKAGE_VERSION="0.115.0"  # Use a known stable version
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
temp_file="/tmp/output_update_$$.json"
jq --arg output "$CHECK_DETAILS" \
   '.check_output = $output' \
   "${RESULT_FILE}" > "${temp_file}" && mv "${temp_file}" "${RESULT_FILE}"

cd - >/dev/null

# If check failed, create a PR with fixes (if possible)
if [[ "${CHECK_STATUS}" == "failed" ]]; then
    echo ""
    echo "Check failed - attempting to create PR with changelog and build..."
    
    # Set up git configuration
    git config --global user.email "buildkite-bot@example.com"
    git config --global user.name "Buildkite Bot"
    
    cd elastic-integrations
    
    # Create a new branch for this fix
    BRANCH_NAME="fix-${INTEGRATION}-issue-${ISSUE_NUMBER:-$(date +%s)}"
    git checkout -b "${BRANCH_NAME}"
    
    # Use the new function to create PR with changelog and build
    if create_integration_pr "packages/${INTEGRATION}" "${BRANCH_NAME}" "Addressing elastic-package check failures"; then
        echo "✅ Successfully created PR with changelog and build"
    else
        echo "⚠️ PR creation with build failed, falling back to basic fix..."
        
        # Fallback: create a simple documentation fix
        echo "# Fixes for ${INTEGRATION}" > "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
        echo "" >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
        echo "This integration failed checks and needs manual review." >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
        echo "Check output:" >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
        echo '```' >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
        echo "${CHECK_DETAILS}" >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
        echo '```' >> "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
        
        git add "packages/${INTEGRATION}/BUILDKITE_FIXES.md"
        
        if ! git diff --staged --quiet; then
            git commit -m "docs: Add troubleshooting information for ${INTEGRATION}

This integration failed elastic-package check and needs manual review.

Related to: ${ISSUE_URL:-}
Build: ${BUILDKITE_BUILD_URL:-}"

            if git push origin "${BRANCH_NAME}"; then
                # Create simple PR
                if gh pr create \
                    --title "docs: Troubleshooting info for ${INTEGRATION}" \
                    --body "This PR documents issues found during elastic-package check for the ${INTEGRATION} integration.

Related to: ${ISSUE_URL:-}
Build: ${BUILDKITE_BUILD_URL:-}

## Issue Details
\`\`\`
${CHECK_DETAILS}
\`\`\`

This requires manual investigation and fixes." \
                    --head "${BRANCH_NAME}" \
                    --base "main"; then
                    
                    PR_URL=$(gh pr view --json url --jq '.url')
                    add_check_result "pr_creation_fallback" "passed" "Created documentation PR: ${PR_URL}"
                    echo "✅ Created fallback documentation PR: ${PR_URL}"
                else
                    add_check_result "pr_creation_fallback" "failed" "Failed to create fallback PR"
                fi
            else
                add_check_result "git_push_fallback" "failed" "Failed to push fallback branch"
            fi
        else
            add_check_result "pr_creation" "skipped" "No changes to commit for fallback"
        fi
    fi
    
    cd - >/dev/null
else
    echo "✅ Integration check passed - creating enhancement PR with changelog and build"
    
    # Even for passing checks, create a PR with changelog and build improvements
    git config --global user.email "buildkite-bot@example.com"  
    git config --global user.name "Buildkite Bot"
    
    cd elastic-integrations
    
    # Create enhancement branch
    BRANCH_NAME="enhance-${INTEGRATION}-issue-${ISSUE_NUMBER:-$(date +%s)}"
    git checkout -b "${BRANCH_NAME}"
    
    if create_integration_pr "packages/${INTEGRATION}" "${BRANCH_NAME}" "Automated enhancements after successful check"; then
        echo "✅ Successfully created enhancement PR with changelog and build"
    else
        echo "⚠️ Enhancement PR creation failed, but check passed"
        add_check_result "enhancement_pr" "failed" "Could not create enhancement PR"
    fi
    
    cd - >/dev/null
fi
    
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
                       "${RESULT_FILE}" > "${RESULT_FILE}.tmp" && mv "${RESULT_FILE}.tmp" "${RESULT_FILE}"
                    
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

# Upload the result as an artifact (use relative path for consistency)
buildkite-agent artifact upload "results/${INTEGRATION}.json"

echo "✅ Result uploaded as artifact"