#!/usr/bin/env bash
# Native `#[test]` runner. Discovers every `#[test]`-attributed function in a .mc file
# (via `mcc list-tests`), lowers the file through the selected backend, and runs each
# test in its OWN process so one failure can't abort the suite. A test is an ordinary
#   #[test] export fn name() -> u32 { assert(...); ...; return 1; }
# whose `assert(...)`s trap on failure (mc_trap_Assert -> illegal instruction). A test
# PASSES iff its process exits 0 having returned 1; a trap or a non-1 return is a FAIL,
# and the runner reports which test by name — the point of a native facility over a
# hand-rolled `pass` accumulator.
#
# Usage: tools/test/mc-test-runner.sh <path-to-mcc> <c|llvm> <file.mc>
# Skips (exit 0) when clang/llc is unavailable.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
BACKEND="${2:-c}"
SRC="${3:?usage: mc-test-runner.sh <mcc> <c|llvm> <file.mc>}"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"

HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
NAME=$([ "$BACKEND" = llvm ] && echo "llvm-mc-test" || echo "mc-test")

command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: $NAME (clang not found)"; exit 0; }
if [ "$BACKEND" = llvm ]; then
    command -v "$LLC" >/dev/null 2>&1 || { echo "SKIP: $NAME (llc not found)"; exit 0; }
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Discover #[test] functions (language-side, via the compiler — not a regex).
TESTS=()
while IFS= read -r line; do
    [ -n "$line" ] && TESTS+=("$line")
done < <("$MCC" list-tests "$SRC")
if [ "${#TESTS[@]}" -eq 0 ]; then
    echo "SKIP: $NAME ($(basename "$SRC") has no #[test] functions)"
    exit 0
fi

# Lower the fixture through the selected backend.
if [ "$BACKEND" = llvm ]; then
    MCC="$MCC" LLC="$LLC" "$HERE/tools/toolchain/mcc-llvm-cc.sh" "$SRC" -o "$WORK/mod.o" >/dev/null
else
    MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/mod.o" >/dev/null
fi

# Trap stubs: a failing assert calls mc_trap_Assert -> illegal instruction, killing the
# child process so the test reads as FAIL.
cat >"$WORK/trap.c" <<'C'
void mc_trap_Assert(void){__builtin_trap();}
void mc_trap_Bounds(void){__builtin_trap();}
void mc_trap_DivideByZero(void){__builtin_trap();}
void mc_trap_IntegerOverflow(void){__builtin_trap();}
void mc_trap_InvalidRepresentation(void){__builtin_trap();}
void mc_trap_InvalidShift(void){__builtin_trap();}
void mc_trap_NullUnwrap(void){__builtin_trap();}
void mc_trap_Unreachable(void){__builtin_trap();}
C

# Generate the runner: fork each test; pass iff the child exits 0 after returning 1.
{
    echo '#include <stdint.h>'
    echo '#include <stdio.h>'
    echo '#include <unistd.h>'
    echo '#include <sys/wait.h>'
    for t in "${TESTS[@]}"; do echo "extern uint32_t ${t}(void);"; done
    echo 'struct mc_test { const char *name; uint32_t (*fn)(void); };'
    echo 'static struct mc_test mc_tests[] = {'
    for t in "${TESTS[@]}"; do echo "  { \"${t}\", ${t} },"; done
    echo '};'
    cat <<'C'
int main(void) {
    int n = (int)(sizeof(mc_tests) / sizeof(mc_tests[0]));
    int failed = 0;
    for (int i = 0; i < n; i++) {
        pid_t pid = fork();
        if (pid == 0) { _exit(mc_tests[i].fn() == 1u ? 0 : 1); }
        int st = 0;
        waitpid(pid, &st, 0);
        int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
        printf("%s %s\n", ok ? "ok  " : "FAIL", mc_tests[i].name);
        if (!ok) failed++;
    }
    printf("--- %d passed, %d failed (%d total) ---\n", n - failed, failed, n);
    return failed == 0 ? 0 : 1;
}
C
} >"$WORK/runner.c"

"$CLANG" -std=c11 -w "$WORK/runner.c" "$WORK/trap.c" "$WORK/mod.o" -o "$WORK/runner"

set +e
"$WORK/runner"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "PASS: $NAME — all ${#TESTS[@]} #[test] function(s) in $(basename "$SRC") passed ($BACKEND backend, process-isolated)"
    exit 0
fi
echo "FAIL: $NAME — one or more #[test] functions failed ($BACKEND backend)"
exit 1
