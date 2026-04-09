#!/usr/bin/env bash
set -euo pipefail

REPO_FULL_NAME="${REPO_FULL_NAME:-gorinovdan/DevOpsLabs}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-devopslabs}"
RUNNER_NAME="${RUNNER_NAME:-$(scutil --get LocalHostName 2>/dev/null || hostname)-minikube}"
RUNNER_LABELS="${RUNNER_LABELS:-minikube-local}"

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

require_cmd gh

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

if [[ ! -x "${RUNNER_DIR}/config.sh" ]]; then
  echo "Error: runner is not installed in ${RUNNER_DIR}. Install/unpack it first." >&2
  exit 1
fi

registration_token="$(
  gh api "repos/${REPO_FULL_NAME}/actions/runners/registration-token" \
    -X POST \
    --jq .token
)"

cd "${RUNNER_DIR}"

if [[ -f .runner ]]; then
  echo "Runner is already configured in ${RUNNER_DIR}."
  exit 0
fi

./config.sh \
  --unattended \
  --url "https://github.com/${REPO_FULL_NAME}" \
  --token "${registration_token}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --work "_work"

echo "Runner configured successfully in ${RUNNER_DIR}."
