#!/usr/bin/env bash
#========================================================================================
# This fork's own edits of the OpenWrt source tree, run AFTER upstream's
# config/openwrt_main/diy-part2.sh (so upstream's script stays untouched and keeps
# following upstream).
#
#   cd <openwrt source dir> && diy-part3.sh
#
# The edits of the rootfs files (installer, openwrt-tf, ...) are in stage-rootfs-files.sh.
#========================================================================================
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------- packages ---
# HomeProxy is not in the OpenWrt feeds; it lives in its own repo.
rm -rf package/homeproxy
git clone -q --depth=1 https://github.com/immortalwrt/homeproxy.git package/homeproxy

# luci-app-dockerman depends on ttyd (container console). ttyd is removed from this fork, so
# drop the dependency; everything else of dockerman works, only the console button does not.
DM="feeds/luci/applications/luci-app-dockerman/Makefile"
[[ -f "${DM}" ]] || die "${DM} not found (feeds not installed?)"
sed -i -E '/^[[:space:]]*\+ttyd[[:space:]]*\\?[[:space:]]*$/d' "${DM}"
! grep -qE '\+ttyd' "${DM}" || die "could not remove the ttyd dependency from ${DM}"

# --------------------------------------------------------- base-files tweaks ---
CFG="package/base-files/files/bin/config_generate"
# NTP pool -> reachable public servers
sedx "${CFG}" 's/0\.openwrt\.pool\.ntp\.org/time.windows.com/' time.windows.com
sedx "${CFG}" 's/1\.openwrt\.pool\.ntp\.org/time.apple.com/' time.apple.com
sedx "${CFG}" 's/2\.openwrt\.pool\.ntp\.org/time.google.com/' time.google.com
sedx "${CFG}" 's/3\.openwrt\.pool\.ntp\.org/time.cloudflare.com/' time.cloudflare.com

# ------------------------------------------------ luci-app-amlogic (single rootfs) ---
# The data partition is p3 now (there is no second rootfs), upstream says p4 everywhere.
# (upstream's diy-part2.sh cloned the package into package/luci-app-amlogic)
LA="package/luci-app-amlogic"
[[ -d "${LA}/luci-app-amlogic/root" ]] || {
    rm -rf "${LA}"
    git clone -q -b main --depth=1 https://github.com/ophub/luci-app-amlogic.git "${LA}"
}
LAR="${LA}/luci-app-amlogic"
sedx "${LAR}/root/usr/share/rpcd/acl.d/luci-app-amlogic.json" 's#/mnt/mmcblk\*p4/#/mnt/mmcblk*p3/#' '/mnt/mmcblk*p3/' '/mnt/mmcblk*p4/'
sedx "${LAR}/root/usr/share/rpcd/ucode/luci.amlogic" "s#'p4/'#'p3/'#" "'p3/'" "'p4/'"
sedx "${LAR}/htdocs/luci-static/resources/view/amlogic/config.js" 's#\(/mnt/mmcblk\*p4\)#(/mnt/mmcblk*p3)#' '(/mnt/mmcblk*p3)' '/mnt/mmcblk*p4'

echo "diy-part3: done"
