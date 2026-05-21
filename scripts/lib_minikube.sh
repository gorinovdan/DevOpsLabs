#!/usr/bin/env bash

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}" >&2
    exit 1
  fi
}

# Run a kubectl command with retry on transient apiserver errors.
# minikube's docker-driver apiserver intermittently flaps for tens of
# seconds at a time (EOF on openapi/v2, "connection refused" on the
# loopback API endpoint, etc). Bare kubectl invocations then fail the
# whole CI step. Use this helper for any kubectl invocation whose
# target object may be created/updated/queried mid-flap.
#
# Usage: kubectl_retry <attempts> -- kubectl <args...>
kubectl_retry() {
  local attempts="${1}"; shift
  if [[ "${1:-}" == "--" ]]; then shift; fi
  local attempt
  for attempt in $(seq 1 "${attempts}"); do
    if "$@"; then
      return 0
    fi
    if [[ "${attempt}" -eq "${attempts}" ]]; then
      return 1
    fi
    echo "kubectl_retry: attempt ${attempt}/${attempts} failed (likely apiserver hiccup), sleeping 10s..." >&2
    sleep 10
  done
}

# Block until the apiserver is responsive, with a generous deadline.
# We've observed apiserver flaps lasting 60-90s on the docker-driver
# minikube under load; without an explicit gate, downstream kubectl
# commands (kubectl apply, rollout status, etc) fail one by one and
# burn the job's allotted retries individually.
wait_for_apiserver() {
  local timeout_seconds="${1:-300}"
  local deadline=$(( $(date +%s) + timeout_seconds ))
  local first=1
  while [[ $(date +%s) -lt ${deadline} ]]; do
    if kubectl --request-timeout=5s get --raw='/readyz' >/dev/null 2>&1; then
      [[ "${first}" == "0" ]] && echo "apiserver responsive again."
      return 0
    fi
    if [[ "${first}" == "1" ]]; then
      echo "Waiting for apiserver to become responsive..."
      first=0
    fi
    sleep 3
  done
  echo "Error: apiserver did not become responsive within ${timeout_seconds}s." >&2
  return 1
}

proxy_targets_loopback() {
  local proxy_value="$1"
  local proxy_host=""

  proxy_host="${proxy_value#*://}"
  proxy_host="${proxy_host%%/*}"

  if [[ "${proxy_host}" == *"@"* ]]; then
    proxy_host="${proxy_host##*@}"
  fi

  case "${proxy_host%%:*}" in
    localhost|127.*|::1|'[::1]')
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

append_no_proxy_entry() {
  local current_value="$1"
  local entry="$2"

  if [[ -z "${current_value}" ]]; then
    printf '%s\n' "${entry}"
    return 0
  fi

  case ",${current_value}," in
    *,"${entry}",*)
      printf '%s\n' "${current_value}"
      ;;
    *)
      printf '%s,%s\n' "${current_value}" "${entry}"
      ;;
  esac
}

build_minikube_no_proxy() {
  local no_proxy_value="${NO_PROXY:-${no_proxy:-}}"
  local entry=""

  for entry in localhost 127.0.0.1 ::1 192.168.49.1 192.168.49.2 host.docker.internal kubernetes.default.svc .svc .svc.cluster.local; do
    no_proxy_value="$(append_no_proxy_entry "${no_proxy_value}" "${entry}")"
  done

  printf '%s\n' "${no_proxy_value}"
}

run_minikube() {
  local no_proxy_value=""
  local var=""
  local value=""
  local stripped_loopback_proxy="0"
  local -a env_cmd=(env)
  local -a env_assignments=()
  local -a proxy_vars=(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy)

  no_proxy_value="$(build_minikube_no_proxy)"
  env_assignments+=("NO_PROXY=${no_proxy_value}" "no_proxy=${no_proxy_value}")

  for var in "${proxy_vars[@]}"; do
    value="${!var-}"
    if [[ -n "${value}" ]] && proxy_targets_loopback "${value}"; then
      env_cmd+=("-u" "${var}")
      stripped_loopback_proxy="1"
    fi
  done

  if [[ "${stripped_loopback_proxy}" == "1" ]]; then
    echo "Ignoring loopback proxy environment for minikube command." >&2
  fi

  "${env_cmd[@]}" "${env_assignments[@]}" minikube "$@"
}

