# cloudflare-tunnel

Окремий Docker-стек для Cloudflare Tunnel (`cloudflared`).
Виокремлено з [DSpace-docker](../DSpace-docker).

## Архітектура

```
Інтернет -> Cloudflare -> cloudflared (tunnel) -> proxy-net -> Traefik -> DSpace
```

Контейнер підключається до зовнішньої мережі `proxy-net`.

## SOPS + age (dev)

Для Swarm deploy у dev використовуємо зашифровані файли в корені repo:
- `env.dev.enc`
- `env.prod.enc` (підготовлено на майбутнє)

Plaintext `.env*` не комітимо.

## Локальний compose (опційно)

```bash
cp .env.example .env
# заповнити TUNNEL_TOKEN
nano .env
docker compose up -d
```

## Swarm deploy (dev/prod)

1. Створити/оновити Docker Secret через Ansible SOPS-flow.
2. Вибрати secret name під середовище:

```bash
export CF_TUNNEL_TOKEN_SECRET_NAME=cf_tunnel_token_dev_v1
# для prod приклад:
# export CF_TUNNEL_TOKEN_SECRET_NAME=cf_tunnel_token_prod_v1
```

3. Деплой:

```bash
docker compose -f docker-compose.yml -f docker-compose.swarm.yml config \
| sed '/^name:/d' \
| docker stack deploy -c - cf_tunnel
```

Для Swarm у `docker-compose.swarm.yml` використовується `restart_policy.condition: any`
без `max_attempts`. Це потрібно, щоб тунель автоматично піднімався після мережевих
інцидентів, навіть якщо `cloudflared` завершується з кодом `0` після SIGTERM.

## Змінні

| Змінна | Дефолт | Опис |
|--------|--------|------|
| `TUNNEL_TOKEN` | _обов'язково_ | Токен тунелю з Cloudflare Dashboard |
| `CLOUDFLARE_TUNNEL_VERSION` | `2026.2.0` | Версія образу `cloudflared` |
| `PROXY_NET_NAME` | `proxy-net` | Ім'я зовнішньої Docker-мережі |
| `COMPOSE_PROJECT_NAME` | `cf-tunnel` | Ім'я проєкту Compose |
| `CF_TUNNEL_TOKEN_SECRET_NAME` | _обов'язково для swarm_ | Назва зовнішнього Docker Secret з токеном |
