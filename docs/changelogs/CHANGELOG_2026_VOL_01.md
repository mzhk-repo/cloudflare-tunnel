# CHANGELOG 2026 VOL 01

## [2026-04-28] — 

- **Context:** 
- **Change:** 
- **Verification:** 
- **Risks:** 
- **Rollback:** 

## [2026-04-28] — Ідемпотентне створення Swarm external network

- **Context:** GitHub Actions deploy падав на `docker stack deploy`, бо external network `proxy-net` не існувала як swarm-scoped network.
- **Change:** Додано `scripts/ensure-swarm-network.sh`, який читає `ORCHESTRATOR_ENV_FILE` без `source`, а за його відсутності визначає `dev/prod` через аргумент, `ENVIRONMENT_NAME` або `SERVER_ENV` і розшифровує `env.<env>.enc` через SOPS у `/dev/shm`. Скрипт ідемпотентно створює overlay attachable network і підключений як predeploy у `scripts/deploy-orchestrator-swarm.sh`. Production workflow також переведено з відсутнього `scripts/deploy-orchestrator.sh` на `scripts/deploy-orchestrator-swarm.sh`, щоб GitHub Actions не йшов у fallback.
- **Verification:** Пройдено `bash -n`, `shellcheck` і mock-перевірки сценаріїв створення, повторного запуску, SOPS-вибору `env.prod.enc`, некоректної наявної мережі та відсутнього середовища без реального впливу на production Docker.
- **Risks:** Якщо на хості вже існує мережа з такою назвою, але не `driver=overlay` або не `scope=swarm`, скрипт зупинить деплой з явною помилкою.
- **Rollback:** Видалити виклик `ensure_external_networks` із `scripts/deploy-orchestrator-swarm.sh` та прибрати `scripts/ensure-swarm-network.sh`.

## [2026-04-28] — Runbook для Cloudflare Tunnel scripts

- **Context:** `docs/scripts_runbook.md` описував VictoriaMetrics/Grafana stack і не відповідав поточному репозиторію `cloudflare-tunnel`.
- **Change:** Runbook переписано під Cloudflare Tunnel: додано env-контракти, категоризацію фактичних скриптів, manual execution для `deploy-orchestrator-swarm.sh`, `ensure-swarm-network.sh`, out-of-scope helper-ів і mock execution без реального Docker deploy.
- **Verification:** Виконано мок-запуск `scripts/deploy-orchestrator-swarm.sh` з тимчасовим fake `docker`; `swarm` гілка пройшла до `Swarm deploy completed` без production-дій.
- **Risks:** Mock-перевірка підтверджує orchestration flow, але не замінює реальний deploy на хості з активним Docker Swarm і валідним Docker Secret.
- **Rollback:** Повернути попередній вміст `docs/scripts_runbook.md` і видалити цей changelog-запис.

## [2026-04-28] — Optional Ansible refresh для Cloudflare Tunnel deploy

- **Context:** GitHub Actions deploy падав у `scripts/deploy-orchestrator-swarm.sh` з `ERROR: ansible-playbook not found on host`, бо shared workflow передавав `INFRA_REPO_PATH`, але на deploy host не було Ansible CLI.
- **Change:** Додано `ANSIBLE_SECRETS_REFRESH=auto|required|skip`. У дефолтному `auto` режимі відсутній `ansible-playbook`, infra repo, inventory або playbook дають warning і пропускають secrets refresh. Перед deploy додано явну перевірку Docker Secret `CF_TUNNEL_TOKEN_SECRET_NAME`, щоб deploy не продовжувався без external secret.
- **Verification:** Пройдено `bash -n scripts/deploy-orchestrator-swarm.sh`, `bash -n scripts/ensure-swarm-network.sh`, mock success path, missing ansible у `auto`, missing ansible у `required` та missing Docker Secret.
- **Risks:** Якщо secret не створений заздалегідь, deploy тепер впаде пізніше з явною помилкою про відсутній Docker Secret.
- **Rollback:** Повернути hard-fail поведінку в `run_ansible_secrets_if_configured` і прибрати `ensure_swarm_secret_exists`.

## [2026-04-28] — Cleanup Swarm manifest artifacts on failure

- **Context:** Після невдалих запусків могли залишатися тимчасові manifest-файли `.cf_tunnel.stack.*.yml`.
- **Change:** Cleanup trap у `scripts/deploy-orchestrator-swarm.sh` переведено на `RETURN EXIT` із зафіксованими шляхами до raw/deploy manifest, щоб артефакти видалялися навіть при `exit 1`.
- **Verification:** Пройдено `bash -n scripts/deploy-orchestrator-swarm.sh` і mock failure-сценарій з відсутнім Docker Secret; після падіння `.cf_tunnel.stack.*.yml` не залишились.
- **Risks:** Низькі; cleanup видаляє тільки два конкретні tmp-файли, створені поточним запуском.
- **Rollback:** Повернути trap до `RETURN`, якщо потрібно зберігати tmp manifest для debugging.
