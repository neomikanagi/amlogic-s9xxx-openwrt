#!/usr/bin/env bash
#
# Look inside a finished image before it is released.
#
#   sudo verify-image.sh <openwrt_*-sysupgrade.img.gz> [packages.check]
#
# Checks (any failure = non-zero exit, the release is not published):
#   * the gzip header carries openwrt_<src>_<platform>_<board>_k<kernel>_<date>.img
#     (lib/upgrade/platform.sh reads the board from it before it flashes anything)
#   * exactly two partitions: p1 boot (fat32 / ext4) and p2 rootfs (btrfs); nothing else, so a
#     sysupgrade is nothing but "write p1 and p2"
#   * the rootfs: no ttyd / samba / frp ..., docker + HomeProxy there, the patched installer,
#     openwrt-tf and sysupgrade hooks, /etc is a btrfs subvolume with its pristine snapshot
#   * the boot partition has kernel, initrd, dtb and a boot config pointing at p2's UUID
set -uo pipefail

IMG="${1:?usage: verify-image.sh <image.img.gz> [packages.check]}"
CHECK="${2:-}"
WORK="${VERIFY_TMP:-/builder/verify}"
[[ -d /builder ]] || WORK="${VERIFY_TMP:-/tmp/verify}"

rc=0
fail() {
    echo "::error::verify-image: $*"
    rc=1
}
note() { echo "  - $*"; }

loop=""
M1="${WORK}/boot"
M2="${WORK}/root"
cleanup() {
    umount "${M1}" 2>/dev/null
    umount "${M2}" 2>/dev/null
    [[ -n "${loop}" ]] && losetup -d "${loop}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT
mkdir -p "${M1}" "${M2}"

echo "== verify ${IMG##*/}"

# ---- 1. the board name in the gzip header ------------------------------------------------
magic="$(dd if="${IMG}" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
[[ "${magic}" == "1f8b" ]] || { fail "not a gzip file"; exit 1; }
flg="$(dd if="${IMG}" bs=1 skip=3 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')"
name=""
if [[ $((flg & 8)) -ne 0 && $((flg & 4)) -eq 0 ]]; then
    name="$(dd if="${IMG}" bs=1 skip=10 count=255 2>/dev/null | tr '\000' '\n' | head -n 1)"
fi
if [[ "${name}" =~ ^openwrt_([a-z0-9]+_)?(amlogic|rockchip|allwinner)_(.+)_k([0-9]+\.[0-9]+\.[0-9]+)_([0-9.]+)\.img$ ]]; then
    PLATFORM="${BASH_REMATCH[2]}"
    BOARD="${BASH_REMATCH[3]}"
    KVER="${BASH_REMATCH[4]}"
    note "gzip header name: ${name}  (platform ${PLATFORM}, board ${BOARD}, kernel ${KVER})"
else
    fail "gzip header has no usable file name ('${name}'): sysupgrade could not tell which board this is for"
    exit 1
fi

# ---- 2. unpack, partitions -----------------------------------------------------------------
RAW="${WORK}/image.raw"
gzip -dc "${IMG}" >"${RAW}" 2>/dev/null
[[ -s "${RAW}" ]] || { fail "cannot decompress the image"; exit 1; }
loop="$(losetup -f --show -P "${RAW}")" || { fail "losetup failed"; exit 1; }
udevadm settle 2>/dev/null || sleep 2
parts="$(ls "${loop}"p* 2>/dev/null | wc -l)"
if [[ "${parts}" -ne 2 ]]; then fail "expected exactly 2 partitions, found ${parts}"; fi
note "image $(du -h --apparent-size "${RAW}" | cut -f1) raw, $(du -h "${IMG}" | cut -f1) gzipped; partitions: $(lsblk -n -o NAME,SIZE,FSTYPE "${loop}" | tail -n +2 | awk '{printf "%s %s %s; ", $1, $2, $3}')"

t1="$(blkid -o value -s TYPE "${loop}p1" 2>/dev/null)"
t2="$(blkid -o value -s TYPE "${loop}p2" 2>/dev/null)"
case "${PLATFORM}:${t1}" in
rockchip:ext4 | amlogic:vfat | allwinner:vfat) ;;
*) fail "boot partition is ${t1} on ${PLATFORM}" ;;
esac
[[ "${t2}" == "btrfs" ]] || fail "rootfs partition is '${t2}', expected btrfs"
UUID2="$(blkid -o value -s UUID "${loop}p2")"

