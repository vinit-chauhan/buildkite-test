#!/usr/bin/env bash
set -euo pipefail
umask 077

# ---------- Inputs & constants ----------
INTEGRATION=${INTEGRATION:?INTEGRATION required}
REPOSITORY_NAME=${REPOSITORY_NAME:-vinit-chauhan/integrations}
GIT_USER_NAME=${GIT_USER_NAME:-Buildkite Bot}
GIT_USER_EMAIL=${GIT_USER_EMAIL:-buildkite-bot@example.com}

WORKDIR="${BUILDKITE_BUILD_CHECKOUT_PATH:-$PWD}"
RESULTS_DIR="${WORKDIR}/results"
RESULT_FILE="${RESULTS_DIR}/${INTEGRATION}.json"

echo "Job: ${BUILDKITE_JOB_ID:-unknown}"
echo "Checking integration: ${INTEGRATION}"
echo "Issue: #${ISSUE_NUMBER:-unknown} from ${ISSUE_REPO:-unknown}"
echo "Workspace: ${WORKDIR}"

mkdir -p "${RESULTS_DIR}"

# Seed result file
cat > "${RESULT_FILE}" <<EOF
{
  "integration": "${INTEGRATION}",
  "status": "running",
  "start_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "buildkite_job_id": "${BUILDKITE_JOB_ID:-}",
  "issue_number": "${ISSUE_NUMBER:-}",
  "checks": []
}
EOF

# ---------- Helpers ----------
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

add_check_result() {
  local name="$1" status="$2" message="$3"
  json_inplace --arg n "$name" --arg s "$status" --arg m "$message" \
    '.checks += [{"name":$n,"status":$s,"message":$m}]'
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

# ---------- Tooling setup ----------
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
    add_check_result "gh_install" "passed" "Installed GitHub CLI"
  else
    add_check_result "gh_install" "passed" "GitHub CLI available"
  fi

  echo "${GITHUB_TOKEN:?GITHUB_TOKEN required}" | gh auth login --with-token >/dev/null 2>&1 \
    && add_check_result "gh_auth" "passed" "Authenticated GitHub CLI" \
    || { add_check_result "gh_auth" "failed" "GitHub CLI auth failed"; return 1; }

  gh repo set-default "${REPOSITORY_NAME}" >/dev/null 2>&1 \
    && add_check_result "gh_repo_default" "passed" "Default repo set to ${REPOSITORY_NAME}" \
    || { add_check_result "gh_repo_default" "failed" "Failed to set default repo"; return 1; }
}

setup_elastic_package() {
  if command -v elastic-package >/dev/null 2>&1; then
    add_check_result "elastic_package_install" "passed" "elastic-package present"
    echo "elastic-package version: $(elastic-package version)"
    return 0
  fi

  echo "Installing elastic-package..."
  local ver="0.115.0"
  local arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Unsupported arch: ${arch}"; add_check_result "elastic_package_install" "failed" "Unsupported arch"; return 1 ;;
  esac

  local url="https://github.com/elastic/elastic-package/releases/download/v${ver}/elastic-package_${ver}_linux_${arch}.tar.gz"
  local tmpdir; tmpdir="$(mktemp -d)"
  ( cd "${tmpdir}" && curl -fsSL "${url}" | tar xz && \
      sudo install -m 0755 elastic-package /usr/local/bin/elastic-package ) \
    && add_check_result "elastic_package_install" "passed" "Installed elastic-package v${ver}" \
    || { add_check_result "elastic_package_install" "failed" "Install failed"; return 1; }
}

create_integration_pr() {
  local integration_path="$1" branch_name="$2" reason="$3"

  echo "--- Running elastic-package changelog/build for ${INTEGRATION}"
  git_cfg_user
  configure_origin_token_remote

  pushd "${integration_path}" >/dev/null

  # Changelog (best effort)
  if elastic-package changelog add \
      --type "enhancement" \
      --description "Automated integration improvements and fixes" \
      --link "${ISSUE_URL:-https://github.com/${ISSUE_REPO}/issues/${ISSUE_NUMBER}}" 2>&1; then
    add_check_result "changelog_add" "passed" "Changelog entry added"
  else
    add_check_result "changelog_add" "failed" "Changelog add failed"
  fi

  echo "Building package..."
  local build_out; build_out="$(mktemp)"
  if elastic-package build 2>&1 | tee "${build_out}"; then
    add_check_result "package_build" "passed" "Package built"
    json_inplace --arg out "$(cat "${build_out}")" '.check_output=$out'
  else
    add_check_result "package_build" "failed" "Build failed"
    json_inplace --arg out "$(cat "${build_out}")" '.check_output=$out'
    popd >/dev/null
    return 1
  fi

  git add -A
  if git diff --staged --quiet; then
    add_check_result "pr_creation" "skipped" "No changes to commit"
    popd >/dev/null
    return 0
  fi

  git commit -m "feat: Update ${INTEGRATION} integration

- Add changelog entry
- Rebuild package with elastic-package
- ${reason}

Related: ${ISSUE_URL:-}
Build: ${BUILDKITE_BUILD_URL:-}
Integration: ${INTEGRATION}
"
  git push -u origin "${branch_name}"

  # PR
  local pr_title="feat: Update ${INTEGRATION} integration"
  local pr_body; pr_body="$(cat <<'PR'
## 🔧 Automated Integration Update

This PR contains automated improvements for the integration.

- ✅ Added changelog entry
- ✅ Rebuilt with `elastic-package build`

*Generated by Buildkite.*
PR
)"
  if gh pr create --title "${pr_title}" --body "${pr_body}" --base "main" --head "${branch_name}"; then
    local pr_url; pr_url="$(gh pr view --json url --jq '.url')"
    add_check_result "pr_creation" "passed" "Created PR: ${pr_url}"
    json_inplace --arg url "$pr_url" --arg br "$branch_name" '.pr_url=$url | .pr_branch=$br'
  else
    add_check_result "pr_creation" "failed" "Failed to create PR"
    popd >/dev/null
    return 1
  fi

  popd >/dev/null
  return 0
}

