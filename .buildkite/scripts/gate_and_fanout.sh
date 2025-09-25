#!/usr/bin/env bash
set -euo pipefail

# This script runs first in every build created by the # Upload dynamic pipeline: one job per integration
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
YAMLters for "issues" events with the desired label and front-matter,
# extracts the integrations list, and uploads a dynamic pipeline that fans out.

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1"; exit 1; }; }
require jq
require awk
require yq || true  # We'll try to parse YAML even if yq is missing.

mkdir -p work
BODY_FILE="work/webhook.json"

# Buildkite puts the raw request into this env var when using Incoming Webhook.
# (Pipeline Settings → Webhook → "Builds can be created via a webhook")
if [[ -z "${BUILDKITE_WEBHOOK_BODY:-}" ]]; then
  echo "No BUilDKITE_WEBHOOK_BODY – is this pipeline triggered by the incoming webhook?" >&2
  exit 1
fi

printf "%s" "$BUILDKITE_WEBHOOK_BODY" > "$BODY_FILE"

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

# Parse integrations: allow operation with or without yq
if command -v yq >/dev/null 2>&1; then
  if ! yq -e '.integrations and (.integrations | type == "!!seq")' work/issue.yaml >/dev/null; then
    echo "YAML must define 'integrations: [..]' sequence; exiting."
    exit 0
  fi
  INTEGS_JSON=$(yq -o=json '.integrations' work/issue.yaml)
else
  # Very simple fallback: read lines under 'integrations:' until next key or EOF
  INTEGS_JSON=$(awk '
    $0 ~ /^integrations:/ {inlist=1; next}
    inlist && $0 ~ /^[^ \t-]/ {inlist=0}
    inlist && $0 ~ /^[ \t]*-[ \t]*/ {
      gsub(/^[ \t]*-[ \t]*/, "", $0);
      gsub(/[ \t\r\n]+$/, "", $0);
      printf("\"%s\",\n", $0)
    }
  ' work/issue_body.txt | sed '$ s/,$//' | awk 'BEGIN{print "["} {print} END{print "]"}')
fi

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
    matrix:
      setup:
        integration: ${INTEGS}

  - label: ":memo: summarize"
    key: summarize
    depends_on: "check"
    command: .buildkite/scripts/summarize.sh
    agents: { queue: standard }
YAML

buildkite-agent pipeline upload work/dynamic.yml

