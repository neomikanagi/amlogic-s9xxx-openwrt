# OpenWrt for Amlogic / Rockchip / Allwinner boxes — single-rootfs fork

[ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt) 的 fork，只用官方 `openwrt_main`（`OpenWrt_openwrt_main_*`），
把"两个 rootfs 互相替换"的 A/B 分区改成普通的 **boot + rootfs + data**，升级就是 OpenWrt 自带的
**`*-sysupgrade.img.gz`**（和 [onecloud-openwrt](https://github.com/neomikanagi/onecloud-openwrt) 一样）。

内核、u-boot、设备库（240 个机型）仍然来自 ophub；本仓库只加了"覆盖层"，没有改上游文件，所以能自动跟随上游（见 [跟随上游](#跟随上游)）。

## 下载哪个文件

[Releases](../../releases) 里 `OpenWrt_openwrt_main_save_<年.月>`，每个机型一个文件：

```
openwrt_official_<平台>_<机型>_k<内核>_<日期>-sysupgrade.img.gz
```

| 用途 | 做法 |
| --- | --- |
| **第一次安装**（Amlogic） | 解压写入 SD / U 盘 → 开机 → LuCI → 系统 → Amlogic Service → Install OpenWrt（装进 eMMC）。拔掉 U 盘再重启 |
| 第一次安装（Rockchip / Allwinner） | 直接写到目标盘（Rockchip 的 u-boot 在镜像里），开机后自动在剩余空间建数据分区 |
| **以后每次升级** | LuCI → 系统 → 备份/升级 → 刷写新的固件，选 **同机型** 的 `*-sysupgrade.img.gz`；或 `sysupgrade /tmp/openwrt_*-sysupgrade.img.gz` |

升级只写 boot 和 rootfs 两个分区，**不动 u-boot、分区表和数据分区**（docker、swap 文件都留着），配置默认保留。
镜像要放进内存（`/tmp`），所以需要和镜像一样大的空闲内存（约 350 MB；1 GB 内存的盒子先停掉容器）。
LuCI 的 *Amlogic Service → Online Update* 同样可用（指向本仓库的 Releases），它调用的 `openwrt-update-*` 现在只是 sysupgrade 的包装。

## 分区

```
[ 机型自带的 bootloader 区 ] │ p1 BOOT (fat32, ext4 on Rockchip) │ p2 ROOTFS (btrfs, zstd) │ p3 SHARED = 剩余全部
```

* 只有一个 rootfs（上游是 p2/p3 两个互相替换，p4 才是数据）。数据分区变成 **p3**（`/mnt/mmcblk*p3`），docker 的 data-root 在这里。
* eMMC 安装：rootfs 默认 1024 MiB（`OPENWRT_ROOT_MB` 可改），boot 取机型原值但不小于镜像的 boot（256 MiB）；每机型的 bootloader 保留区（`BLANK1`、N1 的 800 MiB 禁区等）保持上游原值。
* 以 Phicomm N1（8 GB eMMC）为例：数据分区约 6.1 GB（上游 A/B 布局约 4.0 GB）。
* rootfs 比分区小时开机自动 `btrfs filesystem resize max /`（`/etc/init.d/ophub-resize`）。
* 不能从上游的 4 分区布局原地迁移：用新镜像重新安装一次（先备份 `/etc` 和数据分区）。
* 升级前先拔掉安装用的 U 盘/SD（两个 btrfs 会有相同的 UUID）。

升级时的细节（`files/lib/upgrade/platform.sh`）：只接受**同机型**镜像（机型名读自 gzip 头里的原文件名，所以不要重新压缩镜像；强制用 `sysupgrade -F`）；
Amlogic + eMMC 时把镜像里 USB/SD 风格的 boot 分区转成 eMMC 风格并保留安装时选的 DTB；配置直接还原进新 rootfs，重新生成 `.snapshots/etc-000`（`firstboot` 出厂重置仍可用）。

## 默认配置

| 项 | 值 |
| --- | --- |
| LAN IP | 构建时指定，默认 `10.10.10.1`（云编译可选） |
| 登录 | `root` / `password`（请尽快改） |
| 时区 / 语言 | Asia/Tokyo / 简体中文 |
| NTP | time.windows.com / time.apple.com / time.google.com / time.cloudflare.com，并给局域网授时 |
| DNS | dnsmasq-full（替换 dnsmasq，nftset/conntrack/DNSSEC），缓存 1000 条 |
| TCP | BBR（`net.ipv4.tcp_congestion_control=bbr`），4 MB 缓冲上限，conntrack 65536 |
| 内存 | zram swap = 内存的一半（OpenWrt `zram-swap` 默认值，随机型变化），zstd，swappiness 100 |
| 防火墙 | firewall4 / nftables；flow offloading 默认关（会破坏 HomeProxy 的 fwmark 透明代理） |

## 包

相对上游 `config/openwrt_main/config`（见 [`custom/openwrt_main/config.fragment`](custom/openwrt_main/config.fragment)）：

* **删除**：ttyd、Samba 4（含 wsdd2、avahi、netbios、CIFS 模块）、FRP 客户端、FRP 服务端，以及只被它们依赖的库（`libwebsockets`、`libuv`、`dbus`、`libavahi-*`、`libpopt`、`liburing`…，构建时自动算出并在日志里列出）；
  还有 attended sysupgrade（它会推荐官方 armsr 镜像，在这些盒子上不能启动）。
* **新增**：Docker（dockerd、docker-compose、LuCI Dockerman）、HomeProxy + sing-box、BBR、zram。
* LuCI Dockerman 在官方源码里依赖 ttyd（容器控制台）；这里去掉了这条依赖，其余功能不受影响，只有"控制台"按钮不可用。

## 云编译

Actions → **Build OpenWrt** → Run workflow：

| 参数 | 说明 |
| --- | --- |
| `openwrt_ip` | 固件默认 LAN IP（**可选**，默认 `10.10.10.1`） |
| `openwrt_board` | 机型，用 `_` 连接，如 `s905d_s912-phicomm-t1`；也可 `all` / `amlogic` / `rockchip` / `allwinner`。名字见 `make-openwrt/openwrt-files/common-files/etc/model_database.conf` 第 14 列 |
| `openwrt_kernel` / `kernel_usage` / `auto_kernel` | ophub 内核系列与标签，默认 `6.12.y` + `flippy`（F 大） |
| **`repack_only`** | 不编译，复用上一次的 rootfs 重新打包（改 IP / 机型 / 换新内核只要约 10 分钟，完整编译要 2–3 小时） |
| `openwrt_size` | 镜像分区 `boot/rootfs`（MiB），默认 `256/1024` |
| `openwrt_storage` | `save` 保留 / `temp` 临时 |

`repack_only` 会重新应用本提交的 `files/` 覆盖层和安装/升级补丁，成品检查确保升级 hook 与本提交一致；不会重编软件包，包选择或源码改动仍须完整编译。

每月 1 日 02:00 UTC 自动编译一次。定时任务用仓库变量（Settings → Secrets and variables → Actions → Variables）：
`OPENWRT_IP`、`OPENWRT_BOARD`、`OPENWRT_KERNEL`、`KERNEL_USAGE`；没设置就用上面的默认值（`s905d_s912-phicomm-t1`，`6.12.y` + `flippy`）。
构建前会检查参数；打包后会打开每个镜像检查（`custom/scripts/verify-image.sh`：分区只有 p1/p2、没有被删的包、docker/HomeProxy 在、补丁已生效…），任何一项不过就不发布。
只保留最近 6 个 release。

## 跟随上游

`scripts/sync-upstream.sh`（每周一由 [Sync upstream](.github/workflows/sync-upstream.yml) 运行，也可手动 `scripts/sync-upstream.sh --push`）：

* 本仓库 = **上游当前的树 + 自己的路径**，没有合并冲突：`.sync/own.txt` 里的路径永远保持本仓库的版本，`.sync/drop.txt` 里的上游路径每次同步后删掉，其余全部换成上游最新（上游新增、删除都会跟上）。
* 对上游文件的改动不做"改过的副本"，而是在**构建时**对刚下载的上游文件做带断言的小改动（`custom/openwrt_main/*.sh`、`custom/patches/*.patch`），所以上游修了 bug 会自动带进来；改不动了就在构建/同步时报错（开 issue），不会悄悄发出半成品。
* 上游改了构建会用到的文件（`remake`、`make-openwrt/`、`config/openwrt_main/` …）时自动检查补丁并触发一次构建。`--dry-run` 在临时工作树预览，不删除本地未跟踪文件；同步只暂存上游实际带来的文件，不提交本地下载、编译输出或密钥。离线回归：`bash scripts/tests/test-sync-upstream.sh`（云编译前也会运行）。

## 目录

```
.github/workflows/build-openwrt.yml   云编译（可选 IP / 机型 / 内核；repack_only）
.github/workflows/sync-upstream.yml   跟随上游
custom/openwrt_main/                  config.fragment（包）、diy-part3.sh（源码树改动）、stage-rootfs-files.sh、packages.check
custom/scripts/                       apply-config.sh + prune-orphans.py（删包及"附带包"）、verify-image.sh、test-upgrade.sh
custom/patches/                       对上游 openwrt-install-amlogic / openwrt-tf 的补丁（三个分区、p4→p3）
custom/rootfs-files/                  openwrt-update-* 包装（调用 sysupgrade）
files/                                OpenWrt 构建期 files/ 覆盖层：platform.sh（升级）、sysctl、uci-defaults、keep.d、ophub-resize
.sync/  scripts/                      同步规则与脚本
config/openwrt_main/  remake  make-openwrt/  action.yml   上游原样（自动跟随）
```

本地验证升级逻辑（root；需要 busybox、btrfs-progs、dosfstools）：`custom/scripts/test-upgrade.sh <镜像.img.gz> <busybox>` 会在 loop 设备上模拟一块装好的 eMMC，用 busybox 跑一遍 `platform.sh`，检查 UUID、bootloader 区、分区表、数据分区、配置还原、eMMC 转换。

## 许可

GPL-2.0，同上游。源自 [ophub/amlogic-s9xxx-openwrt](https://github.com/ophub/amlogic-s9xxx-openwrt)、[ophub/luci-app-amlogic](https://github.com/ophub/luci-app-amlogic)、[unifreq/openwrt_packit](https://github.com/unifreq/openwrt_packit)；HomeProxy 来自 [immortalwrt/homeproxy](https://github.com/immortalwrt/homeproxy)。
