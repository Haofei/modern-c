// Test entry for the FS-server demo (tests/qemu/fs_server_demo.mc). A client opens,
// writes "OK", re-opens, reads back, and verifies — all over IPC to the FS server.
#include <stdint.h>
#include <stddef.h>
void putc_(char c);
void puts_(const char *s);
void mc_halt(void);
uint32_t fs_server_demo(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("fs-server booting\n");
    uint32_t ok = fs_server_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    if (ok == 1) puts_("FS-SERVER-OK\n");
    else puts_("FS-SERVER-FAIL\n");
    mc_halt();
}
