#!/bin/bash
# 将 A/B 系统根分区与 USB 镜像根分区统一为极简尺寸（全局，所有 SoC）
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PREFS="${ROOT_DIR}/config/openwrt_main/build-preferences.env"
# shellcheck source=/dev/null
source "${PREFS}"

ROOT_MB="${EMMC_ROOT_MB:-650}"
MIN_ROOT_MB="${MIN_ROOT_MB:-512}"

echo "[partition] 系统根分区目标: ${ROOT_MB} MiB（A/B 各 ${ROOT_MB}MB）"

# USB/TF 打包镜像（remake）
REMAKE="${ROOT_DIR}/remake"
if [[ -f "${REMAKE}" ]]; then
    sed -i "s/^root_mb=\"[0-9]*\"/root_mb=\"${ROOT_MB}\"/" "${REMAKE}"
    sed -i "s/root_mb >= [0-9]*/root_mb >= ${MIN_ROOT_MB}/" "${REMAKE}"
    sed -i "s/-ge 1024 ]] || error_msg \"Invalid rootfs/-ge ${MIN_ROOT_MB} ]] || error_msg \"Invalid rootfs/" "${REMAKE}"
fi

# U 盘扩容时第三分区（备用 ROOTFS2）
TF="${ROOT_DIR}/make-openwrt/openwrt-files/common-files/usr/sbin/openwrt-tf"
if [[ -f "${TF}" ]]; then
    sed -i "s/^    ROOTFS_MB=\"[0-9]*\"/    ROOTFS_MB=\"${ROOT_MB}\"/" "${TF}"
fi

# Allwinner EMMC 安装
AW="${ROOT_DIR}/make-openwrt/openwrt-files/common-files/usr/sbin/openwrt-install-allwinner"
if [[ -f "${AW}" ]]; then
    sed -i "s/^    ROOT1=\"[0-9]*\"/    ROOT1=\"${ROOT_MB}\"/" "${AW}"
    sed -i "s/^    ROOT2=\"[0-9]*\"/    ROOT2=\"${ROOT_MB}\"/" "${AW}"
fi
