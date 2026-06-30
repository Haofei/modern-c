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
    # In CI (or when MC_REQUIRE_TOOLS=1), a missing toolchain must FAIL rather than silently skip,
    # so a milestone gate cannot look green just because qemu/clang/lld were absent. Locally (the
    # var unset) it still skips, so contributors without the full riscv toolchain are not blocked.
    if [ -n "${MC_REQUIRE_TOOLS:-}" ] || [ -n "${CI:-}" ]; then
        echo "FAIL: $name (required tool missing: $reason; set up the toolchain or unset MC_REQUIRE_TOOLS/CI)"
        exit 1
    fi
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

kernel_boot_lock() {
    local fd="$1"
    local lock="$2"
    eval "exec ${fd}>\"\$lock\""
    if command -v flock >/dev/null 2>&1; then
        flock "$fd"
        return
    fi

    local dir="${lock}.dir"
    while ! mkdir "$dir" 2>/dev/null; do
        if [ -f "$dir/pid" ]; then
            local pid
            pid="$(cat "$dir/pid" 2>/dev/null || true)"
            if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
                rm -rf "$dir"
                continue
            fi
        fi
        sleep 0.1
    done
    printf '%s\n' "$$" > "$dir/pid"
}

kernel_boot_unlock() {
    local fd="$1"
    local lock="$2"
    if command -v flock >/dev/null 2>&1; then
        flock -u "$fd"
    else
        rm -rf "${lock}.dir"
    fi
    eval "exec ${fd}>&-"
}

kernel_boot_compile_mc_object() {
    local backend="$1"
    local src="$2"
    local out="$3"
    local work="$4"
    # Build-safety profile (D2.5). The kernel DEFAULTS to SAFE: every runtime trap check is
    # kept. Set MC_CHECKS=elide-proven to build the RELEASE profile (the fact-gated MIR
    # optimizer elides only checks it proved can never trap, annex E.4) — used by the parity
    # boot. MC_CHECKS=all is the explicit SAFE form and matches the no-flag default.
    local checks="${MC_CHECKS:-all}"
    local checks_flag=()
    [ "$checks" != "all" ] && checks_flag=(--checks="$checks")
    case "$backend" in
        c)
            "$MCC" emit-c "$src" ${checks_flag[@]+"${checks_flag[@]}"} >"$work/module.c"
            "$CLANG" "${CFLAGS[@]}" -c "$work/module.c" -o "$out"
            ;;
        llvm)
            # Default target is integer-only (rv64imac, lp64) to match the kernel. A caller that
            # builds FP code (the all-MC libc: JS numbers / strtod are doubles) sets MC_FP=1 to
            # select the hardware F/D unit + the lp64d ABI, matching its lp64d C objects.
            local mc_mattr="+m,+a,+c"
            local mc_abi="lp64"
            if [ "${MC_FP:-0}" = 1 ]; then
                mc_mattr="+m,+a,+f,+d,+c"
                mc_abi="lp64d"
            fi
            # MC_LLC_EXTRA: optional extra llc flags (space-separated). Used by the
            # backtrace gate to pass -frame-pointer=all so the level functions keep s0
            # as the frame pointer for the unwind walk (the LLVM analogue of the C
            # path's -fno-omit-frame-pointer in CFLAGS).
            local llc_extra=()
            [ -n "${MC_LLC_EXTRA:-}" ] && read -r -a llc_extra <<<"${MC_LLC_EXTRA}"
            MC_CHECKS="$checks" MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$src" -o "$out" \
                -mtriple=riscv64-unknown-elf \
                -mattr="$mc_mattr" \
                -target-abi="$mc_abi" \
                -relocation-model=static \
                -code-model=medium \
                ${llc_extra[@]+"${llc_extra[@]}"}
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
    # A `.mc` source is a converted shared runtime: lower it via emit-c first (arch-neutral),
    # then compile the generated C exactly like a native C object. Lets a caller pass an MC
    # file (e.g. the now-pure-MC context/usermode bring-up) through the same $SHARED/$USERMODE
    # seam with no other harness change.
    if [ "${src##*.}" = mc ]; then
        local gen="$dir/$(basename "${src%.mc}")_gen.c"
        "$MCC" emit-c "$src" > "$gen"
        "$CLANG" "${CFLAGS[@]}" -I"$dir" -fno-builtin -c "$gen" -o "$out"
        return
    fi
    "$CLANG" "${CFLAGS[@]}" -I"$dir" -c "$src" -o "$out"
}

kernel_boot_compile_llvm_support() {
    local backend="$1"
    local out="$2"
    if [ "$backend" = llvm ]; then
        # PROBE: provide nothing. The trap hooks are now self-provided per-object (emitTrapDecl weak
        # trapping defines), and riscv `+m` lowers 64-bit mul/div to hardware — so the support object
        # may be entirely unreferenced. The link will error on any genuinely-undefined symbol.
        :
    fi
}

# Compile the ONE shared freestanding libc (mem*/str*) every bare-metal image
# links against. Replaces the mem*/str* copies that used to be duplicated into
# each per-image runtime .c. Add the resulting object to every ld.lld line.
kernel_boot_compile_rt() {
    local out="$1"
    # The freestanding mem*/str* lib is now PURE MC (kernel/lib/freestanding.mc). Lower it via
    # emit-c and compile with -fno-builtin so clang does NOT rewrite the explicit byte loops back
    # into calls to themselves (the same guarantee the C version relied on). emit-c is arch-neutral,
    # and these scalar loops carry no target specifics, so the caller's $CFLAGS target applies.
    local dir
    dir="$(dirname "$out")"
    "$MCC" emit-c "$HERE/kernel/lib/freestanding.mc" > "$dir/freestanding.c"
    "$CLANG" "${CFLAGS[@]}" -fno-builtin -c "$dir/freestanding.c" -o "$out"
}

# Link the given objects into a bare riscv64 image with $LDSCRIPT, boot it under
# `qemu-system-riscv64 -machine virt -bios none`, dump the UART output, and PASS iff
# the success marker appears (exit 0) else FAIL (exit 1). This collapses the
# link + boot + UART-dump + marker-grep + PASS/FAIL boilerplate that the single-marker
# riscv64 boot gates all repeat verbatim — only the objects, the marker, and the PASS
# detail vary, which are the arguments here. Tests that need OpenSBI/-bios, a netdev,
# bounded retry, an alternate machine/arch, or bespoke extra diagnostics keep their own
# flow (this is deliberately the plain-boot path only).
#
# Reads from the caller's scope (the boot scripts all set these): LDSCRIPT, WORK, LLD,
# QEMU. Honors BOOT_TIMEOUT (default 30).
#
# Usage: kernel_boot_link_run <test-name> <marker> <pass-detail> <obj> [obj...]
kernel_boot_link_run() {
    local test_name="$1"
    local marker="$2"
    local pass_detail="$3"
    shift 3

    "${LLD:-ld.lld}" -T "$LDSCRIPT" "$@" -o "$WORK/image.elf"

    local out
    out="$(timeout "${BOOT_TIMEOUT:-30}" "${QEMU:-qemu-system-riscv64}" -machine virt -bios none -nographic \
            -kernel "$WORK/image.elf" 2>/dev/null || true)"

    echo "--- kernel UART output ---"
    printf '%s\n' "$out"
    echo "--------------------------"

    if printf '%s' "$out" | grep -q "$marker"; then
        echo "PASS: $test_name — $pass_detail"
        exit 0
    fi
    echo "FAIL: $test_name — expected '$marker' in kernel output"
    exit 1
}
