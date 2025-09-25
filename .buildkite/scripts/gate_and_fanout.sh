#!/usr/bin/env bash
set -euo pipefail

# This script runs first in every build created by the webhook.
# It filters for "issues" events with the desired label and front-matter,
# extracts the integrations list, and uploads a dynamic pipeline that fans out.

# Install yq if not present
if ! command -v yq >/dev/null 2>&1; then
  echo "Installing yq..."
  
  # Try different installation methods based on what's available
  if command -v wget >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    # Method 1: Direct download (preferred)
    YQ_VERSION="v4.35.2"
    YQ_BINARY="yq_linux_amd64"
    
    wget -qO /tmp/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}"
    chmod +x /tmp/yq
    sudo mv /tmp/yq /usr/local/bin/yq
    
  elif command -v curl >/dev/null 2>&1; then
    # Method 2: Using curl and local PATH
    YQ_VERSION="v4.35.2"
    YQ_BINARY="yq_linux_amd64"
    
    mkdir -p ~/.local/bin
    curl -sL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}" -o ~/.local/bin/yq
    chmod +x ~/.local/bin/yq
    export PATH="$HOME/.local/bin:$PATH"
    
  elif command -v apt-get >/dev/null 2>&1; then
    # Method 3: Using apt (if available)
    sudo apt-get update -qq
    sudo apt-get install -y yq
    
  else
    echo "Cannot install yq - no suitable installation method found"
    echo "Please install yq manually or ensure wget/curl is available"
    exit 1
  fi
  
  echo "yq installed successfully"
  yq --version
fi

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
require jq
require awk
require yq

mkdir -p work
BODY_FILE="work/webhook.json"

# Buildkite puts the raw request into this env var when using Incoming Webhook.
# (Pipeline Settings → Webhook → "Builds can be created via a webhook")
# When triggered from GitHub Actions, this might be structured differently
if [[ -z "${BUILDKITE_WEBHOOK_BODY:-}" ]]; then
  echo "No BUILDKITE_WEBHOOK_BODY – checking if triggered from GitHub Actions..." >&2
  
  # Check if we have the data from GitHub Actions environment
  if [[ -n "${ISSUE_NUMBER:-}" && -n "${ISSUE_YAML:-}" ]]; then
    echo "Found GitHub Actions environment variables, creating webhook body structure" >&2
    # Create a structure that mimics what we'd get from a webhook
    cat > "$BODY_FILE" <<EOF
{
  "action": "${ISSUE_EVENT:-opened}",
  "issue": {
    "number": ${ISSUE_NUMBER},
    "html_url": "${ISSUE_URL:-}",
    "body": $(printf '%s' "${ISSUE_YAML}" | jq -Rs .),
    "labels": [{"name": "ai-doc-gen"}]
  },
  "repository": {
    "full_name": "${ISSUE_REPO:-}"
  }
}
EOF
  else
    echo "No webhook body and no GitHub Actions env vars found" >&2
    echo "Expected: BUILDKITE_WEBHOOK_BODY or (ISSUE_NUMBER, ISSUE_YAML, etc.)" >&2
    exit 1
  fi
else
  printf "%s" "$BUILDKITE_WEBHOOK_BODY" > "$BODY_FILE"
fi

EVENT=$(jq -r '.action // empty' "$BODY_FILE")
KIND=$(jq -r 'if has("issue") then "issues" elif has("pull_request") then "pull_request" else "unknown" end' "$BODY_FILE")

if [[ "$KIND" != "issues" ]]; then
  echo "Ignoring non-issues event: $KIND"
  exit 0
fi

# Accept opened/labeled/edited/reopened
case "$EVENT" in
  opened|labeled|edited|reopened) : ;;
  *) echo "Ignoring issues.$EVENT"; exit 0 ;;
esac

# Filter on label (ai-doc-gen) — change/remove if you want any issue to trigger.
LABEL_MATCH=$(jq -r '.issue.labels[].name? // empty' "$BODY_FILE" | grep -x "ai-doc-gen" || true)
if [[ -z "$LABEL_MATCH" ]]; then
  echo "No ai-doc-gen label, exiting."
  exit 0
fi

ISSUE_NUMBER=$(jq -r '.issue.number' "$BODY_FILE")
ISSUE_URL=$(jq -r '.issue.html_url' "$BODY_FILE")
ISSUE_REPO=$(jq -r '.repository.full_name' "$BODY_FILE")
ISSUE_BODY=$(jq -r '.issue.body // ""' "$BODY_FILE")

# Extract front-matter YAML between --- markers
echo "$ISSUE_BODY" > work/issue_body.txt
awk 'BEGIN{f=0} /^---[ \t]*$/{c++} c==1{f=1;next} c==2{exit} f{print}' work/issue_body.txt > work/issue.yaml || true

if [[ ! -s work/issue.yaml ]]; then
  echo "No YAML front-matter found in issue body; exiting."
  exit 0
fi

# Parse integrations using yq
echo "Parsing YAML with yq"
if ! yq -e '.integrations and (.integrations | type == "!!seq")' work/issue.yaml >/dev/null; then
  echo "YAML must define 'integrations: [..]' sequence; exiting."
  echo "Expected format:"
  echo "---"
  echo "integrations:"
  echo "  - integration1" 
  echo "  - integration2"
  echo "---"
  exit 0
fi

INTEGS_JSON=$(yq -o=json '.integrations' work/issue.yaml)

# Normalize json array
INTEGS=$(jq -c '.' <<<"${INTEGS_JSON}")

if [[ -z "$INTEGS" || "$INTEGS" == "[]" ]]; then
  echo "No integrations found; exiting."
  exit 0
fi

# Export useful vars to downstream steps (summary will use them)
{
  echo "ISSUE_NUMBER=${ISSUE_NUMBER}"
  echo "ISSUE_URL=${ISSUE_URL}"
  echo "ISSUE_REPO=${ISSUE_REPO}"
} >> "$BUILDKITE_ENV_FILE"

# Upload dynamic pipeline: one job per integration
cat > work/dynamic.yml <<YAML
steps:
  - label: ":package: elastic-package check %{matrix.integration}"
    key: check
    command: .buildkite/scripts/run_check.sh
    agents: { queue: standard }
    env:
      GITHUB_TOKEN: ${GITHUB_TOKEN:-}
      ISSUE_URL: ${ISSUE_URL:-}
      BUILDKITE_BUILD_URL: ${BUILDKITE_BUILD_URL:-}
    matrix:
      setup:
        integration: ${INTEGS}

  - label: ":memo: summarize"
    key: summarize
    depends_on: "check"
    command: .buildkite/scripts/summarize.sh
    agents: { queue: standard }
    env:
      ISSUE_REPO: ${ISSUE_REPO:-}
      ISSUE_NUMBER: ${ISSUE_NUMBER:-}
      GITHUB_TOKEN: ${GITHUB_TOKEN:-}
YAML

buildkite-agent pipeline upload work/dynamic.yml

