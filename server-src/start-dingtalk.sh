#!/bin/bash
# Wrapper script for launching DingTalk under systemd.
# DingTalk 8.x bundles its own Qt/CEF libs across subdirectories; we add all of
# them to LD_LIBRARY_PATH so the dynamic linker finds libcef.so, libdtfbase.so,
# etc.  We no longer delete system libs (libm, libc) — 8.x needs them.
DT_BIN="$(find /opt/apps/com.alibabainc.dingtalk/files -name com.alibabainc.dingtalk -type f | sort -V | tail -1)"
DT_DIR="$(dirname "$DT_BIN")"
LIB_PATHS="$(find "$DT_DIR" -name '*.so' -printf '%h\n' | sort -u | tr '\n' ':')"
export LD_LIBRARY_PATH="${LIB_PATHS}${DT_DIR}"
cd "$DT_DIR"
exec ./com.alibabainc.dingtalk --no-sandbox --disable-gpu
