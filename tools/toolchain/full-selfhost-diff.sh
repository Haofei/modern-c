#!/usr/bin/env bash
# P0 full-selfhost differential harness.
#
# This compares the current Zig compiler oracle with MCC_UNDER_TEST over the tiny
# checked-in corpus manifest. It is an oracle/parity harness, not a self-hosting claim.
set -euo pipefail

repo_root() {
    local d
    d="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do
        d="$(dirname "$d")"
    done
    printf '%s\n' "$d"
}

HERE="$(repo_root)"
MANIFEST="${1:-$HERE/tools/toolchain/full-selfhost-manifest.tsv}"
ORACLE_RAW="${MCC_ORACLE:-zig-out/bin/mcc}"
UNDER_TEST_RAW="${MCC_UNDER_TEST:-$ORACLE_RAW}"
CLANG="${CLANG:-clang}"
LLC="${LLC:-llc}"

resolve_compiler() {
    case "$1" in
        */*) case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$HERE/$1" ;; esac ;;
        *) printf '%s\n' "$1" ;;
    esac
}

compiler_exists() {
    case "$1" in
        */*) [ -x "$1" ] ;;
        *) command -v "$1" >/dev/null 2>&1 ;;
    esac
}

ORACLE="$(resolve_compiler "$ORACLE_RAW")"
UNDER_TEST="$(resolve_compiler "$UNDER_TEST_RAW")"

if ! compiler_exists "$ORACLE"; then
    echo "SKIP: full-selfhost-diff (oracle compiler not found: $ORACLE_RAW)"
    exit 0
fi
if ! compiler_exists "$UNDER_TEST"; then
    echo "FAIL: full-selfhost-diff (compiler under test not found: $UNDER_TEST_RAW)"
    exit 1
fi
if [ ! -f "$MANIFEST" ]; then
    echo "FAIL: full-selfhost-diff (manifest not found: $MANIFEST)"
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

passes=0
failures=0
skips=0
total=0
seen_names=""

note_pass() {
    passes=$((passes + 1))
    echo "PASS: $*"
}

note_fail() {
    failures=$((failures + 1))
    echo "FAIL: $*"
}

note_skip() {
    skips=$((skips + 1))
    echo "SKIP: $*"
}

normalize_file() {
    local in="$1"
    local out="$2"
    sed \
        -e $'s/\r$//' \
        -e "s|$HERE|<repo>|g" \
        -e "s|$WORK|<tmp>|g" \
        -e 's/0x[0-9A-Fa-f][0-9A-Fa-f]* in /0x<addr> in /g' \
        -e 's|/private/var/folders/[^[:space:]"<>]*|<tmp>|g' \
        -e 's|/var/folders/[^[:space:]"<>]*|<tmp>|g' \
        -e 's|/tmp/[^[:space:]"<>]*|<tmp>|g' \
        "$in" > "$out"
}

host_triple() {
    local triple=""
    if command -v "$LLC" >/dev/null 2>&1; then
        triple="$("$LLC" --version | awk -F: '/Default target:/ { gsub(/^[ \t]+/, "", $2); print $2; exit }')"
    fi
    if [ -z "$triple" ] && command -v "$CLANG" >/dev/null 2>&1; then
        triple="$("$CLANG" -dumpmachine 2>/dev/null || true)"
    fi
    printf '%s\n' "$triple"
}

host_arch_flag() {
    local triple
    triple="$(host_triple)"
    case "$triple" in
        riscv64*) printf '%s\n' "--arch=riscv64" ;;
        x86_64*) printf '%s\n' "--arch=x86_64" ;;
        aarch64*|arm64*) printf '%s\n' "--arch=aarch64" ;;
        *) printf '%s\n' "" ;;
    esac
}

has_arch_flag() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --arch=*) return 0 ;;
        esac
    done
    return 1
}

run_compiler() {
    local compiler="$1"
    local stem="$2"
    local subcmd="$3"
    local src="$4"
    shift 4

    set +e
    "$compiler" "$subcmd" "$src" "$@" > "$WORK/$stem.out" 2> "$WORK/$stem.err"
    local rc=$?
    set -e
    printf '%s\n' "$rc" > "$WORK/$stem.rc"
}

compare_normalized() {
    local label="$1"
    local left="$2"
    local right="$3"
    local left_norm="$WORK/$label.oracle.norm"
    local right_norm="$WORK/$label.test.norm"

    normalize_file "$left" "$left_norm"
    normalize_file "$right" "$right_norm"
    if ! cmp -s "$left_norm" "$right_norm"; then
        note_fail "full-selfhost-diff $label - normalized output differs"
        diff -u "$left_norm" "$right_norm" | sed -n '1,80p'
        return 1
    fi
    return 0
}

