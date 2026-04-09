#!/usr/bin/env bash
set -euo pipefail

RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-devopslabs}"

if [[ ! -x "${RUNNER_DIR}/run.sh" ]]; then
  echo "Error: runner is not installed in ${RUNNER_DIR}." >&2
  exit 1
fi

cd "${RUNNER_DIR}"
exec ./run.sh
