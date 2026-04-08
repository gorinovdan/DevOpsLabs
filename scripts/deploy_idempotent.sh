#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${TF_DIR:-${ROOT_DIR}/infra/terraform}"
ANSIBLE_DIR="${ANSIBLE_DIR:-${ROOT_DIR}/infra/ansible}"
TF_AUTO_VARS_FILE="${TF_AUTO_VARS_FILE:-${TF_DIR}/terraform.auto.tfvars}"

REGISTRY_PREFIX="${REGISTRY_PREFIX:-ttl.sh/flowboard-lab-amd64}"
IMAGE_TAG="${IMAGE_TAG:-24h}"
BUILD_PLATFORM="${BUILD_PLATFORM:-}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

SSH_KEY_PATH="${SSH_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
SSH_KEY_COMMENT="${SSH_KEY_COMMENT:-flowboard-lab}"
SSH_USER="${SSH_USER:-ubuntu}"

DEPLOY_DIR="${DEPLOY_DIR:-/opt/flowboard}"
COMPOSE_FILE_NAME="${COMPOSE_FILE_NAME:-docker-compose.prod.yml}"
DB_USER="${DB_USER:-flowboard}"
DB_PASSWORD="${DB_PASSWORD:-flowboard}"
DB_NAME="${DB_NAME:-flowboard}"

SERVER_NAME="${SERVER_NAME:-flowboard-lab-vm}"
SERVER_COMMENT="${SERVER_COMMENT:-Created by deploy_idempotent.sh}"
CPU="${CPU:-2}"
RAM_MB="${RAM_MB:-2048}"
DISK_MB="${DISK_MB:-20480}"

STATUS_WAIT_ATTEMPTS="${STATUS_WAIT_ATTEMPTS:-60}"
STATUS_WAIT_DELAY_SEC="${STATUS_WAIT_DELAY_SEC:-10}"
SSH_WAIT_ATTEMPTS="${SSH_WAIT_ATTEMPTS:-60}"
SSH_WAIT_DELAY_SEC="${SSH_WAIT_DELAY_SEC:-5}"
TF_RETRY_ATTEMPTS="${TF_RETRY_ATTEMPTS:-5}"
TF_RETRY_DELAY_SEC="${TF_RETRY_DELAY_SEC:-5}"

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found: ${cmd}"
    exit 1
  fi
}

ensure_system_tools() {
  local apt_updated=0
  local sudo_cmd=""
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_cmd="sudo"
    else
      echo "Error: run as root or install sudo."
      exit 1
    fi
  fi

  if ! command -v ansible-playbook >/dev/null 2>&1; then
    log "Installing ansible..."
    if [[ "$apt_updated" -eq 0 ]]; then
      $sudo_cmd apt-get update
      apt_updated=1
    fi
    DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y ansible
  fi

  if ! command -v docker >/dev/null 2>&1; then
    log "Installing docker and compose plugin..."
    if [[ "$apt_updated" -eq 0 ]]; then
      $sudo_cmd apt-get update
      apt_updated=1
    fi
    DEBIAN_FRONTEND=noninteractive $sudo_cmd apt-get install -y docker.io docker-compose-v2
  fi

  $sudo_cmd systemctl enable --now docker >/dev/null 2>&1 || true
}

ensure_ssh_key() {
  local ssh_dir
  ssh_dir="$(dirname "${SSH_KEY_PATH}")"
  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"

  if [[ ! -f "${SSH_KEY_PATH}" || ! -f "${SSH_KEY_PATH}.pub" ]]; then
    log "Generating SSH key pair: ${SSH_KEY_PATH}"
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY_PATH}" -C "${SSH_KEY_COMMENT}" >/dev/null
  fi

  chmod 600 "${SSH_KEY_PATH}"
  chmod 644 "${SSH_KEY_PATH}.pub"
}

ensure_tfvars() {
  if [[ -f "${TF_AUTO_VARS_FILE}" ]]; then
    log "Using existing Terraform vars file: ${TF_AUTO_VARS_FILE}"
    return
  fi

  log "Creating Terraform vars file: ${TF_AUTO_VARS_FILE}"
  cat > "${TF_AUTO_VARS_FILE}" <<EOF
server_name = "${SERVER_NAME}"
cpu = ${CPU}
ram_mb = ${RAM_MB}
disk_mb = ${DISK_MB}
ssh_user = "${SSH_USER}"
ssh_public_key_path = "${SSH_KEY_PATH}.pub"
EOF
}

tf() {
  terraform -chdir="${TF_DIR}" "$@"
}

tf_state_rm_if_present() {
  local resource="$1"
  if tf state show "${resource}" >/dev/null 2>&1; then
    tf state rm "${resource}" >/dev/null
    log "Removed stale Terraform state resource: ${resource}"
  fi
}

