// Test entry for the IPC-completeness demo (multi-slot + source filter + notify).
#include <stdint.h>
#include <stddef.h>
void putc_(char c);
void puts_(const char *s);
void mc_halt(void);
uint32_t tcp_server_run(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("tcp-server booting\n");
    uint32_t ok = tcp_server_run((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    if (ok == 1) puts_("TCPSRV-OK\n");
    else puts_("TCPSRV-FAIL\n");
    mc_halt();
}
