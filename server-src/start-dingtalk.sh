#!/bin/bash
# Wrapper script for launching DingTalk under systemd.
# Sets LD_LIBRARY_PATH to include all .so subdirectories and cd's into the
# DingTalk install dir (required for the binary to find its resources).
DT_DIR="$(dirname "$(ls /opt/apps/com.alibabainc.dingtalk/files/*/com.alibabainc.dingtalk | sort -V | tail -1)")"
export LD_LIBRARY_PATH="$(find "$DT_DIR" -name '*.so' -exec dirname {} \; | sort -u | tr '\n' ':')"
cd "$DT_DIR"
exec ./com.alibabainc.dingtalk --no-sandbox
