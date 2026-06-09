#!/usr/bin/env bash
# ELF parser test: compile the ELF parser (kernel/core/elf.mc via the test
# wrappers in tests/qemu/lang/elf_demo.mc, with std/bytes + std/addr) to an object,
# link a C driver that crafts a minimal ELF64 image and checks the parsed header
# and program header — including rejection of malformed images.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: elf-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/lang/elf_demo.mc" -o "$WORK/elf.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>

extern uint64_t elf_entry(uintptr_t base, uintptr_t len);
extern uint32_t elf_error_code(uintptr_t base, uintptr_t len);
extern uint64_t elf_seg_vaddr(uintptr_t base, uintptr_t len, uintptr_t i);
extern uint32_t elf_seg_is_load(uintptr_t base, uintptr_t len, uintptr_t i);
extern uint64_t elf_load_first(uintptr_t base, uintptr_t len, uintptr_t dst);

static void put_u16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put_u32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put_u64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
#define ELF_LEN (64 + 56)

int main(void) {
    uint8_t elf[ELF_LEN];
    for (int i = 0; i < ELF_LEN; i++) elf[i] = 0;
    elf[0] = 0x7F; elf[1] = 'E'; elf[2] = 'L'; elf[3] = 'F';
    elf[4] = 2; // ELFCLASS64
    elf[5] = 1; // little-endian
    put_u64(&elf[24], 0x80001000);  // e_entry
    put_u64(&elf[32], 64);          // e_phoff
    put_u16(&elf[54], 56);          // e_phentsize
    put_u16(&elf[56], 1);           // e_phnum
    // one PT_LOAD program header at offset 64, segment = the 4 payload bytes that
    // happen to overlap the header region from p_offset=64 onward; use a small
    // segment whose file bytes are at p_offset and length 4.
    put_u32(&elf[64 + 0], 1);             // p_type = PT_LOAD
    put_u32(&elf[64 + 4], 5);             // p_flags = R|X
    put_u64(&elf[64 + 8], 64);            // p_offset (segment file data starts here)
    put_u64(&elf[64 + 16], 0x80002000);   // p_vaddr
    put_u64(&elf[64 + 32], 4);            // p_filesz
    put_u64(&elf[64 + 40], 8);            // p_memsz (4 file bytes + 4 zero-fill)
    // The segment's first 4 bytes (at p_offset=64) are the phdr's p_type word (1).

    uintptr_t base = (uintptr_t)elf;
    CHECK(elf_entry(base, ELF_LEN) == 0x80001000);
    CHECK(elf_error_code(base, ELF_LEN) == 999);          // valid header
    CHECK(elf_seg_vaddr(base, ELF_LEN, 0) == 0x80002000); // segment vaddr
    CHECK(elf_seg_is_load(base, ELF_LEN, 0) == 1);        // PT_LOAD

    // Load the segment and verify the bytes were copied (4 file bytes = p_type word
    // 0x01,0x00,0x00,0x00) and the bss tail zero-filled (memsz 8 > filesz 4).
    uint8_t dst[16];
    for (int i = 0; i < 16; i++) dst[i] = 0xAA;
    CHECK(elf_load_first(base, ELF_LEN, (uintptr_t)dst) == 4);
    CHECK(dst[0] == 1 && dst[1] == 0 && dst[2] == 0 && dst[3] == 0); // copied file bytes
    CHECK(dst[4] == 0 && dst[5] == 0 && dst[6] == 0 && dst[7] == 0); // zero-filled bss
    CHECK(dst[8] == 0xAA);                                           // untouched past memsz

    // Bad magic -> BadMagic (ordinal 1).
    uint8_t bad[ELF_LEN];
    for (int i = 0; i < ELF_LEN; i++) bad[i] = elf[i];
    bad[1] = 'X';
    CHECK(elf_error_code((uintptr_t)bad, ELF_LEN) == 1);

    // Truncated buffer -> TooSmall (ordinal 0).
    CHECK(elf_error_code(base, 32) == 0);

    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/elf.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: elf-test — ELF64 parse (header+phdr) + segment load (copy+bss zero-fill) + reject bad magic/truncation"
    exit 0
fi
echo "FAIL: elf-test — driver returned non-zero (failing CHECK line)"
exit 1
