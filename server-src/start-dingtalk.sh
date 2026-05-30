#!/bin/bash
# Wrapper script for launching DingTalk under systemd.
# Uses a separate lib directory with only DingTalk-specific libraries to avoid
# conflicts with system libs (libcrypto, libm, etc.).
DT_BIN="$(find /opt/apps/com.alibabainc.dingtalk/files -name com.alibabainc.dingtalk -type f | sort -V | tail -1)"
DT_DIR="$(dirname "$DT_BIN")"
export LD_LIBRARY_PATH="/opt/dingtalk-libs"
cd "$DT_DIR"
exec ./com.alibabainc.dingtalk --no-sandbox
