#!/usr/bin/env bash

# =============================================================================
# Integration Workflow Helper Functions
# =============================================================================
# This file contains reusable functions for integration workflows.
# Source this file in your workflow scripts: source "$(dirname "$0")/helper.sh"
# =============================================================================

# Ensure this file is sourced, not executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Error: This file should be sourced, not executed directly."
  echo "Usage: source \"\$(dirname \"\$0\")/helper.sh\""
  exit 1
fi

# ---------- Configuration Validation ----------
validate_required_vars() {
  local required_vars=("INTEGRATION" "REPOSITORY_NAME" "WORKDIR" "RESULTS_DIR" "RESULT_FILE")
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      echo "Error: Required variable $var is not set"
      return 1
    fi
  done
}

# ---------- Logging & Results Management ----------
initialize_workspace() {
  local workflow_name="${WORKFLOW_NAME:-Integration Workflow}"
  
  echo "Job: ${BUILDKITE_JOB_ID:-unknown}"
  echo "Running workflow: ${workflow_name}"
  echo "Integration: ${INTEGRATION}"
  echo "Issue: #${ISSUE_NUMBER:-unknown} from ${ISSUE_REPO:-unknown}"
  echo "Workspace: ${WORKDIR}"
  
  mkdir -p "${RESULTS_DIR}"
  
  # Seed result file
  cat > "${RESULT_FILE}" <<EOF
{
  "integration": "${INTEGRATION}",
  "workflow": "${workflow_name}",
  "status": "running",
  "start_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "buildkite_job_id": "${BUILDKITE_JOB_ID:-}",
  "issue_number": "${ISSUE_NUMBER:-}",
  "commands": []
}
EOF
}

json_inplace() {
  # $1: jq program, operates on $RESULT_FILE atomically
  local tmp; tmp="$(mktemp)"
  jq "$@" "${RESULT_FILE}" > "${tmp}" && mv "${tmp}" "${RESULT_FILE}"
}

update_result() {
  local status="$1" message="$2"
  local end_time; end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  json_inplace --arg s "$status" --arg m "$message" --arg t "$end_time" \
    '.status=$s | .message=$m | .end_time=$t'
}

add_command_result() {
  local name="$1" status="$2" message="$3" output="${4:-}"
  json_inplace --arg n "$name" --arg s "$status" --arg m "$message" --arg o "$output" \
    '.commands += [{"name":$n,"status":$s,"message":$m,"output":$o}]'
}

# ---------- Repository Management ----------
setup_repository() {
  if [[ ! -d "${WORKDIR}/elastic-integrations" ]]; then
    echo "Cloning ${REPOSITORY_NAME} ..."
    git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPOSITORY_NAME}.git" \
      "${WORKDIR}/elastic-integrations"
    add_command_result "repository_clone" "passed" "Cloned ${REPOSITORY_NAME}"
  else
    echo "Updating ${REPOSITORY_NAME} ..."
    pushd "${WORKDIR}/elastic-integrations" >/dev/null
    git fetch --quiet origin main
    git reset --hard origin/main
    popd >/dev/null
    add_command_result "repository_update" "passed" "Synced ${REPOSITORY_NAME}"
  fi
}

validate_integration_exists() {
  local integration_path="${WORKDIR}/elastic-integrations/packages/${INTEGRATION}"
  if [[ ! -d "${integration_path}" ]]; then
    add_command_result "integration_exists" "failed" "Not found: ${integration_path}"
    update_result "failed" "Integration '${INTEGRATION}' not found in ${REPOSITORY_NAME}"
    return 1
  fi
  add_command_result "integration_exists" "passed" "Found ${integration_path}"
  echo "${integration_path}"
}

git_cfg_user() {
  git config --global user.name  "${GIT_USER_NAME}"
  git config --global user.email "${GIT_USER_EMAIL}"
}

configure_origin_token_remote() {
  # use token HTTPS so we can push
  git remote set-url origin \
    "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPOSITORY_NAME}.git"
}

