#!/usr/bin/env bash
#
# Run the sysupgrade logic (files/lib/upgrade/platform.sh) against a real image on loop
# devices, with busybox as the shell and as the tools, i.e. the way it runs in sysupgrade's
# ramfs. Needs root, loop devices and: losetup sfdisk mkfs.btrfs mkfs.fat fatlabel btrfs
# blkid mkfs.ext4 uuidgen tar and a (static) busybox.
#
#   sudo test-upgrade.sh <openwrt_*.img.gz> [busybox] [openwrt common.sh]
#
# It builds a fake eMMC disk the way openwrt-install-amlogic leaves it (p1 EMMC_BOOT, p2 btrfs
# with its own UUID, p3 data), puts a user configuration on it, flashes the image over it and
# checks what a box would see on its next boot.
set -uo pipefail

IMG="${1:?usage: test-upgrade.sh <image.img.gz> [busybox] [common.sh]}"
BB="${2:-${BUSYBOX:-$(command -v busybox || true)}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_SH="${HERE}/../../files/lib/upgrade/platform.sh"
COMMON_SH="${3:-${COMMON_SH:-}}"
[[ -x "${BB}" ]] || { echo "need busybox (arg 2 or \$BUSYBOX)"; exit 2; }
if [[ -z "${COMMON_SH}" || ! -f "${COMMON_SH}" ]]; then
    COMMON_SH="/tmp/openwrt-common.sh"
    curl -fsSL https://raw.githubusercontent.com/openwrt/openwrt/main/package/base-files/files/lib/upgrade/common.sh -o "${COMMON_SH}" ||
        { echo "need OpenWrt's package/base-files/files/lib/upgrade/common.sh (arg 3)"; exit 2; }
fi

