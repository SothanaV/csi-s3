#!/usr/bin/env bash
# Lint and render the chart, optionally against a values file.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CHART_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
RELEASE_NAME=${1:-"csi-s3"}
NAMESPACE=${2:-"kube-system"}
VALUES_FILE=${3:-""}

echo "==> Lint ${CHART_DIR}"
if [[ -n "${VALUES_FILE}" ]]; then
  helm lint --strict "${CHART_DIR}" -f "${VALUES_FILE}"
else
  helm lint --strict "${CHART_DIR}"
fi

echo "==> Render (release=${RELEASE_NAME} namespace=${NAMESPACE})"
RENDER_ARGS=(helm template "${RELEASE_NAME}" "${CHART_DIR}" --namespace "${NAMESPACE}")
if [[ -n "${VALUES_FILE}" ]]; then
  RENDER_ARGS+=(-f "${VALUES_FILE}")
fi
"${RENDER_ARGS[@]}" | kubectl apply --dry-run=client -f -

echo "==> OK"
