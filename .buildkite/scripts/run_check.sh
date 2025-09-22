#!/usr/bin/env bash
set -euo pipefail

: "${INTEGRATION:?}"  # from matrix
: "${INTEGRATIONS_REPO:=elastic/integrations}"
: "${INTEGRATIONS_BRANCH:=main}"
: "${INTEGRATION_PATH_PREFIX:=packages}"

WORK="work/${INTEGRATION}"
mkdir -p "$WORK"
pushd "$WORK" >/dev/null

echo "--- Cloning ${INTEGRATIONS_REPO}@${INTEGRATIONS_BRANCH}"
git clone --depth=1 --branch "$INTEGRATIONS_BRANCH" "https://github.com/${INTEGRATIONS_REPO}.git" repo
cd repo

PKG_DIR="${INTEGRATION_PATH_PREFIX}/${INTEGRATION}"
if [[ ! -d "$PKG_DIR" ]]; then
  echo "Package not found: ${PKG_DIR}"
  echo "{\"integration\":\"$INTEGRATION\",\"status\":\"not_found\"}" > ../result.json
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

echo "--- elastic-package check ${PKG_DIR}"
set +e
elastic-package check -v -f "$PKG_DIR"
rc=$?
set -e

status="passed"; [[ $rc -ne 0 ]] && status="failed"
echo "{\"integration\":\"$INTEGRATION\",\"status\":\"$status\",\"exit_code\":$rc}" > ../result.json
popd >/dev/null
buildkite-agent artifact upload "work/${INTEGRATION}/result.json"
exit $rc

