#include <stdint.h>
#include <stddef.h>
void *memset(void *d, int c, size_t n) { uint8_t *p=d; for(size_t i=0;i<n;++i)p[i]=(uint8_t)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { uint8_t *a=d; const uint8_t *b=s; for(size_t i=0;i<n;++i)a[i]=b[i]; return d; }
void putc_(char c); void puts_(const char *s); void mc_halt(void);
uint32_t privilege_demo(void);
__attribute__((used)) void test_main(void) {
    puts_("privilege booting\n");
    if (privilege_demo() == 1) puts_("PRIV-OK\n"); else puts_("PRIV-FAIL\n");
    mc_halt();
}
