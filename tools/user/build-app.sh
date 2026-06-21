#!/usr/bin/env bash
# Build a confined MC app into an isolated U-mode ELF (Phase 1 of the QuickJS-agent plan).
# Compiles the app MC (through the chosen backend) + the user crt0/ecall shim for the riscv
# freestanding target, and links them with user/runtime/user.ld into a position-dependent,
# multi-segment ELF (distinct R|X / R / R|W load segments) that kernel/core/elf_loader maps
# into an isolated address space. No per-app glue — any `export fn main() -> i32` app works.
#
# Usage: tools/user/build-app.sh <app.mc> <c|llvm> <out.elf>
set -euo pipefail

APP="${1:?usage: build-app.sh <app.mc> <c|llvm> <out.elf>}"
BACKEND="${2:-c}"
OUT="${3:?missing out.elf}"
# The kernel-boot-lib helpers reference these (with `set -u`); give them defaults + export.
export CLANG="${CLANG:-clang}"
export LLC="${LLC:-llc}"
export LLD="${LLD:-ld.lld}"

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
MCC="${MCC:-$HERE/zig-out/bin/mcc}"

# RISC-V freestanding target for the APP — the boot-lib compile helpers consume this `CFLAGS`.
# Apps are built with the F/D float extension (rv64imafdc, lp64d ABI) because JS numbers (and
# libm) are doubles; the kernel enables mstatus.FS before entering the app (enter_user in
# usermode_runtime.c).
# The app is a SEPARATE ELF from the (integer-only) kernel, so the ABIs don't link together;
# the syscall boundary (mc_ecall) passes only integers, unaffected by lp64d.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imafdc -mabi=lp64d
    -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
    -Wno-unused-parameter -Wno-unused-function -fno-builtin)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# App -> riscv object. An MC app goes through the chosen backend; a C app (e.g. QuickJS)
# compiles with clang and links the freestanding libc (user/libc).
APP_OBJS=("$WORK/app.o")
SUPPORT_OBJ=""
case "$APP" in
    *.c)
        "$CLANG" "${CFLAGS[@]}" -I"$HERE" -c "$APP" -o "$WORK/app.o"
        "$CLANG" "${CFLAGS[@]}" -I"$HERE" -c "$HERE/user/libc/libc.c" -o "$WORK/libc.o"
        APP_OBJS+=("$WORK/libc.o")
        # Full libm: build/reuse the vendored-openlibm archive and link it LAST (so the linker
        # pulls only the math members the app references). Cached under zig-out (gitignored).
        LIBM="$HERE/zig-out/lib/libopenlibm.a"
        mkdir -p "$(dirname "$LIBM")"
        CLANG="$CLANG" bash "$HERE/tools/user/build-openlibm.sh" "$LIBM"
        APP_OBJS+=("$LIBM")
        ;;
    *)
        # Apps build with hardware FP (CFLAGS use lp64d), so the MC object must too — otherwise
        # the LLVM backend emits an lp64 (integer-ABI) object that won't link with the lp64d crt0.
        MC_FP=1 kernel_boot_compile_mc_object "$BACKEND" "$APP" "$WORK/app.o" "$WORK"
        SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"
        ;;
esac

# crt0 + ecall shim.
kernel_boot_compile_c_object "$HERE/user/runtime/crt0.c" "$WORK/crt0.o"

# Link the user ELF: crt0 (entry) first, then the app (+ libc for C), with the user layout.
"$LLD" -T "$HERE/user/runtime/user.ld" "$WORK/crt0.o" "${APP_OBJS[@]}" $SUPPORT_OBJ -o "$OUT"

echo "built $OUT:"
${LLVM_READELF:-llvm-readelf} -l "$OUT" 2>/dev/null | grep -E 'Entry|LOAD' || true