reset_minikube_profile() {
  echo "Resetting minikube profile before retry..." >&2
  run_minikube delete >/dev/null 2>&1 || true
}

minikube_status_text() {
  run_minikube status 2>&1 || true
}

minikube_profile_is_stale() {
  local status_text="$1"

  if printf '%s\n' "${status_text}" | grep -q "No such container: minikube"; then
    return 1
  fi

  if printf '%s\n' "${status_text}" | grep -q "host: Running" \
      && printf '%s\n' "${status_text}" | grep -Eq "kubelet: Stopped|apiserver: Stopped"; then
    return 0
  fi

  return 1
}

start_minikube_profile() {
  local driver="${1:-docker}"
  local cpus="${2:-4}"
  local memory="${3:-6144}"
  local wait_timeout="${MINIKUBE_WAIT_TIMEOUT:-6m0s}"
  local kubernetes_version="${MINIKUBE_KUBERNETES_VERSION:-v1.31.6}"

  preload_minikube_bootstrap_assets "${kubernetes_version}"

  run_minikube start \
    --driver="${driver}" \
    --cpus="${cpus}" \
    --memory="${memory}" \
    --kubernetes-version="${kubernetes_version}" \
    --delete-on-failure=true \
    --wait=apiserver,kubelet,system_pods \
    --wait-timeout="${wait_timeout}"
}

minikube_profile_kubernetes_version() {
  local profile="${MINIKUBE_PROFILE:-minikube}"

  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  run_minikube profile list -o json 2>/dev/null \
    | jq -r --arg profile "${profile}" \
      '.valid[]? | select(.Name == $profile) | (.Config.KubernetesConfig.KubernetesVersion // .Config.Nodes[0].KubernetesVersion // "")' \
    | head -n 1
}

minikube_profile_version_mismatch() {
  local desired_version="${1}"
  local current_version=""

  if [[ -z "${desired_version}" ]]; then
    return 1
  fi

  current_version="$(minikube_profile_kubernetes_version || true)"
  [[ -n "${current_version}" && "${current_version}" != "${desired_version}" ]]
}

minikube_core_images() {
  local kubernetes_version="${1}"

  case "${kubernetes_version}" in
    v1.31.6)
      printf '%s\n' \
        "registry.k8s.io/kube-apiserver:${kubernetes_version}" \
        "registry.k8s.io/kube-controller-manager:${kubernetes_version}" \
        "registry.k8s.io/kube-scheduler:${kubernetes_version}" \
        "registry.k8s.io/kube-proxy:${kubernetes_version}" \
        "registry.k8s.io/etcd:3.5.15-0" \
        "registry.k8s.io/coredns/coredns:v1.11.3" \
        "registry.k8s.io/pause:3.10" \
        "gcr.io/k8s-minikube/storage-provisioner:v5"
      ;;
  esac
}

minikube_image_cache_path() {
  local image="${1}"
  local arch
  local cache_name

  arch="$(detect_host_arch)"
  cache_name="${image//@sha256:/@sha256_}"
  cache_name="${cache_name//:/_}"

  printf '%s/.minikube/cache/images/%s/%s\n' "${HOME}" "${arch}" "${cache_name}"
}

