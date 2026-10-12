# 多 AI 交接

> Cursor / Claude Code / Pi 共用。换棒时在**最上面**追加一条。

## 2026-10-13 — pi → 无（补删动态 DNS，已触发重编）

- **状态：** 已补删并推送，旧含 DDNS 的 Build `38252904963`（2h38m 成功）作废；新全编译已触发，真机未验收。
- **改了：** `config.fragment` 加删 `luci-app-ddns`、`luci-i18n-ddns-zh-cn`、`ddns-scripts`、`ddns-scripts-services`（上游四项全是 `=y`）；`packages.check` 加一行 forbid；README 删除清单加动态 DNS。孤立依赖走 `prune-orphans.py` 自动 drop，不手写。
- **为什么·思路：** 用户指漏删动态 DNS。上游只有这四项 DDNS 是开的，其余 provider 包本来就是 not set；forbid 只写直接包，避免把仍被需要的共享库误杀。`test-sync-upstream.sh` 与 `check-patches.sh` 通过；包选择变更须完整编译，不能 repack。
- **请你：** 看新 Build 的 `verify-image.sh`（forbid 含 ddns 四项）与 N1/T1 镜像；真机照前条验收。不要还原：DDNS 四项的 not set + forbid。

## 2026-10-12 — pi → 无（默认改 F 大 6.12 + N1/T1 + 1024MiB，已触发云编译）

- **状态：** 已改默认并推送，云编译已触发（workflow_dispatch，全编译，board=`s905d_s912-phicomm-t1`、kernel=`6.12.y`+`flippy`、size=`256/1024`）。编译约 2–3 小时，真机未验收。
- **改了：** `build-openwrt.yml` 默认 `openwrt_board s905d_s912-phicomm-t1`（去 Panther X2）、`openwrt_kernel 6.12.y`、`kernel_usage flippy`（F 大，`vars.KERNEL_USAGE` 也可覆盖定时任务）；`custom/patches/openwrt-install-{amlogic,allwinner}.patch` 的 `OPENWRT_ROOT_MB` 默认 `1536→1024`（仍可 `OPENWRT_ROOT_MB=2048` 覆盖，下限 1024 不变）；README 同步默认与 N1 数据分区约 6.1GB。镜像分区 `openwrt_size` 本来就是 `256/1024`，未动。
- **为什么·思路：** 用户要“F 大的 6.12、只要 N1T1、rootfs 1024”。N1=`s905d`、T1=`s912-phicomm-t1` 均在 model_database 第 14 列且 `BUILD=yes`；N1/T1 的 `KERNEL_TAGS=stable/all`，`-u flippy -k 6.12.y` 会落到 `kernel_flippy` 的 6.12.x（API 已确认有 6.12.112），与 remake 的 `-u/-k` 语义一致。离线验证：`test-sync-upstream.sh` 通过，`check-patches.sh` 三补丁可应用，board token 双命中。
- **请你：** 看新 Build 的 `verify-image.sh` 与 Release `*-sysupgrade.img.gz`（N1/T1 各 1 个）；真机照旧条 N1 流程验收（U 盘起 → Install → 重启 → 同机型 sysupgrade）。不要还原：`flippy` 默认、`s905d_s912-phicomm-t1` 默认、`OPENWRT_ROOT_MB:-1024`。

## 2026-10-11 — claudecode → 无（云编译“失败”查明：旧提交的校验误报，已由 #4 出片）

