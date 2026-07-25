#!/usr/bin/env bash
# mcc-pkg: a minimal MC package build tool (toolchain / package-manager slice).
#
# Reads a declarative `mcpkg.txt` manifest and builds the package by lowering its
# entry module — whose `import`s pull in package-local modules and dependencies
# — to a linkable object via the selected compile-to-object driver. This is the foundational
# build/packaging layer; a dependency registry and release publishing build on
# top of it.
#
# Usage:
#   tools/toolchain/mcc-pkg.sh info  [manifest|dir]   # print the parsed manifest
#   tools/toolchain/mcc-pkg.sh deps  [manifest|dir]   # resolve + version-check deps
#   tools/toolchain/mcc-pkg.sh build [manifest|dir]   # build entry -> output object
#
# The manifest path defaults to ./mcpkg.txt; a directory argument looks for
# mcpkg.txt inside it.
#
# Dependencies are declared in a `[deps]` section as `name = path@version`;
# `deps`/`build` resolve each transitively and verify the dependency package's
# own manifest `version` matches the requested one.
set -euo pipefail

MCC="${MCC_UNDER_TEST:-${MCC:-zig-out/bin/mcc}}"
MCC_PKG_CC="${MCC_PKG_CC:-}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"

cmd="${1:-}"
arg="${2:-mcpkg.txt}"
[ -d "$arg" ] && arg="$arg/mcpkg.txt"
MANIFEST="$arg"

if [ -z "$cmd" ] || [ ! -f "$MANIFEST" ]; then
    echo "usage: mcc-pkg.sh {info|deps|build} [manifest|dir]" >&2
    exit 2
fi

# Parse a top-level `key = value` (above any `[section]`) from a given manifest.
field_in() {
    sed -E '/^[[:space:]]*\[/q' "$1" | sed -n -E "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\1/p" | head -n1
}
field() { field_in "$MANIFEST" "$1"; }

validate_package_file_path() {
    local label="$1" value="$2" component
    [ -n "$value" ] || { echo "mcc-pkg: manifest missing '$label'" >&2; exit 1; }
    case "$value" in
        /*|\\*|[A-Za-z]:/*|[A-Za-z]:\\*) echo "mcc-pkg: manifest '$label' must be package-relative" >&2; exit 1 ;;
    esac
    IFS='/' read -r -a components <<< "$value"
    for component in "${components[@]}"; do
        case "$component" in
            ""|"."|"..") echo "mcc-pkg: manifest '$label' contains an unsafe path component" >&2; exit 1 ;;
        esac
    done
}

contained_package_file() {
    local label="$1" value="$2" require_existing="$3"
    validate_package_file_path "$label" "$value"
    local candidate="$MANIFEST_DIR/$value" parent
    parent="$(dirname "$candidate")"
    [ -d "$parent" ] || { echo "mcc-pkg: manifest '$label' parent does not exist" >&2; exit 1; }
    [ ! -L "$candidate" ] || { echo "mcc-pkg: manifest '$label' cannot be a symlink" >&2; exit 1; }
    parent="$(cd "$parent" && pwd -P)"
    case "$parent" in
        "$MANIFEST_DIR"|"$MANIFEST_DIR"/*) ;;
        *) echo "mcc-pkg: manifest '$label' escapes the package root" >&2; exit 1 ;;
    esac
    if [ "$require_existing" = 1 ] && [ ! -f "$candidate" ]; then
        echo "mcc-pkg: manifest '$label' does not name a regular file" >&2
        exit 1
    fi
    printf '%s/%s\n' "$parent" "$(basename "$candidate")"
}

# Emit `name path version` for each `[deps]` entry (`name = path@version`).
deps_of() {
    awk '
        /^[[:space:]]*\[deps\]/ { indeps=1; next }
        /^[[:space:]]*\[/       { indeps=0 }
        indeps && /=/ {
            line=$0; sub(/#.*/, "", line)
            n=line; sub(/[[:space:]]*=.*/, "", n); gsub(/[[:space:]]/, "", n)
            v=line; sub(/[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v)
            if (n=="") next
            path=v; ver=""
            if (index(v, "@")) { path=v; sub(/@.*/, "", path); ver=v; sub(/.*@/, "", ver) }
            print n, path, ver
        }
    ' "$1"
}

PKG_NAME="$(field name)"
PKG_VERSION="$(field version)"
PKG_ENTRY="$(field entry)"
PKG_OUTPUT="$(field output)"
MANIFEST_DIR="$(cd "$(dirname "$MANIFEST")" && pwd)"

# Resolve every declared dependency transitively: locate each manifest and verify
# its requested version. Fails on a missing dep or a version mismatch.
resolve_manifest_deps() {
    local manifest="$1"
    local base_dir="$2"
    local seen="${3:-}"
    deps_of "$manifest" | while read -r name path ver; do
        [ -n "$name" ] || continue
        local dep_manifest="$base_dir/$path/mcpkg.txt"
        if [ ! -f "$dep_manifest" ]; then
            echo "mcc-pkg: dependency '$name' not found at $path/mcpkg.txt" >&2
            exit 1
        fi
        local have
        have="$(field_in "$dep_manifest" version)"
        if [ -n "$ver" ] && [ "$have" != "$ver" ]; then
            echo "mcc-pkg: dependency '$name' version mismatch (wanted $ver, found $have)" >&2
            exit 1
        fi
        echo "$name $path ${have:-?}"
        local dep_dir
        dep_dir="$(cd "$(dirname "$dep_manifest")" && pwd)"
        case " $seen " in
            *" $dep_manifest "*) ;;
            *) resolve_manifest_deps "$dep_manifest" "$dep_dir" "$seen $dep_manifest" ;;
        esac
    done
}

resolve_deps() {
    resolve_manifest_deps "$MANIFEST" "$MANIFEST_DIR" "$MANIFEST"
}

case "$cmd" in
    info)
        echo "package: ${PKG_NAME:-?} ${PKG_VERSION:-}"
        echo "entry:   ${PKG_ENTRY:-?}"
        echo "output:  ${PKG_OUTPUT:-?}"
        ;;
    deps)
        resolved="$(resolve_deps)"
        if [ -z "$resolved" ]; then
            echo "mcc-pkg: ${PKG_NAME:-package} has no dependencies"
        else
            echo "$resolved" | while read -r name path ver; do
                echo "dep: $name $ver ($path)"
            done
        fi
        ;;
    build)
        # Resolve + version-check dependencies before building (fails fast).
        resolve_deps >/dev/null
        ENTRY="$(contained_package_file entry "$PKG_ENTRY" 1)"
        OUT="$(contained_package_file output "$PKG_OUTPUT" 0)"
        DRIVER="${MCC_PKG_CC:-$HERE/tools/toolchain/mcc-cc.sh}"
        MCC_UNDER_TEST="$MCC" MCC="$MCC" "$DRIVER" "$ENTRY" -o "$OUT" >/dev/null
        echo "mcc-pkg: built ${PKG_NAME:-package} -> $OUT"
        ;;
    *)
        echo "mcc-pkg: unknown command '$cmd'" >&2
        exit 2
        ;;
esac
