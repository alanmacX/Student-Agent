#!/usr/bin/env bash
# One-command data export for server migration.
#
# Produces a single tarball containing the SQLite database and .env. Shipping
# .env along means ACCESS_TOKEN and the VAPID push keys carry over, so existing
# web clients stay logged in and push subscriptions keep working on the new box.
#
# Usage:   bash server-src/scripts/backup.sh [output_dir]
# Then:    scp the printed .tgz to the new server and run restore.sh there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # server-src
cd "$SRC_DIR"

OUT_DIR="${1:-$PWD}"
TS="$(date +%Y%m%d-%H%M%S)"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT

COMPOSE="docker compose"; $COMPOSE version &>/dev/null 2>&1 || COMPOSE="docker-compose"
BACKEND="$($COMPOSE ps -aq backend 2>/dev/null | head -1 || true)"; [ -n "$BACKEND" ] || BACKEND="server-src-backend-1"

echo "[•] checkpointing WAL (flush recent writes into the main db file)..."
docker exec "$BACKEND" python -c "import sqlite3;c=sqlite3.connect('/data/chatbot.db');c.execute('PRAGMA wal_checkpoint(TRUNCATE)');c.close()" 2>/dev/null \
  && echo "    ok" || echo "    (backend not running — copying db as-is)"

echo "[•] copying database..."
docker cp "$BACKEND:/data/chatbot.db" "$STAGE/chatbot.db"

if [ -f .env ]; then cp .env "$STAGE/.env"; echo "[•] included .env (token + push keys)"; else echo "[!] no .env found — skipping"; fi

OUT="$OUT_DIR/student-agent-backup-$TS.tgz"
tar -czf "$OUT" -C "$STAGE" .
echo "[✓] backup written: $OUT  ($(du -h "$OUT" | cut -f1))"
echo
echo "  下一步（迁移到新服务器）:"
echo "    scp \"$OUT\" newserver:/tmp/"
echo "    # 新服务器: git clone → bash install.sh → 然后:"
echo "    bash server-src/scripts/restore.sh /tmp/$(basename "$OUT")"
