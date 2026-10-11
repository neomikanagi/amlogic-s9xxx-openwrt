#!/usr/bin/env bash
#========================================================================================
# Follow upstream (ophub/amlogic-s9xxx-openwrt) except for what this fork changed.
#
#   scripts/sync-upstream.sh [--push] [--dry-run]
#
# The fork is "upstream's tree + our own paths", so there is nothing to merge:
#   * .sync/own.txt   - paths that are ours; never taken from upstream
#   * .sync/drop.txt  - upstream paths we do not want; removed after every sync
#   * everything else is replaced by upstream's current tree (new files come in, files that
#     upstream deleted go away)
# custom/ patches upstream's files at BUILD time, in small asserted edits, rather than carrying
# modified copies, so a sync can never silently lose a change of ours or an upstream fix.
#
# --push     push the sync commit to origin
# --dry-run  show what would change, leave the tree as it was
#
# Exit: 0 = done / already up to date, 1 = error. When running in GitHub Actions the outputs
# `changed` and `relevant` (a file listed in .sync/watch.txt or the build inputs changed) are set.
#========================================================================================
set -euo pipefail

PUSH=0
DRY=0
for a in "$@"; do
    case "${a}" in
    --push) PUSH=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown option ${a}" >&2; exit 1 ;;
    esac
done

cd "$(git rev-parse --show-toplevel)"
# shellcheck disable=SC1091
source .sync/config
readlist() { grep -vE '^\s*(#|$)' "$1" || true; }
output() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "$1=$2" >>"${GITHUB_OUTPUT}" || true; }

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "${UPSTREAM_URL}"
git fetch -q upstream "${UPSTREAM_BRANCH}"
U="upstream/${UPSTREAM_BRANCH}"
U_SHA="$(git rev-parse "${U}")"
LAST="$(cat .sync/upstream.sha 2>/dev/null || true)"

if [[ "${LAST}" == "${U_SHA}" ]]; then
    echo "up to date with upstream ${U_SHA:0:9}"
    output changed false
    output relevant false
    exit 0
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "the working tree is not clean, commit or stash first" >&2
    exit 1
fi

mapfile -t OWN < <(readlist .sync/own.txt)
mapfile -t DROP < <(readlist .sync/drop.txt)
mapfile -t WATCH < <(readlist .sync/watch.txt)
BEFORE="$(git rev-parse HEAD)"

# 1. remove every tracked file that is not ours
is_own() {
    local f="$1" o
    for o in "${OWN[@]}"; do
        [[ "${f}" == "${o}" || "${f}" == "${o}/"* ]] && return 0
    done
    return 1
}
git ls-files -z | while IFS= read -r -d '' f; do
    is_own "${f}" || printf '%s\0' "${f}"
done | xargs -0 -r git rm -q -f --

# 2. upstream's tree, without our paths and without the dropped ones
excl=(--anchored)
for p in "${OWN[@]}" "${DROP[@]}"; do excl+=("--exclude=${p}" "--exclude=${p}/*"); done
git archive "${U}" | tar -x "${excl[@]}"
# files ignored by .gitignore (e.g. kernel/u-boot downloads) must not hide a change
git add -A -f
printf '%s\n' "${U_SHA}" >.sync/upstream.sha
git add -f .sync/upstream.sha

if git diff --cached --quiet -- . ':!.sync/upstream.sha'; then
    echo "upstream ${U_SHA:0:9} brings nothing that is not already here"
    git commit -q -m "pi: sync: upstream ${U_SHA:0:9} (no file changes)" -- .sync/upstream.sha 2>/dev/null || true
    output changed false
    output relevant false
    exit 0
fi

CHANGED="$(git diff --cached --name-status -- . ':!.sync/upstream.sha')"
echo "${CHANGED}" | head -n 60
n="$(wc -l <<<"${CHANGED}")"
[[ "${n}" -gt 60 ]] && echo "... ${n} files in total"

relevant=false
while IFS=$'\t' read -r _ path _; do
    for w in "${WATCH[@]}"; do
        [[ "${path}" == "${w}" || "${path}" == "${w}/"* ]] && relevant=true
    done
    case "${path}" in make-openwrt/* | config/openwrt_main/* | remake | action.yml) relevant=true ;; esac
done <<<"${CHANGED}"
output changed true
output relevant "${relevant}"

if [[ "${DRY}" -eq 1 ]]; then
    git reset -q --hard "${BEFORE}"
    git clean -fdq
    echo "(dry run: tree restored)"
    exit 0
fi

LOG="$(git log --oneline -n 25 "${LAST:-${U}~25}..${U}" 2>/dev/null || true)"
{
    echo "pi: sync: upstream ${U_SHA:0:9}"
    echo
    echo "Upstream ${UPSTREAM_URL%.git} ${UPSTREAM_BRANCH}${LAST:+, ${LAST:0:9}..${U_SHA:0:9}}"
    echo
    echo "${LOG}"
    echo
    echo "Files:"
    echo "${CHANGED}" | head -n 80
} >/tmp/sync-msg.txt
git commit -q -F /tmp/sync-msg.txt
echo "committed: $(git log --oneline -1)"

if [[ "${PUSH}" -eq 1 ]]; then
    git push origin HEAD
fi
