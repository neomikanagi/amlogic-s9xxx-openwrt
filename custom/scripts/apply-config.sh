#!/usr/bin/env bash
#
# Turn the upstream .config into the one this fork builds.
#
#   apply-config.sh <openwrt-source-dir> [fragment] [packages.check]
#
# Runs inside a prepared OpenWrt tree (feeds installed, .config = config/openwrt_main/config
# after diy-part2.sh). Result: a final, defconfig'ed .config, verified against packages.check.
set -euo pipefail

OWRT="${1:?usage: apply-config.sh <openwrt-dir> [fragment] [packages.check]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="${2:-${HERE}/../openwrt_main/config.fragment}"
CHECK="${3:-${HERE}/../openwrt_main/packages.check}"

cd "${OWRT}"
[[ -f .config ]] || { echo "::error::no .config in ${PWD}"; exit 1; }

defconfig() {
    if ! make defconfig >/tmp/defconfig.log 2>&1; then
        tail -n 40 /tmp/defconfig.log
        echo "::error::make defconfig failed"
        exit 1
    fi
}

# 0. what upstream's config really contains after kconfig resolved it (needed to tell
#    "attached" packages from user choices once the fragment has removed their parents)
defconfig
cp .config .config.upstream-resolved

# 1. fragment on top of .config: drop the old line of every symbol it mentions, append it
awk '
    FNR == NR {
        if ($0 ~ /^CONFIG_[A-Za-z0-9_+.-]+=/) { s = $0; sub(/^CONFIG_/, "", s); sub(/=.*/, "", s); sym[s] = 1; add[++n] = $0 }
        else if ($0 ~ /^# CONFIG_[A-Za-z0-9_+.-]+ is not set$/) { s = $2; sub(/^CONFIG_/, "", s); sym[s] = 1; add[++n] = $0 }
        next
    }
    {
        s = ""
        if ($0 ~ /^CONFIG_[A-Za-z0-9_+.-]+=/) { s = $0; sub(/^CONFIG_/, "", s); sub(/=.*/, "", s) }
        else if ($0 ~ /^# CONFIG_[A-Za-z0-9_+.-]+ is not set$/) { s = $2; sub(/^CONFIG_/, "", s) }
        if (s == "" || !(s in sym)) print
    }
    END { for (i = 1; i <= n; i++) print add[i] }
' "${FRAGMENT}" .config >.config.new
mv .config.new .config
echo "fragment applied: $(grep -cE '^(CONFIG_[A-Za-z0-9_+.-]+=|# CONFIG_[A-Za-z0-9_+.-]+ is not set$)' "${FRAGMENT}") settings"

# 2. resolve, then drop the packages that only the disabled ones needed, resolve again
defconfig
python3 "${HERE}/prune-orphans.py" .config.upstream-resolved tmp/.packageinfo "${FRAGMENT}" >/tmp/orphans.txt
# Disable the orphans, and the fragment's own disabled packages once more: kconfig may have
# switched some of them back on in the first pass (a library that "selects" its daemon), and
# a symbol that is written back as =y stays on although nothing needs it any more.
{
    sed -nE 's/^# CONFIG_PACKAGE_([^ ]+) is not set$/\1/p' "${FRAGMENT}"
    cat /tmp/orphans.txt
} | sort -u | while read -r pkg; do
    [[ -n "${pkg}" ]] || continue
    sed -i "/^CONFIG_PACKAGE_${pkg//./\\.}=/d" .config
    grep -qxF "# CONFIG_PACKAGE_${pkg} is not set" .config || echo "# CONFIG_PACKAGE_${pkg} is not set" >>.config
done
defconfig

# 3. verify
rc=0
while read -r verb pkgs; do
    case "${verb}" in
    forbid)
        for p in ${pkgs}; do
            if grep -qE "^CONFIG_PACKAGE_${p//./\\.}=[ym]$" .config; then
                echo "::error::forbidden package is still enabled: ${p}"
                rc=1
            fi
        done
        ;;
    require)
        for p in ${pkgs}; do
            if ! grep -qE "^CONFIG_PACKAGE_${p//./\\.}=[ym]$" .config; then
                echo "::error::required package is missing from the final .config: ${p}"
                rc=1
            fi
        done
        ;;
    esac
done < <(grep -vE '^\s*(#|$)' "${CHECK}")
[[ "${rc}" -eq 0 ]] || exit 1
echo "config OK: $(grep -cE '^CONFIG_PACKAGE_[^=]+=y$' .config) packages built in, $(grep -cE '^CONFIG_PACKAGE_[^=]+=m$' .config) as modules"
