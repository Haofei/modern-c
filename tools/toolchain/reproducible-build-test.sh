#!/usr/bin/env bash
# Reproducible-build / determinism gate.
#
# A trustworthy toolchain must be a pure function of its input: compiling the SAME source
# twice, in the same environment, must yield BYTE-IDENTICAL output. Non-determinism (hash-map
# iteration order leaking into emitted symbol order, embedded timestamps, temp-path names,
# address-dependent ordering) silently breaks source-to-binary auditability and defeats
# signed-image reproducibility (see the OTA / signed-boot gates).
#
# This gate compiles a fixed input through mcc TWICE per backend and asserts the two emissions
# are byte-identical. It compares the compiler's OWN TEXT OUTPUT (emitted C and emitted LLVM IR)
# rather than a fully linked binary on purpose: linked ELF/Mach-O images legitimately carry
# build-path and timestamp noise from clang/lld that is outside mcc's control, whereas the
# emitted C and LLVM text are exactly the artifact mcc is responsible for making deterministic.
# It needs NO external toolchain (clang/llc), so it runs everywhere and never self-skips.
#
# KNOWN GAPS: this checks determinism of mcc's textual emission only. It does NOT assert that the
# downstream native link (clang + lld) is bit-reproducible — that depends on the host toolchain's
# own -frandom-seed / build-id / path-remap settings and is out of scope here.
#
# Usage: tools/toolchain/reproducible-build-test.sh <path-to-mcc>
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-env.sh"
HERE="$(mc_repo_root)"

# A representative, self-contained fixture already used by the optimizer-equivalence gate.
SRC="$HERE/tests/toolchain/opt_index_demo.mc"

W="$(mktemp -d)"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "reproducible-build-test: FAILED rc=$rc — kept work dir: $W" >&2; else rm -rf "$W"; fi' EXIT

fail() {
    echo "FAIL: reproducible-build-test — $1"
    exit 1
}

# compare_two <label> <emit-args...> : run `mcc <emit-args>` twice and require identical bytes.
compare_two() {
    local label="$1"; shift
    "$MCC" "$@" > "$W/${label}.a" 2>/dev/null
    "$MCC" "$@" > "$W/${label}.b" 2>/dev/null
    if ! cmp -s "$W/${label}.a" "$W/${label}.b"; then
        echo "--- first 20 differing lines ($label) ---" >&2
        diff "$W/${label}.a" "$W/${label}.b" 2>/dev/null | head -20 >&2 || true
        fail "$label emission differs between two compiles of the same input (non-deterministic)"
    fi
    local sum
    sum="$(cksum < "$W/${label}.a")"
    echo "  $label: byte-identical across two compiles (cksum: $sum)"
}

# Emitted C — default and optimized.
compare_two "emit-c"           emit-c "$SRC"
compare_two "emit-c-opt"       emit-c "$SRC" --optimize
# Emitted LLVM IR — default and optimized (arch pinned so the triple is stable/comparable).
compare_two "emit-llvm"        emit-llvm "$SRC" --arch=riscv64
compare_two "emit-llvm-opt"    emit-llvm "$SRC" --arch=riscv64 --optimize

echo "PASS: reproducible-build-test — mcc emitted C and LLVM IR are byte-identical across repeated compiles of a fixed input (default + --optimize)"
exit 0
