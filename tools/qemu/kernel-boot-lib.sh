#!/usr/bin/env bash
set -euo pipefail

kernel_boot_repo_root() {
    local d
    d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd)
    while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do
        d=$(dirname "$d")
    done
    printf '%s' "$d"
}

kernel_boot_skip() {
    local name="$1"
    local reason="$2"
    echo "SKIP: $name ($reason)"
    exit 0
}

kernel_boot_require_riscv() {
    local name="$1"
    local backend="$2"
    command -v "$CLANG" >/dev/null 2>&1 || kernel_boot_skip "$name" "clang not found"
    command -v "$LLD" >/dev/null 2>&1 || kernel_boot_skip "$name" "ld.lld not found"
    command -v "$QEMU" >/dev/null 2>&1 || kernel_boot_skip "$name" "$QEMU not found"
    "$CLANG" --print-targets 2>/dev/null | grep -q riscv64 || kernel_boot_skip "$name" "clang has no riscv64 target"
    if [ "$backend" = llvm ]; then
        command -v "$LLC" >/dev/null 2>&1 || kernel_boot_skip "$name" "llc not found"
    fi
}

kernel_boot_compile_mc_object() {
    local backend="$1"
    local src="$2"
    local out="$3"
    local work="$4"
    case "$backend" in
        c)
            "$MCC" emit-c "$src" >"$work/module.c"
            "$CLANG" "${CFLAGS[@]}" -c "$work/module.c" -o "$out"
            ;;
        llvm)
            MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$src" -o "$out" \
                -mtriple=riscv64-unknown-elf \
                -mattr=+m,+a,+c \
                -target-abi=lp64 \
                -relocation-model=static \
                -code-model=medium
            ;;
        *)
            echo "unknown kernel backend: $backend" >&2
            exit 2
            ;;
    esac
}

# Generate the authoritative MC virtqueue layout-assert header (sizeof/offsetof for every shared
# struct) into $1. C runtimes that hand-mirror std/virtqueue.mc's structs `#include
# "virtq_layout_assert.h"`; compiling them with $1 on the include path turns any MC<->C layout
# drift into a _Static_assert compile error. Idempotent — safe to call repeatedly per build.
kernel_boot_emit_virtq_layout_header() {
    local dir="$1"
    local root
    root="$(kernel_boot_repo_root)"
    "$MCC" emit-layout "$root/std/virtqueue.mc" \
        --structs=VringDesc,DescTable,VringAvail,UsedElem,VringUsed,Virtq \
        >"$dir/virtq_layout_assert.h"
}

# Generate the authoritative MC virtqueue struct *definitions* (A2: single source of truth) into
# $1/virtq_structs.h. The platform header `#include`s this instead of hand-declaring the vring/Virtq
# structs, so the MC struct in std/virtqueue.mc is the ONLY declaration — there is no hand-written C
# copy to drift. The generated header carries the A1 sizeof/offsetof asserts too (belt-and-suspenders).
# Idempotent — safe to call repeatedly per build.
kernel_boot_emit_virtq_structs_header() {
    local dir="$1"
    local root
    root="$(kernel_boot_repo_root)"
    "$MCC" emit-c-struct "$root/std/virtqueue.mc" \
        --structs=VringDesc,DescTable,VringAvail,UsedElem,VringUsed,Virtq \
        >"$dir/virtq_structs.h"
}

kernel_boot_compile_c_object() {
    local src="$1"
    local out="$2"
    local dir
    dir="$(dirname "$out")"
    # Make the generated virtq headers available to any runtime that includes them. Generated next
    # to the output object and added to the include path; harmless for runtimes that don't include
    # them. virtq_structs.h holds the GENERATED struct definitions (the platform header includes it
    # instead of hand-mirroring); virtq_layout_assert.h holds the standalone A1 layout asserts.
    kernel_boot_emit_virtq_layout_header "$dir"
    kernel_boot_emit_virtq_structs_header "$dir"
    "$CLANG" "${CFLAGS[@]}" -I"$dir" -c "$src" -o "$out"
}

kernel_boot_compile_llvm_support() {
    local backend="$1"
    local out="$2"
    if [ "$backend" = llvm ]; then
        kernel_boot_compile_c_object "$HERE/kernel/arch/riscv64/llvm_kernel_support.c" "$out"
        printf '%s' "$out"
    fi
}

# Compile the ONE shared freestanding libc (mem*/str*) every bare-metal image
# links against. Replaces the mem*/str* copies that used to be duplicated into
# each per-image runtime .c. Add the resulting object to every ld.lld line.
kernel_boot_compile_rt() {
    local out="$1"
    kernel_boot_compile_c_object "$HERE/kernel/arch/riscv64/freestanding.c" "$out"
}
