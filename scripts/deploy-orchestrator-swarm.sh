#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="${ORCHESTRATOR_MODE:-noop}"
STACK_NAME="${STACK_NAME:-cf_tunnel}"
ENV_FILE="${ORCHESTRATOR_ENV_FILE:-/tmp/env.decrypted}"
ANSIBLE_SECRETS_REFRESH="${ANSIBLE_SECRETS_REFRESH:-auto}"

log() {
  printf '[deploy-orchestrator] %s\n' "$*"
}

detect_compose_file() {
  if [[ -f "docker-compose.yaml" ]]; then
    echo "docker-compose.yaml"
  elif [[ -f "docker-compose.yml" ]]; then
    echo "docker-compose.yml"
  else
    echo ""
  fi
}

set_default_secret_name() {
  if [[ -n "${CF_TUNNEL_TOKEN_SECRET_NAME:-}" ]]; then
    return 0
  fi

  case "${ENVIRONMENT_NAME:-}" in
    development|dev)
      export CF_TUNNEL_TOKEN_SECRET_NAME="cf_tunnel_token_dev_v1"
      ;;
    production|prod)
      export CF_TUNNEL_TOKEN_SECRET_NAME="cf_tunnel_token_prod_v1"
      ;;
  esac
}

run_ansible_secrets_if_configured() {
  local infra_repo_path environment inventory_env inventory_path playbook_path

  infra_repo_path="${INFRA_REPO_PATH:-}"
  environment="${ENVIRONMENT_NAME:-}"

  case "${ANSIBLE_SECRETS_REFRESH}" in
    auto|required|skip)
      ;;
    *)
      log "ERROR: unsupported ANSIBLE_SECRETS_REFRESH=${ANSIBLE_SECRETS_REFRESH}. Supported: auto|required|skip"
      exit 1
      ;;
  esac

  if [[ "${ANSIBLE_SECRETS_REFRESH}" == "skip" ]]; then
    log "ANSIBLE_SECRETS_REFRESH=skip; skip ansible secrets refresh"
    return 0
  fi

  if [[ -z "${infra_repo_path}" ]]; then
    log "INFRA_REPO_PATH is not set; skip ansible secrets refresh"
    return 0
  fi

  if [[ ! -d "${infra_repo_path}" ]]; then
    if [[ "${ANSIBLE_SECRETS_REFRESH}" == "auto" ]]; then
      log "WARNING: INFRA_REPO_PATH does not exist (${infra_repo_path}); skip ansible secrets refresh"
      return 0
    fi
    log "ERROR: INFRA_REPO_PATH does not exist: ${infra_repo_path}"
    exit 1
  fi

  if ! command -v ansible-playbook >/dev/null 2>&1; then
    if [[ "${ANSIBLE_SECRETS_REFRESH}" == "auto" ]]; then
      log "WARNING: ansible-playbook not found on host; skip ansible secrets refresh"
      return 0
    fi
    log "ERROR: ansible-playbook not found on host"
    exit 1
  fi

  case "${environment}" in
    development|dev)
      inventory_env="dev"
      ;;
    production|prod)
      inventory_env="prod"
      ;;
    *)
      log "ERROR: unsupported ENVIRONMENT_NAME=${environment} (expected: development|production)"
      exit 1
      ;;
  esac

  inventory_path="${infra_repo_path}/ansible/inventories/${inventory_env}/hosts.yml"
  playbook_path="${infra_repo_path}/ansible/playbooks/swarm.yml"

  if [[ ! -f "${inventory_path}" ]]; then
    if [[ "${ANSIBLE_SECRETS_REFRESH}" == "auto" ]]; then
      log "WARNING: inventory file not found (${inventory_path}); skip ansible secrets refresh"
      return 0
    fi
    log "ERROR: inventory file not found: ${inventory_path}"
    exit 1
  fi
  if [[ ! -f "${playbook_path}" ]]; then
    if [[ "${ANSIBLE_SECRETS_REFRESH}" == "auto" ]]; then
      log "WARNING: playbook file not found (${playbook_path}); skip ansible secrets refresh"
      return 0
    fi
    log "ERROR: playbook file not found: ${playbook_path}"
    exit 1
  fi

  log "Refreshing Swarm secrets via Ansible (inventory=${inventory_env})"
  ANSIBLE_CONFIG="${infra_repo_path}/ansible/ansible.cfg" \
    ansible-playbook \
    -i "${inventory_path}" \
    "${playbook_path}" \
    --tags secrets
}

