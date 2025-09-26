#!/usr/bin/env bash
set -euo pipefail

# Simple orchestration script that receives data from GitHub Actions
# and creates matrix jobs for each integration

echo "=== Integration Check Orchestrator ==="
echo "Build: ${BUILDKITE_BUILD_NUMBER:-unknown}"
echo "Pipeline: ${BUILDKITE_PIPELINE_SLUG:-unknown}"

# Check required environment variables from GitHub Actions
missing_vars=()
[[ -z "${ISSUE_NUMBER:-}" ]] && missing_vars+=("ISSUE_NUMBER")
[[ -z "${ISSUE_URL:-}" ]] && missing_vars+=("ISSUE_URL") 
[[ -z "${ISSUE_REPO:-}" ]] && missing_vars+=("ISSUE_REPO")
[[ -z "${INTEGRATIONS_JSON:-}" ]] && missing_vars+=("INTEGRATIONS_JSON")
[[ -z "${GITHUB_TOKEN:-}" ]] && missing_vars+=("GITHUB_TOKEN")

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "❌ Missing required environment variables:"
    printf '  - %s\n' "${missing_vars[@]}"
    echo ""
    echo "Available environment variables:"
    env | grep -E '^(BUILDKITE_|GITHUB_|ISSUE_|INTEGRATIONS_)' | sort
    exit 1
fi

echo "✅ All required variables present"
echo "Issue: #${ISSUE_NUMBER} from ${ISSUE_REPO}"
echo "Integrations JSON: ${INTEGRATIONS_JSON}"

# Validate integrations JSON
if ! echo "${INTEGRATIONS_JSON}" | jq empty 2>/dev/null; then
    echo "❌ Invalid JSON in INTEGRATIONS_JSON"
    exit 1
fi

# Extract integrations array
INTEGRATIONS=$(echo "${INTEGRATIONS_JSON}" | jq -r '.[]' 2>/dev/null || echo "")

if [[ -z "${INTEGRATIONS}" ]]; then
    echo "❌ No integrations found in JSON"
    exit 1
fi

echo "Found integrations:"
echo "${INTEGRATIONS_JSON}" | jq -r '.[]' | sed 's/^/  - /'

# Store environment variables for downstream jobs
mkdir -p artifacts
cat > artifacts/build-env.txt << EOF
ISSUE_NUMBER=${ISSUE_NUMBER}
ISSUE_URL=${ISSUE_URL}
ISSUE_REPO=${ISSUE_REPO}
GITHUB_TOKEN=${GITHUB_TOKEN}
EOF

# Generate dynamic pipeline with matrix jobs
echo ""
echo "Generating dynamic pipeline..."

# Debug: Show the integrations we're working with
echo "Debug: INTEGRATIONS_JSON content:"
echo "${INTEGRATIONS_JSON}"
echo "Debug: Parsing integrations:"
echo "${INTEGRATIONS_JSON}" | jq -r '.[]' | while IFS= read -r integration; do
    echo "  Integration: '${integration}'"
done

# Create YAML for matrix setup - ensure proper formatting
INTEGRATIONS_ARRAY=$(echo "${INTEGRATIONS_JSON}" | jq -r '.[]')

cat > dynamic-pipeline.yml << 'EOF'
steps:
  - label: ":package: Check {{matrix.integration}}"
    key: "check"
    command: ".buildkite/scripts/check_integration.sh"
    matrix:
      setup:
        integration:
EOF

# Add each integration as a YAML array item
echo "${INTEGRATIONS_ARRAY}" | while IFS= read -r integration; do
    echo "          - \"${integration}\"" >> dynamic-pipeline.yml
done

cat >> dynamic-pipeline.yml << EOF
    artifact_paths: "results/{{matrix.integration}}.json"
    agents:
      queue: "default"
    env:
      ISSUE_NUMBER: "${ISSUE_NUMBER}"
      ISSUE_URL: "${ISSUE_URL}"
      ISSUE_REPO: "${ISSUE_REPO}"
      GITHUB_TOKEN: "${PR_TOKEN}"
      INTEGRATION: "{{matrix.integration}}"

  - label: ":memo: Summarize Results"
    key: "summarize"
    depends_on: "check"
    command: ".buildkite/scripts/summarize_results.sh"
    agents:
      queue: "default"
    env:
      ISSUE_NUMBER: "${ISSUE_NUMBER}"
      ISSUE_REPO: "${ISSUE_REPO}"
      GITHUB_TOKEN: "${GITHUB_TOKEN}"
EOF

echo "Generated pipeline:"
cat dynamic-pipeline.yml

# Validate the YAML before uploading
if command -v yq >/dev/null 2>&1; then
    echo ""
    echo "Validating generated YAML..."
    if yq eval '.' dynamic-pipeline.yml >/dev/null 2>&1; then
        echo "✅ YAML is valid"
    else
        echo "❌ Generated YAML is invalid:"
        yq eval '.' dynamic-pipeline.yml 2>&1 || true
        exit 1
    fi
else
    echo "⚠️  yq not available, skipping YAML validation"
fi

echo ""
echo "Uploading dynamic pipeline..."
buildkite-agent pipeline upload dynamic-pipeline.yml

echo "✅ Pipeline uploaded successfully"