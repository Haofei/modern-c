// Host driver for the virtqueue completion fault-injection fixture. std/virtqueue pulls in
// std/time (tick/delay) and std/dma (the no-IOMMU DMA primitives) via the buffer/completion
// paths, so those platform externs are stubbed here to resolve the host link — the fault cases
// reject before touching DMA, and the one valid completion's reconstructed buffer is discarded.
// The fixture returns 1 iff every fault class is rejected with the right typed error and a
// well-formed completion is accepted.
#include <stdint.h>
#include <stdio.h>

uint64_t mc_read_ticks(void) { return 0; }
void mc_udelay(uint32_t us) { (void)us; }

// no-IOMMU identity DMA stubs: device address == cpu address.
uintptr_t mc_dma_alloc_base(uintptr_t len) { (void)len; return 0x1000; }
void mc_dma_free_base(uintptr_t dev, uintptr_t cpu, uintptr_t len) { (void)dev; (void)cpu; (void)len; }
void mc_dma_clean_for_device_base(uintptr_t dev, uintptr_t cpu, uintptr_t len) { (void)dev; (void)cpu; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev, uintptr_t len) { (void)len; return dev; }

extern uint32_t vqf_run(void);

int main(void) {
    uint32_t r = vqf_run();
    if (r == 1) {
        printf("virtqueue fault injection: bad id, not-in-flight, and used.len>alloc each rejected with their own distinct typed error\n");
        return 0;
    }
    printf("FAIL: vqf_run returned %u (expected 1)\n", r);
    return 1;
}
