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

### 本地

```bash
git fetch upstream main
./sync-upstream.sh
# 或 ./sync-upstream.sh --fetch
```

### 云端（GitHub Actions，推荐）

仓库已包含工作流 **Sync upstream openwrt_main**（`.github/workflows/sync-upstream-config.yml`）：

| 触发方式 | 说明 |
|----------|------|
| **每周一 14:00 北京时间** | 自动 `fetch` 官方 → `merge` → 应用 `custom-packages.conf` → 有变更则 `push` |
| **手动** | GitHub → Actions → *Sync upstream openwrt_main* → Run workflow |

手动运行时可选 **合并官方全仓库**（默认开启）：拉取新机型、内核脚本、workflow 等；关闭则仅重跑 config 定制（不 merge）。

**前提**：仓库 Settings → Actions → General → Workflow permissions 选 **Read and write**。

## 定制摘要

- 默认 LAN：`10.10.10.1`
- 代理：HomeProxy + sing-box（不用 momo / passwall）
- 容器：docker + dockerd + dockerman + lxc
- 关闭：samba4、attendedsysupgrade、ddns、frp
- 内存：zram + zstd
- 蓝牙：kmod-bluetooth / btusb / btsdio + bluez
- USB 共享：华为/安卓驱动（官方已有）+ 苹果 usbmuxd
