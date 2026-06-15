#!/usr/bin/env bash
# Restore a backup produced by backup.sh onto a fresh install.
#
# Run this AFTER `bash install.sh` has brought the stack up on the new server.
# It swaps in the old database and .env, then recreates the backend so the
# restored ACCESS_TOKEN / VAPID keys take effect. The freshly generated .env is
# kept as .env.fresh.<ts> in case you want to compare.
#
# Usage:   bash server-src/scripts/restore.sh <backup.tgz>
set -euo pipefail

BACKUP="${1:-}"
[ -n "$BACKUP" ] && [ -f "$BACKUP" ] || { echo "usage: bash restore.sh <backup.tgz>"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; cd "$SRC_DIR"
COMPOSE="docker compose"; $COMPOSE version &>/dev/null 2>&1 || COMPOSE="docker-compose"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$BACKUP" -C "$STAGE"
[ -f "$STAGE/chatbot.db" ] || { echo "[✗] backup is missing chatbot.db"; exit 1; }

BACKEND="$($COMPOSE ps -aq backend 2>/dev/null | head -1 || true)"; [ -n "$BACKEND" ] || BACKEND="server-src-backend-1"
VOL="$(docker inspect "$BACKEND" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' 2>/dev/null || true)"
[ -n "$VOL" ] || VOL="server-src_chatbot_data"
echo "[•] target data volume: $VOL"

echo "[•] stopping backend..."
$COMPOSE stop backend >/dev/null 2>&1 || true

if [ -f "$STAGE/.env" ]; then
  [ -f .env ] && cp .env ".env.fresh.$(date +%s)"
  cp "$STAGE/.env" .env
  echo "[•] restored .env (ACCESS_TOKEN + VAPID preserved; new install's .env saved as .env.fresh.*)"
fi

echo "[•] writing database into the volume (drops stale WAL/SHM)..."
docker run --rm -v "$VOL":/data -v "$STAGE":/backup alpine sh -c \
  "rm -f /data/chatbot.db /data/chatbot.db-wal /data/chatbot.db-shm && cp /backup/chatbot.db /data/chatbot.db"

echo "[•] recreating backend so restored .env loads..."
$COMPOSE up -d --force-recreate backend >/dev/null
for _ in $(seq 1 15); do curl -fsS http://localhost/health >/dev/null 2>&1 && break; sleep 2; done
if curl -fsS http://localhost/health >/dev/null 2>&1; then
  echo "[✓] restore complete — backend healthy. 旧的访问令牌已生效，网页和推送无需重新登录。"
else
  echo "[!] backend not healthy yet — check: $COMPOSE logs --tail=80 backend"
fi
