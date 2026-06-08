#!/usr/bin/env bash
# VFS test: compile the fd-table VFS over ramfs (kernel/fs/vfs.mc via the test
# wrappers) to an object, link a C driver, and check open/write/read with fd
# positions, re-open, read-past-end, close, and use-after-close.
set -euo pipefail

MCC="${1:-zig-out/bin/mcc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: vfs-test (clang not found)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MCC="$MCC" "$HERE/tools/mcc-cc.sh" "$HERE/tests/qemu/vfs_demo.mc" -o "$WORK/vfs.o" >/dev/null

cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>

extern void     v_init(void);
extern uint64_t v_open(uintptr_t name, uintptr_t name_len);
extern uint64_t v_write(uintptr_t fd, uintptr_t src, uintptr_t len);
extern uint64_t v_read(uintptr_t fd, uintptr_t dst, uintptr_t len);
extern uint64_t v_close(uintptr_t fd);

#define ERR ((uint64_t)-1)
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)

int main(void) {
    v_init();
    static const char log[] = "log";

    // open (creates), write twice (appends, advancing the fd position).
    uint64_t w = v_open((uintptr_t)log, 3);
    CHECK(w == 0);
    CHECK(v_write(w, (uintptr_t)"abc", 3) == 3);
    CHECK(v_write(w, (uintptr_t)"de", 2) == 2);

    // re-open the same file -> a fresh fd at position 0.
    uint64_t r = v_open((uintptr_t)log, 3);
    CHECK(r == 1);

    char buf[8];
    for (int i = 0; i < 8; i++) buf[i] = 0;
    CHECK(v_read(r, (uintptr_t)buf, 8) == 5); // reads "abcde"
    CHECK(buf[0] == 'a' && buf[1] == 'b' && buf[2] == 'c' && buf[3] == 'd' && buf[4] == 'e');
    CHECK(v_read(r, (uintptr_t)buf, 8) == 0);  // position now at end

    // close + use-after-close is rejected.
    CHECK(v_close(w) == 0);
    CHECK(v_write(w, (uintptr_t)"x", 1) == ERR); // bad fd
    CHECK(v_close(w) == ERR);                    // already closed

    return 0;
}
EOF

"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/vfs.o" -o "$WORK/app"
if "$WORK/app"; then
    echo "PASS: vfs-test — fd-table VFS over ramfs: open/write/read with positions, re-open, EOF, close, use-after-close"
    exit 0
fi
echo "FAIL: vfs-test — driver returned non-zero (failing CHECK line)"
exit 1