# ---------- Command Execution Framework ----------
run_command() {
  local cmd_name="$1" cmd_description="$2" working_dir="$3"
  shift 3
  local cmd_args=("$@")
  
  echo "--- Running: ${cmd_description}"
  
  local output_file; output_file="$(mktemp)"
  local start_time; start_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  
  pushd "${working_dir}" >/dev/null
  
  if "${cmd_args[@]}" 2>&1 | tee "${output_file}"; then
    add_command_result "${cmd_name}" "passed" "${cmd_description} completed successfully" "$(cat "${output_file}")"
    popd >/dev/null
    return 0
  else
    add_command_result "${cmd_name}" "failed" "${cmd_description} failed" "$(cat "${output_file}")"
    popd >/dev/null
    return 1
  fi
}

# ---------- GitHub CLI Setup ----------
setup_github_cli() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "Installing GitHub CLI..."
    # idempotent apt setup
    if [[ ! -f /usr/share/keyrings/githubcli-archive-keyring.gpg ]]; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
    fi
    if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh curl ca-certificates
    add_command_result "gh_install" "passed" "Installed GitHub CLI"
  else
    add_command_result "gh_install" "passed" "GitHub CLI available"
  fi

  if gh auth status >/dev/null 2>&1; then
    add_command_result "gh_auth" "passed" "GitHub CLI already authenticated"
    echo "✅ GitHub CLI already authenticated"
  else
    # Try token authentication
    if echo "${GITHUB_TOKEN}" | gh auth login --with-token >/dev/null 2>&1; then
      add_command_result "gh_auth" "passed" "Successfully authenticated GitHub CLI"
      echo "✅ GitHub CLI authenticated successfully"
    else
      # Fallback: Check if GITHUB_TOKEN environment variable authentication works
      if [[ -n "${GITHUB_TOKEN:-}" ]] && gh auth status >/dev/null 2>&1; then
        add_command_result "gh_auth" "passed" "GitHub CLI using environment token"
        echo "✅ GitHub CLI using environment token authentication"
      else
        add_command_result "gh_auth" "failed" "Failed to authenticate GitHub CLI"
        echo "❌ Failed to authenticate GitHub CLI"
        echo "Debug: GITHUB_TOKEN length: ${#GITHUB_TOKEN}"
        gh auth status 2>&1 || true
        return 1
      fi
    fi
  fi

  gh repo set-default "${REPOSITORY_NAME}" >/dev/null 2>&1 \
    && add_command_result "gh_repo_default" "passed" "Default repo set to ${REPOSITORY_NAME}" \
    || { add_command_result "gh_repo_default" "failed" "Failed to set default repo for ${REPOSITORY_NAME}"; return 1; }
}

# ---------- Pull Request Management ----------
raise_pr() {
  local branch_name="$1" commit_message="$2" pr_title="$3" pr_body="$4" pr_type="${5:-enhancement}"
  
  echo "--- Creating Pull Request"
  git_cfg_user
  configure_origin_token_remote
  
  pushd "${WORKDIR}/elastic-integrations" >/dev/null
  
  git checkout -b "${branch_name}"
  
  # Navigate to integration directory for changes
  pushd "packages/${INTEGRATION}" >/dev/null
  
  git add -A
  if git diff --staged --quiet; then
    add_command_result "pr_creation" "skipped" "No changes to commit"
    popd >/dev/null
    popd >/dev/null
    return 0
  fi
  
  git commit -m "${commit_message}"
  git push -u origin "${branch_name}"
  
  popd >/dev/null  # Back to repo root
  
  # Create PR
  if gh pr create --title "${pr_title}" --body "${pr_body}" --base "main" --head "${branch_name}"; then
    local pr_url; pr_url="$(gh pr view --json url --jq '.url')"
    add_command_result "pr_creation" "passed" "Created PR: ${pr_url}"
    json_inplace --arg url "$pr_url" --arg br "$branch_name" '.pr_url=$url | .pr_branch=$br'
    echo "✅ PR created: ${pr_url}"
    
    # Add bumped up version in changelog and manifest
    if [[ "$pr_type" == "bugfix" ]]; then
      version_bump="patch"
    elif [[ "$pr_type" == "enhancement" ]]; then
      version_bump="minor"
    fi
    increment_version "${version_bump}"

    # Add changelog entry referencing the PR
    add_changelog_entry "${5:-enhancement}" "${pr_title}" "${pr_url}"
  else
    add_command_result "pr_creation" "failed" "Failed to create PR"
    popd >/dev/null
    return 1
  fi

  popd >/dev/null
  return 0
}

