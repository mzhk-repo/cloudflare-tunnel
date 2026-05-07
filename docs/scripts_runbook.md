# Runbook: scripts (Cloudflare Tunnel)

## Env-контракти

- CI/CD decrypt flow: shared workflow розшифровує `env.dev.enc` або `env.prod.enc` у тимчасовий dotenv-файл і передає шлях через `ORCHESTRATOR_ENV_FILE`.
- Swarm deploy flow: `scripts/deploy-orchestrator-swarm.sh` запускається з `ORCHESTRATOR_MODE=swarm`, перевіряє env-файл, визначає Docker Secret для Cloudflare Tunnel token і деплоїть stack `cf_tunnel`.
- Network flow: `scripts/ensure-swarm-network.sh` перевіряє або створює external Swarm network для Traefik/proxy-шару. За замовчуванням це `proxy-net`.
- Secret flow: значення Cloudflare tunnel token не передається у manifest як plaintext. `scripts/render-versioned-env-secret.sh` створює immutable Docker Secret із hash-based назвою та записує її в `CF_TUNNEL_TOKEN_SECRET_NAME`.
- Ansible refresh flow: `ANSIBLE_SECRETS_REFRESH=auto` є дефолтом. Якщо `INFRA_REPO_PATH` заданий, але `ansible-playbook` недоступний, refresh пропускається з warning; далі deploy продовжується тільки якщо Docker Secret уже існує.
- Локальний fallback на `.env` дозволений тільки для dev-перевірок, коли `ORCHESTRATOR_ENV_FILE` не передано.

## Категоризація скриптів

| Скрипт | Категорія | Статус |
|---|---|---|
| `scripts/deploy-orchestrator-swarm.sh` | 1б / orchestrator | Основний Swarm deploy entrypoint для CI/CD |
| `scripts/render-versioned-env-secret.sh` | 1б / deploy-adjacent | Рендерить Docker Secret для `TUNNEL_TOKEN` із hash-based назвою |
| `scripts/ensure-swarm-network.sh` | 1б / deploy-adjacent | Pre-deploy перевірка external Swarm network |
| `scripts/validate_sops_encrypted.py` | out-of-scope | SOPS validation helper, не змінювати |
| `scripts/entrypoint.sh` | out-of-scope | Docker ENTRYPOINT контейнера, не змінювати |

## Категорія 1б: deploy-adjacent

### `scripts/deploy-orchestrator-swarm.sh`

#### Бізнес-логіка

- Основний Swarm orchestrator для Cloudflare Tunnel stack.
- У режимі `noop` нічого не деплоїть і лише друкує підказку.
- У режимі `swarm` перевіряє наявність `docker-compose.yml` і `docker-compose.swarm.yml`.
- Читає env через `ORCHESTRATOR_ENV_FILE`; якщо файл відсутній, допускає fallback на локальний `.env` тільки для dev.
- Встановлює дефолтну назву Docker Secret за `ENVIRONMENT_NAME` тільки як fallback до versioned render flow.
- Якщо задано `INFRA_REPO_PATH`, у режимі `ANSIBLE_SECRETS_REFRESH=auto` пробує запустити Ansible playbook `ansible/playbooks/swarm.yml` з тегом `secrets`. Якщо Ansible недоступний, refresh пропускається з warning.
- Викликає `scripts/render-versioned-env-secret.sh`, який створює або перевикористовує Docker Secret для `TUNNEL_TOKEN`, оновлює `CF_TUNNEL_TOKEN_SECRET_NAME` у runtime env-файлі та експортує це ім'я для подальших перевірок.
- Перед deploy перевіряє, що external Docker Secret `CF_TUNNEL_TOKEN_SECRET_NAME` існує у Swarm.
- Викликає `scripts/ensure-swarm-network.sh` перед рендерингом manifest.
- Рендерить merged manifest через `docker compose --env-file ... config`, прибирає верхній `name:` і виконує `docker stack deploy -c <manifest> <STACK_NAME>`.

#### Manual execution

