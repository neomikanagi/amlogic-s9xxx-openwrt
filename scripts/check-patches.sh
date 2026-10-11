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
mkdir -p "${T}/custom/rootfs-files/lib/upgrade"
printf '%s\n' '# stale upgrade hook from an older rootfs' > "${T}/custom/rootfs-files/lib/upgrade/platform.sh"
(cd "${T}" && bash custom/openwrt_main/stage-rootfs-files.sh "${T}" "${T}/luci-app-amlogic/luci-app-amlogic")
# Repack-only must refresh every file and symlink from the current files/ tree,
# not merely keep whichever upgrade hook was baked into the older rootfs.
while IFS= read -r -d '' f; do
    cmp -s "${T}/${f}" "${T}/custom/rootfs-files/${f#files/}" || {
        echo "stale or missing packaging overlay: ${f}" >&2; exit 1;
    }
done < <(find "${T}/files" -type f -printf 'files/%P\0')
while IFS= read -r -d '' f; do
    [[ -L "${T}/custom/rootfs-files/${f#files/}" ]] &&
        [[ "$(readlink "${T}/${f}")" == "$(readlink "${T}/custom/rootfs-files/${f#files/}")" ]] || {
        echo "stale or missing packaging symlink: ${f}" >&2; exit 1;
    }
done < <(find "${T}/files" -type l -printf 'files/%P\0')
echo "patches and current files/ packaging overlay OK"
