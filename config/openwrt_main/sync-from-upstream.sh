#!/bin/bash
#========================================================================================================================
# 从 ophub/amlogic-s9xxx-openwrt 官方同步 openwrt_main 配置，并应用 custom-packages.conf 定制
# 用法（在仓库根目录）:
#   ./config/openwrt_main/sync-from-upstream.sh
#   ./config/openwrt_main/sync-from-upstream.sh --fetch
#========================================================================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CFG_DIR="${ROOT_DIR}/config/openwrt_main"
CUSTOM="${CFG_DIR}/custom-packages.conf"
FRAGMENT="${CFG_DIR}/diy-part2.custom.sh"
PREFS="${CFG_DIR}/build-preferences.env"
CONFIG_FILE="${CFG_DIR}/config"
DIY_FILE="${CFG_DIR}/diy-part2.sh"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

cd "${ROOT_DIR}"

if [[ "${1:-}" == "--fetch" ]]; then
    git fetch "${UPSTREAM_REMOTE}" "${UPSTREAM_BRANCH}"
fi

if ! git rev-parse "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}" >/dev/null 2>&1; then
    echo "错误: 找不到 ${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}"
    exit 1
fi

# shellcheck source=/dev/null
source "${PREFS}"

echo "[sync] 拉取官方 config ..."
git show "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}:config/openwrt_main/config" >"${CONFIG_FILE}"
git show "${UPSTREAM_REMOTE}/${UPSTREAM_BRANCH}:config/openwrt_main/diy-part2.sh" >"${DIY_FILE}"

sed -i '/^ONFIG_PACKAGE_/d' "${CONFIG_FILE}"

enable_pkg() {
    local key="CONFIG_PACKAGE_${1}"
    grep -q "^${key}=y" "${CONFIG_FILE}" && return 0
    if grep -q "^# ${key} is not set" "${CONFIG_FILE}"; then
        sed -i "s/^# ${key} is not set/${key}=y/" "${CONFIG_FILE}"
    else
        echo "${key}=y" >>"${CONFIG_FILE}"
    fi
}

disable_pkg() {
    local key="CONFIG_PACKAGE_${1}"
    sed -i "s/^${key}=y/# ${key} is not set/" "${CONFIG_FILE}" 2>/dev/null || true
    sed -i "s/^${key}=m.*/# ${key} is not set/" "${CONFIG_FILE}" 2>/dev/null || true
}

section=""
while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    line="$(echo "${line}" | xargs)"
    [[ -z "${line}" ]] && continue
    case "${line}" in
    @ENABLE) section="enable" ; continue ;;
    @DISABLE) section="disable" ; continue ;;
    esac
    case "${section}" in
    enable) enable_pkg "${line}" ;;
    disable) disable_pkg "${line}" ;;
    esac
done <"${CUSTOM}"

sed -i "s/^default_ip=\".*\"/default_ip=\"${DEFAULT_IP}\"/" "${DIY_FILE}"

# 在 luci-app-amlogic 克隆之后注入定制片段
TMP="${DIY_FILE}.tmp"
awk -v frag="${FRAGMENT}" '
    /git clone.*luci-app-amlogic/ { print; while ((getline line < frag) > 0) print line; close(frag); next }
    /rm -rf package\/homeproxy/ { skip=1; next }
    skip && /time\.cloudflare/ { skip=0; next }
    skip { next }
    { print }
' "${DIY_FILE}" >"${TMP}" && mv "${TMP}" "${DIY_FILE}"

chmod +x "${DIY_FILE}" "${CFG_DIR}/sync-from-upstream.sh" "${CFG_DIR}/apply-build-preferences.sh" 2>/dev/null || true

if [[ -x "${CFG_DIR}/apply-build-preferences.sh" ]]; then
    "${CFG_DIR}/apply-build-preferences.sh" || true
fi

if [[ -x "${CFG_DIR}/apply-partition-sizes.sh" ]]; then
    "${CFG_DIR}/apply-partition-sizes.sh"
fi

echo "[sync] 完成: ${CONFIG_FILE}"
