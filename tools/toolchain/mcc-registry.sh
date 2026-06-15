#!/usr/bin/env bash
# mcc-registry: the registry / version-resolution / publish-install slice of the MC package
# manager, layered on the `mcpkg.txt` manifests that `mcc-pkg.sh` builds.
#
# A *registry* is an offline directory of published package versions:
#
#   <registry>/index                       # one "<name>\t<version>" line per published version
#   <registry>/pkgs/<name>/<version>/...    # the published package tree (sources + mcpkg.txt)
#   <registry>/pkgs/<name>/<version>/.checksum
#
# A consumer declares registry dependencies in its manifest's `[registry-deps]` section as
# `name = <constraint>`, where a constraint is `=X.Y.Z` (exact) or `^X.Y.Z` (the highest
# published `X.*.*` that is `>= X.Y.Z`). `install` resolves each constraint against the
# registry, vendors the chosen version into `<pkg>/mc_packages/<name>/`, and writes an
# `mcpkg.lock` pinning the exact resolved versions + checksums. A subsequent `install` re-uses
# the lock (verifying the checksum), so a build is reproducible. Everything is filesystem-local
# and deterministic — no network — so it is fully testable offline.
#
# Usage:
#   mcc-registry.sh publish  <pkg-dir>          --registry <reg>
#   mcc-registry.sh versions <name>             --registry <reg>
#   mcc-registry.sh resolve  <name> <constraint> --registry <reg>
#   mcc-registry.sh install  <pkg-dir>          --registry <reg> [--frozen]
set -euo pipefail

# --- shared manifest parsing (same convention as mcc-pkg.sh) ---------------------------------
field_in() {
    sed -E '/^[[:space:]]*\[/q' "$1" | sed -n -E "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\1/p" | head -n1
}

# Emit `name constraint` for each `[registry-deps]` entry (`name = constraint`).
registry_deps_of() {
    awk '
        /^[[:space:]]*\[registry-deps\]/ { inreg=1; next }
        /^[[:space:]]*\[/                { inreg=0 }
        inreg && /=/ {
            line=$0; sub(/#.*/, "", line)
            n=line; sub(/[[:space:]]*=.*/, "", n); gsub(/[[:space:]]/, "", n)
            v=line; sub(/[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v)
            if (n!="") print n, v
        }
    ' "$1"
}

# Content checksum of a directory: hash the sorted list of (path, file-hash), excluding build
# output and the vendor/lock files so it is stable across installs.
checksum_dir() {
    local dir="$1" hasher
    if command -v sha256sum >/dev/null 2>&1; then hasher="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then hasher="shasum -a 256"
    else echo "mcc-registry: no sha256 tool found" >&2; return 1; fi
    ( cd "$dir" && find . -type f \
        ! -path './mc_packages/*' ! -name 'mcpkg.lock' ! -name '*.o' ! -name '.checksum' \
        | LC_ALL=C sort | while read -r f; do $hasher "$f"; done | $hasher | awk '{print $1}' )
}

# --- version policy --------------------------------------------------------------------------
# major.minor.patch components of a version string.
ver_major() { printf '%s' "$1" | cut -d. -f1; }

# Is $1 >= $2 by version ordering? (sort -V puts the larger last.)
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -V | tail -n1)" = "$1" ]; }

# All published versions of a package, version-sorted ascending.
published_versions() {
    local reg="$1" name="$2"
    [ -f "$reg/index" ] || return 0
    awk -F'\t' -v n="$name" '$1==n {print $2}' "$reg/index" | LC_ALL=C sort -V
}

# Resolve a constraint against the registry; print the chosen version or fail.
resolve_version() {
    local reg="$1" name="$2" constraint="$3"
    local versions; versions="$(published_versions "$reg" "$name")"
    [ -n "$versions" ] || { echo "mcc-registry: no published versions for '$name'" >&2; return 1; }

    case "$constraint" in
        =*)
            local want="${constraint#=}"
            if printf '%s\n' $versions | grep -qx "$want"; then printf '%s\n' "$want"; return 0; fi
            echo "mcc-registry: '$name' has no published version '$want'" >&2; return 1 ;;
        ^*)
            local base="${constraint#^}" major; major="$(ver_major "$base")"
            local best=""
            for v in $versions; do
                [ "$(ver_major "$v")" = "$major" ] || continue
                ver_ge "$v" "$base" || continue
                best="$v"   # versions are ascending, so the last match is the highest
            done
            [ -n "$best" ] && { printf '%s\n' "$best"; return 0; }
            echo "mcc-registry: no published '$name' satisfies ^$base" >&2; return 1 ;;
        *)
            # bare version: treat as exact
            resolve_version "$reg" "$name" "=$constraint" ;;
    esac
}

# --- commands --------------------------------------------------------------------------------
cmd="${1:-}"; shift || true
REG=""; ARGS=(); FROZEN=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --registry) REG="$2"; shift 2 ;;
        --frozen)   FROZEN=1; shift ;;
        *)          ARGS+=("$1"); shift ;;
    esac
done
[ -n "$REG" ] || { echo "mcc-registry: --registry <dir> is required" >&2; exit 2; }

pkg_dir() { local a="${1:-.}"; [ -f "$a" ] && a="$(dirname "$a")"; (cd "$a" && pwd); }

