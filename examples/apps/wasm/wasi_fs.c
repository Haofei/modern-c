// examples/apps/wasm/wasi_fs.c — the Phase-2 guest: a stock wasm32-wasi program (POSIX file I/O
// via zig's wasi-libc) that drives the REAL capability-checked FS tool path, the WASM mirror of
// examples/agents/agent_fs.js. The kernel minted the agent a path-cap rooted at "/ws" with
// read+write and an allowlist of {FS_WRITE, FS_READ} ONLY, so:
//   - write then read under /ws  -> ALLOWED (round-trip returns "hi")
//   - mkdir under /ws            -> DENIED  (not allowlisted) -> EACCES (from the broker's E_DENIED)
// It prints "fs: ok" ONLY on the fully-correct path (round-trip correct AND mkdir denied), so a
// broken capability mapping cannot print the success sentinel. wasi-libc lowers these POSIX calls
// to path_open/fd_read/fd_write/fd_close/path_create_directory against the "/ws" preopen, which the
// shim routes to TOOL_OP_FS_* through agent_fs_call. See docs/wasm-migration-plan.md Phase 2.

#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    // write "hi" to /ws/a.txt
    int fd = open("/ws/a.txt", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd < 0) { printf("fs: FAIL open-write (%d)\n", errno); return 1; }
    if (write(fd, "hi", 2) != 2) { printf("fs: FAIL write\n"); close(fd); return 1; }
    close(fd);

    // read it back
    fd = open("/ws/a.txt", O_RDONLY);
    if (fd < 0) { printf("fs: FAIL open-read (%d)\n", errno); return 1; }
    char buf[8];
    memset(buf, 0, sizeof buf);
    ssize_t n = read(fd, buf, sizeof buf);
    close(fd);
    if (!(n == 2 && buf[0] == 'h' && buf[1] == 'i')) {
        printf("fs: FAIL read mismatch n=%d\n", (int)n);
        return 1;
    }
    printf("fs: read=%s\n", buf);

    // Broker-level deny: mkdir is not in the agent's tool allowlist -> E_DENIED -> EACCES.
    int r = mkdir("/ws/sub", 0755);
    if (r == 0) { printf("fs: FAIL mkdir UNEXPECTEDLY allowed\n"); return 1; }
    if (errno != EACCES) { printf("fs: FAIL mkdir denied wrong errno %d\n", errno); return 1; }
    printf("fs: mkdir denied EACCES\n");

    // Preopen-level deny (no cap = no access): a path with no matching preopen (outside /ws) is
    // refused by the WASI preopen sandbox itself — wasi-libc returns an error without the request
    // ever reaching the host or the broker. This is the capability mapping "no preopen = no cap".
    int efd = open("/etc/passwd", O_RDONLY);
    if (efd >= 0) { printf("fs: FAIL outside-preopen UNEXPECTEDLY opened\n"); close(efd); return 1; }
    printf("fs: outside-preopen refused (errno=%d)\n", errno);

    printf("fs: ok\n");
    return 0;
}
