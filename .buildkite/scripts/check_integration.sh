#!/usr/bin/env bash
set -euo pipefail
umask 077

# =============================================================================
# Integration Check Workflow
# =============================================================================
# This workflow runs elastic-package check, build, and changelog operations
# on integrations and creates PRs with the results.
# =============================================================================

# ---------- Configuration ----------
INTEGRATION=${INTEGRATION:?INTEGRATION required}
REPOSITORY_NAME=${REPOSITORY_NAME:-vinit-chauhan/integrations}
GIT_USER_NAME=${GIT_USER_NAME:-Buildkite Bot}
GIT_USER_EMAIL=${GIT_USER_EMAIL:-buildkite-bot@example.com}

WORKDIR="${BUILDKITE_BUILD_CHECKOUT_PATH:-$PWD}"
RESULTS_DIR="${WORKDIR}/results"
RESULT_FILE="${RESULTS_DIR}/${INTEGRATION}.json"

# Workflow configuration
WORKFLOW_NAME=${WORKFLOW_NAME:-"Integration Check"}
BRANCH_PREFIX=${BRANCH_PREFIX:-"auto-update"}
PR_TITLE_PREFIX=${PR_TITLE_PREFIX:-"feat: Update"}
CREATE_PR=${CREATE_PR:-true}

# ---------- Load Helper Functions ----------
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${SCRIPT_DIR}/helper.sh"

# ---------- Integration Check Commands ----------
run_integration_check_commands() {
  local integration_path="$1"
  local overall_status="passed"
  
  # Command 1: Run elastic-package check
  if ! run_command "elastic_package_check" "Run elastic-package check" "${integration_path}" \
      elastic-package check; then
    overall_status="failed"
  fi
  
  # Command 2: Append to README file.
  cat <<EOF >> "${integration_path}/_dev/build/docs/README.md"
## Dummy Section
This is a dummy section added for testing purposes.
EOF
  
  # Command 3: Build package
  if ! run_command "package_build" "Build integration package" "${integration_path}" \
      elastic-package build; then
    overall_status="failed"
  fi
  
  echo "${overall_status}"
}

# ---------- PR Configuration ----------
PR_TITLE="[bulk][dummy_task] Update ${INTEGRATION} integration"
PR_TYPE="${PR_TYPE:-"enhancement"}"
PR_BODY="## 🔧 Elastic Package Integration Update

This PR contains automated improvements for the **${INTEGRATION}** integration using elastic-package tools.

### Changes Made:
- ✅ Ran elastic-package check for validation
- ✅ Added changelog entry for tracking
- ✅ Rebuilt package with latest elastic-package build"

# ---------- Main Execution ----------
# Use the helper's run_workflow function with custom PR title and body
run_workflow "setup_elastic_package_tools" "run_integration_check_commands" "${PR_TITLE}" "${PR_BODY}" "${PR_TYPE}"