ensure_swarm_secret_exists() {
  if ! command -v docker >/dev/null 2>&1; then
    log "ERROR: docker CLI not found on host"
    exit 1
  fi

  if ! docker secret inspect "${CF_TUNNEL_TOKEN_SECRET_NAME}" >/dev/null 2>&1; then
    log "ERROR: required Docker Secret not found: ${CF_TUNNEL_TOKEN_SECRET_NAME}"
    log "Create or refresh it before deploy, or run with ANSIBLE_SECRETS_REFRESH=required on a host with ansible-playbook."
    exit 1
  fi

  log "Docker Secret exists: ${CF_TUNNEL_TOKEN_SECRET_NAME}"
}

ensure_external_networks() {
  log "Ensuring required external Swarm networks"
  ORCHESTRATOR_ENV_FILE="${ENV_FILE}" "${SCRIPT_DIR}/ensure-swarm-network.sh"
}

deploy_swarm() {
  local compose_file swarm_file raw_manifest deploy_manifest

  compose_file="$(detect_compose_file)"
  swarm_file="docker-compose.swarm.yml"
  raw_manifest="$(mktemp "${PROJECT_ROOT}/.${STACK_NAME}.stack.raw.XXXXXX.yml")"
  deploy_manifest="$(mktemp "${PROJECT_ROOT}/.${STACK_NAME}.stack.deploy.XXXXXX.yml")"
  trap "rm -f '${raw_manifest}' '${deploy_manifest}'" RETURN EXIT

  if [[ -z "${compose_file}" ]]; then
    log "ERROR: compose file not found (expected docker-compose.yaml|yml)"
    exit 1
  fi
  if [[ ! -f "${swarm_file}" ]]; then
    log "ERROR: ${swarm_file} not found"
    exit 1
  fi

  if [[ ! -f "${ENV_FILE}" ]]; then
    if [[ -f ".env" ]]; then
      ENV_FILE=".env"
      log "WARNING: env.*.enc not decrypted or ORCHESTRATOR_ENV_FILE not provided. Fallback to local .env — dev only."
    else
      log "ERROR: env file not found (${ORCHESTRATOR_ENV_FILE:-/tmp/env.decrypted}) and .env missing"
      exit 1
    fi
  fi

  set_default_secret_name
  if [[ -z "${CF_TUNNEL_TOKEN_SECRET_NAME:-}" ]]; then
    log "ERROR: CF_TUNNEL_TOKEN_SECRET_NAME is not set"
    exit 1
  fi

  run_ansible_secrets_if_configured
  ensure_swarm_secret_exists
  ensure_external_networks

  log "Rendering Swarm manifest (stack=${STACK_NAME}, env_file=${ENV_FILE})"
  docker compose --env-file "${ENV_FILE}" \
    -f "${compose_file}" \
    -f "${swarm_file}" \
    config > "${raw_manifest}"

  awk 'NR==1 && $1=="name:" {next} {print}' "${raw_manifest}" > "${deploy_manifest}"

  log "Deploying stack ${STACK_NAME}"
  docker stack deploy -c "${deploy_manifest}" "${STACK_NAME}"

  log "Swarm deploy completed"
}

cd "${PROJECT_ROOT}"

case "${MODE}" in
  noop)
    log "No-op mode. Set ORCHESTRATOR_MODE=swarm to enable Phase 8 Swarm deploy path."
    ;;
  swarm)
    deploy_swarm
    ;;
  *)
    log "ERROR: unknown ORCHESTRATOR_MODE=${MODE}. Supported: noop, swarm"
    exit 1
    ;;
esac
