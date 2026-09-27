#!/bin/bash
# =============================================================================
# omr-vps-deploy / verify.sh
#
# 只验收、不改动系统。可以随时重复跑（装前装后、出问题时）。
#
#   bash verify.sh
#
# 它是 deploy.sh --verify 的薄封装：本地有 deploy.sh 就用本地的，
# 没有（比如单独 curl 这个文件）就临时拉一份官方仓库里的 deploy.sh。
# 验收项的唯一实现在 deploy.sh 的 verify()，这里不重复维护第二份。
# =============================================================================
set -uo pipefail

RAW_BASE="https://raw.githubusercontent.com/Sharkecho/omr-vps-deploy/main"

SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/deploy.sh" ]; then
    exec bash "$SELF_DIR/deploy.sh" --verify
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "[verify] 本地没有 deploy.sh，从 $RAW_BASE 取一份到 $TMP"
if ! curl -fsSL -m 90 -o "$TMP/deploy.sh" "$RAW_BASE/deploy.sh"; then
    echo "[verify] 拉取失败：检查这台机器能否访问 raw.githubusercontent.com" >&2
    exit 1
fi
exec bash "$TMP/deploy.sh" --verify
