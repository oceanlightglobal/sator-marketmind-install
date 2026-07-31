#!/usr/bin/env bash
set -euo pipefail

# MarketMind is installed beside wa-cs. It never runs docker compose down,
# removes volumes, restarts wacs_app, or owns ports 80/443.

RELEASE_BASE="${RELEASE_BASE:-https://raw.githubusercontent.com/oceanlightglobal/sator-marketmind-install/main}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/oceanlightglobal/sator-marketmind:latest}"
UPDATER_IMAGE="${UPDATER_IMAGE:-ghcr.io/oceanlightglobal/sator-marketmind-updater:latest}"
VERSION_MANIFEST_URL="${VERSION_MANIFEST_URL:-${RELEASE_BASE}/version.json}"

INSTALL_DIR="/opt/marketmind"
WACS_DIR="/opt/wa-cs"
CADDY_CONTAINER="wacs_caddy"
WACS_APP_CONTAINER="wacs_app"
SITE_ADDRESS="marketmind.139-99-89-252.sslip.io"
PUBLIC_URL="https://${SITE_ADDRESS}"
ALLOW_CADDY_RESTART="${ALLOW_CADDY_RESTART:-0}"

BOLD='\033[1m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; NC='\033[0m'
step() { echo -e "\n${BOLD}▶ $*${NC}"; }
ok() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
fail() { echo -e "\n${RED}✗ $*${NC}\n" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) SITE_ADDRESS="${2:-}"; PUBLIC_URL="https://${SITE_ADDRESS}"; shift 2 ;;
    --dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: install.sh [--domain marketmind.example.com] [--dir /opt/marketmind]"
      exit 0
      ;;
    *) fail "不认识的参数：$1" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || fail "请用 root 运行安装脚本"
[[ "$INSTALL_DIR" != "$WACS_DIR" ]] || fail "MarketMind 不能安装到现有客服目录 ${WACS_DIR}"
[[ "$INSTALL_DIR" == /opt/marketmind* ]] || fail "安装目录必须位于 /opt/marketmind 下"

echo -e "${BOLD}MarketMind v0.2 · 同机隔离安装${NC}"
echo "现有客服：${WACS_DIR}（只读检查，不更新、不重启）"
echo "新系统：  ${INSTALL_DIR}"

step "1/6 只读检查现有 AI 客服"
command -v docker >/dev/null 2>&1 || fail "Docker 不存在。现有 wa-cs 应已安装 Docker，请先检查服务器状态。"
docker compose version >/dev/null 2>&1 || fail "Docker Compose 插件不可用"
docker inspect "$CADDY_CONTAINER" >/dev/null 2>&1 || fail "找不到 ${CADDY_CONTAINER}，中止以避免误建第二个公网代理"
docker inspect "$WACS_APP_CONTAINER" >/dev/null 2>&1 || fail "找不到 ${WACS_APP_CONTAINER}，中止以避免影响现有客服"

WACS_HEALTH_BEFORE="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$WACS_APP_CONTAINER")"
[[ "$WACS_HEALTH_BEFORE" == "healthy" || "$WACS_HEALTH_BEFORE" == "running" ]] \
  || fail "现有客服状态为 ${WACS_HEALTH_BEFORE}，先处理现有故障，MarketMind 未做任何改动"
ok "现有客服状态：${WACS_HEALTH_BEFORE}"

WACS_ROUTE_BEFORE="$(
  docker exec "$CADDY_CONTAINER" wget -qO- http://app:3000/api/health
)" || fail "Caddy 当前无法通过 app:3000 访问现有客服，MarketMind 未做任何改动"
[[ -n "$WACS_ROUTE_BEFORE" ]] || fail "现有客服代理目标返回空内容，MarketMind 未做任何改动"
ok "现有客服代理目标已留存，安装后会逐字核对"

mapfile -t CADDY_NETWORKS < <(
  docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{"\n"}}{{end}}' "$CADDY_CONTAINER" |
    sed '/^[[:space:]]*$/d'
)
WACS_CADDY_NETWORK=""
for network in "${CADDY_NETWORKS[@]}"; do
  if docker network inspect "$network" --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' |
      grep -Fxq "$WACS_APP_CONTAINER"; then
    WACS_CADDY_NETWORK="$network"
    break
  fi
done
[[ -n "$WACS_CADDY_NETWORK" ]] || fail "找不到 Caddy 与现有客服共享的 Docker 网络，未修改任何配置"
ok "共享代理网络：${WACS_CADDY_NETWORK}"

