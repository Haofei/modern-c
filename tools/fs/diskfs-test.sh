#!/usr/bin/env bash
# On-disk FS test: format, create+write a file, remount, read it back from the device.
set -euo pipefail
MCC="${1:-zig-out/bin/mcc}"
HERE="$(d=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd); while [ "$d" != / ] && [ ! -e "$d/build.zig" ]; do d=$(dirname "$d"); done; printf %s "$d")"
CLANG="${CLANG:-clang}"
command -v "$CLANG" >/dev/null 2>&1 || { echo "SKIP: diskfs-test (clang not found)"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MCC="$MCC" "$HERE/tools/toolchain/mcc-cc.sh" "$HERE/tests/qemu/fs/diskfs_demo.mc" -o "$WORK/d.o" >/dev/null
cat >"$WORK/driver.c" <<'EOF'
#include <stdint.h>
extern uint32_t diskfs_run(void);
#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) { CHECK(diskfs_run() == 1); return 0; }
EOF
"$CLANG" -std=c11 -Wall -Wextra -Werror "$WORK/driver.c" "$WORK/d.o" -o "$WORK/app"
if "$WORK/app"; then echo "PASS: diskfs-test — on-disk FS: format + create + write, then remount and read the file back from the device (persistent superblock/inode/data)"; exit 0; fi
echo "FAIL: diskfs-test"; exit 1
