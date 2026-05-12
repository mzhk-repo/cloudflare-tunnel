#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_TMP=""
ENV_FILE="${ORCHESTRATOR_ENV_FILE:-}"
NETWORK_NAME="${PROXY_NET_NAME:-}"
NETWORK_DRIVER="${SWARM_NETWORK_DRIVER:-overlay}"
NETWORK_ATTACHABLE="${SWARM_NETWORK_ATTACHABLE:-true}"

log() {
  printf '[ensure-swarm-network] %s\n' "$*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

cleanup_env_tmp() {
  if [[ -n "${ENV_TMP:-}" && -f "${ENV_TMP}" ]]; then
    if command -v shred >/dev/null 2>&1; then
      shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
    else
      rm -f "${ENV_TMP}"
    fi
  fi
}

resolve_environment() {
  local env="${1:-${ENVIRONMENT_NAME:-${SERVER_ENV:-}}}"

  case "${env}" in
    dev|development)
      echo "dev"
      ;;
    prod|production)
      echo "prod"
      ;;
    *)
      die "environment unknown: '${env}'. Set ENVIRONMENT_NAME, SERVER_ENV or pass dev|prod as first argument."
      ;;
  esac
}

decrypt_env_file() {
  local environment enc_file

  environment="$(resolve_environment "${1:-}")"
  enc_file="${PROJECT_ROOT}/env.${environment}.enc"

  [[ -f "${enc_file}" ]] || die "encrypted env file not found: ${enc_file}"
  command -v sops >/dev/null 2>&1 || die "sops CLI not found"

  ENV_TMP="$(mktemp /dev/shm/env-XXXXXX)"
  chmod 600 "${ENV_TMP}"
  trap cleanup_env_tmp EXIT

  log "Decrypting ${enc_file} to RAM env file"
  sops --decrypt --input-type dotenv --output-type dotenv "${enc_file}" > "${ENV_TMP}"
  ENV_FILE="${ENV_TMP}"
}

read_env_var() {
  local key="$1" file="$2" line value

  [[ -f "${file}" ]] || return 0

  line="$(grep -m1 -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "${file}" || true)"
  [[ -n "${line}" ]] || return 0

  value="${line#*=}"
  value="${value%%#*}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"

  printf '%s' "${value}"
}

resolve_env_file() {
  local environment_arg="${1:-}"

  if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
    return 0
  fi

  if [[ -n "${ENV_FILE}" && ! -f "${ENV_FILE}" ]]; then
    log "WARNING: ORCHESTRATOR_ENV_FILE points to missing file: ${ENV_FILE}; trying local SOPS env"
  fi

  decrypt_env_file "${environment_arg}"
}

resolve_network_name() {
  local env_value

  if [[ -z "${NETWORK_NAME}" ]]; then
    env_value="$(read_env_var "PROXY_NET_NAME" "${ENV_FILE}")"
    NETWORK_NAME="${env_value:-proxy-net}"
  fi

  [[ -n "${NETWORK_NAME}" ]] || die "network name is empty"
}

ensure_docker_ready() {
  local swarm_state

  command -v docker >/dev/null 2>&1 || die "docker CLI not found"

  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
  if [[ "${swarm_state}" != "active" ]]; then
    die "Docker Swarm is not active on this host (state=${swarm_state:-unknown})"
  fi
}

network_exists() {
  docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1
}

validate_existing_network() {
  local driver scope

  driver="$(docker network inspect --format '{{.Driver}}' "${NETWORK_NAME}")"
  scope="$(docker network inspect --format '{{.Scope}}' "${NETWORK_NAME}")"

  if [[ "${driver}" != "${NETWORK_DRIVER}" || "${scope}" != "swarm" ]]; then
    die "network ${NETWORK_NAME} exists, but driver=${driver}, scope=${scope}; expected driver=${NETWORK_DRIVER}, scope=swarm"
  fi

  log "Network ${NETWORK_NAME} already exists (driver=${driver}, scope=${scope})"
}

create_network() {
  local create_args

  create_args=(network create --driver "${NETWORK_DRIVER}")
  if [[ "${NETWORK_ATTACHABLE}" == "true" ]]; then
    create_args+=(--attachable)
  fi
  create_args+=("${NETWORK_NAME}")

  log "Creating swarm network ${NETWORK_NAME} (driver=${NETWORK_DRIVER}, attachable=${NETWORK_ATTACHABLE})"
  docker "${create_args[@]}" >/dev/null
  validate_existing_network
}

main() {
  cd "${PROJECT_ROOT}"

  resolve_env_file "${1:-}"
  resolve_network_name
  ensure_docker_ready

  if network_exists; then
    validate_existing_network
  else
    create_network
  fi
}

main "$@"
