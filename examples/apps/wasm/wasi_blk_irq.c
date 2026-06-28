// examples/apps/wasm/wasi_blk_irq.c — Phase-6 S-mode virtio-blk IRQ peer, the WASM mirror of
// examples/agents/agent_blk_irq_tool.js. A stock wasm32-wasi guest reads "/ws/disk" through the
// capability-checked FS broker; the kernel services the read from a REAL S-mode virtio-blk device
// and delivers the completion via a PLIC interrupt + SYS_POLL. The disk image's first bytes are
// "DISK". mkdir under /ws is NOT in the agent's tool allowlist, so it is denied. Prints "blk-irq:
// ok" only on the fully-correct IRQ path (read returns DISK AND mkdir denied).
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    int fd = open("/ws/disk", O_RDONLY);
    if (fd < 0) { printf("blk-irq: FAIL open (%d)\n", errno); return 1; }
    char buf[16];
    memset(buf, 0, sizeof buf);
    ssize_t n = read(fd, buf, sizeof buf);   // completed by a real virtio-blk IRQ
    close(fd);
    if (!(n >= 4 && memcmp(buf, "DISK", 4) == 0)) {
        printf("blk-irq: bad value n=%d\n", (int)n);
        return 1;
    }
    printf("blk-irq: read=DISK\n");

    // Broker-level deny: mkdir is not in the agent's tool allowlist -> denied.
    if (mkdir("/ws/sub", 0755) == 0) { printf("blk-irq: mkdir FAIL (allowed)\n"); return 1; }
    printf("blk-irq: mkdir denied\n");

    printf("blk-irq: ok\n");
    return 0;
}
