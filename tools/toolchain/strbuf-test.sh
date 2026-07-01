#!/usr/bin/env bash
# StrBuf test: a module imports the growable `std/strbuf` (`StrBuf`, built on `Vec<u8>`),
# builds a known string with put_str/put_byte/put_u32/put_hex_u32 (forcing several grows),
# reads it back byte-by-byte, and free+reuses the buffer — all with a malloc-backed
# allocator, then linked/run. The driver checks the exact emitted bytes.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
SRC="$HERE/tests/toolchain/strbuf_user.mc"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: strbuf-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$SRC" -o "$WORK/strbuf.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
size_t mc_malloc(size_t n){ return (size_t)malloc(n); }
void   mc_free(size_t a, size_t n){ (void)n; free((void*)a); }
// Matches MC's emitted `mc_slice_const_u8` layout ({ uint8_t const *ptr; uintptr_t len; }):
// the module calls sb_label() to get a genuine `[]const u8` to feed sb_put_str.
typedef struct { uint8_t const *ptr; uintptr_t len; } mc_slice_const_u8;
mc_slice_const_u8 sb_label(void){
    static const uint8_t s[2] = { 'N', '=' };
    return (mc_slice_const_u8){ .ptr = s, .len = 2 };
}
extern uint32_t strbuf_len(void);
extern uint8_t  strbuf_byte(uint32_t i);
extern uint32_t strbuf_checksum(void);
int main(void) {
    // Canonical string: "N=" + u32(UINT32_MAX) + ' ' + hex(0xDEADBEEF) + u32(0).
    const char *want = "N=4294967295 0xdeadbeef0";
    uint32_t n = (uint32_t)strlen(want);            // 24
    if (strbuf_len() != n) return 1;
    for (uint32_t i = 0; i < n; i++) {
        if (strbuf_byte(i) != (uint8_t)want[i]) return 2;
    }
    // Weighted checksum sum(byte[i]*(i+1)); computed here from `want` and compared.
    uint32_t expect = 0;
    for (uint32_t i = 0; i < n; i++) expect += (uint32_t)(uint8_t)want[i] * (i + 1);
    if (strbuf_checksum() != expect) return 3;
    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/strbuf.o" -o "$WORK/prog"
if "$WORK/prog"; then
    echo "PASS: strbuf-test — growable std/strbuf (StrBuf over Vec<u8>) put_str/byte/u32/hex, grew, read back, freed+reused, and ran"
    exit 0
fi
echo "FAIL: strbuf-test — program returned non-zero"
exit 1