ensure_minikube_binary_cached() {
  local kubernetes_version="${1}"
  local binary_name="${2}"
  local arch
  local cache_dir
  local target
  local tmp
  local expected
  local actual
  local base_url

  require_cmd curl
  require_cmd shasum

  arch="$(detect_host_arch)"
  cache_dir="${HOME}/.minikube/cache/linux/${arch}/${kubernetes_version}"
  target="${cache_dir}/${binary_name}"

  if [[ -x "${target}" ]]; then
    return 0
  fi

  mkdir -p "${cache_dir}"
  tmp="${target}.download"
  base_url="https://dl.k8s.io/release/${kubernetes_version}/bin/linux/${arch}/${binary_name}"

  echo "Caching Kubernetes binary for minikube: ${binary_name} ${kubernetes_version}"
  curl -fsSL --retry 5 --retry-delay 5 -o "${tmp}" "${base_url}"
  expected="$(curl -fsSL --retry 5 --retry-delay 5 "${base_url}.sha256" | tr -d '[:space:]')"
  actual="$(shasum -a 256 "${tmp}" | awk '{print $1}')"
  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${tmp}"
    echo "Error: checksum mismatch for ${binary_name} ${kubernetes_version}." >&2
    return 1
  fi

  chmod +x "${tmp}"
  mv "${tmp}" "${target}"
}

ensure_minikube_image_cached() {
  local image="${1}"
  local cache_path

  require_cmd docker

  cache_path="$(minikube_image_cache_path "${image}")"
  if [[ -s "${cache_path}" ]]; then
    return 0
  fi

  ensure_host_image "${image}"
  mkdir -p "$(dirname "${cache_path}")"
  echo "Caching bootstrap image for minikube: ${image}"
  docker save -o "${cache_path}" "${image}"
}

preload_minikube_bootstrap_assets() {
  local kubernetes_version="${1}"
  local binary_name
  local image

  if [[ "${MINIKUBE_PRELOAD_BOOTSTRAP_ASSETS:-1}" != "1" ]]; then
    return 0
  fi

  for binary_name in kubeadm kubelet kubectl; do
    ensure_minikube_binary_cached "${kubernetes_version}" "${binary_name}"
  done

  while IFS= read -r image; do
    [[ -z "${image}" ]] && continue
    ensure_minikube_image_cached "${image}"
  done < <(minikube_core_images "${kubernetes_version}")
}

compute_file_hash() {
  local file_path="$1"

  shasum -a 256 "${file_path}" | awk '{print $1}'
}

ensure_frontend_dependencies() {
  local frontend_dir="$1"
  local lock_file="${frontend_dir}/package-lock.json"
  local modules_dir="${frontend_dir}/node_modules"
  local stamp_file="${modules_dir}/.package-lock.sha256"
  local current_hash=""
  local cached_hash=""

  require_cmd npm

  if [[ ! -f "${lock_file}" ]]; then
    echo "Error: frontend lock file not found: ${lock_file}" >&2
    exit 1
  fi

  current_hash="$(compute_file_hash "${lock_file}")"
  if [[ -f "${stamp_file}" ]]; then
    cached_hash="$(cat "${stamp_file}")"
  fi

  if [[ -d "${modules_dir}" && "${current_hash}" == "${cached_hash}" ]]; then
    echo "Reusing cached frontend dependencies."
    return 0
  fi

  echo "Installing frontend dependencies..."
  (
    cd "${frontend_dir}"
    npm ci --prefer-offline
  )

  mkdir -p "${modules_dir}"
  printf '%s\n' "${current_hash}" > "${stamp_file}"
}

build_backend_runtime_image_with_host_tools() {
  local project_root="$1"
  local target_image="$2"
  local backend_context
  local target_arch

  require_cmd go
  require_cmd docker

  if docker image inspect "${target_image}" >/dev/null 2>&1; then
    echo "Using cached backend image: ${target_image}"
    return 0
  fi

  backend_context="$(mktemp -d)"
  trap 'rm -rf "${backend_context}"' RETURN
  target_arch="$(go env GOARCH)"

  echo "Building backend binary on host..."
  (
    cd "${project_root}/backend"
    CGO_ENABLED=0 GOOS=linux GOARCH="${target_arch}" go build -trimpath -ldflags="-s -w" -o "${backend_context}/server" ./cmd/server
  )

  cat > "${backend_context}/Dockerfile" <<'EOF'
FROM scratch
COPY server /server
ENV PORT=8080
EXPOSE 8080
USER 10001:10001
ENTRYPOINT ["/server"]
EOF

  echo "Packaging backend runtime image: ${target_image}"
  docker build -t "${target_image}" "${backend_context}" >/dev/null

  trap - RETURN
  rm -rf "${backend_context}"
}

