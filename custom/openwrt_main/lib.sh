# Shared helpers for the custom/openwrt_main scripts (sourced, not executed).

die() {
    echo "::error::${0##*/}: $*"
    exit 1
}

# sedx <file> <sed-expression> <literal that must be in the file afterwards> [literal that must be gone]
# An edit of a freshly downloaded upstream file that no longer matches makes the build fail
# early instead of shipping a half-patched image.
sedx() {
    [[ -f "$1" ]] || die "$1 does not exist"
    sed -i -E "$2" "$1"
    grep -qF -- "$3" "$1" || die "edit of $1 did not produce '$3' (upstream changed?)"
    [[ -z "${4:-}" ]] || ! grep -qF -- "$4" "$1" || die "'$4' is still in $1 after the edit (upstream changed?)"
}
