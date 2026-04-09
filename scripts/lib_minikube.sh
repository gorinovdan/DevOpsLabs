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

detect_host_arch() {
  case "$(uname -m)" in
    arm64|aarch64)
      echo "arm64"
      ;;
    x86_64|amd64)
      echo "amd64"
      ;;
    *)
      echo "Error: unsupported host architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
}

build_prometheus_image_from_release() {
  local image="$1"
  local version="$2"
  local arch
  local workdir
  local src_dir
  local context_dir

  require_cmd curl
  require_cmd tar
  require_cmd docker

  if docker image inspect "${image}" >/dev/null 2>&1; then
    echo "Using cached Prometheus image: ${image}"
    return 0
  fi

  arch="$(detect_host_arch)"
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' RETURN

  echo "Downloading Prometheus ${version} release for ${arch}..."
  curl -LfsS \
    -o "${workdir}/prometheus.tar.gz" \
    "https://github.com/prometheus/prometheus/releases/download/v${version}/prometheus-${version}.linux-${arch}.tar.gz"

  tar -xzf "${workdir}/prometheus.tar.gz" -C "${workdir}"
  src_dir="${workdir}/prometheus-${version}.linux-${arch}"
  context_dir="${workdir}/context"
  mkdir -p "${context_dir}"

  cp "${src_dir}/prometheus" "${context_dir}/prometheus"
  cp -R "${src_dir}/consoles" "${context_dir}/consoles"
  cp -R "${src_dir}/console_libraries" "${context_dir}/console_libraries"

  cat > "${context_dir}/Dockerfile" <<'EOF'
FROM busybox:1.36
COPY prometheus /bin/prometheus
COPY consoles /usr/share/prometheus/consoles
COPY console_libraries /usr/share/prometheus/console_libraries
EXPOSE 9090
ENTRYPOINT ["/bin/prometheus"]
EOF

  echo "Packaging Prometheus runtime image: ${image}"
  docker build -t "${image}" "${context_dir}" >/dev/null

  trap - RETURN
  rm -rf "${workdir}"
}

build_grafana_image_from_release() {
  local image="$1"
  local version="$2"
  local arch
  local workdir
  local src_dir
  local context_dir

  require_cmd curl
  require_cmd tar
  require_cmd docker

  if docker image inspect "${image}" >/dev/null 2>&1; then
    echo "Using cached Grafana image: ${image}"
    return 0
  fi

  arch="$(detect_host_arch)"
  workdir="$(mktemp -d)"
  trap 'rm -rf "${workdir}"' RETURN

  echo "Downloading Grafana ${version} release for ${arch}..."
  curl -LfsS \
    -o "${workdir}/grafana.tar.gz" \
    "https://dl.grafana.com/oss/release/grafana-${version}.linux-${arch}.tar.gz"

  tar -xzf "${workdir}/grafana.tar.gz" -C "${workdir}"
  src_dir="${workdir}/grafana-v${version}"
  context_dir="${workdir}/context"
  mkdir -p "${context_dir}/grafana"

  cp -R "${src_dir}/conf" "${context_dir}/grafana/conf"
  cp -R "${src_dir}/bin" "${context_dir}/grafana/bin"
  cp -R "${src_dir}/public" "${context_dir}/grafana/public"
  cp -R "${src_dir}/plugins-bundled" "${context_dir}/grafana/plugins-bundled"
  cp "${src_dir}/LICENSE" "${context_dir}/grafana/LICENSE"

  cat > "${context_dir}/Dockerfile" <<'EOF'
FROM alpine:3.19.1
ENV PATH="/usr/share/grafana/bin:$PATH" \
    GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
    GF_PATHS_DATA="/var/lib/grafana" \
    GF_PATHS_HOME="/usr/share/grafana" \
    GF_PATHS_LOGS="/var/log/grafana" \
    GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
    GF_PATHS_PROVISIONING="/etc/grafana/provisioning"
RUN apk add --no-cache ca-certificates bash curl tzdata musl-utils
WORKDIR /usr/share/grafana
COPY grafana/conf ./conf
COPY grafana/bin ./bin
COPY grafana/public ./public
COPY grafana/plugins-bundled ./plugins-bundled
COPY grafana/LICENSE ./LICENSE
RUN mkdir -p "$GF_PATHS_PROVISIONING/datasources" \
             "$GF_PATHS_PROVISIONING/dashboards" \
             "$GF_PATHS_PROVISIONING/notifiers" \
             "$GF_PATHS_PROVISIONING/plugins" \
             "$GF_PATHS_PROVISIONING/access-control" \
             "$GF_PATHS_PROVISIONING/alerting" \
             "$GF_PATHS_LOGS" \
             "$GF_PATHS_PLUGINS" \
             "$GF_PATHS_DATA/dashboards" \
             /etc/grafana \
    && cp conf/sample.ini "$GF_PATHS_CONFIG" \
    && cp conf/ldap.toml /etc/grafana/ldap.toml \
    && chmod -R 777 "$GF_PATHS_DATA" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING"
EXPOSE 3000
ENTRYPOINT ["/usr/share/grafana/bin/grafana", "server", "--homepath=/usr/share/grafana", "--config=/etc/grafana/grafana.ini"]
EOF

  echo "Packaging Grafana runtime image: ${image}"
  docker build -t "${image}" "${context_dir}" >/dev/null

  trap - RETURN
  rm -rf "${workdir}"
}

build_local_observability_images() {
  local prometheus_image="$1"
  local prometheus_version="$2"
  local grafana_image="$3"
  local grafana_version="$4"

  build_prometheus_image_from_release "${prometheus_image}" "${prometheus_version}"
  build_grafana_image_from_release "${grafana_image}" "${grafana_version}"
}

