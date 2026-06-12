#!/usr/bin/env bash
# Student-Agent v2 upgrade script
# Usage:
#   bash server-src/upgrade.sh
#   bash server-src/upgrade.sh --skip-pull --skip-build
#   bash server-src/upgrade.sh --pull-images
set -euo pipefail

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${BLUE}[•]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[x]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${SCRIPT_DIR}"

SKIP_PULL=false
SKIP_BUILD=false
PULL_IMAGES=false
NO_HEALTHCHECK=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-pull) SKIP_PULL=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --pull-images) PULL_IMAGES=true; shift ;;
    --no-healthcheck) NO_HEALTHCHECK=true; shift ;;
    -h|--help)
      sed -n '1,8p' "$0"
      exit 0
      ;;
    *) warn "未知参数: $1"; shift ;;
  esac
done

command -v docker &>/dev/null || fail "Docker not found"
COMPOSE="docker compose"
$COMPOSE version &>/dev/null 2>&1 || COMPOSE="docker-compose"

echo ""
echo "  Student-Agent v2 升级"
echo "  ─────────────────────────────────────"
echo "  repo: ${REPO_DIR}"
echo "  compose: ${SCRIPT_DIR}/docker-compose.yml"
echo ""

if [[ "$SKIP_PULL" == "false" && -d "${REPO_DIR}/.git" ]]; then
  info "拉取最新代码..."
  BEFORE=$(git -C "${REPO_DIR}" rev-parse --short HEAD)
  git -C "${REPO_DIR}" pull --ff-only
  AFTER=$(git -C "${REPO_DIR}" rev-parse --short HEAD)
  if [[ "$BEFORE" == "$AFTER" ]]; then
    ok "代码已是最新 (${AFTER})"
  else
    ok "代码已更新 ${BEFORE} -> ${AFTER}"
    git -C "${REPO_DIR}" log --oneline "${BEFORE}..${AFTER}" | head -10
  fi
else
  warn "跳过代码拉取"
fi

if [[ "$SKIP_BUILD" == "false" ]]; then
  if [[ "$PULL_IMAGES" == "true" ]]; then
    info "尝试拉取预构建镜像..."
    if $COMPOSE pull --ignore-buildable; then
      ok "镜像拉取完成"
    else
      warn "镜像拉取失败，改为本地构建"
      $COMPOSE build backend frontend
    fi
  else
    info "从当前源码构建 backend/frontend..."
    $COMPOSE build backend frontend
    ok "源码构建完成"
  fi
else
  warn "跳过镜像构建"
fi

info "启动/滚动重启服务..."
$COMPOSE up -d --remove-orphans
ok "容器已启动"

if [[ "$NO_HEALTHCHECK" == "true" ]]; then
  warn "跳过健康检查"
  exit 0
fi

AUTH_HEADER=()
if [[ -f .env ]]; then
  ACCESS_TOKEN_VALUE=$(grep -E '^ACCESS_TOKEN=' .env | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
  if [[ -n "${ACCESS_TOKEN_VALUE:-}" ]]; then
    AUTH_HEADER=(-H "Authorization: Bearer ${ACCESS_TOKEN_VALUE}")
  fi
fi

info "等待 backend 健康检查..."
for _ in {1..30}; do
  if curl -fsS http://localhost/health >/dev/null; then
    ok "/health 正常"
    break
  fi
  sleep 2
done
curl -fsS http://localhost/health >/dev/null || {
  $COMPOSE ps
  $COMPOSE logs --tail=120 backend
  fail "/health 仍不可用"
}

info "验证 dashboard v2 端点..."
curl -fsS "${AUTH_HEADER[@]}" http://localhost/api/dashboard/today >/dev/null || {
  $COMPOSE logs --tail=120 backend
  fail "/api/dashboard/today 验证失败"
}
ok "dashboard v2 正常"

info "当前容器状态"
$COMPOSE ps

echo ""
echo -e "${GREEN}  ✓ 升级完成${NC}"
echo ""
