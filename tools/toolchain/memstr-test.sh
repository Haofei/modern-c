#!/usr/bin/env bash
# Byte-slice string-op test: a module uses the allocation-free `std/mem` string ops
# (mem_eql / mem_starts_with / mem_index_of_byte / mem_index_of / split_by+split_next)
# over `[]const u8` inputs, is compiled to an object, linked with a C driver, and run.
set -euo pipefail

MCC="${1:-${MCC_UNDER_TEST:-zig-out/bin/mcc}}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/memstr_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: memstr-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC_UNDER_TEST="$MCC" MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/memstr.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t mstr_eql_same(void);
extern uint32_t mstr_eql_diff(void);
extern uint32_t mstr_eql_difflen(void);
extern uint32_t mstr_starts_yes(void);
extern uint32_t mstr_starts_no(void);
extern uint32_t mstr_starts_too_long(void);
extern uint32_t mstr_index_byte_present(void);
extern uint32_t mstr_index_byte_absent(void);
extern uint32_t mstr_index_of_present(void);
extern uint32_t mstr_index_of_absent(void);
extern uint32_t mstr_index_of_empty(void);
extern uint32_t mstr_split_encoded(void);
extern uint32_t mstr_split_empty_field(void);
extern uint32_t mstr_split_field_bytes(void);
int main(void) {
    if (mstr_eql_same()          != 1u)    return 1;    // "foo" == "foo"
    if (mstr_eql_diff()          != 0u)    return 2;    // "foo" != "fox"
    if (mstr_eql_difflen()       != 0u)    return 3;    // "foo" != "foobar" (length)
    if (mstr_starts_yes()        != 1u)    return 4;    // "foobar" starts "foo"
    if (mstr_starts_no()         != 0u)    return 5;    // "foobar" !starts "bar"
    if (mstr_starts_too_long()   != 0u)    return 6;    // prefix longer than hay
    if (mstr_index_byte_present()!= 1001u) return 7;    // ',' at index 1
    if (mstr_index_byte_absent() != 0u)    return 8;    // 'z' absent
    if (mstr_index_of_present()  != 1001u) return 9;    // "bc" first at index 1 of "abcbc"
    if (mstr_index_of_absent()   != 0u)    return 10;   // "xy" absent
    if (mstr_index_of_empty()    != 1000u) return 11;   // empty needle matches at 0
    if (mstr_split_encoded()     != 306u)  return 12;   // 3 fields, lens 1+2+3
    if (mstr_split_empty_field() != 302u)  return 13;   // 3 fields, lens 1+0+1
    if (mstr_split_field_bytes() != 1u)    return 14;   // 2nd field borrows "bb"
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/memstr.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: memstr-test — allocation-free std/mem byte-slice string ops (eql/starts_with/index_of/split) compiled, linked, and ran"
    exit 0
fi
echo "FAIL: memstr-test — program returned non-zero"
exit 1
