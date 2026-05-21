#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PREFS="${ROOT_DIR}/config/openwrt_main/build-preferences.env"
WORKFLOW="${ROOT_DIR}/.github/workflows/build-openwrt-system-image.yml"

# shellcheck source=/dev/null
source "${PREFS}"

[[ -f "${WORKFLOW}" ]] || exit 0

# 仅改 workflow_dispatch 各 input 的 default 行（在对应 input 块内）
patch_default() {
    local name="$1" value="$2"
    awk -v name="${name}" -v val="\"${value}\"" '
        $0 ~ "^      " name ":" { inblock=1 }
        inblock && /^      [a-z_]+:/ && $0 !~ "^      " name ":" { inblock=0 }
        inblock && /^        default:/ { sub(/default: .*/, "default: " val); inblock=0 }
        { print }
    ' "${WORKFLOW}" >"${WORKFLOW}.tmp" && mv "${WORKFLOW}.tmp" "${WORKFLOW}"
}

patch_default "source_branch" "${WORKFLOW_SOURCE_BRANCH_DEFAULT}"
patch_default "openwrt_board" "${WORKFLOW_OPENWRT_BOARD_DEFAULT}"
patch_default "openwrt_kernel" "${WORKFLOW_OPENWRT_KERNEL_DEFAULT}"
patch_default "kernel_usage" "${WORKFLOW_KERNEL_USAGE_DEFAULT}"
patch_default "openwrt_ip" "${WORKFLOW_OPENWRT_IP_DEFAULT}"

echo "[prefs] 已更新 ${WORKFLOW}"
