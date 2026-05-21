# openwrt_main 定制同步说明

## 架构

| 文件 | 作用 |
|------|------|
| `custom-packages.conf` | 相对官方 **额外启用/禁用** 的软件包列表 |
| `diy-part2.custom.sh` | 编译时脚本片段（HomeProxy、NTP） |
| `build-preferences.env` | 默认 IP、Actions 默认板型/内核等 |
| `sync-from-upstream.sh` | **一键**：拉官方 `config` + `diy-part2.sh` → 应用上述定制 |
| `apply-build-preferences.sh` | 把构建偏好写入 GitHub workflow |

## 官方更新后如何同步

在仓库根目录：

```bash
git fetch upstream main
./config/openwrt_main/sync-from-upstream.sh
```

或一步：

```bash
./config/openwrt_main/sync-from-upstream.sh --fetch
```

## 定制摘要

- 默认 LAN：`10.10.10.1`
- 代理：HomeProxy + sing-box（不用 momo / passwall）
- 容器：docker + dockerd + dockerman + lxc
- 关闭：samba4、attendedsysupgrade、ddns、frp
- 内存：zram + zstd
- 蓝牙：kmod-bluetooth / btusb / btsdio + bluez
- USB 共享：华为/安卓驱动（官方已有）+ 苹果 usbmuxd
