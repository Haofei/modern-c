// kernel/arch/riscv64/platform_virtio.h — the virtio split-virtqueue + DMA struct
// layouts (matching std/virtqueue.mc + std/dma.mc) and the trivial DMA ownership
// transitions, shared by every virtio runtime (net, blk, kmain-net, udp). Each such
// runtime previously re-declared all of this. The DMA *pool* (mc_dma_alloc/free) and
// device discovery stay per-runtime since they differ (single-slot vs bump pool;
// device id). Include once per virtio runtime.
#ifndef MC_PLATFORM_VIRTIO_H
#define MC_PLATFORM_VIRTIO_H
#include <stdint.h>

typedef struct VringDesc { uint64_t addr; uint32_t len; uint16_t flags; uint16_t next; } VringDesc;
typedef struct DescTable { VringDesc d[8]; } DescTable;
typedef struct VringAvail { uint16_t flags; uint16_t idx; uint16_t ring[8]; uint16_t used_event; } VringAvail;
typedef struct UsedElem { uint32_t id; uint32_t len; } UsedElem;
typedef struct VringUsed { uint16_t flags; uint16_t idx; UsedElem ring[8]; uint16_t avail_event; } VringUsed;
typedef struct mc_array_u64_8 { uint64_t elems[8]; } mc_array_u64_8;
typedef struct Virtq {
    DescTable *desc; VringAvail *avail; VringUsed *used;
    uint16_t size; uint16_t free_head; uint16_t num_free; uint16_t last_used;
    mc_array_u64_8 inflight_addr;
} Virtq;
typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct VirtioMmio VirtioMmio;

// DMA ownership transitions (std/dma): identity on QEMU's coherent memory.
DeviceBuffer mc_dma_clean_for_device(CpuBuffer b) { DeviceBuffer d = { b.dev_addr, b.len }; return d; }
CpuBuffer mc_dma_invalidate_for_cpu(DeviceBuffer b) { CpuBuffer c = { b.dev_addr, b.dev_addr, b.len }; return c; }

#endif // MC_PLATFORM_VIRTIO_H