```bash
# 1. Розшифрувати env у тимчасовий файл:
ENV_TMP="$(mktemp /dev/shm/env-XXXXXX)"
chmod 600 "${ENV_TMP}"
sops --decrypt --input-type dotenv --output-type dotenv env.dev.enc > "${ENV_TMP}"

# 2. Запустити Swarm deploy:
ORCHESTRATOR_MODE=swarm \
ENVIRONMENT_NAME=development \
STACK_NAME=cf_tunnel \
ORCHESTRATOR_ENV_FILE="${ENV_TMP}" \
bash scripts/deploy-orchestrator-swarm.sh

# 3. Знищити тимчасовий файл:
shred -u "${ENV_TMP}" 2>/dev/null || rm -f "${ENV_TMP}"
```

#### Mock execution

Цей сценарій проходить `swarm` гілку без реального Docker deploy: у `PATH` підставляється тимчасовий fake `docker`, який відповідає на `docker info`, `docker network inspect`, `docker compose config` і `docker stack deploy`.

```bash
TMP_DIR="$(mktemp -d /tmp/cf-mock-XXXXXX)"
MOCK_BIN="${TMP_DIR}/bin"
ENV_FILE="${TMP_DIR}/env.mock"
mkdir -p "${MOCK_BIN}"

printf '%s\n' \
  'PROXY_NET_NAME=proxy-net' \
  'CLOUDFLARE_TUNNEL_VERSION=2026.2.0' \
  > "${ENV_FILE}"

cat > "${MOCK_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '[mock-docker] %s\n' "$*" >&2

if [[ "${1:-}" == "info" ]]; then
  printf 'active\n'
elif [[ "${1:-}" == "network" && "${2:-}" == "inspect" ]]; then
  if [[ "$*" == *'{{.Driver}}'* ]]; then
    printf 'overlay\n'
  elif [[ "$*" == *'{{.Scope}}'* ]]; then
    printf 'swarm\n'
  else
    printf '[]\n'
  fi
elif [[ "${1:-}" == "compose" ]]; then
  cat <<'YAML'
name: cf-tunnel
services:
  tunnel:
    image: cloudflare/cloudflared:2026.2.0
    command:
      - tunnel
      - --metrics
      - 0.0.0.0:2000
      - run
      - --token-file
      - /run/secrets/cloudflare_tunnel_token
networks:
  proxy-net:
    name: proxy-net
    external: true
secrets:
  cloudflare_tunnel_token:
    name: cf_tunnel_token_dev_v1
    external: true
YAML
elif [[ "${1:-}" == "stack" && "${2:-}" == "deploy" ]]; then
  printf 'mock stack deploy accepted\n' >&2
else
  printf 'mock docker: unsupported args: %s\n' "$*" >&2
  exit 2
fi
EOF

chmod +x "${MOCK_BIN}/docker"

PATH="${MOCK_BIN}:${PATH}" \
ORCHESTRATOR_MODE=swarm \
ENVIRONMENT_NAME=development \
STACK_NAME=cf_tunnel \
ORCHESTRATOR_ENV_FILE="${ENV_FILE}" \
bash scripts/deploy-orchestrator-swarm.sh

rm -rf "${TMP_DIR}"
```

Очікуваний результат: `Swarm deploy completed`, але реальний `docker stack deploy` не виконується.

#### Ansible refresh modes

```bash
# Дефолт: спробувати Ansible refresh, але не падати якщо ansible-playbook недоступний.
ANSIBLE_SECRETS_REFRESH=auto bash scripts/deploy-orchestrator-swarm.sh

# Жорсткий режим: падати, якщо INFRA_REPO_PATH/playbook/ansible-playbook недоступні.
ANSIBLE_SECRETS_REFRESH=required bash scripts/deploy-orchestrator-swarm.sh

# Повністю пропустити Ansible refresh і покладатися на вже існуючий Docker Secret.
ANSIBLE_SECRETS_REFRESH=skip bash scripts/deploy-orchestrator-swarm.sh
```

Навіть якщо refresh пропущено, скрипт перевіряє Docker Secret перед `docker stack deploy`. Якщо secret відсутній, deploy завершується явною помилкою:

```text
[deploy-orchestrator] ERROR: required Docker Secret not found: cf_tunnel_token_dev_v1
```

### `scripts/render-versioned-env-secret.sh`

#### Бізнес-логіка

