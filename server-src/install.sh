#!/usr/bin/env bash
# Student-Agent installer
# Usage: bash install.sh [--no-dingtalk] [--port 80]
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[•]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

SKIP_DINGTALK=false
PORT=80
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-dingtalk) SKIP_DINGTALK=true; shift ;;
    --port) PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo ""
echo "  Student-Agent 安装程序"
echo "  ───────────────────────────────────────"
echo ""

# ── Prerequisites ────────────────────────────────────────────────────────────
info "检查依赖..."

# Docker
if ! command -v docker &>/dev/null; then
  die "未找到 Docker。请先安装: https://docs.docker.com/engine/install/"
fi
ok "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"

# Docker Compose (v2 plugin or standalone)
if docker compose version &>/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE="docker-compose"
else
  die "未找到 Docker Compose v2。请升级 Docker 或单独安装 docker-compose-plugin。"
fi
ok "Compose: $($COMPOSE version --short 2>/dev/null || echo 'ok')"

# Port check
if ss -tlnp "sport = :${PORT}" 2>/dev/null | grep -q LISTEN; then
  warn "端口 ${PORT} 已被占用，nginx 可能无法启动。请用 --port 指定其他端口。"
fi

# ── .env setup ───────────────────────────────────────────────────────────────
echo ""
info "配置 .env..."

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo ""
  echo "  ┌─ 必要配置 ────────────────────────────────────┐"
  echo ""

  # Standby agent provider
  read -rp "  LLM Provider (openai/anthropic/custom) [openai]: " PROVIDER
  PROVIDER="${PROVIDER:-openai}"
  sed -i "s|^STANDBY_AGENT_PROVIDER=.*|STANDBY_AGENT_PROVIDER=${PROVIDER}|" .env

  read -rp "  LLM Model [gpt-4o-mini]: " MODEL
  MODEL="${MODEL:-gpt-4o-mini}"
  sed -i "s|^STANDBY_AGENT_MODEL=.*|STANDBY_AGENT_MODEL=${MODEL}|" .env

  echo ""
  read -rp "  是否配置 Web Push 通知 (需要 HTTPS)? [y/N]: " SETUP_PUSH
  if [[ "${SETUP_PUSH,,}" == "y" ]]; then
    if command -v python3 &>/dev/null && python3 -c "import py_vapid" 2>/dev/null; then
      KEYS=$(python3 -c "
from py_vapid import Vapid
v = Vapid()
v.generate_keys()
print(v.private_key())
print(v.public_key())
")
      PRIV=$(echo "$KEYS" | head -1)
      PUB=$(echo "$KEYS" | tail -1)
      sed -i "s|^VAPID_PRIVATE_KEY=.*|VAPID_PRIVATE_KEY=${PRIV}|" .env
      sed -i "s|^VAPID_PUBLIC_KEY=.*|VAPID_PUBLIC_KEY=${PUB}|" .env
      read -rp "  联系邮箱 [admin@example.com]: " MAILTO
      MAILTO="${MAILTO:-admin@example.com}"
      sed -i "s|^VAPID_MAILTO=.*|VAPID_MAILTO=mailto:${MAILTO}|" .env
      ok "VAPID 密钥已生成"
    else
      warn "未找到 py-vapid，跳过 Push 配置。之后可手动编辑 .env"
    fi
  fi

  echo "  └───────────────────────────────────────────────┘"
  echo ""
  ok ".env 已创建"
else
  ok ".env 已存在，跳过交互配置"
fi

# Port
if [[ "$PORT" != "80" ]]; then
  # Patch nginx.conf listen port
  sed -i "s|listen 80;|listen ${PORT};|g" nginx.conf 2>/dev/null || true
fi

# ── DingTalk setup ───────────────────────────────────────────────────────────
if [[ "$SKIP_DINGTALK" == "false" ]]; then
  echo ""
  read -rp "  是否配置钉钉监听? (可选, 需要服务器能运行 Linux 图形应用) [y/N]: " SETUP_DT
  if [[ "${SETUP_DT,,}" == "y" ]]; then
    echo ""
    echo "  钉钉监听说明:"
    echo "  1. 服务器需要安装钉钉 Linux 客户端并完成扫码登录"
    echo "  2. 数据库路径通常为 ~/.config/DingTalk/<账号目录>/DBFiles/dingtalk.db"
    echo "  3. 查看: ls ~/.config/DingTalk/"
    echo ""
    read -rp "  钉钉 DB 路径 [~/.config/DingTalk/…/DBFiles]: " DT_PATH
    if [[ -n "$DT_PATH" ]]; then
      DT_DIR="$(dirname "$DT_PATH")"
      # Patch docker-compose.yml dingtalk volume
      sed -i "s|/root/.config/DingTalk/[^:]*:|${DT_DIR}:|" docker-compose.yml 2>/dev/null || true
      ok "钉钉 DB 路径已更新"
    fi
    warn "完成后请在 Settings → 钉钉 → 消息过滤 配置要监听的群"
  else
    # Comment out dingtalk volume mount if not needed
    warn "跳过钉钉配置。如需后续启用，编辑 docker-compose.yml 取消注释钉钉 volumes"
  fi
fi

# ── Build & start ────────────────────────────────────────────────────────────
echo ""
info "构建并启动容器..."

# Try pull first (fast path if pre-built images exist), fall back to build
if $COMPOSE pull backend frontend 2>/dev/null; then
  ok "已拉取预构建镜像"
  $COMPOSE up -d
else
  info "未找到预构建镜像，从源码构建（首次约 2-5 分钟）..."
  $COMPOSE up -d --build
fi

# ── Wait for health ──────────────────────────────────────────────────────────
echo ""
info "等待服务启动..."
MAX=30; COUNT=0
until curl -sf "http://localhost:${PORT}/api/health" &>/dev/null || [[ $COUNT -ge $MAX ]]; do
  sleep 2; COUNT=$((COUNT+1)); printf "."
done
echo ""

if curl -sf "http://localhost:${PORT}/api/health" &>/dev/null; then
  ok "服务已就绪"
else
  warn "服务可能还在启动，请稍候查看: $COMPOSE logs backend"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}  ✓ 安装完成！${NC}"
echo ""
echo "  访问地址: http://$(hostname -I | awk '{print $1}'):${PORT}"
echo ""
echo "  后续操作:"
echo "    · 在 Settings → Provider 添加 API Key"
echo "    · 在 Settings → 学习通 扫码登录"
[[ "${SETUP_DT,,}" == "y" ]] && echo "    · 在 Settings → 钉钉 → 消息过滤 配置群白名单"
echo ""
echo "  管理命令:"
echo "    查看日志:  $COMPOSE logs -f backend"
echo "    升级:      bash upgrade.sh"
echo "    停止:      $COMPOSE down"
echo ""
