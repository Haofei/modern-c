// kernel/arch/riscv64/platform_virtio.h — the virtio split-virtqueue + DMA struct
// layouts (matching std/virtqueue.mc + std/dma.mc) and the trivial DMA ownership
// transitions, shared by every virtio runtime (net, blk, kmain-net, udp). Each such
// runtime previously re-declared all of this. The DMA *pool* (mc_dma_alloc_base/free_base) and
// device discovery stay per-runtime since they differ (single-slot vs bump pool;
// device id). Include once per virtio runtime.
#ifndef MC_PLATFORM_VIRTIO_H
#define MC_PLATFORM_VIRTIO_H
#include <stdint.h>

// A2 (single source of truth): the virtio split-virtqueue structs (VringDesc, DescTable,
// VringAvail, UsedElem, VringUsed, Virtq, and the `mc_array_*` wrappers they embed) are NO LONGER
// hand-written here. They are GENERATED verbatim from std/virtqueue.mc's MC structs by
// `mcc emit-c-struct` into virtq_structs.h (see tools/qemu/kernel-boot-lib.sh), which the build
// drops next to each object and puts on the include path. The MC struct is the ONLY declaration, so
// there is no hand copy to drift — the BSS-corruption / boot-hang class (MC writing past a C `Virtq`
// that lost a field) is structurally impossible. The generated header also carries the A1
// sizeof/offsetof `_Static_assert`s as a belt-and-suspenders cross-check.
#include "virtq_structs.h"

typedef struct CpuBuffer { uintptr_t dev_addr; uintptr_t cpu_addr; uintptr_t len; } CpuBuffer;
typedef struct DeviceBuffer { uintptr_t dev_addr; uintptr_t len; } DeviceBuffer;
typedef struct VirtioMmio VirtioMmio;

// DMA ownership transitions (std/dma): identity on QEMU's coherent memory.
void mc_dma_clean_for_device_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev_addr, uintptr_t len) { (void)len; return dev_addr; }

#endif // MC_PLATFORM_VIRTIO_H
