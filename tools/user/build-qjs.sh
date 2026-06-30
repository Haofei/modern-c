#!/usr/bin/env bash
# Compile the 4 QuickJS translation units (dtoa/libunicode/libregexp/quickjs — quickjs.c alone is
# ~50k lines) ONCE per (compiler + flags) into a shared cache, then copy them into <out-dir>. The
# native qjs gates (qjs-confined/agent/net/cancel, x86-qjs, arm-qjs, qjs-smode-*, ...) all rebuild
# these per gate; this turns ~30 redundant ~9s compiles into one. The cache key is a hash of the
# compiler + exact cflags (so each arch/ABI variant gets its own objects, byte-identical to what the
# per-gate compile would have produced), and it is rebuilt only when a QuickJS source changes.
#
#   usage: build-qjs.sh <out-dir> <clang> <cflag>...     (cflags must include -I<quickjs>)
set -uo pipefail
OUT="${1:?usage: build-qjs.sh <out-dir> <clang> <cflags...>}"; shift
CLANG="${1:?missing clang}"; shift   # remaining args = the cflags used for the 4 TUs

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
QJS="$HERE/third_party/quickjs"

ROOT="$HERE/.wamr-cache/qjs-native"; mkdir -p "$ROOT"
key="$(printf '%s\n' "$CLANG" "$@" | md5sum | cut -d' ' -f1)"
CACHE="$ROOT/$key"
want="$(printf '%s ' "$CLANG" "$@"; ls -la "$QJS"/*.c "$QJS"/*.h 2>/dev/null | md5sum)"

kernel_boot_lock 9 "$ROOT/.lock"
if [ "$(cat "$CACHE/stamp" 2>/dev/null)" != "$want" ]; then
    mkdir -p "$CACHE"
    for f in dtoa libunicode libregexp quickjs; do
        "$CLANG" "$@" -c "$QJS/$f.c" -o "$CACHE/$f.o"
    done
    printf '%s' "$want" > "$CACHE/stamp"
fi
kernel_boot_unlock 9 "$ROOT/.lock"

for f in dtoa libunicode libregexp quickjs; do cp "$CACHE/$f.o" "$OUT/$f.o"; done