# ---- 3. rootfs -----------------------------------------------------------------------------
mount -t btrfs -o ro,compress=zstd "${loop}p2" "${M2}" || { fail "cannot mount the rootfs"; exit 1; }
R="${M2}"
need_file() { [[ -e "${R}/$1" || -L "${R}/$1" ]] || fail "missing in rootfs: /$1"; }
need_text() { grep -qF -- "$2" "${R}/$1" 2>/dev/null || fail "/$1 does not contain '$2'"; }
no_text() { ! grep -qF -- "$2" "${R}/$1" 2>/dev/null || fail "/$1 still contains '$2'"; }

# packages: the apk database is the truth about what is inside
DB="${R}/lib/apk/db/installed"
if [[ -f "${DB}" ]]; then
    installed="$(sed -n 's/^P://p' "${DB}" | sort -u)"
    note "$(wc -l <<<"${installed}") packages installed"
    if [[ -n "${CHECK}" && -f "${CHECK}" ]]; then
        while read -r verb pkgs; do
            case "${verb}" in
            forbid) for p in ${pkgs}; do grep -qxF "${p}" <<<"${installed}" && fail "package ${p} is installed but must not be"; done ;;
            require) for p in ${pkgs}; do grep -qxF "${p}" <<<"${installed}" || fail "package ${p} is not installed"; done ;;
            esac
        done < <(grep -vE '^\s*(#|$)' "${CHECK}")
    fi
else
    fail "no apk database at /lib/apk/db/installed"
fi

for f in usr/bin/dockerd usr/bin/docker usr/bin/sing-box etc/init.d/dockerd etc/config/homeproxy \
    lib/upgrade/platform.sh etc/init.d/ophub-resize etc/rc.d/S99ophub-resize etc/sysctl.d/12-ophub.conf \
    etc/uci-defaults/99-ophub-defaults lib/upgrade/keep.d/ophub \
    usr/sbin/openwrt-install-amlogic usr/sbin/openwrt-tf usr/sbin/openwrt-update-amlogic \
    usr/sbin/openwrt-update-rockchip usr/sbin/openwrt-kernel usr/sbin/openwrt-backup \
    usr/sbin/mkfs.btrfs sbin/btrfs usr/sbin/fatlabel etc/init.d/zram; do
    # btrfs lives in /usr/bin or /sbin depending on the packaging, accept either
    if [[ "${f}" == "sbin/btrfs" ]]; then
        [[ -e "${R}/sbin/btrfs" || -e "${R}/usr/sbin/btrfs" || -e "${R}/usr/bin/btrfs" ]] || fail "missing in rootfs: btrfs"
    elif [[ "${f}" == "usr/sbin/mkfs.btrfs" ]]; then
        [[ -e "${R}/usr/sbin/mkfs.btrfs" || -e "${R}/sbin/mkfs.btrfs" || -e "${R}/usr/bin/mkfs.btrfs" ]] || fail "missing in rootfs: mkfs.btrfs"
    elif [[ "${f}" == "usr/sbin/fatlabel" ]]; then
        [[ -e "${R}/usr/sbin/fatlabel" || -e "${R}/sbin/fatlabel" || -e "${R}/usr/bin/fatlabel" ]] || fail "missing in rootfs: fatlabel"
    else
        need_file "${f}"
    fi