make_c_driver() {
    local entry="$1"
    local out="$2"
    cat > "$out" <<EOF
#include <stdint.h>
#include <stdio.h>
extern uint32_t ${entry}(void);
int main(void) {
    printf("%u\\n", ${entry}());
    return 0;
}
EOF
}

make_trap_driver() {
    local entry="$1"
    local out="$2"
    cat > "$out" <<EOF
#include <stdint.h>
#include <stdio.h>

void mc_trap_Assert(void) { __builtin_trap(); }
void mc_trap_Bounds(void) { __builtin_trap(); }
void mc_trap_DivideByZero(void) { __builtin_trap(); }
void mc_trap_IntegerOverflow(void) { __builtin_trap(); }
void mc_trap_InvalidRepresentation(void) { __builtin_trap(); }
void mc_trap_InvalidShift(void) { __builtin_trap(); }
void mc_trap_NullUnwrap(void) { __builtin_trap(); }
void mc_trap_Unreachable(void) { __builtin_trap(); }

extern uint32_t ${entry}(void);
int main(void) {
    printf("%u\\n", ${entry}());
    return 0;
}
EOF
}

run_binary() {
    local bin="$1"
    local out="$2"
    local rcfile="$3"
    set +e
    "$bin" > "$out" 2>&1
    local rc=$?
    set -e
    printf '%s\n' "$rc" > "$rcfile"
}

link_and_run_c() {
    local name="$1"
    local tag="$2"
    local c_file="$3"
    local entry="$4"
    local expected="$5"
    local driver="$WORK/$name.$tag.driver.c"
    local bin="$WORK/$name.$tag.bin"
    local cc_err="$WORK/$name.$tag.cc.err"
    local run_out="$WORK/$name.$tag.run.out"
    local run_rc="$WORK/$name.$tag.run.rc"

    make_c_driver "$entry" "$driver"
    if ! "$CLANG" -std=c11 -Wall -Wextra -Werror -x c "$c_file" "$driver" -o "$bin" > /dev/null 2> "$cc_err"; then
        note_fail "full-selfhost-diff $name - clang failed for $tag C output"
        sed -n '1,40p' "$cc_err"
        return 1
    fi
    run_binary "$bin" "$run_out" "$run_rc"
    if [ "$(cat "$run_rc")" != "0" ]; then
        note_fail "full-selfhost-diff $name - $tag binary exited $(cat "$run_rc")"
        sed -n '1,40p' "$run_out"
        return 1
    fi
    if [ -n "$expected" ] && [ "$(cat "$run_out")" != "$expected" ]; then
        note_fail "full-selfhost-diff $name - $tag stdout '$(cat "$run_out")' != expected '$expected'"
        return 1
    fi
    return 0
}

link_and_run_llvm_object() {
    local name="$1"
    local tag="$2"
    local ll_file="$3"
    local entry="$4"
    local expected="$5"
    local obj="$WORK/$name.$tag.o"
    local driver="$WORK/$name.$tag.llvm_driver.c"
    local bin="$WORK/$name.$tag.llvm_bin"
    local llc_err="$WORK/$name.$tag.llc.err"
    local cc_err="$WORK/$name.$tag.llvm_cc.err"
    local run_out="$WORK/$name.$tag.llvm_run.out"
    local run_rc="$WORK/$name.$tag.llvm_run.rc"
    local link_flags=()
    local llc_args=()
    local triple
    triple="$(host_triple)"

    if [ "$(uname -s)" = "Linux" ]; then
        link_flags=(-no-pie)
    fi
    if [ -n "$triple" ]; then
        llc_args=("-mtriple=$triple")
    fi

    if ! "$LLC" -filetype=obj "$ll_file" -o "$obj" ${llc_args[@]+"${llc_args[@]}"} > /dev/null 2> "$llc_err"; then
        note_fail "full-selfhost-diff $name - llc failed for $tag LLVM output"
        sed -n '1,40p' "$llc_err"
        return 1
    fi

    make_trap_driver "$entry" "$driver"
    if ! "$CLANG" -std=c11 ${link_flags[@]+"${link_flags[@]}"} "$driver" "$obj" -o "$bin" > /dev/null 2> "$cc_err"; then
        note_fail "full-selfhost-diff $name - clang failed linking $tag LLVM object"
        sed -n '1,40p' "$cc_err"
        return 1
    fi

    run_binary "$bin" "$run_out" "$run_rc"
    if [ "$(cat "$run_rc")" != "0" ]; then
        note_fail "full-selfhost-diff $name - $tag LLVM object binary exited $(cat "$run_rc")"
        sed -n '1,40p' "$run_out"
        return 1
    fi
    if [ -n "$expected" ] && [ "$(cat "$run_out")" != "$expected" ]; then
        note_fail "full-selfhost-diff $name - $tag LLVM stdout '$(cat "$run_out")' != expected '$expected'"
        return 1
    fi
    return 0
}