- **状态：** 云端已出片。Release `OpenWrt_openwrt_main_save_2026.10` 现有 5 个 `*-sysupgrade.img.gz` + rootfs + config + sha256sums，来自 repack-only `38139887345`（提交 `120844f`），5 个镜像 `verify-image.sh` 全部 `== OK`，没有内核模块缺失警告。真机仍未验收。
- **改了：** 只加本条，未改代码。
- **为什么·思路：** 失败的全编译 `38134342511` 跑的是旧提交 `fa744d3`。编译、rootfs 上传、remake 打包都成功了，只挂在校验步骤的 “no kernel image (zImage/Image)”。原因是当时的检查写成 `ls zImage Image | grep -q .`，而脚本开着 `set -o pipefail`；Amlogic 机型没有 `Image`，`ls` 退出码为 2，整条管道就判失败，**镜像本身没问题**。Pi 在 `ac4e687` 已改成 `[[ -e … || -e … ]]`，本地已复现“旧写法判失败、新写法判通过”。boot 用量 155 MiB 也和“含 zImage”对得上（只算内核文件约 139 MiB）。剩下的 Node 20 弃用警告来自 `dev-drprasad/delete-older-releases@v0.3.4`，GitHub 已强制改用 Node 24 运行，“Prune old releases”步骤是成功的，而且上游还没有更新版本，所以不处理。
- **请你：** 无。真机验收照上一条 pi 的第 2 点做。

## 2026-10-11 — pi → 无（保留必要云任务、修正 repack 覆盖层）

- **状态：** 离线验证通过、代码 `120844f` 已推送；仅保留 Build #2 `38134342511`（全编译运行中）与修正版 Build #4 `38139887345`（repack-only 排队）。旧 Build #3 `38136871362` 已确认 cancelled。不重复编译软件包，不阻塞对话等待云端。
- **改了：** `stage-rootfs-files.sh` 在打包阶段刷新完整 `files/` 覆盖层；`verify-image.sh` 对比成品升级 hook 与当前提交；`check-patches.sh` 用故意过期的 hook 验证覆盖，并核对所有 files 文件/符号链接；README 明确 repack 与全编译边界。
- **为什么·思路：** 用户要求只留必要任务。当前没有任何 rootfs Release，因此全编译不能停；重打包是最新 installer 等补丁的必要后置步骤，不是第二次完整编译。同时发现旧 repack 只刷新安装脚本，未刷新编译时已烘入的 `files/lib/upgrade/platform.sh`，会漏掉挂载重试修补；因此旧 #3 必须换成修正版。补丁/覆盖层检查（含过期 hook 覆盖）、同步四组回归、bash 语法、Pi 工人 shellcheck error 级与两条 workflow 的 actionlint 均通过。没有本机编译固件，最终镜像/真机仍未验收。
- **请你：** 无。旧失败 Build #1 与已成功 Sync 已结束，不占运行资源，无需删除历史；只保留全编译与最终打包两个必要阶段。

## 2026-10-11 — pi → 无（续做：同步安全与最终云验收）

- **状态：** 代码已补齐并推送 `8921a98`；首次完整编译 `38134342511` 仍在运行，最新代码 repack-only `38136871362` 已排队，最终固件验收待云端完成，不冒充已发布。
- **改了：** `sync-upstream.sh` 的 dry-run 改为临时工作树，真实同步只强制暂存上游实际路径；新增 `scripts/tests/test-sync-upstream.sh` 并接到云构建 check job，更新 README。此前已验证的单 rootfs、eMMC/Allwinner 与包选择方案均保留。
- **为什么·思路：** 原 `git clean -fd` 会删除调用方未跟踪文件，`git add -A -f` 会把本地忽略的下载/构建产物乃至密钥提交。四组离线回归验证 dry-run 不变、正确更新/删除/保护上游路径、不暂存本地文件、重复同步幂等；补丁应用、bash 语法、Pi 工人 shellcheck error 级及本 fork build/sync 两条 workflow 的 actionlint 通过。旧上游镜像在宿主隔离 loop 文件上跑升级逻辑，分区表/bootloader/p3、配置、UUID、eMMC 转换检查通过；唯一失败是旧镜像本来没有本 fork 的 sysupgrade hook，**这不算最终新固件通过**。Pi 工人 cgroup 不允许 loop setup，未放宽容器护栏、未安装宿主依赖。
- **请你：** 无。用户要求云编译自行继续，不在本机编译、不阻塞对话等待；已停止本会话等待，未取消云任务。21:24 JST 核对：首次全编译仍在 Compile 步骤，最新代码 repack-only 在 concurrency 队列，等前者结束后复用其 rootfs。最终云镜像与真机启动未验收；不能把排队/脚本通过写成固件已成功。

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