build_frontend_runtime_image_with_host_tools() {
  local project_root="$1"
  local target_image="$2"
  local nginx_image="${3:-nginx:1.25-alpine}"
  local frontend_context

  require_cmd docker
  ensure_frontend_dependencies "${project_root}/frontend"

  if docker image inspect "${target_image}" >/dev/null 2>&1; then
    echo "Using cached frontend image: ${target_image}"
    return 0
  fi

  ensure_host_image "${nginx_image}"

  echo "Building frontend assets on host..."
  (
    cd "${project_root}/frontend"
    npm run build >/dev/null
  )

  frontend_context="$(mktemp -d)"
  trap 'rm -rf "${frontend_context}"' RETURN

  cp "${project_root}/frontend/nginx.conf" "${frontend_context}/nginx.conf"
  cp -R "${project_root}/frontend/dist" "${frontend_context}/dist"

  cat > "${frontend_context}/Dockerfile" <<EOF
FROM ${nginx_image}
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
EOF

  echo "Packaging frontend runtime image: ${target_image}"
  docker build -t "${target_image}" "${frontend_context}" >/dev/null

  trap - RETURN
  rm -rf "${frontend_context}"
}

ensure_minikube_running() {
  local auto_start="${1:-0}"
  local driver="${2:-docker}"
  local cpus="${3:-4}"
  local memory="${4:-6144}"
  local status_text=""
  local kubernetes_version="${MINIKUBE_KUBERNETES_VERSION:-v1.31.6}"

  status_text="$(minikube_status_text)"

  if [[ "${auto_start}" == "1" ]] && minikube_profile_version_mismatch "${kubernetes_version}"; then
    echo "Existing minikube profile uses Kubernetes $(minikube_profile_kubernetes_version); expected ${kubernetes_version}; resetting it before start." >&2
    reset_minikube_profile
    status_text="$(minikube_status_text)"
  fi

  if run_minikube status >/dev/null 2>&1; then
    configure_minikube_docker_proxy || true
    # `minikube status` returns ok as soon as the docker container is
    # alive, but kubelet / apiserver may still be booting. Block until
    # the apiserver is actually serving readyz so downstream kubectl
    # calls don't crash on a 60s flap.
    if wait_for_apiserver 180; then
      return 0
    fi
    if [[ "${auto_start}" == "1" ]]; then
      echo "Existing minikube profile is not responsive; resetting it before retry." >&2
      reset_minikube_profile
    else
      return 1
    fi
  elif [[ "${auto_start}" == "1" ]] && minikube_profile_is_stale "${status_text}"; then
    echo "Detected stale minikube profile with stopped kubelet/apiserver; resetting it before start." >&2
    reset_minikube_profile
  elif [[ "${auto_start}" != "1" ]]; then
    echo "Error: minikube is not running. Start it first or set AUTO_START_MINIKUBE=1." >&2
    exit 1
  fi

  if run_minikube status >/dev/null 2>&1; then
    return 0
  fi

  echo "Starting minikube with driver=${driver}, cpus=${cpus}, memory=${memory}..."
  if start_minikube_profile "${driver}" "${cpus}" "${memory}"; then
    configure_minikube_docker_proxy || true
    wait_for_apiserver 300
    return 0
  fi

  reset_minikube_profile
  echo "Retrying minikube start with a clean profile..." >&2
  start_minikube_profile "${driver}" "${cpus}" "${memory}"
  configure_minikube_docker_proxy || true
  wait_for_apiserver 300
}