W="$(mktemp -d /tmp/upgtest.XXXXXX)"
IL=""
DL=""
fails=0
ok() { echo "  ok    $*"; }
bad() {
    echo "  FAIL  $*"
    fails=$((fails + 1))
}
check() { # check <description> <command...>
    local d="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "${d}"; else bad "${d}"; fi
}
cleanup() {
    for m in "${W}"/mnt/*; do umount "${m}" 2>/dev/null; done
    [[ -n "${IL}" ]] && losetup -d "${IL}" 2>/dev/null
    [[ -n "${DL}" ]] && losetup -d "${DL}" 2>/dev/null
    rm -rf "${W}" /tmp/ophub-work /tmp/ophub-upgrade.env /tmp/partmap.image /tmp/image.bs
}
trap cleanup EXIT
mkdir -p "${W}"/mnt/{img1,img2,d1,d2,d3} "${W}/live_boot" "${W}/bin"

echo "== unpack the image"
gzip -dc "${IMG}" >"${W}/img.raw" 2>/dev/null
IL="$(losetup -f --show -P "${W}/img.raw")"
udevadm settle 2>/dev/null || sleep 2
mount -o ro "${IL}p1" "${W}/mnt/img1" && mount -t btrfs -o ro "${IL}p2" "${W}/mnt/img2" || { echo "cannot mount the image"; exit 2; }
UUID_IMG="$(blkid -o value -s UUID "${IL}p2")"
cp "${W}/mnt/img2/etc/ophub-release" "${W}/ophub-release"
PLATFORM="$(sed -n "s/^PLATFORM='\(.*\)'/\1/p" "${W}/ophub-release")"
BOARD="$(sed -n "s/^BOARD='\(.*\)'/\1/p" "${W}/ophub-release")"
echo "   image: ${PLATFORM}/${BOARD}, rootfs UUID ${UUID_IMG}"
[[ "${PLATFORM}" == "amlogic" ]] || echo "   (not an Amlogic image: the eMMC conversion checks are skipped)"

echo "== fake eMMC disk (what openwrt-install-amlogic leaves)"
truncate -s 5G "${W}/disk.img"
sfdisk -q "${W}/disk.img" <<EOF
label: dos
start=139264, size=1048576, type=c
start=1638400, size=3145728, type=83
start=4784128, type=83
EOF
DL="$(losetup -f --show -P "${W}/disk.img")"
udevadm settle 2>/dev/null || sleep 2
UUID0="$(uuidgen)"
OLD_FDT="/dtb/amlogic/meson-gxl-s905d-phicomm-n1-thresh.dtb"
mkfs.fat -n EMMC_BOOT -F 32 "${DL}p1" >/dev/null
mkfs.btrfs -q -f -U "${UUID0}" -L EMMC_ROOTFS -m single "${DL}p2" >/dev/null
mkfs.ext4 -q -F -L EMMC_SHARED "${DL}p3"
mount "${DL}p1" "${W}/mnt/d1"
(cd "${W}/mnt/img1" && tar cf - .) | (cd "${W}/mnt/d1" && tar xf -)
(
    cd "${W}/mnt/d1" || exit 1
    if [[ "${PLATFORM}" == "amlogic" ]]; then
        rm -f s905_autoscript* aml_autoscript*
        mv -f boot-emmc.ini boot.ini
        mv -f boot-emmc.cmd boot.cmd
        mv -f boot-emmc.scr boot.scr
        sed -i -E "s|^FDT=.*|FDT=${OLD_FDT}|; s|UUID=[^ ]*|UUID=${UUID0}|" uEnv.txt
        cp uEnv.txt "${W}/live_boot/uEnv.txt"
    fi
)
mount -t btrfs -o compress=zstd:6 "${DL}p2" "${W}/mnt/d2"
(
    cd "${W}/mnt/d2" || exit 1
    btrfs subvolume create etc >/dev/null
    mkdir -p bin boot dev lib opt mnt overlay proc rom root run sbin sys tmp usr www .reserved .snapshots
    for d in root etc bin sbin lib opt usr www; do
        [[ -e "${W}/mnt/img2/${d}" ]] || continue
        (cd "${W}/mnt/img2" && tar cf - "${d}") | tar xf -
    done
    printf 'UUID=%s / btrfs compress=zstd:6 0 1\nLABEL=EMMC_BOOT /boot vfat defaults 0 2\n' "${UUID0}" >etc/fstab
    sed -i "s|option label 'BOOT'|option label 'EMMC_BOOT'|; s|option uuid '[^']*'|option uuid '${UUID0}'|" etc/config/fstab
    btrfs subvolume snapshot -r etc .snapshots/etc-000 >/dev/null
    # what the user did to the box
    # (the image has no etc/config/network or system: config_generate writes them on first boot)
    printf "config interface 'lan'\n\toption device 'br-lan'\n\toption proto 'static'\n\toption ipaddr '10.10.11.1'\n" >etc/config/network
    printf "config system\n\toption hostname 'TESTBOX'\n\toption timezone 'JST-9'\n" >etc/config/system
    echo 'testuser:x:1234:1234:test:/home/test:/bin/false' >>etc/passwd
    echo 'testuser:*:19000:0:99999:7:::' >>etc/shadow
    touch etc/.ophub-defaults-applied
    mkdir -p etc/uci-defaults && echo 'exit 0' >etc/uci-defaults/10_disable_services
    mkdir -p etc/docker && echo '{"data-root":"/mnt/mmcblk2p3/docker/"}' >etc/docker/daemon.json
    tar -czf "${W}/backup.tgz" etc/config/network etc/config/system etc/passwd etc/shadow etc/group etc/fstab \
        etc/config/fstab etc/.ophub-defaults-applied etc/uci-defaults/10_disable_services etc/docker/daemon.json
)
umount "${W}/mnt/d1" "${W}/mnt/d2"
mount "${DL}p3" "${W}/mnt/d3" && echo "do not touch" >"${W}/mnt/d3/keep.txt" && umount "${W}/mnt/d3"
umount "${W}/mnt/img1" "${W}/mnt/img2"
GAP_BEFORE="$(dd if="${W}/disk.img" bs=1M count=68 2>/dev/null | md5sum | cut -d' ' -f1)"
PT_BEFORE="$(sfdisk -d "${W}/disk.img" 2>/dev/null | grep -v '^label-id\|^device' | md5sum | cut -d' ' -f1)"

echo "== busybox tool box (like sysupgrade's ramfs)"
cp "${BB}" "${W}/bin/busybox"
for a in sh ash cat cp mv rm mkdir rmdir ls grep awk sed cut sort tail head tr dd hexdump tar gzip zcat mount umount \
    sleep sync date wc basename readlink find touch chmod printf stat '[' echo; do
    ln -sf busybox "${W}/bin/${a}"
done
for t in blkid btrfs fatlabel e2label; do
    p="$(command -v "${t}" 2>/dev/null || true)"
    [[ -n "${p}" ]] && ln -sf "${p}" "${W}/bin/${t}"
done

run_platform() { # run_platform <image> <script body>
    local image="$1" body="$2"
    env -i PATH="${W}/bin" HOME=/tmp OPHUB_RELEASE="${W}/ophub-release" OPHUB_LIVE_BOOT="${W}/live_boot" \
        OPHUB_TEST_DISK_TYPE=EMMC \
        "${W}/bin/busybox" ash -c "
logger() { :; }
cmdline_get_var() { :; }
. '${COMMON_SH}'
. '${PLATFORM_SH}'
ophub_root_dev() { echo '${DL}p2'; }
${body}
" 2>&1 | sed 's/^/        | /'
    return "${PIPESTATUS[0]}"
}

echo "== platform_check_image"
run_platform "${IMG}" "platform_check_image '${IMG}'"
rc=$?
[[ "${rc}" -eq 0 ]] && ok "accepts the image for ${PLATFORM}/${BOARD}" || bad "check rejected the image (rc ${rc})"
grep -q "OP_BOARD='${BOARD}'" /tmp/ophub-upgrade.env 2>/dev/null && ok "env file written" || bad "no env file"

# wrong board
sed "s/^BOARD='.*'/BOARD='some-other-board'/" "${W}/ophub-release" >"${W}/ophub-release.other"
OLD_REL="${W}/ophub-release"
cp "${W}/ophub-release" "${W}/ophub-release.keep"
cp "${W}/ophub-release.other" "${W}/ophub-release"
run_platform "${IMG}" "platform_check_image '${IMG}'" >/dev/null
[[ $? -ne 0 ]] && ok "rejects an image for another board" || bad "accepted an image for another board"
cp "${W}/ophub-release.keep" "${W}/ophub-release"

# an image without file name in the gzip header, one with three partitions
truncate -s 64M "${W}/tiny.raw"
sfdisk -q "${W}/tiny.raw" <<EOF
label: dos
start=2048, size=20480, type=c
start=24576, size=20480, type=83
start=45056, size=20480, type=83
EOF
gzip -n -c "${W}/tiny.raw" >"${W}/noname.img.gz"
run_platform "${W}/noname.img.gz" "platform_check_image '${W}/noname.img.gz'" >/dev/null
[[ $? -ne 0 ]] && ok "rejects a 3-partition image without board name" || bad "accepted a bogus image"
cp "${W}/tiny.raw" "${W}/openwrt_official_${PLATFORM}_${BOARD}_k6.12.1_2026.01.01.img" && gzip -f "${W}/openwrt_official_${PLATFORM}_${BOARD}_k6.12.1_2026.01.01.img"
run_platform "${W}/openwrt_official_${PLATFORM}_${BOARD}_k6.12.1_2026.01.01.img.gz" "platform_check_image '${W}'/openwrt_official_${PLATFORM}_${BOARD}_k6.12.1_2026.01.01.img.gz" >/dev/null
[[ $? -ne 0 ]] && ok "rejects a 3-partition image even with the right name" || bad "accepted a 3-partition image"

echo "== platform_do_upgrade"
run_platform "${IMG}" "platform_check_image '${IMG}' && UPGRADE_BACKUP='${W}/backup.tgz' platform_do_upgrade '${IMG}'"
rc=$?
[[ "${rc}" -eq 0 ]] && ok "do_upgrade finished" || bad "do_upgrade failed (rc ${rc})"
sync

echo "== what the box sees on the next boot"
UUID_NOW="$(blkid -o value -s UUID "${DL}p2")"
[[ "${UUID_NOW}" == "${UUID_IMG}" ]] && ok "p2 carries the image's UUID" || bad "p2 UUID ${UUID_NOW} != ${UUID_IMG}"
GAP_AFTER="$(dd if="${W}/disk.img" bs=1M count=68 2>/dev/null | md5sum | cut -d' ' -f1)"
[[ "${GAP_AFTER}" == "${GAP_BEFORE}" ]] && ok "bootloader area (first 68 MiB) untouched" || bad "bootloader area changed"
PT_AFTER="$(sfdisk -d "${W}/disk.img" 2>/dev/null | grep -v '^label-id\|^device' | md5sum | cut -d' ' -f1)"
[[ "${PT_AFTER}" == "${PT_BEFORE}" ]] && ok "partition table untouched" || bad "partition table changed"
mount "${DL}p3" "${W}/mnt/d3" && [[ "$(cat "${W}/mnt/d3/keep.txt")" == "do not touch" ]] && ok "data partition p3 untouched" || bad "p3 changed"
umount "${W}/mnt/d3" 2>/dev/null

mount -t btrfs "${DL}p2" "${W}/mnt/d2" || bad "cannot mount the new rootfs"
R="${W}/mnt/d2"
check "new rootfs has the sysupgrade hook" grep -q ophub_fix_rootfs "${R}/lib/upgrade/platform.sh"
check "config restored: LAN IP" grep -q "10.10.11.1" "${R}/etc/config/network"
check "config restored: hostname" grep -q TESTBOX "${R}/etc/config/system"
check "config restored: defaults marker" test -e "${R}/etc/.ophub-defaults-applied"
check "config restored: docker daemon.json" grep -q mmcblk2p3 "${R}/etc/docker/daemon.json"
check "user added before the upgrade kept" grep -q '^testuser:' "${R}/etc/passwd"
check "system accounts of the new image kept" grep -q '^root:' "${R}/etc/passwd"
check "fstab: root = new UUID" grep -q "UUID=${UUID_IMG}" "${R}/etc/fstab"
check "fstab does not name the old UUID" bash -c "! grep -q '${UUID0}' '${R}/etc/fstab' '${R}/etc/config/fstab'"
if [[ "${PLATFORM}" == "amlogic" ]]; then
    check "fstab: /boot by EMMC_BOOT" grep -q 'LABEL=EMMC_BOOT /boot' "${R}/etc/fstab"
    check "config/fstab: /boot by EMMC_BOOT" grep -q "label 'EMMC_BOOT'" "${R}/etc/config/fstab"
    check "pristine snapshot re-created with EMMC_BOOT" grep -q 'LABEL=EMMC_BOOT' "${R}/.snapshots/etc-000/fstab"
fi
check "snapshot etc-001 (after restore) exists" test -d "${R}/.snapshots/etc-001"
check "etc is still a subvolume" bash -c "btrfs subvolume list '${R}' | grep -q ' path etc\$'"
umount "${W}/mnt/d2"

mount "${DL}p1" "${W}/mnt/d1" || bad "cannot mount the new boot partition"
B="${W}/mnt/d1"
if [[ "${PLATFORM}" == "amlogic" ]]; then
    [[ "$(blkid -o value -s LABEL "${DL}p1")" == "EMMC_BOOT" ]] && ok "boot label is EMMC_BOOT" || bad "boot label is $(blkid -o value -s LABEL "${DL}p1")"
    check "no s905_autoscript / aml_autoscript" bash -c "! ls '${B}'/s905_autoscript* '${B}'/aml_autoscript* 2>/dev/null | grep -q ."
    check "boot-emmc.* converted to boot.*" bash -c "! ls '${B}'/boot-emmc.* 2>/dev/null | grep -q . && test -f '${B}/boot.scr'"
    check "boot.scr is the image's boot-emmc.scr" bash -c "mount -o ro ${IL}p1 ${W}/mnt/img1 && cmp -s '${W}/mnt/img1/boot-emmc.scr' '${B}/boot.scr'; r=\$?; umount ${W}/mnt/img1; exit \$r"
    check "uEnv.txt: DTB chosen at install time kept" grep -q "^FDT=${OLD_FDT}\$" "${B}/uEnv.txt"
    check "uEnv.txt: root=UUID of the new rootfs" grep -q "root=UUID=${UUID_IMG}" "${B}/uEnv.txt"
    check "kernel files present" bash -c "test -e '${B}/zImage' && test -e '${B}/uInitrd' && test -d '${B}/dtb'"
fi
umount "${W}/mnt/d1"

echo
if [[ "${fails}" -eq 0 ]]; then echo "ALL TESTS PASSED"; else echo "${fails} TEST(S) FAILED"; fi
exit "${fails}"
