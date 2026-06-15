#!/usr/bin/env bash
# Restrict the DingTalk QR screenshot helper (binds 0.0.0.0:7777, no auth, can
# drive the desktop via xdotool) to the Docker bridge + localhost only. The
# backend reaches it through host.docker.internal, so container traffic (source
# in the 172.16.0.0/12 bridge range) must pass; everything else is dropped.
#
# Idempotent: safe to re-run. Wired into dingtalk-qr.service via an ExecStartPre
# drop-in so it re-applies on every (re)start, including at boot.
set -euo pipefail
PORT=7777
BRIDGE=172.16.0.0/12   # covers Docker's 172.18.x / 172.19.x networks
LOCAL=127.0.0.0/8

# Drop any prior copies of our exact rules so re-runs don't stack duplicates.
for spec in \
  "-p tcp --dport $PORT -s $LOCAL -j ACCEPT" \
  "-p tcp --dport $PORT -s $BRIDGE -j ACCEPT" \
  "-p tcp --dport $PORT -j DROP"; do
  while iptables -C INPUT $spec 2>/dev/null; do iptables -D INPUT $spec; done
done

# Re-insert at the top of INPUT in priority order (last insert ends up first):
# 1) localhost ACCEPT  2) docker bridge ACCEPT  3) DROP everything else.
iptables -I INPUT 1 -p tcp --dport "$PORT" -j DROP
iptables -I INPUT 1 -p tcp --dport "$PORT" -s "$BRIDGE" -j ACCEPT
iptables -I INPUT 1 -p tcp --dport "$PORT" -s "$LOCAL" -j ACCEPT

echo "qr-firewall: port $PORT restricted to $LOCAL + $BRIDGE"
