#!/usr/bin/env bash
set -euo pipefail

# Orchestrates matrix checks per integration and uploads a child pipeline.

echo "=== Integration Check Orchestrator ==="
echo "Build: ${BUILDKITE_BUILD_NUMBER:-unknown}"
echo "Pipeline: ${BUILDKITE_PIPELINE_SLUG:-unknown}"

# ---- Required env ----
missing=()
[[ -z "${ISSUE_NUMBER:-}"      ]] && missing+=("ISSUE_NUMBER")
[[ -z "${ISSUE_URL:-}"         ]] && missing+=("ISSUE_URL")
[[ -z "${ISSUE_REPO:-}"        ]] && missing+=("ISSUE_REPO")
[[ -z "${INTEGRATIONS_JSON:-}" ]] && missing+=("INTEGRATIONS_JSON")
[[ -z "${GITHUB_TOKEN:-}"      ]] && missing+=("GITHUB_TOKEN")
[[ -z "${GITHUB_PR_TOKEN:-}"   ]] && missing+=("GITHUB_PR_TOKEN")
if (( ${#missing[@]} )); then
  echo "❌ Missing env:"
  printf '  - %s\n' "${missing[@]}"
  echo; echo "Available (filtered):"
  env | grep -E '^(BUILDKITE_|GITHUB_|ISSUE_|INTEGRATIONS_)' | sort || true
  exit 1
fi

echo "✅ All required variables present"
echo "Issue: #${ISSUE_NUMBER} from ${ISSUE_REPO}"
echo "Integrations JSON: ${INTEGRATIONS_JSON}"

# ---- Validate and extract integrations ----
if ! echo "${INTEGRATIONS_JSON}" | jq -e 'type=="array" and length>0' >/dev/null; then
  echo "❌ INTEGRATIONS_JSON must be a non-empty JSON array"; exit 1
fi

mapfile -t INTEGRATIONS < <(echo "${INTEGRATIONS_JSON}" | jq -r '.[]')
echo "Found integrations:"; for i in "${INTEGRATIONS[@]}"; do echo "  - ${i}"; done

# ---- Persist minimal shared context (optional) ----
mkdir -p artifacts
cat > artifacts/build-env.txt <<EOF
ISSUE_NUMBER=${ISSUE_NUMBER}
ISSUE_URL=${ISSUE_URL}
ISSUE_REPO=${ISSUE_REPO}
EOF

# ---- Generate dynamic pipeline YAML ----
PIPELINE_FILE="dynamic-pipeline.yml"
: > "${PIPELINE_FILE}"

cat >> "${PIPELINE_FILE}" <<'YAML'
steps:
  - label: ":package: Check {{matrix.integration}}"
    key: "check"
    command: ".buildkite/scripts/check_integration.sh"
    matrix:
      setup:
        integration:
YAML

for integration in "${INTEGRATIONS[@]}"; do
  # simple YAML-safe quoting (names expected like "cisco_duo")
  printf '          - "%s"\n' "${integration}" >> "${PIPELINE_FILE}"
done

cat >> "${PIPELINE_FILE}" <<EOF
    env:
      ISSUE_NUMBER: "${ISSUE_NUMBER}"
      ISSUE_URL: "${ISSUE_URL}"
      ISSUE_REPO: "${ISSUE_REPO}"
      # NOTE: Passing tokens here will interpolate into the uploaded pipeline.
      # Prefer pipeline/cluster secrets if available.
      GITHUB_TOKEN: "${GITHUB_PR_TOKEN}"
      INTEGRATION: "{{matrix.integration}}"

  - label: ":memo: Summarize Results"
    key: "summarize"
    depends_on: "check"
    command: ".buildkite/scripts/summarize_results.sh"
    env:
      ISSUE_NUMBER: "${ISSUE_NUMBER}"
      ISSUE_REPO: "${ISSUE_REPO}"
      GITHUB_TOKEN: "${GITHUB_PR_TOKEN}"
EOF

# ---- Optional: validate YAML if yq is present ----
if command -v yq >/dev/null 2>&1; then
  echo; echo "Validating generated YAML..."
  yq eval '.' "${PIPELINE_FILE}" >/dev/null \
    && echo "✅ YAML is valid" \
    || { echo "❌ YAML invalid"; yq eval '.' "${PIPELINE_FILE}" || true; exit 1; }
else
  echo "⚠️ yq not available, skipping YAML validation"
fi

# ---- Upload child pipeline (reject secrets by default) ----
echo; echo "Uploading dynamic pipeline..."
export BUILDKITE_AGENT_PIPELINE_UPLOAD_REJECT_SECRETS="${BUILDKITE_AGENT_PIPELINE_UPLOAD_REJECT_SECRETS:-true}"
buildkite-agent pipeline upload "${PIPELINE_FILE}"

echo "✅ Pipeline uploaded successfully"
