#!/usr/bin/env bash
#
# Do custom/'s edits of upstream files still apply? (the same step the build starts with)
#
#   scripts/check-patches.sh
#
# Clones luci-app-amlogic, runs custom/openwrt_main/stage-rootfs-files.sh in a throw-away copy
# of this repository. Exit 1 = upstream moved and a patch / edit needs re-basing.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
git ls-files -z | xargs -0 -I{} cp --parents -a {} "${T}/" 2>/dev/null || true
git clone -q -b main --depth=1 https://github.com/ophub/luci-app-amlogic.git "${T}/luci-app-amlogic"
(cd "${T}" && bash custom/openwrt_main/stage-rootfs-files.sh "${T}" "${T}/luci-app-amlogic/luci-app-amlogic")
echo "patches OK"