# When the host is sitting behind an HTTP/SOCKS proxy on 127.0.0.1
# (e.g. Clash / V2Ray / corp tunnel), kubelet/dockerd inside the
# minikube node cannot reach quay.io / ghcr.io / docker.io through
# Docker Desktop's internal DNS. We translate the host loopback proxy
# to host.docker.internal:<port> and apply it as a systemd drop-in for
# dockerd + cri-docker so in-cluster image pulls work.
configure_minikube_docker_proxy() {
  local raw_proxy="${HTTP_PROXY:-${HTTPS_PROXY:-${http_proxy:-${https_proxy:-}}}}"
  if [[ -z "${raw_proxy}" ]]; then
    return 0
  fi

  local proxy_url=""
  if [[ "${raw_proxy}" == http://* || "${raw_proxy}" == https://* ]]; then
    proxy_url="${raw_proxy}"
  else
    return 0
  fi

  local rewritten=""
  rewritten="${proxy_url//127.0.0.1/host.docker.internal}"
  rewritten="${rewritten//localhost/host.docker.internal}"

  if ! command -v minikube >/dev/null 2>&1; then
    return 0
  fi

  local marker="# managed-by: lib_minikube.sh"
  local desired_block
  desired_block="$(cat <<EOF
${marker}
[Service]
Environment="HTTP_PROXY=${rewritten}"
Environment="HTTPS_PROXY=${rewritten}"
Environment="NO_PROXY=localhost,127.0.0.1,::1,192.168.49.0/24,host.docker.internal,kubernetes.default.svc,.svc,.svc.cluster.local,10.0.0.0/8,172.16.0.0/12"
EOF
)"

  local current
  current="$(run_minikube ssh -- "sudo cat /etc/systemd/system/docker.service.d/http-proxy.conf 2>/dev/null" 2>/dev/null || true)"
  if [[ "${current}" == "${desired_block}"* ]]; then
    return 0
  fi

  echo "Configuring minikube dockerd to use host proxy ${rewritten}..."
  local b64
  b64="$(printf '%s' "${desired_block}" | base64)"

  run_minikube ssh -- "sudo mkdir -p /etc/systemd/system/docker.service.d && \
    echo '${b64}' | base64 --decode | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null && \
    sudo systemctl daemon-reload && \
    sudo systemctl restart docker && \
    sudo systemctl restart cri-docker.service" >/dev/null
}

ensure_host_image() {
  local image="$1"
  local attempts="${IMAGE_PULL_ATTEMPTS:-5}"
  local delay="${IMAGE_PULL_DELAY:-10}"

  require_cmd docker

  if docker image inspect "${image}" >/dev/null 2>&1; then
    return 0
  fi

  local i
  for i in $(seq 1 "${attempts}"); do
    echo "Pulling image on host (attempt ${i}/${attempts}): ${image}"
    if docker pull "${image}"; then
      return 0
    fi
    if (( i < attempts )); then
      echo "Pull failed, sleeping ${delay}s before retry..." >&2
      sleep "${delay}"
    fi
  done

  echo "Error: failed to pull ${image} after ${attempts} attempts." >&2
  return 1
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
    eval "$(run_minikube -p minikube docker-env --shell bash)"
    docker image inspect "${image}" >/dev/null 2>&1
  )
}

