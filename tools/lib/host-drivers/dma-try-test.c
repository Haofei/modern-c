// Host driver for dma-try-test: a tiny one-shot DMA pool behind the fallible provider primitive
// `mc_dma_alloc_base_try`, so std/dma's `try_alloc` returns a typed DmaError.OutOfMemory on
// exhaustion instead of trapping. The infallible `mc_dma_alloc_base` and the rest of the std/dma
// extern seam are stubbed (the fixture emits them but only drives the fallible path).
#include <stdint.h>

static uint8_t g_pool[256];
static int g_in_use = 0;

// Fallible: 0 on exhaustion / in-use, never traps.
uintptr_t mc_dma_alloc_base_try(uintptr_t len) {
    if (len > sizeof(g_pool) || g_in_use) return 0;
    g_in_use = 1;
    for (uintptr_t i = 0; i < len; ++i) g_pool[i] = 0;
    return (uintptr_t)g_pool;
}
uintptr_t mc_dma_alloc_base(uintptr_t len) { return mc_dma_alloc_base_try(len); }
void mc_dma_free_base(uintptr_t dev, uintptr_t cpu, uintptr_t len) { (void)dev; (void)cpu; (void)len; g_in_use = 0; }
void mc_dma_clean_for_device_base(uintptr_t dev, uintptr_t cpu, uintptr_t len) { (void)dev; (void)cpu; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev, uintptr_t len) { (void)len; return dev; }

extern uint32_t dma_try_run(void);

#define CHECK(c) do { if (!(c)) return __LINE__; } while (0)
int main(void) {
    CHECK(dma_try_run() == 0x3); // small alloc ok (0x1) + oversized alloc -> typed OutOfMemory (0x2)
    return 0;
}
