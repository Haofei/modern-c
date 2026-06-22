// kernel/drivers/rng — the system entropy driver. A single virtio-rng (virtio
// device-id 4) driver plus a clean `rng_fill(buf, len)` API, built on the shared
// transport (std/virtio: scan / handshake), the split virtqueue (std/virtqueue:
// submit / kick / wait / complete) and DMA ownership (std/dma) — the same layering
// virtio_net / virtio_blk use. This is where in-kernel callers (TLS today; tokens /
// nonces later) get real device entropy, instead of every caller re-walking the mmio
// window and hand-rolling the queue cycle.
//
// This lives under kernel/drivers (not std) because it is a board-touching device
// driver, not a freestanding language primitive: the virtio-mmio discovery window is a
// board fact, pulled from kernel/platform/active/ rather than hardcoded here, so std/
// never has to import a platform backend (which would invert the layering).
//
// The C runtimes (bearssl_smoke_runtime.c, https_get_runtime.c) share the *same*
// probe via kernel/drivers/virtio/virtio_rng.c; this module is the MC-world twin
// of that driver, so the two languages keep one device contract, not two.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "std/dma.mc";
import "std/time.mc";
import "kernel/platform/active/virtio_mmio_hw.mc";

const VIRTIO_RNG_DEVICE_ID: u32 = 4;
const RNG_TIMEOUT_TICKS: u64 = 50_000_000; // ~5s at the CLINT's 10 MHz (real-time bound)
const RNG_CHUNK: usize = 256;              // bytes requested from the device per round
// The virtio-mmio discovery window (base / stride / count) is a board fact, read from the
// platform backend via plat_virtio_mmio_*(). (VIRTIO_MAGIC comes from std/virtio.mc.)


// Why an entropy read failed — a typed error, like the rest of the virtio drivers.
enum RngError {
    NoDevice,        // no virtio-rng (device-id 4) in the mmio window
    DeviceInitFailed,// virtio handshake / feature negotiation failed
    QueueUnavailable,// the request queue could not be set up
    Timeout,         // the device did not return bytes in time
    DeviceFault,     // the device returned an inconsistent completion
    ShortRead,       // the device returned zero bytes for a request
}

// The device-class surface: the register block plus the single request queue.
struct RngDevice {
    regs: MmioPtr<VirtioMmio>,
    vq: *mut Virtq,
}

// Find the entropy device and bring it up: scan for device-id 4, run the virtio 1.x
// handshake (virtio-rng requires no feature bits), set up the request queue, go live.
// `vq` is caller-owned storage for the one queue (as with blk/net).
export fn rng_open(vq: *mut Virtq) -> Result<RngDevice, RngError> {
    // Scan the mmio window for the entropy device (device-id 4). The MC twin of the
    // inline C slot scan; kept local so the net/blk drivers don't inherit it. The matching
    // slot is brought up and returned from inside the loop, so there is no carry-out `regs`
    // variable to leave conditionally-uninitialized — a fall-through past the loop means no
    // device was found. The window geometry comes from the platform backend.
    let mmio_base: usize = plat_virtio_mmio_base();
    let mmio_stride: usize = plat_virtio_mmio_stride();
    let mmio_count: u32 = plat_virtio_mmio_count();
    var i: u32 = 0;
    while i < mmio_count {
        let addr: usize = mmio_base + (i as usize) * mmio_stride;
        var slot: MmioPtr<VirtioMmio> = uninit;
        unsafe { slot = mmio.map<VirtioMmio>(phys(addr))?; }
        if slot.magic.read(.acquire) == VIRTIO_MAGIC && slot.device_id.read(.acquire) == VIRTIO_RNG_DEVICE_ID {
            // Found the entropy device: run the virtio 1.x handshake (virtio-rng requires
            // no feature bits), set up the request queue, and go live.
            switch virtio_init(slot, VIRTIO_RNG_DEVICE_ID, 0, 0) {
                ok(up) => {}
                err(e) => { return err(.DeviceInitFailed); }
            }
            switch vq_setup(slot, 0, vq) {
                ok(up) => {}
                err(e) => { return err(.QueueUnavailable); }
            }
            virtio_driver_ok(slot);
            return ok(.{ .regs = slot, .vq = vq });
        }
        i = i + 1;
    }
    return err(.NoDevice);
}

// Pull one round of entropy from the device into `dst` (up to `max` bytes). Posts a
// device-writable DMA buffer, kicks the queue, waits (bounded) for the completion,
// then copies the bytes the device actually wrote into `dst`. Returns the number of
// bytes written, or a typed error. This is the single DMA-cycle for entropy:
// alloc -> clean_for_device -> submit_rx -> kick -> wait_used -> complete -> copy.
export fn rng_read(dev: *RngDevice, dst: usize, max: usize) -> Result<usize, RngError> {
    let regs: MmioPtr<VirtioMmio> = dev.regs;
    let vq: *mut Virtq = dev.vq;

    var want: usize = RNG_CHUNK;
    if max < want { want = max; }

    let cpu: CpuBuffer = alloc(want);            // zeroed by the allocator
    let d: DeviceBuffer = clean_for_device(cpu); // cpu consumed
    switch vq_submit_rx(vq, d) {                 // d consumed (in flight, or reclaimed)
        ok(id) => {}
        err(e) => { return err(.QueueUnavailable); }
    }
    vq_kick(regs, 0);

    if !vq_wait_used(vq, RNG_TIMEOUT_TICKS) {
        return err(.Timeout);
    }
    switch vq_complete(vq) {
        ok(cb) => {
            let wrote: usize = cb.used_len as usize; // bytes the device actually wrote
            let dbuf: DeviceBuffer = cb.buf;
            unsafe { forget_unchecked(cb); }
            var cpu_back: CpuBuffer = invalidate_for_cpu(dbuf);
            var n: usize = wrote;
            if n > max { n = max; }
            var i: usize = 0;
            while i < n {
                let b: u8 = read_u8(&cpu_back, i);
                unsafe { raw.store<u8>(phys(dst + i), b); }
                i = i + 1;
            }
            free(cpu_back);
            if wrote == 0 {
                return err(.ShortRead);
            }
            return ok(n);
        }
        err(e) => {
            // Inconsistent completion: reset so the device relinquishes the buffer,
            // then reclaim it rather than leak. The device is poisoned afterward.
            if virtio_reset(regs) {
                let reclaimed: usize = vq_reset_reclaim(vq);
            }
            return err(.DeviceFault);
        }
    }
}

// The clean entropy API: fill exactly `len` bytes at `dst` with device randomness,
// reading as many rounds as needed. Returns true on success; on any device error
// returns false (callers must treat a false return as "no entropy", never proceed
// with a partial/guessed buffer). This is the seam a CSPRNG seeds from.
export fn rng_fill(dev: *RngDevice, dst: usize, len: usize) -> bool {
    var got: usize = 0;
    while got < len {
        switch rng_read(dev, dst + got, len - got) {
            ok(n) => {
                if n == 0 {
                    return false; // no progress: fail closed rather than spin
                }
                got = got + n;
            }
            err(e) => { return false; }
        }
    }
    return true;
}
