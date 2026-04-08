#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AUTO_START_MINIKUBE="${AUTO_START_MINIKUBE:-1}" \
BUILD_LOCAL="${BUILD_LOCAL:-1}" \
ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-1}" \
RUN_SMOKE_TEST="${RUN_SMOKE_TEST:-1}" \
RUN_HPA_VALIDATION="${RUN_HPA_VALIDATION:-0}" \
"${ROOT_DIR}/scripts/deploy_minikube.sh"
