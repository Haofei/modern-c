// Shared virtio-rng (virtio device-id 4) entropy driver — the SINGLE freestanding
// C implementation of the device-id-4 probe + handshake + one-shot random read,
// used to be copy-pasted into bearssl_smoke_runtime.c and https_get_runtime.c.
//
// Layout/semantics are byte-for-byte the same as the two former inline copies:
//   * scan the 8 virtio-mmio slots at 0x1000_1000 (stride 0x1000) for device-id 4,
//   * virtio 1.x reset + ACK/DRIVER/FEATURES_OK handshake (no features wanted),
//   * one device-writable split-virtqueue (size <= 8) on queue 0,
//   * post a buffer, kick queue 0, poll the used ring (~5s @ 10 MHz) for completion.
//
// The driver owns its vring + DMA scratch (BSS, identity-mapped). It depends on the
// host runtime only for `mc_read_ticks()` (CLINT mtime), which both runtimes export.
#ifndef MC_VIRTIO_RNG_H
#define MC_VIRTIO_RNG_H

#include <stdint.h>
#include <stddef.h>

// Monotonic ticks (QEMU virt CLINT mtime, 10 MHz). Provided by the host runtime.
uint64_t mc_read_ticks(void);

// Scan the virtio-mmio slots for an entropy device (device-id 4).
// Returns the device's register base, or 0 if no rng device is present.
volatile uint8_t *vrng_find(void);

// virtio 1.x init handshake + single device-writable queue setup on `regs`.
// Returns 1 on success, 0 on any failure (wrong version, FEATURES_OK rejected,
// no queue). `regs` must come from vrng_find().
int vrng_init(volatile uint8_t *regs);

// Post a device-writable buffer of `len` bytes (clamped to the internal scratch),
// kick the queue, and spin (real-time bounded) until the device returns a used
// entry. On success copies the device-written bytes into `dst` and returns the
// number of bytes the device wrote; returns 0 on timeout. `dst` may hold fewer
// than `len` bytes only if the device wrote fewer.
uint32_t vrng_fill(volatile uint8_t *regs, uint8_t *dst, uint32_t len);

#endif // MC_VIRTIO_RNG_H
