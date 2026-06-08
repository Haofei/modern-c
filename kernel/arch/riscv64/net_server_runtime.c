// Test entry for the net-server demo (tests/qemu/net_server_demo.mc). A client binds a
// UDP port, injects a datagram, and receives it back — all over IPC to the net server.
#include <stdint.h>
#include <stddef.h>
void *memset(void *d, int c, size_t n) { uint8_t *p=d; for(size_t i=0;i<n;++i)p[i]=(uint8_t)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { uint8_t *a=d; const uint8_t *b=s; for(size_t i=0;i<n;++i)a[i]=b[i]; return d; }
void putc_(char c);
void puts_(const char *s);
void mc_halt(void);
uint32_t net_server_demo(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("net-server booting\n");
    uint32_t ok = net_server_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    if (ok == 1) puts_("NET-SERVER-OK\n");
    else puts_("NET-SERVER-FAIL\n");
    mc_halt();
}
