#!/usr/bin/env bash
# Build ONE bootable kernel image from an MC demo and run it as an interactive QEMU VM.
#
# This is the "just run it on my Mac" launcher: it reuses the same compile/link steps the
# m0 boot gates use (tools/qemu/kernel-boot-lib.sh), but writes a PERSISTENT image and boots
# QEMU with NO timeout and a live serial console you can Ctrl-A X out of. QEMU is a real
# hardware-emulating VM; UTM is only a GUI wrapper over this same qemu-system-riscv64.
#
# Prerequisites (macOS, all via Homebrew — no Docker needed):
#   brew install qemu llvm lld     # qemu-system-riscv64, clang/llc, ld.lld
#   zig build                      # builds zig-out/bin/mcc (the MC compiler), if not already built
# The only tool the stock Homebrew LLVM bottle omits is ld.lld -> `brew install lld`.
#
# Usage:
#   tools/run-kernel.sh [demo.mc] [c|llvm]
# Examples:
#   tools/run-kernel.sh                                   # default: signed_boot demo, C backend
#   tools/run-kernel.sh tests/qemu/proc/agent_preempt_demo.mc c
#   MC_DISK=disk.img tools/run-kernel.sh tests/qemu/arch/blk_persist_demo.mc   # attach a virtio-blk disk
#
# Env knobs:
#   MCC, CLANG, LLD, LLC, QEMU   override tool paths (LLD defaults to `brew --prefix lld`/bin if present)
#   MC_PLATFORM=<file.mc>        extra platform object to link (e.g. kernel/arch/riscv64/mmode_dma_time.mc
#                                for demos that use std/dma + std/time, like the blk_* demos)
#   MC_RUNTIME=<file.mc>         extra runtime object (demos whose entry lives in a *_runtime.mc)
#   MC_DISK=<path>               attach as a raw virtio-blk disk (created 16 MiB if it doesn't exist)
#   MC_CHECKS=elide-proven       build the release (fact-gated) profile instead of the safe default
#   OUT=<dir>                    output dir for the built image (default: out/vm)
set -euo pipefail

SRC_IN="${1:-tests/qemu/arch/signed_boot_demo.mc}"
BACKEND="${2:-c}"

MCC="${MCC_UNDER_TEST:-${MCC:-zig-out/bin/mcc}}"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
QEMU="${QEMU:-qemu-system-riscv64}"
# Prefer an explicit LLD; else `ld.lld` on PATH; else a Homebrew lld formula. Homebrew ships lld
# keg-only under a versioned name (lld, lld@21, ...) that is NOT symlinked onto PATH, so probe both
# the unversioned prefix and any versioned opt dir.
if [ -z "${LLD:-}" ]; then
    if command -v ld.lld >/dev/null 2>&1; then
        LLD="ld.lld"
    elif command -v brew >/dev/null 2>&1; then
        for p in "$(brew --prefix lld 2>/dev/null)/bin/ld.lld" /opt/homebrew/opt/lld@*/bin/ld.lld /usr/local/opt/lld@*/bin/ld.lld; do
            [ -x "$p" ] && { LLD="$p"; break; }
        done
        LLD="${LLD:-ld.lld}"
    else
        LLD="ld.lld"
    fi
fi

source "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/qemu" && pwd)/kernel-boot-lib.sh"
HERE="$(kernel_boot_repo_root)"
SRC="$HERE/$SRC_IN"
[ -f "$SRC" ] || { echo "no such demo: $SRC" >&2; exit 2; }
LDSCRIPT="$HERE/tests/qemu/virt.ld"

# Friendly tool check (the lib's require* would just SKIP; here we want a loud error).
for t in "$MCC" "$CLANG" "$LLC" "$QEMU"; do
    command -v "$t" >/dev/null 2>&1 || { echo "missing tool: $t" >&2; exit 3; }
done
command -v "$LLD" >/dev/null 2>&1 || { echo "missing linker: $LLD  (run: brew install lld)" >&2; exit 3; }

OUT="${OUT:-$HERE/out/vm}"
mkdir -p "$OUT"
WORK="$OUT"   # persistent — no cleanup trap

CFLAGS=(--target=riscv64-unknown-elf -march=rv64imac -mabi=lp64
        -nostdlib -ffreestanding -fno-pic -mcmodel=medany -O1 -Wall -Wextra
        -Wno-unused-function -Wno-unused-variable -fno-builtin)

echo ">> compiling $SRC_IN ($BACKEND backend)"
OBJS=()
kernel_boot_compile_rt "$WORK/freestanding.o"; OBJS+=("$WORK/freestanding.o")
kernel_boot_compile_mc_object "$BACKEND" "$SRC" "$WORK/main.o" "$WORK"; OBJS+=("$WORK/main.o")
if [ -n "${MC_PLATFORM:-}" ]; then
    kernel_boot_compile_mc_object "$BACKEND" "$HERE/$MC_PLATFORM" "$WORK/platform.o" "$WORK"; OBJS+=("$WORK/platform.o")
fi
if [ -n "${MC_RUNTIME:-}" ]; then
    kernel_boot_compile_mc_object "$BACKEND" "$HERE/$MC_RUNTIME" "$WORK/runtime.o" "$WORK/rt"; OBJS+=("$WORK/runtime.o")
fi
SUPPORT_OBJ="$(kernel_boot_compile_llvm_support "$BACKEND" "$WORK/llvm-support.o")"

echo ">> linking $OUT/kernel.elf"
"$LLD" -T "$LDSCRIPT" "${OBJS[@]}" $SUPPORT_OBJ -o "$OUT/kernel.elf"

QARGS=(-machine virt -bios none -nographic -kernel "$OUT/kernel.elf")
if [ -n "${MC_DISK:-}" ]; then
    [ -f "$MC_DISK" ] || { echo ">> creating 16 MiB disk $MC_DISK"; qemu-img create -f raw "$MC_DISK" 16M >/dev/null 2>&1 || dd if=/dev/zero of="$MC_DISK" bs=1m count=16 >/dev/null 2>&1; }
    QARGS+=(-drive file="$MC_DISK",format=raw,if=none,id=d0 -device virtio-blk-device,drive=d0)
fi

echo ">> booting: $QEMU ${QARGS[*]}"
echo ">> (serial console below; exit QEMU with Ctrl-A then X)"
echo "----------------------------------------------------------------"
exec "$QEMU" "${QARGS[@]}"