run_c_row() {
    local name="$1"
    local src="$2"
    local entry="$3"
    local expected="$4"
    shift 4
    local flags=("$@")

    run_compiler "$ORACLE" "$name.oracle.c" emit-c "$src" ${flags[@]+"${flags[@]}"}
    run_compiler "$UNDER_TEST" "$name.test.c" emit-c "$src" ${flags[@]+"${flags[@]}"}

    local oracle_rc test_rc
    oracle_rc="$(cat "$WORK/$name.oracle.c.rc")"
    test_rc="$(cat "$WORK/$name.test.c.rc")"
    if [ "$oracle_rc" != "0" ] || [ "$test_rc" != "0" ]; then
        note_fail "full-selfhost-diff $name - positive emit-c failed (oracle=$oracle_rc test=$test_rc)"
        sed -n '1,40p' "$WORK/$name.oracle.c.err"
        sed -n '1,40p' "$WORK/$name.test.c.err"
        return
    fi
    compare_normalized "$name.emit-c" "$WORK/$name.oracle.c.out" "$WORK/$name.test.c.out" || return

    if ! command -v "$CLANG" >/dev/null 2>&1; then
        note_skip "full-selfhost-diff $name run (clang not found)"
        note_pass "full-selfhost-diff $name - emit-c text matches"
        return
    fi

    link_and_run_c "$name" oracle "$WORK/$name.oracle.c.out" "$entry" "$expected" || return
    link_and_run_c "$name" test "$WORK/$name.test.c.out" "$entry" "$expected" || return
    compare_normalized "$name.run" "$WORK/$name.oracle.run.out" "$WORK/$name.test.run.out" || return
    note_pass "full-selfhost-diff $name - emit-c text and hosted run output match ($expected)"
}

run_diag_row() {
    local name="$1"
    local src="$2"
    local expected_code="$3"
    shift 3
    local flags=("$@")

    run_compiler "$ORACLE" "$name.oracle.diag" emit-c "$src" ${flags[@]+"${flags[@]}"}
    run_compiler "$UNDER_TEST" "$name.test.diag" emit-c "$src" ${flags[@]+"${flags[@]}"}

    cat "$WORK/$name.oracle.diag.out" "$WORK/$name.oracle.diag.err" > "$WORK/$name.oracle.diag.all"
    cat "$WORK/$name.test.diag.out" "$WORK/$name.test.diag.err" > "$WORK/$name.test.diag.all"

    local oracle_rc test_rc
    oracle_rc="$(cat "$WORK/$name.oracle.diag.rc")"
    test_rc="$(cat "$WORK/$name.test.diag.rc")"
    if [ "$oracle_rc" = "0" ]; then
        note_fail "full-selfhost-diff $name - oracle accepted negative fixture"
        return
    fi
    if [ "$test_rc" = "0" ]; then
        note_fail "full-selfhost-diff $name - compiler under test accepted negative fixture"
        return
    fi
    if [ "$oracle_rc" != "$test_rc" ]; then
        note_fail "full-selfhost-diff $name - diagnostic exit status differs (oracle=$oracle_rc test=$test_rc)"
        return
    fi
    if ! grep -q "$expected_code" "$WORK/$name.oracle.diag.all"; then
        note_fail "full-selfhost-diff $name - oracle diagnostic lacks expected code $expected_code"
        sed -n '1,60p' "$WORK/$name.oracle.diag.all"
        return
    fi
    if ! grep -q "$expected_code" "$WORK/$name.test.diag.all"; then
        note_fail "full-selfhost-diff $name - compiler under test diagnostic lacks expected code $expected_code"
        sed -n '1,60p' "$WORK/$name.test.diag.all"
        return
    fi
    compare_normalized "$name.diag" "$WORK/$name.oracle.diag.all" "$WORK/$name.test.diag.all" || return
    note_pass "full-selfhost-diff $name - negative diagnostic matches ($expected_code)"
}

