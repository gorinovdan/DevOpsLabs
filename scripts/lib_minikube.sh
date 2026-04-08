#!/usr/bin/env bash

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

ensure_minikube_running() {
  local auto_start="${1:-0}"
  local driver="${2:-docker}"
  local cpus="${3:-4}"
  local memory="${4:-6144}"

  if minikube status >/dev/null 2>&1; then
    return 0
  fi

  if [[ "${auto_start}" != "1" ]]; then
    echo "Error: minikube is not running. Start it first or set AUTO_START_MINIKUBE=1." >&2
    exit 1
  fi

  echo "Starting minikube with driver=${driver}, cpus=${cpus}, memory=${memory}..."
  minikube start --driver="${driver}" --cpus="${cpus}" --memory="${memory}"
}

ensure_host_image() {
  local image="$1"

  require_cmd docker

  if docker image inspect "${image}" >/dev/null 2>&1; then
    return 0
  fi

  echo "Pulling image on host: ${image}"
  docker pull "${image}"
}

image_present_in_minikube() {
  local image="$1"
  (
    eval "$(minikube -p minikube docker-env --shell bash)"
    docker image inspect "${image}" >/dev/null 2>&1
  )
}

load_image_into_minikube() {
  local image="$1"

  require_cmd docker
  require_cmd minikube

  if image_present_in_minikube "${image}"; then
    return 0
  fi

  ensure_host_image "${image}"

  echo "Loading image into minikube: ${image}"
  docker save "${image}" | (
    eval "$(minikube -p minikube docker-env --shell bash)"
    docker load >/dev/null
  )
}

compute_dir_hash() {
  local dir="$1"

  find "${dir}" \
    -type f \
    ! -path '*/node_modules/*' \
    ! -path '*/dist/*' \
    ! -path '*/coverage/*' \
    ! -path '*/.git/*' \
    -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 \
    | shasum -a 256 \
    | awk '{print substr($1, 1, 12)}'
}

render_template_file() {
  local source_file="$1"
  local target_file="$2"

  sed \
    -e "s#__BACKEND_IMAGE__#${BACKEND_IMAGE}#g" \
    -e "s#__FRONTEND_IMAGE__#${FRONTEND_IMAGE}#g" \
    -e "s#__POSTGRES_IMAGE__#${POSTGRES_IMAGE}#g" \
    -e "s#__INIT_POSTGRES_IMAGE__#${INIT_POSTGRES_IMAGE}#g" \
    -e "s#__PROMETHEUS_IMAGE__#${PROMETHEUS_IMAGE}#g" \
    -e "s#__GRAFANA_IMAGE__#${GRAFANA_IMAGE}#g" \
    "${source_file}" > "${target_file}"
}

kubectl_apply_if_changed() {
  local manifest_path="$1"
  local display_name="${2:-${manifest_path}}"

  if kubectl diff -f "${manifest_path}" >/dev/null 2>&1; then
    echo "Manifest up-to-date: ${display_name}"
    return 0
  fi

  kubectl apply -f "${manifest_path}"
}
