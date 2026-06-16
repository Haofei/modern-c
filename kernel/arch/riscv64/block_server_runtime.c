// Test entry for the block-server demo (tests/qemu/block_server_demo.mc). A client
// writes + reads a block through the storage server over IPC and verifies the bytes.
#include <stdint.h>
#include <stddef.h>
void putc_(char c);
void puts_(const char *s);
void mc_halt(void);
uint32_t block_server_demo(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("block-server booting\n");
    uint32_t ok = block_server_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    if (ok == 1) puts_("BLK-SERVER-OK\n");
    else puts_("BLK-SERVER-FAIL\n");
    mc_halt();
}
