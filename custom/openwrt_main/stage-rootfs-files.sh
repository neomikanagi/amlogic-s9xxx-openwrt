#!/usr/bin/env bash
#========================================================================================
# Prepare the files that the packaging step (remake) puts over the OpenWrt rootfs.
#
#   stage-rootfs-files.sh <repo root> <luci-app-amlogic checkout>
#
# remake copies luci-app-amlogic's scripts from a fresh clone with "--update=none", i.e. a
# file that already exists in make-openwrt/openwrt-files/common-files wins. So this script
#   * stages patched copies of upstream's scripts into custom/rootfs-files (the
#     `openwrt_files` input of the packaging step), and
#   * patches upstream's own files inside this checkout (build copy only, never committed).
# Every patch/edit is asserted: when upstream moved on, the build stops here.
#========================================================================================
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="$(cd "${1:?usage: stage-rootfs-files.sh <repo root> <luci-app-amlogic dir>}" && pwd)"
LAR="$(cd "${2:?usage: stage-rootfs-files.sh <repo root> <luci-app-amlogic dir>}" && pwd)"
OUT="${REPO}/custom/rootfs-files"
COMMON="${REPO}/make-openwrt/openwrt-files/common-files"
GH_REPO="${GITHUB_REPOSITORY:-neomikanagi/amlogic-s9xxx-openwrt}"

[[ -d "${LAR}/root/usr/sbin" ]] || die "${LAR} is not the luci-app-amlogic package directory"

mkdir -p "${OUT}/usr/sbin" "${OUT}/usr/share/amlogic"
for f in openwrt-backup openwrt-kernel openwrt-install-amlogic; do
    cp -f "${LAR}/root/usr/sbin/${f}" "${OUT}/usr/sbin/${f}"
done
for f in amlogic_check_firmware.sh amlogic_check_kernel.sh amlogic_check_plugin.sh; do
    cp -f "${LAR}/root/usr/share/amlogic/${f}" "${OUT}/usr/share/amlogic/${f}"
done

# the data partition is p3 now (no second rootfs); upstream says p4
for f in usr/sbin/openwrt-backup usr/sbin/openwrt-kernel usr/share/amlogic/amlogic_check_firmware.sh usr/share/amlogic/amlogic_check_kernel.sh; do
    sedx "${OUT}/${f}" 's#(\$\{EMMC_NAME\}\$\{PARTITION_NAME\})4#\13#g' '${PARTITION_NAME}3' '${PARTITION_NAME}4'
done
patch -p1 -d "${OUT}" <"${REPO}/custom/patches/openwrt-install-amlogic.patch" ||
    die "custom/patches/openwrt-install-amlogic.patch no longer applies to upstream's installer: re-base it"

# updates go through sysupgrade: one wrapper (committed as openwrt-update-amlogic) under all four names luci-app-amlogic may call
for p in rockchip allwinner kvm; do
    cp -f "${OUT}/usr/sbin/openwrt-update-amlogic" "${OUT}/usr/sbin/openwrt-update-${p}"
done
chmod +x "${OUT}"/usr/sbin/openwrt-* "${OUT}"/usr/share/amlogic/*.sh

# upstream files that live in this repository (patched in the build checkout only)
patch -p1 -d "${COMMON}" <"${REPO}/custom/patches/openwrt-tf.patch" ||
    die "custom/patches/openwrt-tf.patch no longer applies to upstream's openwrt-tf: re-base it"
sedx "${COMMON}/etc/custom_service/start_service.sh" 's#(\$\{PARTITION_NAME\})4"#\13"#' '${PARTITION_NAME}3"' '${PARTITION_NAME}4"'
sedx "${COMMON}/etc/profile.d/30-sysinfo.sh" 's#(\$\{PARTITION_NAME\})4"#\13"#; s#(\$\{mmc_name\}p)4"#\13"#' '${mmc_name}p3"' '${mmc_name}p4"'
sedx "${COMMON}/usr/sbin/openwrt-swap" 's#(\$\{PARTITION_NAME\})4"#\13"#' '${PARTITION_NAME}3"' '${PARTITION_NAME}4"'
# luci-app-amlogic "Online Update" must look at this fork's releases
sedx "${COMMON}/etc/config/amlogic" "s#option amlogic_firmware_repo .*#option amlogic_firmware_repo 'https://github.com/${GH_REPO}'#" "github.com/${GH_REPO}'"

echo "stage-rootfs-files: done (repo ${GH_REPO})"
