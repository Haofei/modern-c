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

die() { echo "mcc-registry: $*" >&2; exit 1; }

validate_name() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [ "$value" != "." ] && [ "$value" != ".." ] ||
        die "invalid package name '$value'"
}

validate_version() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid package version '$value'"
}

validate_constraint() {
    local value="$1" version="$1"
    case "$value" in =*|^*) version="${value:1}" ;; esac
    validate_version "$version"
}

canonical_dir() {
    local path="$1"
    [ ! -L "$path" ] || die "refusing symlinked root '$path'"
    mkdir -p "$path"
    (cd "$path" && pwd -P)
}

require_plain_path() {
    local root="$1"; shift
    local current="$root" component
    for component in "$@"; do
        current="$current/$component"
        [ ! -L "$current" ] || die "refusing symlink in managed path '$current'"
    done
    case "$current" in "$root"/*) ;; *) die "managed path escaped root '$root'" ;; esac
}

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

# Content checksum of the exact installed inventory. The only excluded file is
# the checksum record itself; every other regular file is authenticated.
# Length-prefixing paths makes newline and other unusual Unix names unambiguous.
checksum_dir() {
    python3 - "$1" <<'PY'
import hashlib, os, stat, struct, sys
root = os.path.realpath(sys.argv[1])
entries = []
for directory, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames.sort()
    filenames.sort()
    for name in dirnames:
        path = os.path.join(directory, name)
        rel = os.path.relpath(path, root)
        if not stat.S_ISDIR(os.lstat(path).st_mode):
            raise SystemExit(f"mcc-registry: non-directory package entry: {rel}")
    for name in filenames:
        path = os.path.join(directory, name)
        rel = os.path.relpath(path, root)
        if rel == ".checksum":
            continue
        mode = os.lstat(path).st_mode
        if not stat.S_ISREG(mode):
            raise SystemExit(f"mcc-registry: non-regular package entry: {rel}")
        entries.append((os.fsencode(rel), path))
digest = hashlib.sha256()
for encoded, path in sorted(entries):
    size = os.path.getsize(path)
    digest.update(struct.pack(">Q", len(encoded)))
    digest.update(encoded)
    digest.update(struct.pack(">Q", size))
    with open(path, "rb") as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
print(digest.hexdigest())
PY
}

copy_publish_inventory() {
    python3 - "$1" "$2" <<'PY'
import os, shutil, stat, sys
source, target = map(os.path.realpath, sys.argv[1:3])
for directory, dirnames, filenames in os.walk(source, followlinks=False):
    rel_dir = os.path.relpath(directory, source)
    dirnames[:] = sorted(d for d in dirnames if not (rel_dir == "." and d == "mc_packages"))
    for name in dirnames:
        path = os.path.join(directory, name)
        rel = os.path.relpath(path, source)
        if not stat.S_ISDIR(os.lstat(path).st_mode):
            raise SystemExit(f"mcc-registry: refusing non-directory package entry: {rel}")
    for name in sorted(filenames):
        if (rel_dir == "." and name == "mcpkg.lock") or name.endswith(".o"):
            continue
        path = os.path.join(directory, name)
        rel = os.path.relpath(path, source)
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise SystemExit(f"mcc-registry: refusing non-regular package entry: {rel}")
        destination = os.path.join(target, rel)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copyfile(path, destination)
PY
}

copy_installed_inventory() {
    python3 - "$1" "$2" <<'PY'
import os, shutil, stat, sys
source, target = map(os.path.realpath, sys.argv[1:3])
for directory, dirnames, filenames in os.walk(source, followlinks=False):
    dirnames.sort()
    for name in dirnames:
        path = os.path.join(directory, name)
        rel = os.path.relpath(path, source)
        if not stat.S_ISDIR(os.lstat(path).st_mode):
            raise SystemExit(f"mcc-registry: refusing non-directory published entry: {rel}")
    for name in sorted(filenames):
        path = os.path.join(directory, name)
        rel = os.path.relpath(path, source)
        if rel == ".checksum":
            continue
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise SystemExit(f"mcc-registry: refusing non-regular published entry: {rel}")
        destination = os.path.join(target, rel)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.copyfile(path, destination)
PY
}

# --- version policy --------------------------------------------------------------------------
# major.minor.patch components of a version string.
ver_major() { printf '%s' "$1" | cut -d. -f1; }

# Is $1 >= $2 by version ordering? (sort -V puts the larger last.)
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort -V | tail -n1)" = "$1" ]; }

version_satisfies() {
    local version="$1" constraint="$2" base major
    validate_version "$version"
    validate_constraint "$constraint"
    case "$constraint" in
        =*) [ "$version" = "${constraint#=}" ] ;;
        ^*)
            base="${constraint#^}"; major="$(ver_major "$base")"
            [ "$(ver_major "$version")" = "$major" ] && ver_ge "$version" "$base"
            ;;
        *) [ "$version" = "$constraint" ] ;;
    esac
}

# All published versions of a package, version-sorted ascending.
published_versions() {
    local reg="$1" name="$2"
    validate_name "$name"
    local package_root="$reg/pkgs/$name" entry version
    [ -d "$package_root" ] || return 0
    for entry in "$package_root"/*; do
        [ -d "$entry" ] || continue
        version="$(basename "$entry")"
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s\n' "$version"
        fi
    done | LC_ALL=C sort -V
}

# The immutable package directories are authoritative; `index` is a rebuildable
# cache for humans and older tooling, never the publication commit point.
rebuild_index() {
    local reg="$1" output="$2" package name_dir version_dir name version
    : > "$output"
    for name_dir in "$reg"/pkgs/*; do
        [ -d "$name_dir" ] || continue
        name="$(basename "$name_dir")"
        validate_name "$name"
        for version_dir in "$name_dir"/*; do
            [ -d "$version_dir" ] || continue
            version="$(basename "$version_dir")"
            [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            printf '%s\t%s\n' "$name" "$version" >> "$output"
        done
    done
    LC_ALL=C sort -u "$output" -o "$output"
}

# Resolve a constraint against the registry; print the chosen version or fail.
resolve_version() {
    local reg="$1" name="$2" constraint="$3"
    validate_name "$name"
    validate_constraint "$constraint"
    local versions; versions="$(published_versions "$reg" "$name")"
    [ -n "$versions" ] || { echo "mcc-registry: no published versions for '$name'" >&2; return 1; }
    local indexed
    for indexed in $versions; do validate_version "$indexed"; done

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

acquire_process_lock() {
    local lock="$1" label="$2" owner
    if mkdir "$lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock/owner"
        return 0
    fi
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
        die "$label is busy"
    fi
    # A dead owner cannot protect state. Recovery is operation-specific; after
    # it runs, replacing this exact lock directory is safe and bounded.
    rm -rf -- "$lock"
    mkdir "$lock" || die "cannot acquire $label lock"
    printf '%s\n' "$$" > "$lock/owner"
}

release_process_lock() {
    local lock="$1"
    rm -f -- "$lock/owner" "$lock/phase"
    rmdir "$lock" 2>/dev/null || true
}

recover_install_transaction() {
    local dir="$1"
    local lock="$dir/.mcpkg.install.lock"
    [ -d "$lock" ] || return 0
    local owner phase
    owner="$(cat "$lock/owner" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
        die "package installation is busy"
    fi
    phase="$(cat "$lock/phase" 2>/dev/null || true)"
    local next_vendor="$dir/.mc_packages.install.next"
    local next_lock="$dir/.mcpkg.lock.next"
    local previous_vendor="$dir/.mc_packages.previous"
    if [ "$phase" = committing ]; then
        if [ -d "$next_vendor" ]; then
            if [ -e "$dir/mc_packages" ] && [ ! -e "$previous_vendor" ]; then
                mv "$dir/mc_packages" "$previous_vendor"
            fi
            [ ! -e "$dir/mc_packages" ] || rm -rf -- "$dir/mc_packages"
            mv "$next_vendor" "$dir/mc_packages"
        fi
        if [ -f "$next_lock" ]; then mv "$next_lock" "$dir/mcpkg.lock"; fi
        [ ! -e "$previous_vendor" ] || rm -rf -- "$previous_vendor"
    else
        [ ! -e "$next_vendor" ] || rm -rf -- "$next_vendor"
        [ ! -e "$next_lock" ] || rm -f -- "$next_lock"
    fi
    rm -rf -- "$lock"
}

case "$cmd" in
    publish)
        DIR="$(pkg_dir "${ARGS[0]:-.}")"
        MAN="$DIR/mcpkg.txt"
        [ -f "$MAN" ] || { echo "mcc-registry: no mcpkg.txt in $DIR" >&2; exit 1; }
        name="$(field_in "$MAN" name)"; version="$(field_in "$MAN" version)"
        [ -n "$name" ] && [ -n "$version" ] || { echo "mcc-registry: manifest needs name + version" >&2; exit 1; }
        validate_name "$name"; validate_version "$version"
        REG="$(canonical_dir "$REG")"
        require_plain_path "$REG" pkgs
        mkdir -p "$REG/pkgs/$name"
        publish_lock="$REG/.publish.lock"
        acquire_process_lock "$publish_lock" "registry publication"
        stage=""
        index_tmp=""
        cleanup_publish() {
            [ -z "$stage" ] || [ ! -e "$stage" ] || rm -rf -- "$stage"
            [ -z "$index_tmp" ] || [ ! -e "$index_tmp" ] || rm -f -- "$index_tmp"
            release_process_lock "$publish_lock"
        }
        trap cleanup_publish EXIT INT TERM
        # The immutable destination and index are one registry transaction.
        # Recheck only after acquiring the registry-wide publication lock.
        require_plain_path "$REG" pkgs "$name" "$version"
        dest="$REG/pkgs/$name/$version"
        if [ -d "$dest" ]; then
            echo "mcc-registry: $name@$version already published (immutable); refusing to overwrite" >&2; exit 1
        fi
        [ ! -e "$dest" ] || die "$name@$version has a non-directory registry entry"
        stage="$(mktemp -d "$REG/pkgs/$name/.publish.XXXXXX")"
        # Copy the publishable tree; checksum_dir then authenticates every copied file.
        copy_publish_inventory "$DIR" "$stage"
        checksum_dir "$stage" > "$stage/.checksum"
        mv "$stage" "$dest"
        if [ "${MCC_REGISTRY_FAIL_AFTER_PACKAGE_COMMIT:-0}" = 1 ]; then
            die "injected failure after package commit"
        fi
        index_tmp="$(mktemp "$REG/.index.XXXXXX")"
        rebuild_index "$REG" "$index_tmp"
        mv "$index_tmp" "$REG/index"
        echo "published: $name@$version -> $dest ($(cat "$dest/.checksum"))"
        cleanup_publish
        trap - EXIT INT TERM
        ;;
    versions)
        name="${ARGS[0]:?usage: versions <name> --registry <reg>}"
        REG="$(canonical_dir "$REG")"
        published_versions "$REG" "$name"
        ;;
    resolve)
        name="${ARGS[0]:?usage: resolve <name> <constraint> --registry <reg>}"
        constraint="${ARGS[1]:?usage: resolve <name> <constraint> --registry <reg>}"
        REG="$(canonical_dir "$REG")"
        resolve_version "$REG" "$name" "$constraint"
        ;;
    install)
        DIR="$(pkg_dir "${ARGS[0]:-.}")"
        MAN="$DIR/mcpkg.txt"
        [ -f "$MAN" ] || { echo "mcc-registry: no mcpkg.txt in $DIR" >&2; exit 1; }
        recover_install_transaction "$DIR"
        install_lock="$DIR/.mcpkg.install.lock"
        acquire_process_lock "$install_lock" "package installation"
        new_lock=""
        vendor_stage=""
        cleanup_install_stage() {
            [ -z "$new_lock" ] || [ ! -e "$new_lock" ] || rm -f -- "$new_lock"
            [ -z "$vendor_stage" ] || [ ! -e "$vendor_stage" ] || rm -rf -- "$vendor_stage"
            release_process_lock "$install_lock"
        }
        trap cleanup_install_stage EXIT INT TERM
        LOCK="$DIR/mcpkg.lock"
        VENDOR="$DIR/mc_packages"
        REG="$(canonical_dir "$REG")"
        [ ! -L "$VENDOR" ] || die "refusing symlinked vendor root '$VENDOR'"
        VENDOR="$(canonical_dir "$VENDOR")"
        # Read any existing lock into a lookup (name -> "version checksum").
        locked_version() { [ -f "$LOCK" ] && awk -v n="$1" '$1==n {print $2}' "$LOCK"; }
        locked_checksum() { [ -f "$LOCK" ] && awk -v n="$1" '$1==n {print $3}' "$LOCK"; }

        if [ -f "$LOCK" ]; then
            awk '
                /^#/ || NF == 0 { next }
                NF != 3 { exit 1 }
                $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ { exit 1 }
                $2 !~ /^[0-9]+\.[0-9]+\.[0-9]+$/ { exit 1 }
                length($3) != 64 || $3 !~ /^[0-9a-f]+$/ { exit 1 }
                seen[$1]++ { exit 1 }
            ' "$LOCK" || die "malformed or duplicate lockfile entry"
        fi

        new_lock="$DIR/.mcpkg.lock.next"
        [ ! -e "$new_lock" ] || die "stale next lockfile survived recovery"
        : > "$new_lock"
        printf '# mcpkg.lock v1 — generated by mcc-registry; do not edit by hand\n' > "$new_lock"
        vendor_stage="$DIR/.mc_packages.install.next"
        [ ! -e "$vendor_stage" ] || die "stale next vendor tree survived recovery"
        mkdir "$vendor_stage"
        count=0
        while read -r name constraint; do
            [ -n "$name" ] || continue
            validate_name "$name"; validate_constraint "$constraint"
            count=$((count + 1))
            pinned="$(locked_version "$name" || true)"
            if [ -n "$pinned" ]; then
                # Reproducible path: honor the locked version (must still satisfy the constraint).
                validate_version "$pinned"
                version_satisfies "$pinned" "$constraint" ||
                    die "locked $name@$pinned does not satisfy manifest constraint '$constraint'"
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
            require_plain_path "$REG" pkgs "$name" "$version"
            src="$REG/pkgs/$name/$version"
            [ -d "$src" ] || { echo "mcc-registry: $name@$version missing from registry" >&2; exit 1; }
            # Verify the published checksum, then verify the lock's checksum if present.
            [ -f "$src/.checksum" ] && [ ! -L "$src/.checksum" ] ||
                die "missing or non-regular checksum for $name@$version"
            [ "$(wc -l < "$src/.checksum" | tr -d '[:space:]')" = 1 ] ||
                die "malformed checksum for $name@$version"
            want="$(cat "$src/.checksum")"
            [[ "$want" =~ ^[0-9a-f]{64}$ ]] ||
                die "malformed checksum for $name@$version"
            have="$(checksum_dir "$src")"
            if [ "$have" != "$want" ]; then
                echo "mcc-registry: checksum mismatch for $name@$version (registry tampered)" >&2; exit 1
            fi
            lc="$(locked_checksum "$name" || true)"
            [ -z "$lc" ] || [[ "$lc" =~ ^[0-9a-f]{64}$ ]] || die "invalid checksum for '$name' in lockfile"
            if [ -n "$lc" ] && [ "$lc" != "$have" ]; then
                echo "mcc-registry: $name@$version checksum differs from lockfile (not reproducible)" >&2; exit 1
            fi
            # Build the complete next vendor tree without mutating the live installation.
            require_plain_path "$vendor_stage" "$name"
            target="$vendor_stage/$name"
            [ ! -e "$target" ] || die "duplicate registry dependency '$name'"
            stage="$(mktemp -d "$vendor_stage/.package.XXXXXX")"
            copy_installed_inventory "$src" "$stage"
            mv "$stage" "$target"
            printf '%s\t%s\t%s\n' "$name" "$version" "$have" >> "$new_lock"
            echo "installed: $name@$version ($constraint) -> mc_packages/$name"
        done < <(registry_deps_of "$MAN")

        vendor_backup="$DIR/.mc_packages.previous"
        [ ! -e "$vendor_backup" ] || die "internal vendor backup path already exists"
        printf 'prepared\n' > "$install_lock/phase"
        printf 'committing\n' > "$install_lock/phase"
        if [ -e "$VENDOR" ]; then mv "$VENDOR" "$vendor_backup"; fi
        if ! mv "$vendor_stage" "$VENDOR"; then
            [ ! -e "$vendor_backup" ] || mv "$vendor_backup" "$VENDOR"
            die "failed to commit vendor tree"
        fi
        if [ "${MCC_REGISTRY_KILL_AFTER_VENDOR_COMMIT:-0}" = 1 ]; then
            kill -KILL "$$"
        fi
        if ! mv "$new_lock" "$LOCK"; then
            rm -rf -- "$VENDOR"
            [ ! -e "$vendor_backup" ] || mv "$vendor_backup" "$VENDOR"
            die "failed to commit lockfile"
        fi
        [ ! -e "$vendor_backup" ] || rm -rf -- "$vendor_backup"
        cleanup_install_stage
        trap - EXIT INT TERM
        if [ "$count" -eq 0 ]; then echo "mcc-registry: no [registry-deps]; nothing to install"; fi
        echo "lockfile: $LOCK"
        ;;
    *)
        echo "usage: mcc-registry.sh {publish|versions|resolve|install} ... --registry <dir>" >&2
        exit 2
        ;;
esac