- Deploy-adjacent helper для `scripts/deploy-orchestrator-swarm.sh`.
- Читає env через `--env-file`, `ORCHESTRATOR_ENV_FILE` або локальний `.env` fallback тільки для dev.
- Не виконує env-файл через `source`; підтримує прості dotenv-рядки `KEY=value` та `export KEY=value`.
- Рендерить `TUNNEL_TOKEN` у Docker Secret з назвою `<base>_<sha256-12>`.
- Base name задається через `CF_TUNNEL_TOKEN_SECRET_BASE`; якщо не задано, для `ENVIRONMENT_NAME=development|dev` використовується `cf_tunnel_token_dev`, для `production|prod` — `cf_tunnel_token_prod`, інакше `cf_tunnel_token`.
- Через `--write-env-file` замінює або додає `CF_TUNNEL_TOKEN_SECRET_NAME=<rendered-name>` у runtime env-файлі.
- Повторний запуск із тим самим `TUNNEL_TOKEN` перевикористовує існуючий Docker Secret; зміна токена створює нове hash-based ім'я.

#### Manual execution

```bash
ORCHESTRATOR_ENV_FILE=/tmp/env.decrypted \
ENVIRONMENT_NAME=development \
bash scripts/render-versioned-env-secret.sh \
  --env-file /tmp/env.decrypted \
  --write-env-file /tmp/env.decrypted
```

Очікуваний stdout містить тільки generated dotenv-рядок:

```text
CF_TUNNEL_TOKEN_SECRET_NAME=cf_tunnel_token_dev_<sha256-12>
```

### `scripts/ensure-swarm-network.sh`

#### Бізнес-логіка

- Pre-deploy helper для `scripts/deploy-orchestrator-swarm.sh`.
- Визначає env-файл через `ORCHESTRATOR_ENV_FILE`. Якщо файл не передано, може локально розшифрувати `env.dev.enc` або `env.prod.enc` у `/dev/shm`.
- Визначає середовище через аргумент, `ENVIRONMENT_NAME` або `SERVER_ENV`.
- Читає `PROXY_NET_NAME` з env-файла без `source`; якщо змінної немає, використовує `proxy-net`.
- Перевіряє, що Docker Swarm активний.
- Якщо network існує, перевіряє `driver=overlay` і `scope=swarm`.
- Якщо network відсутня, створює її як overlay network; `SWARM_NETWORK_ATTACHABLE=true` додає `--attachable`.

#### Manual execution

```bash
# Через уже розшифрований env-файл:
ORCHESTRATOR_ENV_FILE=/tmp/env.decrypted bash scripts/ensure-swarm-network.sh

# Або автономно для dev/prod, якщо доступний sops:
ENVIRONMENT_NAME=development bash scripts/ensure-swarm-network.sh
SERVER_ENV=prod bash scripts/ensure-swarm-network.sh
```

#### Negative checks

```bash
# Відсутній env-файл: скрипт спробує перейти до локального SOPS-flow.
ORCHESTRATOR_ENV_FILE=/tmp/nonexistent ENVIRONMENT_NAME=development bash scripts/ensure-swarm-network.sh

# Невідоме середовище має завершитися з явною помилкою.
ENVIRONMENT_NAME=staging bash scripts/ensure-swarm-network.sh
```

## Out of scope

### `scripts/validate_sops_encrypted.py`

#### Бізнес-логіка

- Перевіряє, що SOPS-encrypted файли не містять plaintext-секретів.
- Не бере участі у Swarm deploy runtime.
- Залишається без змін під час refactoring `scripts/`.

#### Manual execution

```bash
python3 scripts/validate_sops_encrypted.py env.dev.enc
python3 scripts/validate_sops_encrypted.py env.prod.enc
```

### `scripts/entrypoint.sh`

#### Бізнес-логіка

- Docker ENTRYPOINT контейнера.
- Читає файли з `/run/secrets` і експортує їх як змінні оточення перед запуском основної команди контейнера.
- Не запускається напряму під час CI/CD deploy.

#### Manual execution

Ручний запуск зазвичай не потрібен. Для локальної перевірки синтаксису:

```bash
bash -n scripts/entrypoint.sh
```