run_llvm_row() {
    local name="$1"
    local src="$2"
    local entry="$3"
    local expected="$4"
    shift 4
    local effective_flags=("$@")
    if ! has_arch_flag ${effective_flags[@]+"${effective_flags[@]}"}; then
        local arch_flag
        arch_flag="$(host_arch_flag)"
        if [ -n "$arch_flag" ]; then
            effective_flags+=("$arch_flag")
        fi
    fi

    run_compiler "$ORACLE" "$name.oracle.ll" emit-llvm "$src" ${effective_flags[@]+"${effective_flags[@]}"}
    run_compiler "$UNDER_TEST" "$name.test.ll" emit-llvm "$src" ${effective_flags[@]+"${effective_flags[@]}"}

    local oracle_rc test_rc
    oracle_rc="$(cat "$WORK/$name.oracle.ll.rc")"
    test_rc="$(cat "$WORK/$name.test.ll.rc")"
    if [ "$oracle_rc" != "0" ] || [ "$test_rc" != "0" ]; then
        note_fail "full-selfhost-diff $name - positive emit-llvm failed (oracle=$oracle_rc test=$test_rc)"
        sed -n '1,40p' "$WORK/$name.oracle.ll.err"
        sed -n '1,40p' "$WORK/$name.test.ll.err"
        return
    fi
    compare_normalized "$name.emit-llvm" "$WORK/$name.oracle.ll.out" "$WORK/$name.test.ll.out" || return

    if ! command -v "$LLC" >/dev/null 2>&1; then
        note_skip "full-selfhost-diff $name object/run (llc not found)"
        note_pass "full-selfhost-diff $name - emit-llvm text matches"
        return
    fi
    if ! command -v "$CLANG" >/dev/null 2>&1; then
        note_skip "full-selfhost-diff $name object/run (clang not found)"
        note_pass "full-selfhost-diff $name - emit-llvm text matches"
        return
    fi

    link_and_run_llvm_object "$name" oracle "$WORK/$name.oracle.ll.out" "$entry" "$expected" || return
    link_and_run_llvm_object "$name" test "$WORK/$name.test.ll.out" "$entry" "$expected" || return
    compare_normalized "$name.llvm-run" "$WORK/$name.oracle.llvm_run.out" "$WORK/$name.test.llvm_run.out" || return
    note_pass "full-selfhost-diff $name - emit-llvm text, object link, and run output match ($expected)"
}

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|\#*) continue ;;
    esac

    IFS=$'\t' read -r name mode relpath probe expected flags <<< "$line"
    total=$((total + 1))

    if [ -z "${name:-}" ] || [ -z "${mode:-}" ] || [ -z "${relpath:-}" ]; then
        note_fail "full-selfhost-diff manifest - malformed row: $line"
        continue
    fi
    if printf '%s\n' "$seen_names" | grep -Fxq "$name"; then
        note_fail "full-selfhost-diff manifest - duplicate row id: $name"
        continue
    fi
    seen_names="${seen_names}${name}
"
    if [ "${expected:-}" = "-" ]; then
        expected=""
    fi

    src="$HERE/$relpath"
    if [ ! -f "$src" ]; then
        note_fail "full-selfhost-diff $name - fixture not found: $relpath"
        continue
    fi

    declare -a flag_array=()
    if [ -n "${flags:-}" ] && [ "$flags" != "-" ]; then
        read -r -a flag_array <<< "$flags"
    fi

    case "$mode" in
        c-run) run_c_row "$name" "$src" "$probe" "${expected:-}" ${flag_array[@]+"${flag_array[@]}"} ;;
        diag) run_diag_row "$name" "$src" "$probe" ${flag_array[@]+"${flag_array[@]}"} ;;
        llvm-object) run_llvm_row "$name" "$src" "$probe" "${expected:-}" ${flag_array[@]+"${flag_array[@]}"} ;;
        *) note_fail "full-selfhost-diff $name - unknown manifest mode: $mode" ;;
    esac
done < "$MANIFEST"

if [ "$failures" -gt 0 ]; then
    echo "FAIL: full-selfhost-diff - $failures failure(s), $passes pass(es), $skips skip(s), $total manifest row(s)"
    exit 1
fi

echo "PASS: full-selfhost-diff - $passes pass(es), $skips skip(s), $total manifest row(s); oracle=$ORACLE_RAW under_test=$UNDER_TEST_RAW"