repair_stale_state_if_needed() {
  local output_file="$1"

  if grep -q "error_code: server_not_found" "${output_file}" && grep -q "with twc_server.vm" "${output_file}"; then
    log "Detected stale state for twc_server.vm (resource is missing in cloud). Repairing local state and retrying."
    tf_state_rm_if_present "twc_server_ip.public_ipv4"
    tf_state_rm_if_present "twc_server.vm"
    return 0
  fi

  return 1
}

tf_with_retry() {
  local attempt=1
  local exit_code=0
  local output_file=""
  local repaired_stale_state=0

  while (( attempt <= TF_RETRY_ATTEMPTS )); do
    output_file="$(mktemp)"
    if tf "$@" 2>&1 | tee "${output_file}"; then
      exit_code=0
      rm -f "${output_file}"
      return 0
    else
      exit_code=${PIPESTATUS[0]}
    fi

    if (( repaired_stale_state == 0 )) && repair_stale_state_if_needed "${output_file}"; then
      repaired_stale_state=1
      rm -f "${output_file}"
      log "Retrying terraform command after local state repair: terraform $*"
      continue
    fi

    rm -f "${output_file}"
    if (( attempt == TF_RETRY_ATTEMPTS )); then
      echo "Error: terraform command failed after ${attempt} attempts: terraform $*"
      return "${exit_code}"
    fi

    log "Terraform command failed (attempt ${attempt}/${TF_RETRY_ATTEMPTS}), retrying in ${TF_RETRY_DELAY_SEC}s: terraform $*"
    sleep "${TF_RETRY_DELAY_SEC}"
    attempt=$((attempt + 1))
  done
}

wait_for_vm_ready() {
  local status ip attempt
  status=""
  ip=""
  for attempt in $(seq 1 "${STATUS_WAIT_ATTEMPTS}"); do
    if ! tf_with_retry apply -refresh-only -auto-approve -input=false >/dev/null; then
      log "Failed to refresh VM state; continuing readiness checks."
      sleep "${STATUS_WAIT_DELAY_SEC}"
      continue
    fi
    status="$(tf output -raw server_status 2>/dev/null || true)"
    ip="$(tf output -raw server_main_ipv4 2>/dev/null || true)"

    if [[ "${status}" == "on" && -n "${ip}" ]]; then
      echo "${ip}"
      return 0
    fi

    log "VM not ready yet (attempt ${attempt}/${STATUS_WAIT_ATTEMPTS}): status=${status:-unknown}, ip=${ip:-none}"
    sleep "${STATUS_WAIT_DELAY_SEC}"
  done

  echo "Error: VM did not become ready in time."
  exit 1
}

wait_for_ssh() {
  local ip="$1"
  local attempt
  for attempt in $(seq 1 "${SSH_WAIT_ATTEMPTS}"); do
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "${SSH_KEY_PATH}" "${SSH_USER}@${ip}" "echo ok" >/dev/null 2>&1; then
      return 0
    fi
    log "SSH is not ready yet (attempt ${attempt}/${SSH_WAIT_ATTEMPTS})"
    sleep "${SSH_WAIT_DELAY_SEC}"
  done
  echo "Error: SSH on ${ip} is not reachable."
  exit 1
}

build_and_push_images() {
  local build_log backend_image frontend_image
  build_log="$(mktemp)"

  if [[ -n "${BUILD_PLATFORM}" ]]; then
    FORCE_REBUILD="${FORCE_REBUILD}" "${ROOT_DIR}/scripts/build_and_push.sh" "${REGISTRY_PREFIX}" "${IMAGE_TAG}" "${BUILD_PLATFORM}" | tee "${build_log}" >&2
  else
    FORCE_REBUILD="${FORCE_REBUILD}" "${ROOT_DIR}/scripts/build_and_push.sh" "${REGISTRY_PREFIX}" "${IMAGE_TAG}" | tee "${build_log}" >&2
  fi

  backend_image="$(awk '/backend_image:/ {print $2}' "${build_log}" | tail -n 1)"
  frontend_image="$(awk '/frontend_image:/ {print $2}' "${build_log}" | tail -n 1)"
  rm -f "${build_log}"

  if [[ -z "${backend_image}" || -z "${frontend_image}" ]]; then
    echo "Error: failed to parse published image names."
    exit 1
  fi

  printf '%s\n%s\n' "${backend_image}" "${frontend_image}"
}

run_ansible_install_docker() {
  local vm_ip="$1"
  local inventory_file
  inventory_file="$(mktemp)"

  cat > "${inventory_file}" <<EOF
[app]
${vm_ip} ansible_user=${SSH_USER} ansible_ssh_private_key_file=${SSH_KEY_PATH}
EOF

  ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg" ansible-playbook -i "${inventory_file}" "${ANSIBLE_DIR}/playbooks/install_docker.yml"
  rm -f "${inventory_file}"
}

