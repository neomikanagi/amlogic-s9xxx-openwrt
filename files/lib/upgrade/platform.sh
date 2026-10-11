# SPDX-License-Identifier: GPL-2.0-or-later
#
# sysupgrade support for images built by this repository (Amlogic / Rockchip /
# Allwinner boxes, kernel + u-boot from ophub, rootfs = OpenWrt armsr).
#
# Layout (same on SD / USB / eMMC / NVMe):
#
#     [ bootloader gap ] p1 BOOT (FAT32, ext4 on Rockchip) | p2 ROOTFS (btrfs) | p3 DATA (rest)
#
# There is only ONE rootfs. An upgrade rewrites p1 and p2 from the
# *-sysupgrade.img.gz and never touches the partition table, the bootloader or
# p3, so docker data / swap files on p3 survive. Config is restored straight
# into the new rootfs, so a failed restore can't leave a half-configured box.
#
# What is done on top of a raw "dd p1 + p2":
#   * the image must be for the same BOARD as the running system (the board
#     name is read from the file name stored in the gzip header)
#   * Amlogic + eMMC: the image's p1 is a USB/SD flavoured boot partition; it is
#     converted to the eMMC flavour (boot-emmc.* -> boot.*, no autoscripts) and
#     the DTB the user picked at install time is kept
#   * Amlogic + eMMC: labels/fstab use EMMC_BOOT (as the installer does) so a
#     stray install stick with the label BOOT can never be mounted as /boot
#   * the new rootfs may be smaller than the partition: it is grown on first
#     boot (/etc/init.d/ophub-firstrun)

REQUIRE_IMAGE_METADATA=0

OPHUB_ENV=/tmp/ophub-upgrade.env
OPHUB_WORK=/tmp/ophub-work
# (overridable so that custom/scripts/test-upgrade.sh can run the logic against loop devices)
OPHUB_RELEASE="${OPHUB_RELEASE:-/etc/ophub-release}"
OPHUB_LIVE_BOOT="${OPHUB_LIVE_BOOT:-/boot}"

# extra programs for the temporary ramfs root (stage2 skips the missing ones)
RAMFS_COPY_BIN="blkid btrfs fatlabel e2label"
RAMFS_COPY_DATA="$OPHUB_ENV"

# ---------------------------------------------------------------- helpers ---

ophub_err() { v "ERROR: $*"; }

# <partition device name> -> sets OP_DISK / OP_PARTN
ophub_part_info() {
	local sys="/sys/class/block/$1"
	[ -e "$sys/partition" ] || return 1
	OP_PARTN="$(cat "$sys/partition")"
	OP_DISK="$(basename "$(readlink -f "$sys/..")")"
	[ -n "$OP_DISK" ] && [ -n "$OP_PARTN" ]
}

# <disk> <partition number> -> prints the partition device name
ophub_find_part() {
	local d name
	for d in /sys/class/block/"$1"*; do
		[ -e "$d/partition" ] || continue
		[ "$(cat "$d/partition")" = "$2" ] || continue
		name="$(basename "$d")"
		[ "$(basename "$(readlink -f "$d/..")")" = "$1" ] || continue
		echo "$name"
		return 0
	done
	return 1
}