# ---------- Changelog Management ----------
add_changelog_entry() {
  local change_type="$1" description="$2" pr_link="${3:-}"

  pushd "${WORKDIR}/elastic-integrations" >/dev/null
  if run_command "changelog_add" "Add changelog entry" "${WORKDIR}/elastic-integrations/packages/${INTEGRATION}" \
      elastic-package changelog add \
        --type "${change_type}" \
        --description "${description}" \
        --link "https://github.com/elastic/integrations/pull/1"; then
    echo "✅ Changelog added"
  else
    echo "⚠️ Changelog add failed (non-critical)"
  fi
  popd >/dev/null
}

update_changelog_pr_link() {
  local pr_url="$1" branch_name="$2" 

  pushd "${WORKDIR}/elastic-integrations" >/dev/null
  git checkout "${branch_name}"

  pushd "packages/${INTEGRATION}" >/dev/null
  
  if ! grep -q "${pr_url}" changelog.yml; then
    sed -i.bkp "1,/link:/s|link: .*|link: ${pr_url}|" changelog.yml
    rm changelog.yml.bkp
    add_command_result "changelog_update" "passed" "Changelog updated with PR link"
  else
    add_command_result "changelog_update" "failed" "Unable to update changelog with PR link"
    popd >/dev/null
    popd >/dev/null
    return 0
  fi

  git add -A

  if git diff --staged --quiet; then
    add_command_result "changelog_commit" "skipped" "No changelog changes to commit"
    popd >/dev/null
    popd >/dev/null
    return 0
  fi

  git commit -m "chore: Add changelog entry - automated update"
  git push

  popd >/dev/null
  popd >/dev/null
  return 0
}

# ---------- Increment version ----------

increment_version() {
    local change_type=$1

    pushd "${WORKDIR}/elastic-integrations/packages/${INTEGRATION}" >/dev/null

    if ! command -v pysemver &> /dev/null
    then
        add_command_result "version_bump" "failed" "pysemver not installed"
        return 1
    fi

    # Get the current version from package.json
    current_version=$(yq .version ./manifest.yml)
    if [[ -z "$current_version" ]]; then
        add_command_result "version_bump" "failed" "Current version not found in manifest.yml"
        return 1
    fi

    new_version=$(pysemver bump "$change_type" "$current_version")
    if [[ -z "$new_version" ]]; then
        add_command_result "version_bump" "failed" "Version bump failed"
        return 1
    fi

    echo "Bumping version from $current_version to $new_version"

    # Update the version in package.json
    sed -i.bkp "s/^version: .*/version: \"$new_version\"/" manifest.yml
    if [[ $? -ne 0 ]]; then
        add_command_result "version_bump" "failed" "Failed to update version in manifest.yml"
        return 1
    fi
    add_command_result "version_bump" "passed" "Version updated to $new_version"
    rm manifest.yml.bkp

    new_entry="- version: \"$new_version\"\n  changes:" 
    sed -i.bkp "2s/^/$new_entry\n/" changelog.yml
    if [[ $? -ne 0 ]]; then
        add_command_result "version_bump" "failed" "Failed to update changelog.yml"
        return 1
    fi
    add_command_result "changelog_update" "passed" "Changelog updated with new version"
    rm changelog.yml.bkp

    popd >/dev/null
}

# ---------- Elastic Package Tool Setup ----------
setup_elastic_package_tools() {
  # Install elastic-package
  if command -v elastic-package >/dev/null 2>&1; then
    add_command_result "elastic_package_install" "passed" "elastic-package present"
    echo "elastic-package version: $(elastic-package version)"
    return 0
  fi

  echo "Installing elastic-package..."
  local ver="0.115.0"
  local arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Unsupported arch: ${arch}"; add_command_result "elastic_package_install" "failed" "Unsupported arch"; return 1 ;;
  esac

  local url="https://github.com/elastic/elastic-package/releases/download/v${ver}/elastic-package_${ver}_linux_${arch}.tar.gz"
  local tmpdir; tmpdir="$(mktemp -d)"
  ( cd "${tmpdir}" && curl -fsSL "${url}" | tar xz && \
      sudo install -m 0755 elastic-package /usr/local/bin/elastic-package ) \
    && add_command_result "elastic_package_install" "passed" "Installed elastic-package v${ver}" \
    || { add_command_result "elastic_package_install" "failed" "Install failed"; return 1; }
}