pull_image_directly_in_minikube() {
  local image="$1"

  echo "Pulling image directly in minikube: ${image}"
  (
    eval "$(run_minikube -p minikube docker-env --shell bash)"
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

  # `minikube image load` streams the image over the minikube SSH tunnel
  # using the daemon's optimized blob upload path. The previous
  # `docker save | docker load` pipe through Docker Desktop's TCP socket
  # bottlenecked at ~5MB/s and stalled out on >500MB images
  # (sonarqube:26.4 is ~1GB compressed). Try the native loader first.
  if docker image inspect "${image}" >/dev/null 2>&1; then
    echo "Loading image into minikube via 'minikube image load': ${image}"
    if minikube -p minikube image load "${image}"; then
      return 0
    fi
    echo "Warning: 'minikube image load' failed, falling back to docker save|load."
    docker save "${image}" | (
      eval "$(run_minikube -p minikube docker-env --shell bash)"
      docker load >/dev/null
    )
    return 0
  fi

  if pull_image_directly_in_minikube "${image}"; then
    return 0
  fi

  ensure_host_image "${image}"

  echo "Loading image into minikube via 'minikube image load': ${image}"
  if minikube -p minikube image load "${image}"; then
    return 0
  fi
  echo "Warning: 'minikube image load' failed, falling back to docker save|load."
  docker save "${image}" | (
    eval "$(run_minikube -p minikube docker-env --shell bash)"
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
    -e "s#__PROMETHEUS_CONFIG_HASH__#${PROMETHEUS_CONFIG_HASH:-}#g" \
    -e "s#__GRAFANA_CONFIG_HASH__#${GRAFANA_CONFIG_HASH:-}#g" \
    "${source_file}" > "${target_file}"
}

apply_template_manifest() {
  local template_path="$1"
  local rendered_path

  rendered_path="$(mktemp)"
  trap 'rm -f "${rendered_path}"' RETURN
  render_template_file "${template_path}" "${rendered_path}"
  kubectl_apply_if_changed "${rendered_path}" "${template_path}"
  trap - RETURN
  rm -f "${rendered_path}"
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

wait_for_http_endpoint() {
  local url="$1"
  local attempts="${2:-30}"

  require_cmd curl

  # 2s curl timeout (down from 5s) keeps the polling loop tight: when the
  # endpoint is briefly unreachable (port-forward reconnecting, pod
  # restarting, etc.) we want to retry sooner rather than burn 5s+1s per
  # iteration. With the typical "wait until Ready" use case, the endpoint
  # responds in <100ms once it's actually up.
  for _ in $(seq 1 "${attempts}"); do
    if curl -fsS --max-time 2 "${url}" >/dev/null 2>&1; then
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
import os
import subprocess
import sys

log_file = sys.argv[1]
command = sys.argv[2:]
child_env = {
    key: value
    for key, value in os.environ.items()
    if key != "RUNNER_TRACKING_ID"
}

with open(log_file, "ab", buffering=0) as log_handle:
    process = subprocess.Popen(
        command,
        env=child_env,
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
  local health_path="${6:-}"
  local state_dir="${TMPDIR:-/tmp}/flowboard-port-forwards"
  local pid_file="${state_dir}/${name}.pid"
  local log_file="${state_dir}/${name}.log"
  local existing_pid=""
  local listener_pid=""
  local listener_cmd=""
  local health_url=""
  local start_attempt=""
  local start_attempts="${PORT_FORWARD_START_ATTEMPTS:-3}"
  local started_pid=""

  mkdir -p "${state_dir}"
  if [[ -n "${health_path}" ]]; then
    health_url="http://127.0.0.1:${local_port}${health_path}"
  fi

  if [[ -f "${pid_file}" ]]; then
    existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      if wait_for_local_port "${local_port}" 127.0.0.1 1; then
        if [[ -z "${health_url}" ]] || wait_for_http_endpoint "${health_url}" 2; then
          echo "Reusing port-forward ${name}: http://127.0.0.1:${local_port}"
          return 0
        fi
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
      if [[ -z "${health_url}" ]] || wait_for_http_endpoint "${health_url}" 2; then
        echo "${listener_pid}" > "${pid_file}"
        echo "Reusing port-forward ${name}: http://127.0.0.1:${local_port}"
        return 0
      fi

      terminate_pid "${listener_pid}"
      sleep 1
    fi

    echo "Error: local port ${local_port} is already in use by another process: ${listener_cmd}" >&2
    return 1
  fi

  for start_attempt in $(seq 1 "${start_attempts}"); do
    echo "Starting port-forward ${name} (attempt ${start_attempt}/${start_attempts}): http://127.0.0.1:${local_port} -> service/${service}:${remote_port}"
    : > "${log_file}"
    start_detached_command \
      "${log_file}" \
      kubectl -n "${namespace}" port-forward "service/${service}" "${local_port}:${remote_port}" --address 127.0.0.1 \
      > "${pid_file}"

    if wait_for_local_port "${local_port}" 127.0.0.1 30; then
      if [[ -z "${health_url}" ]] || wait_for_http_endpoint "${health_url}" 30; then
        return 0
      fi

      echo "Warning: port-forward ${name} listener is up but health probe ${health_url} did not respond yet. Continuing." >&2
      return 0
    fi

    started_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    terminate_pid "${started_pid}"
    rm -f "${pid_file}"
    echo "Warning: port-forward ${name} did not open local port ${local_port}." >&2
    if [[ -s "${log_file}" ]]; then
      echo "Recent ${name} port-forward log:" >&2
      tail -n 20 "${log_file}" >&2 || true
    fi
    sleep 2
  done

  echo "Error: port-forward ${name} did not open local port ${local_port} after ${start_attempts} attempts." >&2
  return 1
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
  stop_port_forward "argocd" "argocd" "argocd-server" 18083 80
  stop_port_forward "sonarqube" "sonarqube" "sonarqube" 19000 9000
  stop_kubectl_proxy 18001
}

# Detached `kubectl proxy` for the Kubernetes Dashboard. Survives the parent
# shell so URLs stay reachable after the GitHub Actions job exits.
ensure_kubectl_proxy() {
  local local_port="${1:-18001}"
  local health_path="${2:-/api/v1/namespaces/kubernetes-dashboard/services/http:kubernetes-dashboard:/proxy/}"
  local state_dir="${TMPDIR:-/tmp}/flowboard-port-forwards"
  local pid_file="${state_dir}/kubectl-proxy-${local_port}.pid"
  local log_file="${state_dir}/kubectl-proxy-${local_port}.log"
  local existing_pid=""
  local listener_pid=""
  local listener_cmd=""
  local health_url="http://127.0.0.1:${local_port}${health_path}"

  mkdir -p "${state_dir}"

  if [[ -f "${pid_file}" ]]; then
    existing_pid="$(cat "${pid_file}" 2>/dev/null || true)"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      if wait_for_local_port "${local_port}" 127.0.0.1 1 \
        && wait_for_http_endpoint "${health_url}" 2; then
        echo "Reusing kubectl proxy on :${local_port}"
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
    if [[ "${listener_cmd}" == *"kubectl"* && "${listener_cmd}" == *"proxy"* && "${listener_cmd}" == *"--port=${local_port}"* ]]; then
      if wait_for_http_endpoint "${health_url}" 2; then
        echo "${listener_pid}" > "${pid_file}"
        echo "Reusing kubectl proxy on :${local_port}"
        return 0
      fi
      terminate_pid "${listener_pid}"
      sleep 1
    else
      echo "Error: local port ${local_port} is already in use by another process: ${listener_cmd}" >&2
      return 1
    fi
  fi

  echo "Starting kubectl proxy on :${local_port}"
  start_detached_command \
    "${log_file}" \
    kubectl proxy "--port=${local_port}" --address=127.0.0.1 \
    > "${pid_file}"

  if wait_for_local_port "${local_port}" 127.0.0.1 30 \
    && wait_for_http_endpoint "${health_url}" 90; then
    return 0
  fi

  echo "Warning: kubectl proxy on :${local_port} listener is up but health probe ${health_url} did not respond yet. Continuing." >&2
  return 0
}

stop_kubectl_proxy() {
  local local_port="${1:-18001}"
  local state_dir="${TMPDIR:-/tmp}/flowboard-port-forwards"
  local pid_file="${state_dir}/kubectl-proxy-${local_port}.pid"
  local log_file="${state_dir}/kubectl-proxy-${local_port}.log"
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
    if [[ "${listener_cmd}" == *"kubectl"* && "${listener_cmd}" == *"proxy"* && "${listener_cmd}" == *"--port=${local_port}"* ]]; then
      terminate_pid "${listener_pid}"
    fi
  fi

  rm -f "${log_file}"
}