# print the root partition device (/dev/xxx) of the running system
ophub_root_dev() {
	local dev uuid
	dev="$(awk '$2=="/" && $1 ~ /^\/dev\// && $1 != "/dev/root" {d=$1} END {print d}' /proc/mounts)"
	if [ -z "$dev" ]; then
		uuid="$(cmdline_get_var root)"
		case "$uuid" in
		UUID=*) dev="$(blkid -U "${uuid#UUID=}" 2>/dev/null)" ;;
		/dev/*) dev="$uuid" ;;
		esac
	fi
	[ -b "$dev" ] && echo "$dev"
}

# the original file name is stored in the gzip header (FNAME); remake gzips
# openwrt_<source>_<platform>_<board>_k<kernel>_<date>.img, so it carries the
# board without having to unpack the image.
ophub_image_name() {
	local img="$1" flg
	[ "$(dd if="$img" bs=2 count=1 2>/dev/null | hexdump -v -n 2 -e '1/1 "%02x"')" = "1f8b" ] || return 1
	flg="$(dd if="$img" bs=1 skip=3 count=1 2>/dev/null | hexdump -v -n 1 -e '1/1 "%d"')"
	[ $((flg & 8)) -ne 0 ] || return 1 # FNAME present
	[ $((flg & 4)) -eq 0 ] || return 1 # FEXTRA not supported
	dd if="$img" bs=1 skip=10 count=255 2>/dev/null | tr '\000' '\n' | head -n 1
}

# <image> : fills /tmp/partmap.image (part start size) from the image's table
ophub_image_partmap() {
	rm -f /tmp/partmap.image /tmp/image.bs
	get_image_dd "$1" of=/tmp/image.bs count=63 bs=512b
	get_partitions /tmp/image.bs image
	rm -f /tmp/image.bs
	[ -s /tmp/partmap.image ]
}

# <file> <var-name> : print VAR='value' / VAR=value from a shell style file
ophub_conf_get() {
	sed -n -e "s/^$2=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}\$/\1/p" "$1" 2>/dev/null | head -n 1
}

# ------------------------------------------------------- check (live system) ---

platform_check_image() {
	local img="$1" rel root_dev root_name boot_name disk_type name
	local p1_start p1_size p2_start p2_size have1 have2 old_fdt

	[ "$#" -gt 1 ] && return 1

	rel="$OPHUB_RELEASE"
	[ -s "$rel" ] || rel=/etc/flippy-openwrt-release
	[ -s "$rel" ] || {
		ophub_err "$OPHUB_RELEASE is missing, this is not an image built by this repository"
		return 1
	}
	PLATFORM="$(ophub_conf_get "$rel" PLATFORM)"
	BOARD="$(ophub_conf_get "$rel" BOARD)"
	[ -n "$PLATFORM" ] && [ -n "$BOARD" ] || {
		ophub_err "PLATFORM/BOARD missing in $rel"
		return 1
	}

	root_dev="$(ophub_root_dev)" || true
	[ -n "$root_dev" ] || {
		ophub_err "cannot determine the root partition"
		return 1
	}
	root_name="${root_dev#/dev/}"
	ophub_part_info "$root_name" || {
		ophub_err "$root_dev is not a partition"
		return 1
	}
	[ "$OP_PARTN" = "2" ] || {
		ophub_err "root is partition $OP_PARTN of /dev/$OP_DISK; this layout needs root on partition 2"
		return 1
	}
	boot_name="$(ophub_find_part "$OP_DISK" 1)" || {
		ophub_err "partition 1 of /dev/$OP_DISK not found"
		return 1
	}

	case "$OP_DISK" in
	mmcblk*) [ -e "/sys/class/block/${OP_DISK}boot0" ] && disk_type=EMMC || disk_type=SD ;;
	sd* | vd* | hd*) disk_type=USB ;;
	nvme*) disk_type=NVME ;;
	*) disk_type=UNKNOWN ;;
	esac
	[ -n "$OPHUB_TEST_DISK_TYPE" ] && disk_type="$OPHUB_TEST_DISK_TYPE"

	# the image must be a disk image ...
	ophub_image_partmap "$img" || {
		ophub_err "no usable partition table in the image"
		return 1
	}
	set -- $(awk '$1==1 {print $2, $3}' /tmp/partmap.image)
	p1_start="$1"
	p1_size="$2"
	set -- $(awk '$1==2 {print $2, $3}' /tmp/partmap.image)
	p2_start="$1"
	p2_size="$2"
	[ -n "$p1_start" ] && [ -n "$p2_start" ] || {
		ophub_err "the image has no partition 1 / 2"
		return 1
	}
	# ... with exactly the single-rootfs layout (p1 boot + p2 rootfs, nothing after)
	if awk '$1>2 {f=1} END {exit !f}' /tmp/partmap.image; then
		ophub_err "the image has more than two partitions; it is not a *-sysupgrade.img.gz of this repository"
		return 1
	fi

	# ... for this board
	name="$(ophub_image_name "$img")"
	case "$name" in
	*"_${PLATFORM}_${BOARD}_k"*) ;;
	"")
		ophub_err "cannot read the board name from the image (gzip header has no file name); use sysupgrade -F to force"
		return 1
		;;
	*)
		ophub_err "image '$name' is not for this board ($PLATFORM / $BOARD); use sysupgrade -F to force"
		return 1
		;;
	esac

	# ... that fits the installed partitions
	have1="$(cat "/sys/class/block/$boot_name/size")"
	have2="$(cat "/sys/class/block/$root_name/size")"
	[ "$p1_size" -le "$have1" ] || {
		ophub_err "image boot partition needs $p1_size sectors, /dev/$boot_name only has $have1"
		return 1
	}
	[ "$p2_size" -le "$have2" ] || {
		ophub_err "image rootfs partition needs $p2_size sectors, /dev/$root_name only has $have2"
		return 1
	}

	# the DTB picked at install time (Amlogic): keep it across upgrades
	old_fdt=""
	[ -f "$OPHUB_LIVE_BOOT/uEnv.txt" ] && old_fdt="$(sed -n 's/^FDT=//p' "$OPHUB_LIVE_BOOT/uEnv.txt" | head -n 1)"

	cat >"$OPHUB_ENV" <<EOF
OP_PLATFORM='$PLATFORM'
OP_BOARD='$BOARD'
OP_DISK='$OP_DISK'
OP_DISK_TYPE='$disk_type'
OP_ROOT_DEV='/dev/$root_name'
OP_BOOT_DEV='/dev/$boot_name'
OP_OLD_FDT='$old_fdt'
OP_P1_START='$p1_start'
OP_P1_SIZE='$p1_size'
OP_P2_START='$p2_start'
OP_P2_SIZE='$p2_size'
EOF
	v "ophub: $PLATFORM/$BOARD on /dev/$OP_DISK ($disk_type): root=/dev/$root_name boot=/dev/$boot_name image='$name'"
	return 0
}

# --------------------------------------------------- do_upgrade (in ramfs) ---

# <new root mounted at $1>
ophub_fix_rootfs() {
	local new="$1" ret=0 f

	# Amlogic + eMMC: the installer names the boot partition EMMC_BOOT. Rewrite
	# the fstab of the new rootfs and re-create the pristine /etc snapshot from
	# it, so that "firstboot" (reset) keeps working.
	if [ "$OP_PLATFORM" = "amlogic" ] && [ "$OP_DISK_TYPE" = "EMMC" ]; then
		[ -f "$new/etc/fstab" ] && sed -i 's|LABEL=BOOT |LABEL=EMMC_BOOT |' "$new/etc/fstab"
		[ -f "$new/etc/config/fstab" ] &&
			sed -i "s|option label 'BOOT'|option label 'EMMC_BOOT'|" "$new/etc/config/fstab"
		if command -v btrfs >/dev/null 2>&1 && [ -d "$new/.snapshots/etc-000" ]; then
			btrfs subvolume delete "$new/.snapshots/etc-000" >/dev/null 2>&1
			btrfs subvolume snapshot -r "$new/etc" "$new/.snapshots/etc-000" >/dev/null 2>&1 ||
				v "WARNING: could not re-create .snapshots/etc-000"
		fi
	fi

	if [ -n "$UPGRADE_BACKUP" ] && [ -f "$UPGRADE_BACKUP" ]; then
		v "Restoring configuration into the new rootfs"
		mkdir -p "$OPHUB_WORK"
		for f in passwd group shadow; do
			cp -f "$new/etc/$f" "$OPHUB_WORK/$f.new" 2>/dev/null
		done
		tar -C "$new" -xzf "$UPGRADE_BACKUP" || {
			ophub_err "config restore failed"
			ret=1
		}
		# accounts that only exist in the new image must not be lost
		for f in passwd group shadow; do
			[ -s "$OPHUB_WORK/$f.new" ] || continue
			while IFS=: read -r name rest; do
				[ -n "$name" ] || continue
				grep -q "^$name:" "$new/etc/$f" || echo "$name:$rest" >>"$new/etc/$f"
			done <"$OPHUB_WORK/$f.new"
		done
		# fstab describes the new partitions, never keep the old copy
		if [ -d "$new/.snapshots/etc-000" ]; then
			cp -f "$new/.snapshots/etc-000/fstab" "$new/etc/fstab" 2>/dev/null
			cp -f "$new/.snapshots/etc-000/config/fstab" "$new/etc/config/fstab" 2>/dev/null
		fi
		if command -v btrfs >/dev/null 2>&1 && [ -d "$new/.snapshots" ]; then
			btrfs subvolume delete "$new/.snapshots/etc-001" >/dev/null 2>&1
			btrfs subvolume snapshot -r "$new/etc" "$new/.snapshots/etc-001" >/dev/null 2>&1
		fi
	fi
	sync
	return "$ret"
}

# <new boot mounted at $1>
ophub_fix_bootfs() {
	local b="$1" k510=1

	# keep the DTB chosen at install time (Amlogic uEnv.txt)
	if [ -n "$OP_OLD_FDT" ] && [ -f "$b/uEnv.txt" ]; then
		sed -i "s|^FDT=.*|FDT=$OP_OLD_FDT|" "$b/uEnv.txt"
	fi

	if [ "$OP_PLATFORM" = "amlogic" ] && [ "$OP_DISK_TYPE" = "EMMC" ]; then
		# kernels with the TEXT_OFFSET patch (marker 0108) need no u-boot overlay
		[ "$(hexdump -n 15 -x "$b/zImage" 2>/dev/null | head -n 1 | awk '{print $7}')" = "0108" ] && k510=0
		(
			cd "$b" || exit 1
			rm -f s905_autoscript* aml_autoscript*
			[ -f boot-emmc.ini ] && mv -f boot-emmc.ini boot.ini
			[ -f boot-emmc.cmd ] && mv -f boot-emmc.cmd boot.cmd
			[ -f boot-emmc.scr ] && mv -f boot-emmc.scr boot.scr
			if [ "$k510" = 1 ]; then
				[ -f u-boot.ext ] && cp -f u-boot.ext u-boot.emmc
			else
				rm -f u-boot.ext u-boot.emmc
			fi
		)
	fi
	sync
}

platform_do_upgrade() {
	local img="$1" newroot="$OPHUB_WORK/root" newboot="$OPHUB_WORK/boot" fstype rc=0

	[ -f "$OPHUB_ENV" ] && . "$OPHUB_ENV" || {
		ophub_err "$OPHUB_ENV is missing (platform_check_image did not run)"
		return 1
	}
	[ -b "$OP_ROOT_DEV" ] && [ -b "$OP_BOOT_DEV" ] || {
		ophub_err "target partitions $OP_ROOT_DEV / $OP_BOOT_DEV not found"
		return 1
	}

	mkdir -p "$newroot" "$newboot"
	sync

	v "Writing the rootfs ($((OP_P2_SIZE / 2048)) MiB) to $OP_ROOT_DEV"
	get_image_dd "$img" of="$OP_ROOT_DEV" ibs=512 obs=1M skip="$OP_P2_START" count="$OP_P2_SIZE" conv=fsync || {
		ophub_err "writing the rootfs failed - the system is probably unbootable now, boot from SD/USB and flash again"
		return 1
	}

	if mount -t btrfs -o compress=zstd:6 "$OP_ROOT_DEV" "$newroot"; then
		ophub_fix_rootfs "$newroot" || rc=1
		umount "$newroot"
	else
		ophub_err "cannot mount the new rootfs, config not restored"
		rc=1
	fi

	v "Writing the boot partition ($((OP_P1_SIZE / 2048)) MiB) to $OP_BOOT_DEV"
	get_image_dd "$img" of="$OP_BOOT_DEV" ibs=512 obs=1M skip="$OP_P1_START" count="$OP_P1_SIZE" conv=fsync || {
		ophub_err "writing the boot partition failed - boot from SD/USB and flash again"
		return 1
	}

	fstype="$(blkid -o value -s TYPE "$OP_BOOT_DEV" 2>/dev/null)"
	[ -n "$fstype" ] || fstype=vfat
	if mount -t "$fstype" "$OP_BOOT_DEV" "$newboot"; then
		ophub_fix_bootfs "$newboot"
		umount "$newboot"
	else
		ophub_err "cannot mount the new boot partition"
		rc=1
	fi

	if [ "$OP_PLATFORM" = "amlogic" ] && [ "$OP_DISK_TYPE" = "EMMC" ] && command -v fatlabel >/dev/null 2>&1; then
		fatlabel "$OP_BOOT_DEV" EMMC_BOOT >/dev/null 2>&1
	fi

	sync
	sleep 2
	[ "$rc" = 0 ] || v "Upgrade finished with warnings, see above"
	return 0
}
