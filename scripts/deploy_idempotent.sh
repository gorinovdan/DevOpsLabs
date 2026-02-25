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

DEPLOY_DIR="${DEPLOY_DIR:-/opt/flowboard}"
COMPOSE_FILE_NAME="${COMPOSE_FILE_NAME:-docker-compose.prod.yml}"
DB_USER="${DB_USER:-flowboard}"
DB_PASSWORD="${DB_PASSWORD:-flowboard}"
DB_NAME="${DB_NAME:-flowboard}"

SERVER_NAME="${SERVER_NAME:-flowboard-lab-vm}"
SERVER_COMMENT="${SERVER_COMMENT:-Created by deploy_idempotent.sh}"
LOCATION="${LOCATION:-ru-1}"
OS_NAME="${OS_NAME:-ubuntu}"
OS_VERSION="${OS_VERSION:-22.04}"
CPU="${CPU:-1}"
RAM_MB="${RAM_MB:-1024}"
DISK_MB="${DISK_MB:-15360}"
PROJECT_ID="${PROJECT_ID:-}"
SSH_KEY_NAME="${SSH_KEY_NAME:-flowboard-lab-key}"

STATUS_WAIT_ATTEMPTS="${STATUS_WAIT_ATTEMPTS:-60}"
STATUS_WAIT_DELAY_SEC="${STATUS_WAIT_DELAY_SEC:-10}"
SSH_WAIT_ATTEMPTS="${SSH_WAIT_ATTEMPTS:-60}"
SSH_WAIT_DELAY_SEC="${SSH_WAIT_DELAY_SEC:-5}"

if [[ -z "${TWC_TOKEN:-}" ]]; then
  echo "Error: TWC_TOKEN is required."
  echo "Example: TWC_TOKEN='<token>' ${0}"
  exit 1
fi

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
server_comment = "${SERVER_COMMENT}"
location = "${LOCATION}"
os_name = "${OS_NAME}"
os_version = "${OS_VERSION}"
cpu = ${CPU}
ram_mb = ${RAM_MB}
disk_mb = ${DISK_MB}
project_id = "${PROJECT_ID}"
ssh_key_name = "${SSH_KEY_NAME}"
ssh_public_key_path = "${SSH_KEY_PATH}.pub"
EOF
}

tf() {
  TWC_TOKEN="${TWC_TOKEN}" terraform -chdir="${TF_DIR}" "$@"
}

wait_for_vm_ready() {
  local status ip attempt
  status=""
  ip=""
  for attempt in $(seq 1 "${STATUS_WAIT_ATTEMPTS}"); do
    tf apply -refresh-only -auto-approve -input=false >/dev/null
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
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "${SSH_KEY_PATH}" "root@${ip}" "echo ok" >/dev/null 2>&1; then
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
${vm_ip} ansible_user=root ansible_ssh_private_key_file=${SSH_KEY_PATH}
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
${vm_ip} ansible_user=root ansible_ssh_private_key_file=${SSH_KEY_PATH}
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
  curl -fsS -m 15 "http://${vm_ip}/api/insights" >/dev/null
  curl -fsS -m 15 "http://${vm_ip}:8080/api/tasks" >/dev/null
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
  tf init -input=false
  tf validate
  tf apply -input=false -auto-approve

  log "Waiting for VM status=on and IPv4..."
  VM_IP="$(wait_for_vm_ready)"
  log "VM is ready: ${VM_IP}"

  log "Waiting for SSH on VM..."
  wait_for_ssh "${VM_IP}"

  log "Building and pushing images..."
  mapfile -t images < <(build_and_push_images)
  BACKEND_IMAGE="${images[0]}"
  FRONTEND_IMAGE="${images[1]}"

  log "Running Ansible Docker installation playbook..."
  run_ansible_install_docker "${VM_IP}"

  if is_stack_current "${VM_IP}" "${BACKEND_IMAGE}" "${FRONTEND_IMAGE}"; then
    log "Stack already runs required images; skipping deploy playbook."
  else
    log "Deploying application stack with Ansible..."
    run_ansible_deploy_stack "${VM_IP}" "${BACKEND_IMAGE}" "${FRONTEND_IMAGE}"
  fi

  log "Running smoke tests..."
  smoke_test "${VM_IP}"

  log "Deployment completed successfully."
  echo ""
  echo "VM IP: ${VM_IP}"
  echo "Frontend: http://${VM_IP}/"
  echo "Backend API: http://${VM_IP}:8080/api/tasks"
  echo "Backend image: ${BACKEND_IMAGE}"
  echo "Frontend image: ${FRONTEND_IMAGE}"
}

main "$@"