step "2/6 下载 MarketMind 独立配置"
mkdir -p "$INSTALL_DIR"
curl -fsSL "${RELEASE_BASE}/docker-compose.yml" -o "${INSTALL_DIR}/docker-compose.yml.new" \
  || fail "下载 docker-compose.yml 失败"
mv "${INSTALL_DIR}/docker-compose.yml.new" "${INSTALL_DIR}/docker-compose.yml"
ok "配置写入 ${INSTALL_DIR}"

randhex() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
randpw() { head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z2-9' | head -c 16; }
upsert_env() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

ENV_FILE="${INSTALL_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
  ok "保留现有 MarketMind .env 与数据"
  INITIAL_ADMIN_PASSWORD="$(grep -E '^INITIAL_ADMIN_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || true)"
  UPDATER_TOKEN="$(grep -E '^UPDATER_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)"
  [[ -n "$UPDATER_TOKEN" ]] || UPDATER_TOKEN="$(randhex)"
else
  INITIAL_ADMIN_PASSWORD="$(randpw)"
  UPDATER_TOKEN="$(randhex)"
  touch "$ENV_FILE"
fi

upsert_env "COMPOSE_PROJECT_NAME" "marketmind" "$ENV_FILE"
upsert_env "PUBLIC_URL" "$PUBLIC_URL" "$ENV_FILE"
upsert_env "WACS_CADDY_NETWORK" "$WACS_CADDY_NETWORK" "$ENV_FILE"
upsert_env "APP_IMAGE" "$APP_IMAGE" "$ENV_FILE"
upsert_env "UPDATER_IMAGE" "$UPDATER_IMAGE" "$ENV_FILE"
upsert_env "INITIAL_ADMIN_PASSWORD" "$INITIAL_ADMIN_PASSWORD" "$ENV_FILE"
upsert_env "UPDATER_TOKEN" "$UPDATER_TOKEN" "$ENV_FILE"
upsert_env "VERSION_MANIFEST_URL" "$VERSION_MANIFEST_URL" "$ENV_FILE"
upsert_env "TZ_NAME" "Asia/Kuala_Lumpur" "$ENV_FILE"
upsert_env "AI_BASE_URL" "https://4aion.com/v1" "$ENV_FILE"
upsert_env "AI_API_KEY" "" "$ENV_FILE"
upsert_env "AI_MODEL" "" "$ENV_FILE"
chmod 600 "$ENV_FILE"

step "3/6 启动 MarketMind 独立容器"
cd "$INSTALL_DIR"
docker compose -p marketmind pull marketmind updater
docker compose -p marketmind up -d --no-deps marketmind updater
for _ in $(seq 1 45); do
  if docker exec marketmind_app wget -qO- http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker exec marketmind_app wget -qO- http://127.0.0.1:3000/api/health >/dev/null \
  || fail "MarketMind 未通过健康检查。现有客服未改动；查看：cd ${INSTALL_DIR} && docker compose logs marketmind"
ok "MarketMind 独立应用健康"

step "4/6 安全加入现有 Caddy"
CADDYFILE="${WACS_DIR}/Caddyfile"
[[ -f "$CADDYFILE" ]] || fail "找不到 ${CADDYFILE}，不会猜测或覆盖代理配置"
BACKUP="${CADDYFILE}.marketmind-backup.$(date +%Y%m%d%H%M%S)"
cp -a "$CADDYFILE" "$BACKUP"
TMP_CADDY="$(mktemp)"
trap 'rm -f "$TMP_CADDY"' EXIT

awk '
  /^# BEGIN MARKETMIND MANAGED BLOCK$/ { skip=1; next }
  /^# END MARKETMIND MANAGED BLOCK$/ { skip=0; next }
  !skip { print }
' "$CADDYFILE" > "$TMP_CADDY"
cat >> "$TMP_CADDY" <<EOF

# BEGIN MARKETMIND MANAGED BLOCK
${SITE_ADDRESS} {
	encode zstd gzip
	reverse_proxy marketmind_app:3000 {
		header_up X-Real-IP {remote_host}
		transport http {
			read_timeout 120s
			write_timeout 120s
		}
	}
	header {
		X-Content-Type-Options nosniff
		X-Frame-Options DENY
		Referrer-Policy no-referrer
		-Server
	}
}
# END MARKETMIND MANAGED BLOCK
EOF
install -m 0644 "$TMP_CADDY" "$CADDYFILE"

if ! docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  cp -a "$BACKUP" "$CADDYFILE"
  fail "新 Caddy 配置验证失败，已恢复 ${BACKUP}；现有客服未重载"
fi

reload_caddy_config() {
  if docker exec "$CADDY_CONTAINER" \
      caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    CADDY_RELOAD_METHOD="hot-reload"
    return 0
  fi

  # wa-cs 的早期安装版本可能在 Caddyfile 里设置了 `admin off`。
  # 这种配置没有可用的热重载入口，Caddy 2.8 对 SIGUSR1 也只会返回
  # "not implemented"。必须得到明确授权才允许只重启共享代理容器；
  # wacs_app、数据库、volume 和镜像都不会被触碰。
  [[ "$ALLOW_CADDY_RESTART" == "1" ]] || return 2
  docker restart "$CADDY_CONTAINER" >/dev/null
  CADDY_RELOAD_METHOD="controlled-restart"
}

restore_caddy_config() {
  cp -a "$BACKUP" "$CADDYFILE"
  if docker exec "$CADDY_CONTAINER" \
      caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$ALLOW_CADDY_RESTART" == "1" ]]; then
    docker restart "$CADDY_CONTAINER" >/dev/null
    return 0
  fi
  return 1
}

CADDY_RELOAD_METHOD=""
if ! reload_caddy_config; then
  cp -a "$BACKUP" "$CADDYFILE"
  fail "Caddy 管理接口关闭，无法热重载。未应用新配置；如接受仅重启 wacs_caddy 一次，请用 ALLOW_CADDY_RESTART=1 重新运行"
fi
if [[ "$CADDY_RELOAD_METHOD" == "controlled-restart" ]]; then
  warn "Caddy 管理接口关闭：已按明确授权仅重启 wacs_caddy；wacs_app 与数据库未重启"
else
  ok "Caddy 配置已验证并热重载（未重启容器）"
fi

step "5/6 验证两个系统"
MARKETMIND_OK=0
for _ in $(seq 1 45); do
  if curl -fsS --max-time 5 "${PUBLIC_URL}/api/health" >/dev/null 2>&1; then
    MARKETMIND_OK=1
    break
  fi
  sleep 2
done
if [[ "$MARKETMIND_OK" -ne 1 ]]; then
  restore_caddy_config || true
  fail "MarketMind HTTPS 验证失败，已恢复并重新应用原 Caddyfile"
fi

WACS_HEALTH_AFTER="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$WACS_APP_CONTAINER")"
if [[ "$WACS_HEALTH_AFTER" != "healthy" && "$WACS_HEALTH_AFTER" != "running" ]]; then
  restore_caddy_config || true
  fail "现有客服健康状态变为 ${WACS_HEALTH_AFTER}，已恢复 Caddy 配置"