run_ansible_deploy_stack() {
  local vm_ip="$1"
  local backend_image="$2"
  local frontend_image="$3"
  local inventory_file
  inventory_file="$(mktemp)"

  cat > "${inventory_file}" <<EOF
[app]
${vm_ip} ansible_user=${SSH_USER} ansible_ssh_private_key_file=${SSH_KEY_PATH}
EOF

  ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg" ansible-playbook -i "${inventory_file}" "${ANSIBLE_DIR}/playbooks/deploy_flowboard.yml" \
    -e "deploy_dir=${DEPLOY_DIR} compose_file_name=${COMPOSE_FILE_NAME} backend_image=${backend_image} frontend_image=${frontend_image} db_user=${DB_USER} db_password=${DB_PASSWORD} db_name=${DB_NAME} registry_url=${REGISTRY_URL:-} registry_username=${REGISTRY_USERNAME:-} registry_password=${REGISTRY_PASSWORD:-}"

  rm -f "${inventory_file}"
}

is_stack_current() {
  local vm_ip="$1"
  local backend_image="$2"
  local frontend_image="$3"
  local ssh_base
  local current_backend current_frontend backend_running frontend_running postgres_running

  ssh_base=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "${SSH_KEY_PATH}" "root@${vm_ip}")

  current_backend="$("${ssh_base[@]}" "docker inspect -f '{{.Config.Image}}' flowboard-backend-1 2>/dev/null || true")"
  current_frontend="$("${ssh_base[@]}" "docker inspect -f '{{.Config.Image}}' flowboard-frontend-1 2>/dev/null || true")"
  backend_running="$("${ssh_base[@]}" "docker inspect -f '{{.State.Running}}' flowboard-backend-1 2>/dev/null || true")"
  frontend_running="$("${ssh_base[@]}" "docker inspect -f '{{.State.Running}}' flowboard-frontend-1 2>/dev/null || true")"
  postgres_running="$("${ssh_base[@]}" "docker inspect -f '{{.State.Running}}' flowboard-postgres-1 2>/dev/null || true")"

  if [[ "${current_backend}" == "${backend_image}" \
        && "${current_frontend}" == "${frontend_image}" \
        && "${backend_running}" == "true" \
        && "${frontend_running}" == "true" \
        && "${postgres_running}" == "true" ]]; then
    return 0
  fi

  return 1
}

smoke_test() {
  local vm_ip="$1"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "${SSH_KEY_PATH}" "${SSH_USER}@${vm_ip}" '
    set -euo pipefail
    frontend_url="$(minikube service frontend -n flowboard --url | head -n 1)"
    curl -fsS -m 20 "${frontend_url}/api/insights" >/dev/null
    curl -fsS -m 20 "${frontend_url}/api/tasks" >/dev/null
  '
}

main() {
  log "Ensuring required tools..."
  ensure_system_tools
  require_cmd terraform
  require_cmd ansible-playbook
  require_cmd docker
  require_cmd ssh
  require_cmd curl
  require_cmd awk

  ensure_ssh_key
  ensure_tfvars

  log "Running Terraform (init/validate/apply)..."
  tf_with_retry init -input=false
  tf_with_retry validate
  tf_with_retry apply -input=false -auto-approve

  log "Waiting for VM status=on and IPv4..."
  VM_IP="$(wait_for_vm_ready)"
  log "VM is ready: ${VM_IP}"

  log "Waiting for SSH on VM..."
  wait_for_ssh "${VM_IP}"

  log "Building and pushing images..."
  images_output="$(build_and_push_images)"
  BACKEND_IMAGE="$(printf '%s\n' "${images_output}" | sed -n '1p')"
  FRONTEND_IMAGE="$(printf '%s\n' "${images_output}" | sed -n '2p')"
  if [[ -z "${BACKEND_IMAGE}" || -z "${FRONTEND_IMAGE}" ]]; then
    echo "Error: failed to parse built image names."
    exit 1
  fi

  log "Running Ansible Docker installation playbook..."
  run_ansible_install_docker "${VM_IP}"

  log "Deploying application stack with Ansible..."
  run_ansible_deploy_stack "${VM_IP}" "${BACKEND_IMAGE}" "${FRONTEND_IMAGE}"

  log "Running smoke tests..."
  smoke_test "${VM_IP}"

  log "Deployment completed successfully."
  echo ""
  echo "VM IP: ${VM_IP}"
  echo "Frontend/Backend are served inside minikube on VM."
  echo "Use SSH and run: minikube service frontend -n flowboard --url"
  echo "Backend image: ${BACKEND_IMAGE}"
  echo "Frontend image: ${FRONTEND_IMAGE}"
}

main "$@"