done
ls "${R}"/etc/modules.d/ 2>/dev/null | grep -qi 'bbr' || fail "no tcp_bbr autoload in /etc/modules.d"
ls "${R}"/etc/modules.d/ 2>/dev/null | grep -qi 'zram' || fail "no zram autoload in /etc/modules.d"
ls -d "${R}"/lib/modules/*/ >/dev/null 2>&1 || fail "no kernel modules in /lib/modules"

# this fork's patches really landed
need_text usr/sbin/openwrt-install-amlogic 'Partition plan'
no_text usr/sbin/openwrt-install-amlogic 'ROOTFS2'
no_text usr/sbin/openwrt-install-amlogic '}p4'
no_text usr/sbin/openwrt-tf 'ROOTFS2'
no_text usr/sbin/openwrt-tf '}4'
need_text usr/sbin/openwrt-update-amlogic 'sysupgrade'
need_text lib/upgrade/platform.sh 'ophub_fix_rootfs'
need_text usr/share/rpcd/ucode/luci.amlogic "'p3/'"
no_text usr/share/rpcd/ucode/luci.amlogic "'p4/'"
need_text usr/share/amlogic/amlogic_check_firmware.sh '${PARTITION_NAME}3'
need_text etc/config/amlogic "github.com/${GITHUB_REPOSITORY:-neomikanagi/amlogic-s9xxx-openwrt}"
need_text etc/config/amlogic "_openwrt_main_"
need_text etc/sysctl.d/12-ophub.conf 'tcp_congestion_control=bbr'
[[ -x "${R}/etc/init.d/ophub-resize" ]] || fail "ophub-resize is not executable"
[[ -x "${R}/etc/uci-defaults/99-ophub-defaults" ]] || fail "99-ophub-defaults is not executable"

# release info written by remake
REL="${R}/etc/ophub-release"
[[ -f "${REL}" ]] || REL="${R}/etc/flippy-openwrt-release"
if [[ -f "${REL}" ]]; then
    grep -qxF "BOARD='${BOARD}'" "${REL}" || fail "${REL##*/}: BOARD is not ${BOARD}"
    grep -qxF "PLATFORM='${PLATFORM}'" "${REL}" || fail "${REL##*/}: PLATFORM is not ${PLATFORM}"
else
    fail "no /etc/ophub-release"
fi

# /etc is a subvolume and has its pristine snapshot (firstboot resets from it)
if command -v btrfs >/dev/null 2>&1; then
    sv="$(btrfs subvolume list "${R}" 2>/dev/null)"
    grep -qE ' path etc$' <<<"${sv}" || fail "etc is not a btrfs subvolume"
    grep -qE ' path \.snapshots/etc-000$' <<<"${sv}" || fail "no .snapshots/etc-000"
fi
fs_used="$(btrfs filesystem usage -b "${R}" 2>/dev/null | awk '/^ *Used:/ {print int($2/1048576)}' | head -n1)"
note "rootfs: ${fs_used:-?} MiB used (compressed) on a $(($(blockdev --getsize64 "${loop}p2") / 1048576)) MiB partition"

# fstab: root by UUID of p2, /boot by label
need_text etc/fstab "UUID=${UUID2}"
need_text etc/fstab 'LABEL=BOOT'

# ---- 4. boot partition ---------------------------------------------------------------------
umount "${M2}"
mount -o ro "${loop}p1" "${M1}" || { fail "cannot mount the boot partition"; exit 1; }
B="${M1}"
ls "${B}"/zImage "${B}"/Image 2>/dev/null | grep -q . || fail "no kernel image (zImage/Image) in the boot partition"
[[ -e "${B}/uInitrd" ]] || fail "no uInitrd in the boot partition"
[[ -d "${B}/dtb" ]] || fail "no dtb directory in the boot partition"
cfg=""
for c in uEnv.txt extlinux/extlinux.conf armbianEnv.txt; do
    [[ -f "${B}/${c}" ]] && cfg="${cfg} ${c}"
done
[[ -n "${cfg}" ]] || fail "no boot configuration (uEnv.txt / extlinux.conf / armbianEnv.txt)"
for c in ${cfg}; do
    grep -qF "${UUID2}" "${B}/${c}" || fail "${c} does not point at the rootfs UUID ${UUID2}"
done
if [[ "${PLATFORM}" == "amlogic" ]]; then
    ls "${B}"/boot-emmc.* >/dev/null 2>&1 || fail "no boot-emmc.* scripts (the sysupgrade converts them for eMMC)"
fi
note "boot: $(du -sm "${B}" | cut -f1) MiB used; config:${cfg}"

[[ "${rc}" -eq 0 ]] && echo "== OK ${IMG##*/}"
exit "${rc}"
