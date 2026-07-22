#!/usr/bin/env bash
# Move-resource leak-invariant fuzzer: generate COUNT MC programs (tools/toolchain/mcgen_move.py)
# that allocate linear `move` resources, reserve their release with `defer`, and run random
# control flow with early returns, then run each through BOTH backends. Two properties are
# checked: the backends agree (output + exit), and the leak invariant holds — harness() returns
# 0, meaning every deferred free fired on every exit path (no leaked or double-handled resource).
#
# Deterministic: seeds 1..COUNT, so it doubles as a stable regression gate; raise COUNT (env)
# to explore further. Any failing seed reproduces exactly with `tools/toolchain/mcgen_move.py <seed>`.
#
# Generated C is compiled WITHOUT -Werror: the generator may emit warned-but-valid shapes; the
# differential is about runtime behavior, not warning cleanliness. The C backend inlines its
# trap helpers; the LLVM backend externalizes them, so the LLVM link gets trap stubs (never
# reached — the generated subset cannot trap). Each seed is independent: fans out across cores.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
COUNT="${COUNT:-200}"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: move-fuzz (python3 not found)"; exit 0; }
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: move-fuzz (clang not found)"; exit 0; }
command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: move-fuzz (llc not found)"; exit 0; }

LINK_FLAGS_STR=""
if [ "$(uname -s)" = "Linux" ]; then LINK_FLAGS_STR="-no-pie"; fi
export MCC HERE CLANG LLC LINK_FLAGS_STR

fuzz_one() {
    local seed="$1"
    # Keep this seed's work dir (and report rc) on FAILURE so a failing/killed seed is diagnosable
    # (rc 137 = SIGKILL: a trap/OOM in the generated program before it printed). Clean on success.
    local W; W="$(mktemp -d)"
    trap 'rc=$?; if [ "$rc" -ne 0 ]; then echo "move-fuzz: seed='"$seed"' FAILED rc=$rc — kept work dir: $W" >&2; else rm -rf "$W"; fi' RETURN
    local repro="reproduce: tools/toolchain/mcgen_move.py $seed"

    python3 "$HERE/tools/toolchain/mcgen_move.py" "$seed" > "$W/p.mc" 2>/dev/null || { echo "FAIL: move-fuzz seed=$seed (generator error)"; return 1; }
    if ! "$MCC" check "$W/p.mc" >/dev/null 2>&1; then
        echo "FAIL: move-fuzz seed=$seed — mcc check rejected a generated program ($repro)"; return 1
    fi

    printf '#include <stdint.h>\n#include <stdio.h>\nextern uint64_t harness(void);\nint main(void){ printf("%%llu\\n", (unsigned long long)harness()); return 0; }\n' > "$W/d.c"
    cat > "$W/ts.c" <<'C'
void mc_trap_Assert(void){__builtin_trap();}
void mc_trap_Bounds(void){__builtin_trap();}
void mc_trap_DivideByZero(void){__builtin_trap();}
void mc_trap_IntegerOverflow(void){__builtin_trap();}
void mc_trap_InvalidRepresentation(void){__builtin_trap();}
void mc_trap_InvalidShift(void){__builtin_trap();}
void mc_trap_NullUnwrap(void){__builtin_trap();}
void mc_trap_Unreachable(void){__builtin_trap();}
C

    if ! "$MCC" emit-c "$W/p.mc" 2>/dev/null | "$CLANG" -std=c11 -w -c -x c - -o "$W/c.o" 2>/dev/null; then
        echo "FAIL: move-fuzz seed=$seed — C backend emit/compile failed ($repro)"; return 1
    fi
    if ! MCC_UNDER_TEST="$MCC" MCC="$MCC" LLC="$LLC" bash "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$W/p.mc" -o "$W/l.o" >/dev/null 2>&1; then
        echo "FAIL: move-fuzz seed=$seed — LLVM backend emit/compile failed ($repro)"; return 1
    fi
    if ! "$CLANG" $LINK_FLAGS_STR -w "$W/d.c" "$W/c.o" -o "$W/c.bin" >/dev/null 2>&1; then
        echo "FAIL: move-fuzz seed=$seed — C link failed ($repro)"; return 1
    fi
    if ! "$CLANG" $LINK_FLAGS_STR -w "$W/d.c" "$W/ts.c" "$W/l.o" -o "$W/l.bin" >/dev/null 2>&1; then
        echo "FAIL: move-fuzz seed=$seed — LLVM link failed ($repro)"; return 1
    fi

    local co lo cr lr
    co="$("$W/c.bin" 2>&1)"; cr=$?
    lo="$("$W/l.bin" 2>&1)"; lr=$?
    if [ "$co" != "$lo" ] || [ "$cr" != "$lr" ]; then
        echo "FAIL: move-fuzz seed=$seed — BACKEND DIVERGENCE: C=(rc=$cr,'$co') LLVM=(rc=$lr,'$lo') ($repro)"; return 1
    fi
    # Leak invariant: harness counts every moment live_count failed to return to 0 after a
    # deferred-release function returned. A correct backend always yields 0; non-zero means a
    # defer was dropped on some exit path (a leaked or double-handled resource).
    if [ "$co" != "0" ]; then
        echo "FAIL: move-fuzz seed=$seed — LEAK INVARIANT: harness returned '$co' (expected 0; a deferred free did not fire on every path) ($repro)"; return 1
    fi
}
export -f fuzz_one

seq 1 "$COUNT" | xargs -P "$JOBS" -I{} bash -c 'fuzz_one "$@"' _ {}
echo "PASS: move-fuzz — $COUNT move-resource programs release every resource exactly once (live_count==0) and both backends agree (seeds 1..$COUNT)"
