#!/usr/bin/env bash
# ramfs test: compile the in-memory filesystem (kernel/fs/ramfs.mc via the test
# wrappers, with std/bytes + std/addr) to an object, link a C driver that creates
# files, writes + reads them back, and checks lookup + error paths.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: ramfs-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/fs/ramfs_demo.mc" -o "$WORK/ramfs.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>

extern void     fs_init(void);
extern uint64_t fs_create(uintptr_t name, uintptr_t name_len, uintptr_t cap);
extern uint64_t fs_write(uintptr_t idx, uintptr_t src, uintptr_t len);
extern uint64_t fs_read(uintptr_t idx, uintptr_t dst, uintptr_t len);
extern uint64_t fs_find(uintptr_t name, uintptr_t name_len);
extern uint64_t fs_size(uintptr_t idx);

#define ERR ((uint64_t)-1)
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    fs_init();

    static const char hello[] = "hello";
    static const char world[] = "world!";
    static const char readme[] = "readme";

    // Create + write + read back.
    uint64_t h = fs_create((uintptr_t)hello, 5, 64);
    CHECK(h == 0);
    CHECK(fs_write(h, (uintptr_t)world, 6) == 6);
    CHECK(fs_size(h) == 6);

    char buf[16];
    for (int i = 0; i < 16; i++) buf[i] = 0;
    CHECK(fs_read(h, (uintptr_t)buf, 16) == 6); // min(16, size=6)
    CHECK(buf[0] == 'w' && buf[1] == 'o' && buf[2] == 'r' && buf[3] == 'l' && buf[4] == 'd' && buf[5] == '!');

    // A second file is independent.
    uint64_t r = fs_create((uintptr_t)readme, 6, 64);
    CHECK(r == 1);
    CHECK(fs_write(r, (uintptr_t)hello, 5) == 5);

    // Lookup by name.
    CHECK(fs_find((uintptr_t)hello, 5) == 0);
    CHECK(fs_find((uintptr_t)readme, 6) == 1);
    CHECK(fs_find((uintptr_t)world, 6) == ERR); // no such file

    // The first file's bytes are unchanged by the second file's write.
    for (int i = 0; i < 16; i++) buf[i] = 0;
    CHECK(fs_read(0, (uintptr_t)buf, 16) == 6);
    CHECK(buf[0] == 'w' && buf[5] == '!');

    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/ramfs.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: ramfs-test — in-memory FS: create / write / read-back / lookup / independence / not-found all correct"
    exit 0
fi
echo "FAIL: ramfs-test — driver returned non-zero (failing CHECK line)"
exit 1
