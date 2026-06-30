#!/usr/bin/env bash
# Build the vendored openlibm (third_party/openlibm) into a freestanding riscv archive
# libopenlibm.a — the full double-precision libm QuickJS's Math needs (pow/exp/log/sin/cos/
# atan2/cbrt/hypot/...). Phase 3 of the QuickJS-agent plan: the transcendentals that can't be
# made exact by hand (the exact bit-functions live in user/libc, but openlibm supersedes them
# as the single complete libm).
#
# Compiles every src/*.c that builds freestanding and archives it; files that don't (long
# double / complex / Bessel / lgamma — none of which JS Math uses) are skipped. If an app ever
# references a skipped symbol, the final app link fails loudly with an undefined symbol — the
# correct signal, not a silent stub.
#
# The archive is cached: rebuilt only when missing or older than the newest openlibm source.
# Usage: tools/user/build-openlibm.sh <out-archive.a>
set -euo pipefail

OUT="${1:?usage: build-openlibm.sh <out.a> [arch-label]}"
ARCH="${2:-riscv64-lp64d}"   # cache label; the cross-arch harnesses pass x86_64 / aarch64
export CLANG="${CLANG:-clang}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
OLM="$HERE/third_party/openlibm"

# Per-arch target flags. OLM_TARGET_FLAGS (env) overrides for the cross-arch callers; the default is
# the riscv64 lp64d freestanding target the U-mode WASM/QuickJS agents use.
case "$ARCH" in
  x86_64)  DEFAULT_TGT=(--target=x86_64-unknown-elf -mno-red-zone) ;;
  aarch64) DEFAULT_TGT=(--target=aarch64-unknown-elf -march=armv8-a) ;;
  *)       DEFAULT_TGT=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d -mcmodel=medany) ;;
esac
if [ -n "${OLM_TARGET_FLAGS:-}" ]; then read -ra DEFAULT_TGT <<< "$OLM_TARGET_FLAGS"; fi
CFLAGS=("${DEFAULT_TGT[@]}" -nostdlib -ffreestanding -fno-pic -fno-pie -O2
        -fno-builtin -DASSEMBLER=0 -I"$OLM/include" -I"$OLM/src" -I"$OLM")

# Build ONCE into a shared, stable cache, then copy to the requested OUT. Callers pass a per-gate
# temp path for OUT, so keying the cache on OUT (as before) never hit — every gate recompiled all
# ~209 TUs (96× in a full m0). The shared cache (.wamr-cache/openlibm, gitignored) is flock-guarded
# and rebuilt only when an openlibm source is newer than it; the per-gate cost drops to a file copy.
CACHE="$HERE/.wamr-cache/openlibm"; mkdir -p "$CACHE"
LIB="$CACHE/libopenlibm-$ARCH.a"
kernel_boot_lock 9 "$CACHE/.lock"
if [ ! -f "$LIB" ] || [ -n "$(find "$OLM" -name '*.[ch]' -newer "$LIB" -print -quit)" ]; then
    WORK="$(mktemp -d)"
    ok=0
    for f in "$OLM"/src/*.c; do
        b="$(basename "$f" .c)"
        if "$CLANG" "${CFLAGS[@]}" -c "$f" -o "$WORK/$b.o" 2>/dev/null; then
            ok=$((ok + 1))
        fi
    done
    "${LLVM_AR:-llvm-ar}" rcs "$LIB" "$WORK"/*.o
    rm -rf "$WORK"
    echo "built $LIB: $ok objects" >&2
fi
kernel_boot_unlock 9 "$CACHE/.lock"

cp "$LIB" "$OUT"
