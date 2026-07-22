#!/usr/bin/env bash
# BearSSL freestanding in-kernel crypto smoke test under REAL OpenSBI in S-mode.
#
# Same EXISTING freestanding BearSSL crypto stack + live virtio-rng entropy as the
# M-mode bearssl-smoke-test, but linked with the S-mode/OpenSBI runtime
# (kernel/arch/riscv64/bearssl_smode_runtime.c) and the OpenSBI payload linker
# script (sbi.ld), and run WITHOUT `-bios none` so QEMU loads the real OpenSBI
# firmware which boots our kernel in S-mode at 0x80200000. The guest:
#   1. computes SHA256("abc") with BearSSL and checks it == the known vector,
#   2. pulls two live reads from the virtio-rng device and asserts they are
#      non-zero AND differ,
#   3. prints the build epoch threaded in via -D MC_BUILD_EPOCH.
# PASS requires the OpenSBI banner AND all three UART proofs: SHA256-OK, RNG-OK,
# BEARSSL-SMOKE-OK. This proves the TLS crypto stack runs under OpenSBI S-mode.
# (satp=0 Bare mode = flat physical; OpenSBI's PMP permits S-mode RAM+MMIO so the
# virtio-rng DMA works unchanged; time via the rdtime CSR since the CLINT mtime
# MMIO faults under OpenSBI.)
#
# No TLS handshake / no network egress here -- deterministic crypto + entropy only.
#
# Usage: tools/arch/bearssl-smode-test.sh <path-to-mcc> [c|llvm]
# Skips (exit 0) when the riscv toolchain or QEMU is unavailable.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
BACKEND="${2:-c}"
CLANG="${CLANG:-clang}"
LLD="${LLD:-ld.lld}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
RUNTIME="$HERE/tests/qemu/arch/bearssl_smode_runtime.mc"
LDSCRIPT="$HERE/tests/qemu/sbi.ld"
BEARSSL="$HERE/third_party/bearssl"
TEST_NAME=$([ "$BACKEND" = llvm ] && echo "llvm-bearssl-smode-test" || echo "bearssl-smode-test")

kernel_boot_require_riscv "$TEST_NAME" "$BACKEND"

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

EPOCH="$(date +%s)"

# Freestanding riscv64 flags. BR_USE_*=0 keeps BearSSL from pulling in any OS
# time/entropy source -- we provide our own (virtio-rng + the clock seam).
# IDENTICAL to the M-mode bearssl-smoke-test.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O2 -fno-builtin
        -DBR_USE_UNIX_TIME=0 -DBR_USE_WIN32_TIME=0
        -DBR_USE_URANDOM=0 -DBR_USE_GETENTROPY=0
        -I"$BEARSSL/freestanding-shim" -I"$BEARSSL/inc" -I"$BEARSSL/src")

echo "Compiling BearSSL freestanding for riscv64..."
BEARSSL_OBJS=()
NBEAR=0
mkdir -p "$WORK/bearssl"
while IFS= read -r f; do
    obj="$WORK/bearssl/$(echo "$f" | sed 's#[/.]#_#g').o"
    "$CLANG" "${CFLAGS[@]}" -c "$f" -o "$obj"
    BEARSSL_OBJS+=("$obj")
    NBEAR=$((NBEAR+1))
done < <(find "$BEARSSL/src" -name '*.c' | sort)
echo "Compiled $NBEAR BearSSL .c files."

# The S-mode runtime carries the boot seam (SBI console/shutdown, rdtime), the
# entry point, the SHA-256 check and the clock seam; pass the build epoch in. The
# runtime lives in kernel/arch/riscv64/, so it needs the virtio driver dir on the
# include path for virtio_rng.h (the M-mode runtime resolves it implicitly as a
# sibling).
# The S-mode runtime is now PURE MC (reuses sbi.mc/sbi_console.mc; declares BearSSL +
# virtio_rng extern). MC has no -D, so the build epoch is a generated MC fn linked alongside.
echo "export fn mc_build_epoch_fn() -> u64 { return $EPOCH; }" > "$WORK/epoch.mc"
mkdir -p "$WORK/rt" "$WORK/ep"
kernel_boot_compile_mc_object "$BACKEND" "$RUNTIME" "$WORK/runtime.o" "$WORK/rt"
kernel_boot_compile_mc_object "$BACKEND" "$WORK/epoch.mc" "$WORK/epoch.o" "$WORK/ep"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"

# Shared virtio-rng entropy driver (single source of truth, also used by https-get).
"$MCC" emit-c "$HERE/kernel/drivers/virtio/virtio_rng.mc" > "$WORK/virtio_rng_gen.c" # virtio-rng driver is now pure MC
"$CLANG" "${CFLAGS[@]}" -c "$WORK/virtio_rng_gen.c" -o "$WORK/virtio_rng.o"

kernel_boot_compile_rt "$WORK/freestanding.o"
"$LLD" -T "$LDSCRIPT" "$WORK/freestanding.o" "$WORK/runtime.o" "$WORK/epoch.o" "$WORK/virtio_rng.o" "${BEARSSL_OBJS[@]}" $SUPPORT_OBJ -o "$WORK/smoke.elf"

# Rough .text size added by BearSSL (for the report).
TEXT_SIZE="$("$CLANG" -print-prog-name=llvm-size >/dev/null 2>&1; command -v llvm-size >/dev/null 2>&1 && llvm-size "$WORK/smoke.elf" 2>/dev/null | tail -1 | awk '{print $1}' || echo '?')"

# Boot under QEMU virt WITH a virtio-rng device. NO '-bios none' -> QEMU loads
# OpenSBI (the real firmware) which boots our kernel in S-mode. The rng appears as
# another virtio-mmio slot (device-id 4); the runtime scans for it.
OUT="$(timeout 40 "$QEMU" -machine virt -m 256M -nographic \
        -global virtio-mmio.force-legacy=false \
        -device virtio-rng-device \
        -kernel "$WORK/smoke.elf" 2>/dev/null || true)"

echo "--- OpenSBI + smoke UART output ---"
printf '%s\n' "$OUT"
echo "-----------------------------------"
echo "build epoch passed: $EPOCH"
echo ".text size of linked ELF: $TEXT_SIZE bytes"

SBI_OK=0; SHA_OK=0; RNG_OK=0; SMOKE_OK=0
printf '%s' "$OUT" | grep -qi 'OpenSBI'         && SBI_OK=1
printf '%s' "$OUT" | grep -q 'SHA256-OK'        && SHA_OK=1
printf '%s' "$OUT" | grep -q 'RNG-OK'           && RNG_OK=1
printf '%s' "$OUT" | grep -q 'BEARSSL-SMOKE-OK' && SMOKE_OK=1

if [ "$SBI_OK" = 1 ] && [ "$SHA_OK" = 1 ] && [ "$RNG_OK" = 1 ] && [ "$SMOKE_OK" = 1 ]; then
    echo "PASS: $TEST_NAME -- BearSSL SHA-256 vector verified in-kernel + live virtio-rng entropy under REAL OpenSBI in S-mode (satp=0 Bare; OpenSBI PMP permits S-mode virtio-mmio + RAM DMA; time via rdtime CSR)."
    exit 0
fi

echo "FAIL: $TEST_NAME -- OpenSBI=$SBI_OK SHA256-OK=$SHA_OK RNG-OK=$RNG_OK BEARSSL-SMOKE-OK=$SMOKE_OK"
exit 1
