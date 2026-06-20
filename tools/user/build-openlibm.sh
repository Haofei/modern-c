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

OUT="${1:?usage: build-openlibm.sh <out.a>}"
export CLANG="${CLANG:-clang}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
OLM="$HERE/third_party/openlibm"

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2
        -fno-builtin -DASSEMBLER=0 -I"$OLM/include" -I"$OLM/src" -I"$OLM")

# Cache: skip the rebuild if the archive is newer than every source.
if [ -f "$OUT" ] && [ -z "$(find "$OLM" -name '*.[ch]' -newer "$OUT" -print -quit)" ]; then
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ok=0
for f in "$OLM"/src/*.c; do
    b="$(basename "$f" .c)"
    if "$CLANG" "${CFLAGS[@]}" -c "$f" -o "$WORK/$b.o" 2>/dev/null; then
        ok=$((ok + 1))
    fi
done

"${LLVM_AR:-llvm-ar}" rcs "$OUT" "$WORK"/*.o
echo "built $OUT: $ok objects" >&2
