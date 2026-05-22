# A/B 根分区 650MB（全局，编译时 patch luci-app-amlogic 安装脚本）
ROOT_MB="650"
INSTALL_SCRIPTS=(
    package/luci-app-amlogic/luci-app-amlogic/root/usr/sbin/openwrt-install-amlogic
    package/luci-app-amlogic/root/usr/sbin/openwrt-install-amlogic
)
for _f in "${INSTALL_SCRIPTS[@]}"; do
    if [[ -f "${_f}" ]]; then
        sed -i "s/^ROOT1=\"[0-9]*\"/ROOT1=\"${ROOT_MB}\"/" "${_f}"
        sed -i "s/^ROOT2=\"[0-9]*\"/ROOT2=\"${ROOT_MB}\"/" "${_f}"
        grep -q "^ROOT1=\"${ROOT_MB}\"" "${_f}" || echo "WARN: ROOT1 patch failed on ${_f}"
        echo "Patched EMMC ROOT1/ROOT2=${ROOT_MB} in ${_f}"
    fi
done

# HomeProxy（sing-box LuCI）
rm -rf package/homeproxy
git clone https://github.com/immortalwrt/homeproxy.git package/homeproxy

# NTP 默认服务器（替换 OpenWrt pool）
sed -i 's/0.openwrt.pool.ntp.org/time.windows.com/' package/base-files/files/bin/config_generate
sed -i 's/1.openwrt.pool.ntp.org/time.apple.com/' package/base-files/files/bin/config_generate
sed -i 's/2.openwrt.pool.ntp.org/time.google.com/' package/base-files/files/bin/config_generate
sed -i 's/3.openwrt.pool.ntp.org/time.aws.com/' package/base-files/files/bin/config_generate
sed -i "/add_list system.ntp.server='time.aws.com'/a \        add_list system.ntp.server='time.cloudflare.com'" package/base-files/files/bin/config_generate
