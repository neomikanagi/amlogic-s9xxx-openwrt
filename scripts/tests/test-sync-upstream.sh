#!/usr/bin/env bash
# Offline regression: syncing follows upstream, never stages local build output,
# and --dry-run never deletes a caller's untracked files.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
unset GITHUB_OUTPUT
init_repo() {
    git init -q -b main "$1"
    git -C "$1" config user.name 'Offline test'
    git -C "$1" config user.email 'offline@example.invalid'
}
init_repo "${T}/upstream"
cd "${T}/upstream"
printf 'old\n' > inherited.txt
printf 'delete me\n' > deleted.txt
printf '/out\nsecret.env\n' > .gitignore
mkdir -p config/docker
printf 'dropped\n' > config/docker/example
git add .; git commit -qm baseline
BASE="$(git rev-parse HEAD)"
git clone -q "${T}/upstream" "${T}/fork"
cd "${T}/fork"
git config user.name 'Offline test'; git config user.email 'offline@example.invalid'
mkdir -p scripts .sync custom
cp "${ROOT}/scripts/sync-upstream.sh" scripts/
printf 'scripts\n.sync\ncustom\n' > .sync/own.txt
printf 'config/docker\n' > .sync/drop.txt
printf 'inherited.txt\n' > .sync/watch.txt
printf 'UPSTREAM_URL=%q\nUPSTREAM_BRANCH=main\n' "${T}/upstream" > .sync/config
printf '%s\n' "${BASE}" > .sync/upstream.sha
printf 'fork-owned\n' > custom/keep.txt
git add .; git commit -qm fork
FORK="$(git rev-parse HEAD)"

cd "${T}/upstream"
printf 'new\n' > inherited.txt
git rm -q deleted.txt
mkdir -p out config/docker custom
printf 'upstream tracked artifact\n' > out/tracked.txt
printf 'new upstream file\n' > new.txt
printf 'must not import\n' > config/docker/another
printf 'must not replace\n' > custom/keep.txt
git add .; git add -f out/tracked.txt; git commit -qm update
NEW="$(git rev-parse HEAD)"

cd "${T}/fork"
mkdir -p out
printf 'local ignored artifact\n' > out/local.txt
printf 'private fixture, never stage\n' > secret.env
printf 'local untracked notes\n' > personal.txt
bash scripts/sync-upstream.sh --dry-run > "${T}/dry.log"
[[ "$(git rev-parse HEAD)" == "${FORK}" ]]
[[ "$(<inherited.txt)" == old ]]
[[ -f deleted.txt && -f personal.txt && -f secret.env && -f out/local.txt ]]
[[ ! -e new.txt && ! -e out/tracked.txt ]]
git diff --quiet; git diff --cached --quiet
[[ "$(<.sync/upstream.sha)" == "${BASE}" ]]
echo 'ok: dry-run leaves HEAD, tracked, untracked and ignored files unchanged'

bash scripts/sync-upstream.sh > "${T}/sync.log"
[[ "$(<inherited.txt)" == new && "$(<new.txt)" == 'new upstream file' ]]
[[ ! -e deleted.txt && ! -e config/docker/example && ! -e config/docker/another ]]
[[ "$(<custom/keep.txt)" == fork-owned ]]
[[ "$(<.sync/upstream.sha)" == "${NEW}" ]]
[[ "$(<out/tracked.txt)" == 'upstream tracked artifact' ]]
git ls-files --error-unmatch out/tracked.txt >/dev/null
for f in out/local.txt secret.env personal.txt; do
    [[ -f "${f}" ]]
    if git ls-files --error-unmatch "${f}" >/dev/null 2>&1; then
        echo "FAIL: staged local file ${f}"; exit 1
    fi
done
echo 'ok: upstream additions/deletions arrive, fork-owned and dropped paths stay correct'
echo 'ok: ignored upstream paths are tracked without staging local artifacts or secrets'
DONE="$(git rev-parse HEAD)"
bash scripts/sync-upstream.sh > "${T}/repeat.log"
[[ "$(git rev-parse HEAD)" == "${DONE}" ]]
echo 'ok: repeated sync is idempotent'
