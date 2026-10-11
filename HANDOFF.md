# 多 AI 交接

> Cursor / Claude Code / Pi 共用。换棒时在**最上面**追加一条。

## 2026-10-11 — pi → 下一棒

- **状态：** 进行中。fork 已建（`neomikanagi/amlogic-s9xxx-openwrt`，公开），首次完整云编译在跑（Actions → Build OpenWrt）。升级逻辑已用 loop 设备＋busybox 在宿主上对上游真镜像测过（`custom/scripts/test-upgrade.sh`，除"镜像里要有本 fork 的 hook"这一项外全过）；**真机未测**（无硬件）。
- **改了：** 全是"覆盖层"，没有改上游文件（`remake`、`make-openwrt/`、`config/openwrt_main/`、`action.yml` 原样）。
  - `custom/openwrt_main/config.fragment` + `custom/scripts/apply-config.sh` + `prune-orphans.py`：在上游 `.config` 上删 ttyd/samba4/frpc/frps/attended-sysupgrade，并自动算出"只被它们依赖的包"一起删；加 docker、dockerman、HomeProxy+sing-box、zram。`packages.check` 在 defconfig 之后、编译之前校验（forbid/require），`verify-image.sh` 对成品镜像里的 apk 数据库再校验一次。
  - `custom/openwrt_main/diy-part3.sh`（源码树：homeproxy、NTP、dockerman 去 ttyd 依赖、luci-app-amlogic p4→p3）、`stage-rootfs-files.sh`（给 remake 的 `openwrt_files`：补丁版 installer、openwrt-tf、update 包装）、`custom/patches/*.patch`。
  - `files/`（OpenWrt 构建期覆盖层）：`lib/upgrade/platform.sh`（sysupgrade：只写 p1+p2，配置直接还原进新 rootfs）、`sysctl.d/12-ophub.conf`（BBR）、`uci-defaults/99-ophub-defaults`（带标记，升级不会重置用户设置）、`init.d/ophub-resize`（btrfs 在线扩到分区大小）、`keep.d/ophub`。
  - `.github/workflows/build-openwrt.yml`（可选 IP/机型/内核；`repack_only` 复用上次 rootfs 只重新打包）、`sync-upstream.yml` + `scripts/sync-upstream.sh` + `.sync/*`（上游的树 + 我们的路径，无合并冲突）。
  - 删了上游的其他 workflow 和 `config/{docker,imagebuilder,lede_master,immortalwrt_master}`（`.sync/drop.txt` 保证每次同步后仍被删）。
- **为什么 / 思路：**
  - **不改上游文件**：改过的副本会在上游更新时悄悄过期。改动要么放在上游没有的路径，要么在构建时对刚下载的文件做带断言的 sed/patch（改不动就报错，不发半成品）。同步脚本因此是"取上游树，保留 own，删 drop"，不用 `git merge`。workflow 文件全归本仓库，所以同步提交不碰 workflow，普通 `GITHUB_TOKEN` 就能推。
  - **单 rootfs**：ophub 装机是 p1 BOOT / p2 ROOTFS1 / p3 ROOTFS2 / p4 SHARED，更新写"另一个 rootfs"。改成 p1/p2/p3(数据)；`openwrt-install-amlogic`、`openwrt-tf` 打补丁，`openwrt-update-*` 换成 sysupgrade 包装。BLANK1/BLANK2（含 N1 的 800 MiB 禁区：bootloader 每次开机会改写 796 MiB 处的 12 字节）保持上游值，别动。
  - **升级判板**：板名读自 gzip 头里存的原文件名（remake 用 `pigz -f openwrt_..._<board>_k...img` 压缩，名字就在头里），不要给镜像重新压缩、也不要删 `-n` 以外的头信息。`sysupgrade -F` 可强制。
  - **镜像里 p1 是 USB/SD 风格**（带 autoscript + boot-emmc.*）：eMMC 升级时 `ophub_fix_bootfs` 复刻安装脚本的转换（删 autoscript、`boot-emmc.*`→`boot.*`、K510 的 u-boot.emmc），并保留安装时选的 DTB；p1 标签改回 `EMMC_BOOT`（避免装机 U 盘的 `BOOT` 标签重名），fstab 同步改并重建 `.snapshots/etc-000`。
  - 对 `ttyd`：LuCI Dockerman 在官方源里 `select ttyd`，所以直接加 dockerman 会把被删的 ttyd 拉回来；`diy-part3.sh` 删掉 Makefile 里的 `+ttyd`（代价：Dockerman 的"控制台"按钮不可用）。`attended-sysupgrade` 一并删，它会推荐官方 armsr 镜像（这些盒子不能启动）。
  - zram **不要写死大小**：`zram-swap` 默认就是内存的一半；onecloud 写死 512 是因为它只有 1 GB。算法设 zstd（内核不支持时 init 自动回退）。
  - 默认 LAN IP `10.10.10.1`（onecloud 同款），云编译的输入可改；定时任务读仓库变量 `OPENWRT_IP/OPENWRT_BOARD/OPENWRT_KERNEL`。默认机型 `s905d_s912-phicomm-t1_panther-x2` 是按 SOCIAL_CALCULUS 里的设备（N1、T1、Panther X2）猜的，随时可改变量。
  - "dns替换"理解为 `dnsmasq`→`dnsmasq-full`（上游 config 已经是 full，fragment 里显式写死并 forbid 普通 dnsmasq）＋缓存 1000＋NTP 池换成可达的几个（与 onecloud 一致）。
- **请你：**
  1. 看首个 Release 的 `*-sysupgrade.img.gz` 是否通过 `verify-image.sh`；失败就改后用 `repack_only` 重打包（rootfs 已先上传，10 分钟）。
  2. 真机试装一台（N1 最合适）：U 盘启动 → Install OpenWrt → 重启 → 再用同一发布系列的新镜像 `sysupgrade`。重点看：eMMC 能起、`/boot` 挂的是 `EMMC_BOOT`、`/mnt/mmcblk*p3` 自动挂载、docker 数据在 p3、升级后配置还在。
  3. 不要还原：`custom/patches/*.patch`、`.sync/own.txt`（`files/`、`custom/` 等）、`BLANK` 值、`config.fragment` 里 `#!keep attr`。
  4. 已知不支持：Allwinner 机型的专用安装脚本（`openwrt-install-allwinner`）还是上游的四分区布局，没改；从上游 A/B 布局原地迁移也不支持（重装）。
