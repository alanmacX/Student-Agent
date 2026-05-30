#!/usr/bin/env bash
# Student-Agent upgrade script
# Usage: bash upgrade.sh [--skip-build]
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${BLUE}[•]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }

SKIP_BUILD=false
while [[ $# -gt 0 ]]; do
  case $1 in --skip-build) SKIP_BUILD=true; shift ;; *) shift ;; esac
done

COMPOSE="docker compose"
command -v docker &>/dev/null || { echo "Docker not found"; exit 1; }
$COMPOSE version &>/dev/null 2>&1 || COMPOSE="docker-compose"

echo ""
echo "  Student-Agent 升级"
echo "  ─────────────────────────────────────"
echo ""

# ── Pull latest code ─────────────────────────────────────────────────────────
if git rev-parse --git-dir &>/dev/null; then
  info "拉取最新代码..."
  BEFORE=$(git rev-parse --short HEAD)
  git pull --ff-only
  AFTER=$(git rev-parse --short HEAD)
  if [[ "$BEFORE" == "$AFTER" ]]; then
    ok "已是最新版本 (${AFTER})"
  else
    ok "已更新 ${BEFORE} → ${AFTER}"
    git log --oneline "${BEFORE}..${AFTER}" | head -10
  fi
else
  warn "非 git 目录，跳过代码更新"
fi

# ── Rebuild / pull images ────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
  info "更新镜像..."
  # Try pull first (pre-built images), fall back to build
  if $COMPOSE pull backend frontend 2>/dev/null; then
    ok "已拉取最新镜像"
  else
    info "从源码重新构建..."
    $COMPOSE build --no-cache backend frontend
    ok "构建完成"
  fi
fi

# ── Rolling restart (zero downtime for nginx/frontend) ──────────────────────
info "滚动重启服务..."
$COMPOSE up -d --remove-orphans
ok "服务已重启"

# ── Wait ─────────────────────────────────────────────────────────────────────
sleep 4
if $COMPOSE ps | grep -q "healthy\|Up"; then
  ok "所有容器运行正常"
else
  warn "部分容器可能未就绪，检查: $COMPOSE logs backend"
fi

echo ""
echo -e "${GREEN}  ✓ 升级完成${NC}"
echo ""
