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

# RISC-V freestanding target — the boot-lib compile helpers consume this `CFLAGS` array.
CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
    -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
    -Wno-unused-parameter -Wno-unused-function -fno-builtin)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# App MC -> riscv object (backend-specific; reuses the proven kernel-boot riscv compile).
kernel_boot_compile_mc_object "$BACKEND" "$APP" "$WORK/app.o" "$WORK"
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"

# crt0 + ecall shim.
kernel_boot_compile_c_object "$HERE/user/runtime/crt0.c" "$WORK/crt0.o"

# Link the user ELF: crt0 (entry) first, then the app, with the user layout.
"$LLD" -T "$HERE/user/runtime/user.ld" "$WORK/crt0.o" "$WORK/app.o" $SUPPORT_OBJ -o "$OUT"

echo "built $OUT:"
${LLVM_READELF:-llvm-readelf} -l "$OUT" 2>/dev/null | grep -E 'Entry|LOAD' || true