# Always mark failure unless we succeeded
trap 'update_result "failed" "Script exited unexpectedly"' EXIT

# ---------- Workspace prep ----------
if [[ ! -d "${WORKDIR}/elastic-integrations" ]]; then
  echo "Cloning ${REPOSITORY_NAME} ..."
  git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${REPOSITORY_NAME}.git" \
    "${WORKDIR}/elastic-integrations"
  add_check_result "repository_clone" "passed" "Cloned ${REPOSITORY_NAME}"
else
  echo "Updating ${REPOSITORY_NAME} ..."
  pushd "${WORKDIR}/elastic-integrations" >/dev/null
  git fetch --quiet origin main
  git reset --hard origin/main
  popd >/dev/null
  add_check_result "repository_update" "passed" "Synced ${REPOSITORY_NAME}"
fi

INTEGRATION_PATH="${WORKDIR}/elastic-integrations/packages/${INTEGRATION}"
if [[ ! -d "${INTEGRATION_PATH}" ]]; then
  add_check_result "integration_exists" "failed" "Not found: ${INTEGRATION_PATH}"
  update_result "failed" "Integration '${INTEGRATION}' not found in ${REPOSITORY_NAME}"
  exit 1
fi
add_check_result "integration_exists" "passed" "Found ${INTEGRATION_PATH}"

setup_elastic_package

echo "Running elastic-package check..."
pushd "${INTEGRATION_PATH}" >/dev/null
CHECK_OUT="$(mktemp)"
if elastic-package check 2>&1 | tee "${CHECK_OUT}"; then
  CHECK_STATUS="passed"; CHECK_MESSAGE="All checks passed"
else
  CHECK_STATUS="failed"; CHECK_MESSAGE="Checks failed (see logs)"
fi
popd >/dev/null

add_check_result "elastic_package_check" "${CHECK_STATUS}" "${CHECK_MESSAGE}"
json_inplace --arg out "$(cat "${CHECK_OUT}")" '.check_output=$out'

# ---------- PR logic ----------
pushd "${WORKDIR}/elastic-integrations" >/dev/null

if [[ "${CHECK_STATUS}" == "failed" ]]; then
  git_cfg_user
  configure_origin_token_remote
  BRANCH_NAME="fix-${INTEGRATION}-issue-${ISSUE_NUMBER:-$(date +%s)}"
  git checkout -b "${BRANCH_NAME}"
  if create_integration_pr "packages/${INTEGRATION}" "${BRANCH_NAME}" "Address check failures"; then
    echo "Created fix PR."
  else
    echo "Fix PR failed; leaving branch for manual follow-up."
  fi
else
  # Success path: create enhancement PR (best effort)
  if setup_github_cli; then
    git_cfg_user
    configure_origin_token_remote
    BRANCH_NAME="enhance-${INTEGRATION}-issue-${ISSUE_NUMBER:-$(date +%s)}"
    git checkout -b "${BRANCH_NAME}"
    create_integration_pr "packages/${INTEGRATION}" "${BRANCH_NAME}" "Post-success enhancements" || true
  else
    add_check_result "enhancement_pr" "failed" "gh setup failed"
  fi
fi

popd >/dev/null

# ---------- Finalize ----------
if [[ "${CHECK_STATUS}" == "passed" ]]; then
  update_result "passed" "Integration check completed successfully"
else
  update_result "failed" "Integration check failed (PR may be opened)"
fi

trap - EXIT

echo ""
echo "=== Integration Check Complete ==="
echo "Status: $(jq -r '.status' "${RESULT_FILE}")"
echo "Result file: ${RESULT_FILE}"

