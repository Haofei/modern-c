#include <stdint.h>
// std/dma (pulled in via the Ethernet MacAddr import) declares these platform DMA hooks; the
// ARP cache never calls them, so stub them so the test links on the host.
uintptr_t mc_dma_alloc_base(uintptr_t len){ (void)len; return 0; }
void mc_dma_free_base(uintptr_t a, uintptr_t b, uintptr_t c){ (void)a; (void)b; (void)c; }
void mc_dma_clean_for_device_base(uintptr_t a, uintptr_t b, uintptr_t c){ (void)a; (void)b; (void)c; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t a, uintptr_t b){ (void)a; (void)b; return 0; }
extern uint32_t arp_cache_run(void);
int main(void){ return arp_cache_run()==1 ? 0 : 1; }
