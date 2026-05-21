# HomeProxy（sing-box LuCI）
rm -rf package/homeproxy
git clone https://github.com/immortalwrt/homeproxy.git package/homeproxy

# NTP 默认服务器（替换 OpenWrt pool）
sed -i 's/0.openwrt.pool.ntp.org/time.windows.com/' package/base-files/files/bin/config_generate
sed -i 's/1.openwrt.pool.ntp.org/time.apple.com/' package/base-files/files/bin/config_generate
sed -i 's/2.openwrt.pool.ntp.org/time.google.com/' package/base-files/files/bin/config_generate
sed -i 's/3.openwrt.pool.ntp.org/time.aws.com/' package/base-files/files/bin/config_generate
sed -i "/add_list system.ntp.server='time.aws.com'/a \        add_list system.ntp.server='time.cloudflare.com'" package/base-files/files/bin/config_generate