fi

WACS_ROUTE_AFTER="$(
  docker exec "$CADDY_CONTAINER" wget -qO- http://app:3000/api/health
)" || WACS_ROUTE_AFTER=""
if [[ "$WACS_ROUTE_AFTER" != "$WACS_ROUTE_BEFORE" ]]; then
  # 若共享网络出现别名碰撞，先只隔离 MarketMind，再恢复代理配置。
  # 不断开、不重启也不修改 wacs_app。
  docker network disconnect "$WACS_CADDY_NETWORK" marketmind_app >/dev/null 2>&1 || true
  restore_caddy_config || true
  fail "现有客服代理目标发生变化，已断开 MarketMind 的共享代理网络并恢复 Caddy 配置"
fi
ok "现有客服仍为 ${WACS_HEALTH_AFTER}"
ok "现有客服代理目标内容与安装前完全一致"
ok "MarketMind HTTPS 正常"

step "6/6 完成"
echo
echo -e "  后台：${BOLD}${PUBLIC_URL}${NC}"
if [[ -n "$INITIAL_ADMIN_PASSWORD" ]]; then
  echo -e "  初始密码：${BOLD}${INITIAL_ADMIN_PASSWORD}${NC}"
  echo "  登录后请立即修改密码。该环境变量以后不会覆盖已设置的密码。"
else
  echo "  管理员密码沿用 MarketMind 数据库中的现有设置。"
fi
echo
echo "  MarketMind：${INSTALL_DIR} / marketmind_app / marketmind_data"
echo "  现有客服：  ${WACS_DIR} / wacs_app（未更新、未重启、未删除）"
echo "  Caddy 备份：${BACKUP}"
