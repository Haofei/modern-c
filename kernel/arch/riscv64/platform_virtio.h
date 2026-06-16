// kernel/arch/riscv64/platform_virtio.h — the virtio split-virtqueue + DMA struct
// layouts (matching std/virtqueue.mc + std/dma.mc) and the trivial DMA ownership
// transitions, shared by every virtio runtime (net, blk, kmain-net, udp). Each such
// runtime previously re-declared all of this. The DMA *pool* (mc_dma_alloc_base/free_base) and
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
// `Virtq` mirrors std/virtqueue.mc's `Virtq` field-for-field. MC owns the queue logic and
// writes through a pointer to this struct, so the C declaration MUST match MC's layout exactly —
// a missing or reordered field means MC writes past (or into the wrong slot of) the C `Virtq`,
// corrupting adjacent BSS. This bit us once (the inflight_len/inflight_present arrays were absent
// here → BSS corruption → boot hang). The `_Static_assert`s in virtq_layout_assert.h (generated
// by `mcc emit-layout std/virtqueue.mc`) now make any such drift a compile error.
typedef struct mc_array_u64_8 { uint64_t elems[8]; } mc_array_u64_8;
typedef struct mc_array_u32_8 { uint32_t elems[8]; } mc_array_u32_8;
typedef struct mc_array_bool_8 { _Bool elems[8]; } mc_array_bool_8;
typedef struct Virtq {
    DescTable *desc; VringAvail *avail; VringUsed *used;
    uint16_t size; uint16_t free_head; uint16_t num_free; uint16_t last_used;
    mc_array_u64_8 inflight_addr;
    mc_array_u32_8 inflight_len;
    mc_array_bool_8 inflight_present;
} Virtq;
typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct VirtioMmio VirtioMmio;

// Authoritative MC layout checks (generated). Fails to compile on any MC<->C struct drift.
#include "virtq_layout_assert.h"

// DMA ownership transitions (std/dma): identity on QEMU's coherent memory.
void mc_dma_clean_for_device_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev_addr, uintptr_t len) { (void)len; return dev_addr; }

#endif // MC_PLATFORM_VIRTIO_H
