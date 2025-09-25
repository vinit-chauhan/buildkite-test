#!/usr/bin/env bash
set -euo pipefail

: "${INTEGRATION:?}"  # from matrix
: "${INTEGRATIONS_REPO:=elastic/integrations}"
: "${INTEGRATIONS_BRANCH:=main}"
: "${INTEGRATION_PATH_PREFIX:=packages}"
: "${GITHUB_TOKEN:?}"  # Required for PR creation

WORK="work/${INTEGRATION}"
mkdir -p "$WORK"
pushd "$WORK" >/dev/null

echo "--- Setting up Git configuration"
git config --global user.email "vinit.chauhan@elastic.co"
git config --global user.name "vinit-chauhan"

echo "--- Cloning ${INTEGRATIONS_REPO}@${INTEGRATIONS_BRANCH}"
git clone --branch "$INTEGRATIONS_BRANCH" "https://github.com/${INTEGRATIONS_REPO}.git" repo
cd repo

# Set up GitHub authentication for pushing
git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${INTEGRATIONS_REPO}.git"

PKG_DIR="${INTEGRATION_PATH_PREFIX}/${INTEGRATION}"
if [[ ! -d "$PKG_DIR" ]]; then
  echo "Package not found: ${PKG_DIR}"
  echo "{\"integration\":\"$INTEGRATION\",\"status\":\"not_found\",\"pr_created\":false}" > ../result.json
  popd >/dev/null
  buildkite-agent artifact upload "work/${INTEGRATION}/result.json"
  exit 0
fi

echo "--- Installing elastic-package"
if command -v go >/dev/null 2>&1; then
  GOBIN="$PWD/.bin" go install github.com/elastic/elastic-package@latest || true
  export PATH="$PWD/.bin:$PATH"
fi
if ! command -v elastic-package >/dev/null 2>&1; then
  curl -sSfL https://raw.githubusercontent.com/elastic/elastic-package/master/install.sh | bash
  export PATH="$PWD/bin:$PATH"
fi
elastic-package version || true

echo "--- Installing GitHub CLI"
if ! command -v gh >/dev/null 2>&1; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  sudo apt update && sudo apt install -y gh
fi

echo "--- Running elastic-package check for ${PKG_DIR}"
cd "$PKG_DIR"
set +e
elastic-package check -v
check_rc=$?
set -e

# Initialize result variables
status="passed"
pr_created=false
pr_url=""

if [[ $check_rc -ne 0 ]]; then
  status="failed"
  echo "--- elastic-package check failed, attempting to create fix PR"
  
  # Create a new branch for the fix
  BRANCH_NAME="fix/${INTEGRATION}-$(date +%Y%m%d-%H%M%S)"
  git checkout -b "$BRANCH_NAME"
  
  # Run elastic-package fix (if available) or stage any changes made
  set +e
  elastic-package fix -v 2>/dev/null || true
  set -e
  
  # Check if there are any changes to commit
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "--- Changes detected, creating PR"
    
    # Add all changes
    git add .
    
    # Create commit
    COMMIT_MSG="Fix elastic-package issues for ${INTEGRATION}

    This PR was automatically created by Buildkite after elastic-package check failed.
    
    Integration: ${INTEGRATION}
    Issue: ${ISSUE_URL:-N/A}
    Build: ${BUILDKITE_BUILD_URL:-N/A}"
    
    git commit -m "$COMMIT_MSG"
    
    # Push the branch
    git push origin "$BRANCH_NAME"
    
    # Create PR using GitHub CLI
    PR_TITLE="Fix elastic-package issues for ${INTEGRATION}"
    PR_BODY="This PR addresses elastic-package check failures for the \`${INTEGRATION}\` integration.

## Changes
- Automated fixes applied by elastic-package
- Manual adjustments may be required

## Context
- **Integration:** \`${INTEGRATION}\`
- **Issue:** ${ISSUE_URL:-N/A}
- **Build:** ${BUILDKITE_BUILD_URL:-N/A}
- **Branch:** \`${BRANCH_NAME}\`

## Review Notes
Please review the changes carefully before merging."

    set +e
    PR_OUTPUT=$(gh pr create \
      --title "$PR_TITLE" \
      --body "$PR_BODY" \
      --base "$INTEGRATIONS_BRANCH" \
      --head "$BRANCH_NAME" \
      2>&1)
    pr_create_rc=$?
    set -e
    
    if [[ $pr_create_rc -eq 0 ]]; then
      pr_created=true
      pr_url=$(echo "$PR_OUTPUT" | grep -o 'https://github.com/[^[:space:]]*' || echo "")
      echo "✅ PR created successfully: $pr_url"
    else
      echo "❌ Failed to create PR: $PR_OUTPUT"
    fi
  else
    echo "--- No changes detected after running fixes"
  fi
else
  echo "✅ elastic-package check passed"
fi

# Go back to work directory to write result
cd ../../..

echo "{\"integration\":\"$INTEGRATION\",\"status\":\"$status\",\"exit_code\":$check_rc,\"pr_created\":$pr_created,\"pr_url\":\"$pr_url\"}" > "$WORK/result.json"
popd >/dev/null
buildkite-agent artifact upload "work/${INTEGRATION}/result.json"

# Exit with original check result
exit $check_rc