image_present_in_minikube() {
  local image="$1"
  (
    eval "$(minikube -p minikube docker-env --shell bash)"
    docker image inspect "${image}" >/dev/null 2>&1
  )
}

pull_image_directly_in_minikube() {
  local image="$1"

  echo "Pulling image directly in minikube: ${image}"
  (
    eval "$(minikube -p minikube docker-env --shell bash)"
    docker pull "${image}"
  )
}

load_image_into_minikube() {
  local image="$1"

  require_cmd docker
  require_cmd minikube

  if image_present_in_minikube "${image}"; then
    return 0
  fi

  if docker image inspect "${image}" >/dev/null 2>&1; then
    echo "Loading image into minikube: ${image}"
    docker save "${image}" | (
      eval "$(minikube -p minikube docker-env --shell bash)"
      docker load >/dev/null
    )
    return 0
  fi

  if pull_image_directly_in_minikube "${image}"; then
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
    -e "s#__KUBE_STATE_METRICS_IMAGE__#${KUBE_STATE_METRICS_IMAGE}#g" \
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

wait_for_local_port() {
  local port="$1"
  local host="${2:-127.0.0.1}"
  local attempts="${3:-30}"

  for _ in $(seq 1 "${attempts}"); do
    if (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1; then
      exec 3>&-
      exec 3<&-
      return 0
    fi
    sleep 1
  done

  return 1
}

find_listener_pid() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -n -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | head -n 1
  fi
}

terminate_pid() {
  local pid="$1"

  if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi

  kill "${pid}" >/dev/null 2>&1 || true

  for _ in $(seq 1 10); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done

  kill -9 "${pid}" >/dev/null 2>&1 || true
}

start_detached_command() {
  local log_file="$1"
  shift

  require_cmd python3

  python3 - "${log_file}" "$@" <<'PY'
import subprocess
import sys

log_file = sys.argv[1]
command = sys.argv[2:]

with open(log_file, "ab", buffering=0) as log_handle:
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )

print(process.pid)
PY
}

ensure_port_forward() {
  local name="$1"
  local namespace="$2"
  local service="$3"
  local local_port="$4"
  local remote_port="$5"
  local state_dir="${TMPDIR:-/tmp}/flowboard-port-forwards"
  local pid_file="${state_dir}/${name}.pid"
  local log_file="${state_dir}/${name}.log"
  local existing_pid=""
  local listener_pid=""
  local listener_cmd=""

  mkdir -p "${state_dir}"

  if [[ -f "${pid_file}" ]]; then
    existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      if wait_for_local_port "${local_port}" 127.0.0.1 1; then
        echo "Reusing port-forward ${name}: http://127.0.0.1:${local_port}"
        return 0
      fi
      kill "${existing_pid}" >/dev/null 2>&1 || true
      sleep 1
    fi
    rm -f "${pid_file}"
  fi

  listener_pid="$(find_listener_pid "${local_port}" || true)"
  if [[ -n "${listener_pid}" ]]; then
    listener_cmd="$(ps -p "${listener_pid}" -o command= 2>/dev/null || true)"
    if [[ "${listener_cmd}" == *"kubectl"* && "${listener_cmd}" == *"port-forward"* && "${listener_cmd}" == *"service/${service}"* && "${listener_cmd}" == *"${local_port}:${remote_port}"* ]]; then
      echo "${listener_pid}" > "${pid_file}"
      echo "Reusing port-forward ${name}: http://127.0.0.1:${local_port}"
      return 0
    fi

    echo "Error: local port ${local_port} is already in use by another process: ${listener_cmd}" >&2
    exit 1
  fi

  echo "Starting port-forward ${name}: http://127.0.0.1:${local_port} -> service/${service}:${remote_port}"
  start_detached_command \
    "${log_file}" \
    kubectl -n "${namespace}" port-forward "service/${service}" "${local_port}:${remote_port}" --address 127.0.0.1 \
    > "${pid_file}"

  if wait_for_local_port "${local_port}" 127.0.0.1 30; then
    return 0
  fi

  echo "Error: failed to establish port-forward ${name}. Log:" >&2
  cat "${log_file}" >&2
  exit 1
}

stop_port_forward() {
  local name="$1"
  local namespace="$2"
  local service="$3"
  local local_port="$4"
  local remote_port="$5"
  local state_dir="${TMPDIR:-/tmp}/flowboard-port-forwards"
  local pid_file="${state_dir}/${name}.pid"
  local log_file="${state_dir}/${name}.log"
  local pid=""
  local listener_pid=""
  local listener_cmd=""

  if [[ -f "${pid_file}" ]]; then
    pid="$(cat "${pid_file}" 2>/dev/null || true)"
    terminate_pid "${pid}"
    rm -f "${pid_file}"
  fi

  listener_pid="$(find_listener_pid "${local_port}" || true)"
  if [[ -n "${listener_pid}" ]]; then
    listener_cmd="$(ps -p "${listener_pid}" -o command= 2>/dev/null || true)"
    if [[ "${listener_cmd}" == *"kubectl"* && "${listener_cmd}" == *"port-forward"* && "${listener_cmd}" == *"-n ${namespace}"* && "${listener_cmd}" == *"service/${service}"* && "${listener_cmd}" == *"${local_port}:${remote_port}"* ]]; then
      terminate_pid "${listener_pid}"
    fi
  fi

  rm -f "${log_file}"
}

stop_default_port_forwards() {
  stop_port_forward "frontend" "flowboard" "frontend" 18081 80
  stop_port_forward "backend" "flowboard" "backend" 18080 8080
  stop_port_forward "grafana" "monitoring" "grafana" 13000 80
  stop_port_forward "prometheus" "monitoring" "prometheus" 19090 9090
}
