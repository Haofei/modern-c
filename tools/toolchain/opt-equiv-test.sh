#!/usr/bin/env bash
# C-vs-LLVM equivalence test for the fact-gated MIR optimizer (annex E): const-index
# bounds-check elision and divide-by-constant check elision (unsigned DivideByZero, and the
# signed INT_MIN/-1 overflow on a runtime-negative dividend). Compiles
# tests/toolchain/opt_index_demo.mc through BOTH backends in four configurations — C/LLVM ×
# default/--optimize — links each into the same entry driver, runs them, and asserts all four
# print the same value. Eliding a provably-dead check must be behavior-preserving, so the
# optimized builds must equal the unoptimized ones AND each other (the signed case pins that
# truncation toward zero is identical between the checked helper and a plain sdiv). It also
# asserts the optimized output actually dropped the checks (C: mc_check_index_usize /
# mc_checked_div_, LLVM: mc_trap_Bounds / mc_trap_DivideByZero) and the unoptimized kept them.
#
# Needs clang + llc; self-skips (not fails) when either is absent — same policy as diff-backend.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-env.sh"
HERE="$(mc_repo_root)"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
mc_require_cmd "opt-equiv-test" "$CLANG"
mc_require_cmd "opt-equiv-test" "$LLC"

SRC="$HERE/tests/toolchain/opt_index_demo.mc"
ENTRY="opt_index_demo"
EXPECT=65

LINK_FLAGS_STR="$(mc_link_flags)"

# emit-llvm defaults to the riscv64 target triple (the kernel arch), but opt-equiv builds and RUNS
# the program on the dev host. So the LLVM path must target the HOST arch — otherwise llc emits a
# foreign-ISA object the host linker rejects ("Relocations in generic ELF (EM: 243): wrong format").
# (emit-c is portable C, so the C path needs no such flag.) Map uname -m to the MC arch name.
case "$(uname -m)" in
    aarch64|arm64) HOST_MC_ARCH=aarch64 ;;
    x86_64|amd64)  HOST_MC_ARCH=x86_64 ;;
    *)             HOST_MC_ARCH=riscv64 ;;
esac

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

printf '#include <stdint.h>\n#include <stdio.h>\nextern uint32_t %s(void);\nint main(void){ printf("%%u\\n", %s()); return 0; }\n' "$ENTRY" "$ENTRY" > "$W/driver.c"
cat > "$W/trap_stubs.c" <<'C'
void mc_trap_Assert(void){__builtin_trap();}
void mc_trap_Bounds(void){__builtin_trap();}
void mc_trap_DivideByZero(void){__builtin_trap();}
void mc_trap_IntegerOverflow(void){__builtin_trap();}
void mc_trap_InvalidRepresentation(void){__builtin_trap();}
void mc_trap_InvalidShift(void){__builtin_trap();}
void mc_trap_NullUnwrap(void){__builtin_trap();}
void mc_trap_Unreachable(void){__builtin_trap();}
C

# build_run <backend:c|llvm> <optflag:""|--optimize> -> prints the program's output
build_run() {
    local backend="$1" optflag="$2" tag="$3"
    if [ "$backend" = "c" ]; then
        "$MCC" emit-c "$SRC" $optflag > "$W/$tag.c"
        "$CLANG" -std=c11 $LINK_FLAGS_STR "$W/driver.c" "$W/$tag.c" -o "$W/$tag.app"
    else
        "$MCC" emit-llvm "$SRC" $optflag --arch="$HOST_MC_ARCH" > "$W/$tag.ll"
        "$LLC" -filetype=obj "$W/$tag.ll" -o "$W/$tag.o"
        "$CLANG" -std=c11 $LINK_FLAGS_STR "$W/driver.c" "$W/trap_stubs.c" "$W/$tag.o" -o "$W/$tag.app"
    fi
    "$W/$tag.app"
}

c0="$(build_run c    ''           c0)"
c1="$(build_run c    --optimize   c1)"
l0="$(build_run llvm ''           l0)"
l1="$(build_run llvm --optimize   l1)"

for pair in "C/default:$c0" "C/optimize:$c1" "LLVM/default:$l0" "LLVM/optimize:$l1"; do
    got="${pair#*:}"; who="${pair%%:*}"
    if [ "$got" != "$EXPECT" ]; then
        echo "FAIL: opt-equiv-test — $who returned '$got', expected '$EXPECT'"; exit 1
    fi
done

# The optimized builds must have actually dropped both checks; the default builds kept them.
# (Match call sites, not the always-emitted helper/macro definitions.)
# -- Bounds check: C `[mc_check_index_usize(`, LLVM `call void @mc_trap_Bounds` (not the
#    always-present `declare`).
grep -q '\[mc_check_index_usize('   "$W/c0.c"  || { echo "FAIL: opt-equiv-test — default C dropped the bounds check"; exit 1; }
grep -q '\[mc_check_index_usize('   "$W/c1.c"  && { echo "FAIL: opt-equiv-test — --optimize C kept the bounds check"; exit 1; }
grep -q 'call void @mc_trap_Bounds' "$W/l0.ll" || { echo "FAIL: opt-equiv-test — default LLVM dropped the bounds check"; exit 1; }
grep -q 'call void @mc_trap_Bounds' "$W/l1.ll" && { echo "FAIL: opt-equiv-test — --optimize LLVM kept the bounds check"; exit 1; }
# -- DivideByZero check: C `= mc_checked_div_` call, LLVM `call void @mc_trap_DivideByZero`.
grep -q '= mc_checked_div_'               "$W/c0.c"  || { echo "FAIL: opt-equiv-test — default C dropped the div check"; exit 1; }
grep -q '= mc_checked_div_'               "$W/c1.c"  && { echo "FAIL: opt-equiv-test — --optimize C kept the div check"; exit 1; }
grep -q 'call void @mc_trap_DivideByZero' "$W/l0.ll" || { echo "FAIL: opt-equiv-test — default LLVM dropped the div check"; exit 1; }
grep -q 'call void @mc_trap_DivideByZero' "$W/l1.ll" && { echo "FAIL: opt-equiv-test — --optimize LLVM kept the div check"; exit 1; }
# -- Const-slice construction check (`start <= end <= len`): C emits the `> mc_len` guard, the
#    LLVM slice check is one of the `@mc_trap_Bounds` calls already asserted gone above (the
#    optimized build has zero bounds traps, slice construction included).
grep -q '> mc_len' "$W/c0.c" || { echo "FAIL: opt-equiv-test — default C dropped the slice bounds check"; exit 1; }
grep -q '> mc_len' "$W/c1.c" && { echo "FAIL: opt-equiv-test — --optimize C kept the slice bounds check"; exit 1; }

echo "PASS: opt-equiv-test — C and LLVM agree ($EXPECT) across default/--optimize; the elided bounds (index + slice) and divide-by-zero checks are behavior-preserving on both backends"