# ---------- Workflow Finalization ----------
finalize_workflow() {
  local workflow_name="${WORKFLOW_NAME:-Integration Workflow}"
  
  echo ""
  echo "=== ${workflow_name} Complete ==="
  echo "Status: $(jq -r '.status' "${RESULT_FILE}")"
  echo "Result file: ${RESULT_FILE}"
  
  # Upload artifact (use absolute path rooted in checkout)
  if command -v buildkite-agent >/dev/null 2>&1; then
    buildkite-agent artifact upload "results/${INTEGRATION}.json"
    echo "✅ Result uploaded as artifact"
  else
    echo "ℹ️ Buildkite agent not available, skipping artifact upload"
  fi
}

# ---------- Main Workflow Runner ----------
run_workflow() {
  local setup_tools_func="$1"
  local run_commands_func="$2"
  local custom_pr_title="${3:-}"
  local custom_pr_body="${4:-}"
  local pr_type="${5:-enhancement}" # Default changelog type
  
  # Validate required variables
  validate_required_vars
  
  # Always mark failure unless we succeeded
  trap 'update_result "failed" "Script exited unexpectedly"' EXIT
  
  # Initialize workspace
  initialize_workspace
  
  # Setup repository
  setup_repository
  
  # Validate integration exists
  local integration_path
  if ! integration_path=$(validate_integration_exists); then
    exit 1
  fi
  
  # Setup required tools
  if declare -f "$setup_tools_func" >/dev/null; then
    "$setup_tools_func"
  else
    echo "Warning: Setup function '$setup_tools_func' not found, skipping tool setup"
  fi
  
  # Run workflow commands
  echo "=== Running Workflow Commands ==="
  local workflow_status
  if declare -f "$run_commands_func" >/dev/null; then
    # Capture only the last line (the status) from the function
    workflow_status=$("$run_commands_func" "${integration_path}" | tail -n 1)
  else
    echo "Error: Commands function '$run_commands_func' not found"
    update_result "failed" "Commands function not found"
    exit 1
  fi
  
  pushd "${WORKDIR}/elastic-integrations" >/dev/null

  # Create PR if enabled and there are changes
  if [[ "${CREATE_PR:-true}" == "true" ]]; then
    setup_github_cli
    
    local branch_prefix="${BRANCH_PREFIX:-auto-update}"
    local pr_title_prefix="${PR_TITLE_PREFIX:-feat: Update}"
    
    local branch_name="${branch_prefix}-${INTEGRATION}-issue-${ISSUE_NUMBER:-$(date +%s)}"
    
    # Use custom PR title if provided, otherwise use default
    local pr_title
    if [[ -n "${custom_pr_title}" ]]; then
      pr_title="${custom_pr_title}"
    else
      pr_title="${pr_title_prefix} ${INTEGRATION} integration"
    fi
    
    local commit_message="${pr_title}

- Automated workflow execution
- ${WORKFLOW_NAME:-Integration Workflow}

Related: ${ISSUE_URL:-}
Build: ${BUILDKITE_BUILD_URL:-}
Integration: ${INTEGRATION}"
    
    # Use custom PR body if provided, otherwise use default
    local pr_body
    if [[ -n "${custom_pr_body}" ]]; then
      # If custom body is provided, append actual results to it
      pr_body="${custom_pr_body}

### Actual Command Results:
$(jq -r '.commands[] | "- " + (if .status == "passed" then "✅" else "❌" end) + " **" + .name + "**: " + .message' "${RESULT_FILE}")

### Related Information:
- **Issue**: ${ISSUE_URL:-N/A}
- **Build**: ${BUILDKITE_BUILD_URL:-N/A}
- **Integration**: \`${INTEGRATION}\`

*This PR was automatically generated by the Buildkite at $(date -u +%Y-%m-%dT%H:%M:%SZ)*"
    else
      # If custom body is not provided, use default
      echo "No custom PR body provided, using default"

      pr_body="## 🔧 Automated Integration Update

This PR contains automated improvements for the integration.

**Workflow:** ${WORKFLOW_NAME:-Integration Workflow}

$(jq -r '.commands[] | "- " + (if .status == "passed" then "✅" else "❌" end) + " " + .name + ": " + .message' "${RESULT_FILE}")

### Related Information:
- **Issue**: ${ISSUE_URL:-N/A}
- **Build**: ${BUILDKITE_BUILD_URL:-N/A}
- **Integration**: \`${INTEGRATION}\`

*This PR was automatically generated by the Buildkite at $(date -u +%Y-%m-%dT%H:%M:%SZ)*"
    fi
    
    if [[ "${workflow_status}" == "failed" ]]; then
      branch_name="fix-${INTEGRATION}-issue-${ISSUE_NUMBER:-$(date +%s)}"
      pr_body="${pr_body}

⚠️ **Note:** Some commands failed. This PR addresses the issues."
    fi

    raise_pr "${branch_name}" "${commit_message}" "${pr_title}" "${pr_body}" "${pr_type}"
  fi

  popd >/dev/null
  
  # Finalize results
  if [[ "${workflow_status}" == "passed" ]]; then
    update_result "passed" "${WORKFLOW_NAME:-Integration Workflow} completed successfully"
  else
    update_result "failed" "${WORKFLOW_NAME:-Integration Workflow} failed (PR may be opened)"
  fi
  
  trap - EXIT
  
  finalize_workflow
}

# ---------- Helper Information ----------
show_helper_usage() {
  cat <<EOF
Integration Workflow Helper Functions

AVAILABLE FUNCTIONS:
  Core Functions:
    - run_workflow(setup_func, commands_func, [pr_title], [pr_body])  # Main workflow runner
    - run_command(name, desc, dir, cmd...)     # Execute command with logging
    - raise_pr(branch, commit_msg, title, body, [pr_type]) # Create pull request
    
  Repository Management:
    - setup_repository()                       # Clone/update repo
    - validate_integration_exists()            # Check integration exists
    - git_cfg_user(), configure_origin_token_remote()
    
  Results & Logging:
    - initialize_workspace()                   # Setup workspace and results
    - add_command_result(name, status, msg, output)
    - update_result(status, message)
    - finalize_workflow()                      # Show final results
    
  GitHub Integration:
    - setup_github_cli()                       # Install and auth GitHub CLI

REQUIRED ENVIRONMENT VARIABLES:
  - INTEGRATION: Integration name
  - REPOSITORY_NAME: GitHub repository
  - WORKDIR: Working directory
  - RESULTS_DIR: Results directory
  - RESULT_FILE: Results JSON file
  - GITHUB_TOKEN: GitHub authentication token

OPTIONAL ENVIRONMENT VARIABLES:
  - WORKFLOW_NAME: Name of the workflow
  - BRANCH_PREFIX: Git branch prefix
  - PR_TITLE_PREFIX: PR title prefix
  - CREATE_PR: Enable/disable PR creation (default: true)
  - GIT_USER_NAME, GIT_USER_EMAIL: Git configuration

USAGE EXAMPLE:
  source "\$(dirname "\$0")/helper.sh"
  
  setup_my_tools() {
    # Install your tools here
  }
  
  run_my_commands() {
    local integration_path="\$1"
    local status="passed"
    
    if ! run_command "my_check" "Run my check" "\${integration_path}" my-tool check; then
      status="failed"
    fi
    
    echo "\${status}"
  }
  
  # Basic usage
  run_workflow "setup_my_tools" "run_my_commands"
  
  # With custom PR title and body
  PR_TITLE="Custom PR Title"
  PR_BODY="Custom PR body with details"
  run_workflow "setup_my_tools" "run_my_commands" "\${PR_TITLE}" "\${PR_BODY}"

EOF
}

# Show usage if helper is called with --help
if [[ "${1:-}" =~ ^(-h|--help|help)$ ]]; then
  show_helper_usage
fi
