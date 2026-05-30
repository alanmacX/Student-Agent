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
SETUP_DT="n"
if [[ "$SKIP_DINGTALK" == "false" ]]; then
  echo ""
  read -rp "  是否启用钉钉消息监听? (可选) [y/N]: " SETUP_DT
fi

if [[ "${SETUP_DT,,}" == "y" ]]; then
  echo ""
  info "配置钉钉监听..."

  # ── 1. 依赖 ──────────────────────────────────────────────────────────────
  info "安装系统依赖 (Xvfb, ImageMagick)..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y -q xvfb x11-utils x11-apps imagemagick \
      libgtk-3-0 libnss3 libxss1 libasound2 libgbm1 2>/dev/null | tail -1
  elif command -v yum &>/dev/null; then
    yum install -y -q xorg-x11-server-Xvfb ImageMagick \
      xorg-x11-apps gtk3 nss alsa-lib 2>/dev/null | tail -1
  else
    warn "未知包管理器，请手动安装: xvfb x11-apps imagemagick"
  fi
  ok "系统依赖安装完成"

  # ── 2. 启动 Xvfb ─────────────────────────────────────────────────────────
  if ! pgrep -x Xvfb &>/dev/null; then
    info "启动 Xvfb 虚拟显示器 :99..."
    Xvfb :99 -screen 0 1280x800x24 -ac &
    sleep 2
    ok "Xvfb 已启动 (DISPLAY=:99)"
  else
    ok "Xvfb 已在运行"
  fi

  # ── 3. 安装钉钉 Linux 客户端 ──────────────────────────────────────────────
  DT_BIN=$(ls /opt/apps/com.alibabainc.dingtalk/files/*/com.alibabainc.dingtalk 2>/dev/null | sort -V | tail -1)
  if [[ -z "$DT_BIN" ]]; then
    info "下载钉钉 Linux 客户端..."
    DT_URL="https://dtapp-pub.dingtalk.com/dingtalk-desktop/xc_dingtalk_update/linux_deb/Release/com.alibabainc.dingtalk_7.6.55-Release.2410312_amd64.deb"
    DT_DEB="/tmp/dingtalk.deb"
    if command -v wget &>/dev/null; then
      wget -q --show-progress -O "$DT_DEB" "$DT_URL" || { warn "下载失败，请手动安装钉钉"; }
    else
      curl -fL -o "$DT_DEB" "$DT_URL" || { warn "下载失败，请手动安装钉钉"; }
    fi
    if [[ -f "$DT_DEB" ]]; then
      dpkg -i "$DT_DEB" 2>/dev/null || apt-get install -f -y -q
      DT_BIN=$(ls /opt/apps/com.alibabainc.dingtalk/files/*/com.alibabainc.dingtalk 2>/dev/null | sort -V | tail -1)
      ok "钉钉已安装: $DT_BIN"
    fi
  else
    ok "钉钉已安装: $DT_BIN"
  fi

  # ── 4. 启动钉钉 ───────────────────────────────────────────────────────────
  if [[ -n "$DT_BIN" ]] && ! pgrep -f com.alibabainc.dingtalk &>/dev/null; then
    info "启动钉钉..."
    DISPLAY=:99 "$DT_BIN" --no-sandbox &>/dev/null &
    sleep 3
    ok "钉钉已启动"
  elif pgrep -f com.alibabainc.dingtalk &>/dev/null; then
    ok "钉钉已在运行"
  fi

  # ── 5. 启动截图辅助服务 (QR server) ──────────────────────────────────────
  if ! ss -tlnp 2>/dev/null | grep -q ':7777'; then
    info "启动截图辅助服务 (port 7777)..."
    DISPLAY=:99 python3 "$(dirname "$0")/dingtalk_qr_server.py" &>/tmp/dingtalk_qr.log &
    sleep 1
    if ss -tlnp 2>/dev/null | grep -q ':7777'; then
      ok "截图服务已启动"
    else
      warn "截图服务启动失败，请查看 /tmp/dingtalk_qr.log"
    fi
  else
    ok "截图服务已在运行"
  fi

  # ── 6. 安装 systemd 服务（持久化重启）────────────────────────────────────
  SYSTEMD_DIR="$(dirname "$0")/systemd"
  if command -v systemctl &>/dev/null && [[ -d "$SYSTEMD_DIR" ]]; then
    for svc in dingtalk-xvfb dingtalk dingtalk-qr; do
      cp "$SYSTEMD_DIR/${svc}.service" /etc/systemd/system/ 2>/dev/null && \
        systemctl enable "$svc" &>/dev/null && \
        ok "systemd: $svc 已注册"
    done
    systemctl daemon-reload
  fi

  echo ""
  echo -e "  ${GREEN}✓ 钉钉已就绪${NC}"
  echo "    打开 Settings → 钉钉 → 点「扫码登录」，"
  echo "    用手机钉钉扫描页面上的二维码即可完成登录。"
  echo ""
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
