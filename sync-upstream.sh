#!/bin/bash
# 仓库根目录快捷入口：同步官方 openwrt_main 并应用 neomikanagi 定制
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
exec "${ROOT}/config/openwrt_main/sync-from-upstream.sh" "$@"