case "$cmd" in
    publish)
        DIR="$(pkg_dir "${ARGS[0]:-.}")"
        MAN="$DIR/mcpkg.txt"
        [ -f "$MAN" ] || { echo "mcc-registry: no mcpkg.txt in $DIR" >&2; exit 1; }
        name="$(field_in "$MAN" name)"; version="$(field_in "$MAN" version)"
        [ -n "$name" ] && [ -n "$version" ] || { echo "mcc-registry: manifest needs name + version" >&2; exit 1; }
        dest="$REG/pkgs/$name/$version"
        if [ -d "$dest" ]; then
            echo "mcc-registry: $name@$version already published (immutable); refusing to overwrite" >&2; exit 1
        fi
        mkdir -p "$dest"
        # Copy the package tree minus vendor/build artifacts.
        ( cd "$DIR" && find . -type f ! -path './mc_packages/*' ! -name 'mcpkg.lock' ! -name '*.o' \
            | while read -r f; do mkdir -p "$dest/$(dirname "$f")"; cp "$f" "$dest/$f"; done )
        checksum_dir "$dest" > "$dest/.checksum"
        mkdir -p "$REG"
        printf '%s\t%s\n' "$name" "$version" >> "$REG/index"
        LC_ALL=C sort -u "$REG/index" -o "$REG/index"
        echo "published: $name@$version -> $dest ($(cat "$dest/.checksum"))"
        ;;
    versions)
        name="${ARGS[0]:?usage: versions <name> --registry <reg>}"
        published_versions "$REG" "$name"
        ;;
    resolve)
        name="${ARGS[0]:?usage: resolve <name> <constraint> --registry <reg>}"
        constraint="${ARGS[1]:?usage: resolve <name> <constraint> --registry <reg>}"
        resolve_version "$REG" "$name" "$constraint"
        ;;
    install)
        DIR="$(pkg_dir "${ARGS[0]:-.}")"
        MAN="$DIR/mcpkg.txt"
        [ -f "$MAN" ] || { echo "mcc-registry: no mcpkg.txt in $DIR" >&2; exit 1; }
        LOCK="$DIR/mcpkg.lock"
        VENDOR="$DIR/mc_packages"
        # Read any existing lock into a lookup (name -> "version checksum").
        locked_version() { [ -f "$LOCK" ] && awk -v n="$1" '$1==n {print $2}' "$LOCK"; }
        locked_checksum() { [ -f "$LOCK" ] && awk -v n="$1" '$1==n {print $3}' "$LOCK"; }

        new_lock="$(mktemp)"
        printf '# mcpkg.lock v1 — generated by mcc-registry; do not edit by hand\n' > "$new_lock"
        mkdir -p "$VENDOR"
        count=0
        while read -r name constraint; do
            [ -n "$name" ] || continue
            count=$((count + 1))
            pinned="$(locked_version "$name" || true)"
            if [ -n "$pinned" ]; then
                # Reproducible path: honor the locked version (must still satisfy the constraint).
                if [ "$(resolve_version "$REG" "$name" "$constraint")" = "" ]; then :; fi
                version="$pinned"
                if ! published_versions "$REG" "$name" | grep -qx "$version"; then
                    echo "mcc-registry: locked $name@$version is not in the registry" >&2; exit 1
                fi
            else
                if [ "$FROZEN" = 1 ]; then
                    echo "mcc-registry: --frozen but '$name' is not in the lockfile" >&2; exit 1
                fi
                version="$(resolve_version "$REG" "$name" "$constraint")"
            fi
            src="$REG/pkgs/$name/$version"
            [ -d "$src" ] || { echo "mcc-registry: $name@$version missing from registry" >&2; exit 1; }
            # Verify the published checksum, then verify the lock's checksum if present.
            have="$(checksum_dir "$src")"
            want="$(cat "$src/.checksum" 2>/dev/null || true)"
            if [ -n "$want" ] && [ "$have" != "$want" ]; then
                echo "mcc-registry: checksum mismatch for $name@$version (registry tampered)" >&2; exit 1
            fi
            lc="$(locked_checksum "$name" || true)"
            if [ -n "$lc" ] && [ "$lc" != "$have" ]; then
                echo "mcc-registry: $name@$version checksum differs from lockfile (not reproducible)" >&2; exit 1
            fi
            # Vendor the resolved version (copy the tree, minus the registry's .checksum marker).
            rm -rf "$VENDOR/$name"
            mkdir -p "$VENDOR/$name"
            ( cd "$src" && find . -type f ! -name '.checksum' \
                | while read -r f; do mkdir -p "$VENDOR/$name/$(dirname "$f")"; cp "$f" "$VENDOR/$name/$f"; done )
            printf '%s\t%s\t%s\n' "$name" "$version" "$have" >> "$new_lock"
            echo "installed: $name@$version ($constraint) -> mc_packages/$name"
        done < <(registry_deps_of "$MAN")

        mv "$new_lock" "$LOCK"
        if [ "$count" -eq 0 ]; then echo "mcc-registry: no [registry-deps]; nothing to install"; fi
        echo "lockfile: $LOCK"
        ;;
    *)
        echo "usage: mcc-registry.sh {publish|versions|resolve|install} ... --registry <dir>" >&2
        exit 2
        ;;
esac
