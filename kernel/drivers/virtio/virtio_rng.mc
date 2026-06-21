// Shared virtio-rng entropy driver — in PURE MC (replaces kernel/drivers/virtio/virtio_rng.c).
// The single source of truth for the device-id-4 probe + handshake + single device-writable queue
// + used-ring poll. Linked by the BearSSL/HTTPS riscv runtimes, which declare vrng_find/vrng_init/
// vrng_fill `extern fn` and provide mc_read_ticks. riscv-only (virtio-mmio on QEMU virt).

const VIRTIO_MMIO_BASE: usize = 0x10001000;
const VIRTIO_MMIO_STRIDE: usize = 0x1000;
const VIRTIO_MMIO_COUNT: usize = 8;

const VMR_MAGIC: usize = 0x000;
const VMR_VERSION: usize = 0x004;
const VMR_DEVICE_ID: usize = 0x008;
const VMR_DRIVER_FEATURES: usize = 0x020;
const VMR_DRIVER_FEAT_SEL: usize = 0x024;
const VMR_QUEUE_SEL: usize = 0x030;
const VMR_QUEUE_NUM_MAX: usize = 0x034;
const VMR_QUEUE_NUM: usize = 0x038;
const VMR_QUEUE_READY: usize = 0x044;
const VMR_QUEUE_NOTIFY: usize = 0x050;
const VMR_INTERRUPT_STATUS: usize = 0x060;
const VMR_INTERRUPT_ACK: usize = 0x064;
const VMR_STATUS: usize = 0x070;
const VMR_QUEUE_DESC_LOW: usize = 0x080;
const VMR_QUEUE_DESC_HIGH: usize = 0x084;
const VMR_QUEUE_DRV_LOW: usize = 0x090;
const VMR_QUEUE_DRV_HIGH: usize = 0x094;
const VMR_QUEUE_DEV_LOW: usize = 0x0a0;
const VMR_QUEUE_DEV_HIGH: usize = 0x0a4;

const VIRTIO_MAGIC: u32 = 0x74726976;
const VIRTIO_VERSION_MODERN: u32 = 2;
const VIRTIO_DEVICE_ID_RNG: u32 = 4;

const STATUS_ACKNOWLEDGE: u32 = 1;
const STATUS_DRIVER: u32 = 2;
const STATUS_DRIVER_OK: u32 = 4;
const STATUS_FEATURES_OK: u32 = 8;

const VQ_SIZE: u16 = 8;
const VRING_DESC_F_WRITE: u16 = 2;

// Split-virtqueue ring — same on-wire layout as the C VrngDesc/Avail/Used (std/virtqueue.mc).
packed struct VrngDesc { addr: u64, len: u32, flags: u16, next: u16 }
packed struct VrngAvail { flags: u16, idx: u16, ring: [8]u16, used_event: u16 }
packed struct VrngUsedElem { id: u32, len: u32 }
packed struct VrngUsed { flags: u16, idx: u16, ring: [8]VrngUsedElem, avail_event: u16 }

global g_rng_desc: [8]VrngDesc;
global g_rng_avail: VrngAvail;
global g_rng_used: VrngUsed;
global g_rng_last_used: u16 = 0;
global g_rng_dma: [256]u8; // DMA-visible scratch the device fills

// The clock seam each linking runtime provides (rdtime/CLINT under its mode).
extern fn mc_read_ticks() -> u64;

fn mmio_rd(base: usize, off: usize) -> u32 {
    var v: u32 = 0;
    unsafe { v = raw.load<u32>(phys(base + off)); }
    return v;
}
fn mmio_wr(base: usize, off: usize, val: u32) -> void {
    unsafe { raw.store<u32>(phys(base + off), val); }
}
// Full memory barrier (DMA visibility + compiler reload), the __sync_synchronize analogue.
fn barrier() -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "fence" clobber("memory") } }
    }
}

export fn vrng_find() -> usize {
    var i: usize = 0;
    while i < VIRTIO_MMIO_COUNT {
        let base: usize = VIRTIO_MMIO_BASE + i * VIRTIO_MMIO_STRIDE;
        if mmio_rd(base, VMR_MAGIC) == VIRTIO_MAGIC && mmio_rd(base, VMR_DEVICE_ID) == VIRTIO_DEVICE_ID_RNG {
            return base;
        }
        i = i + 1;
    }
    return 0;
}

export fn vrng_init(regs: usize) -> u32 {
    if mmio_rd(regs, VMR_VERSION) != VIRTIO_VERSION_MODERN { return 0; }

    // Reset, then handshake (§3.1.1).
    mmio_wr(regs, VMR_STATUS, 0);
    var s: i32 = 0;
    while s < 100000 && mmio_rd(regs, VMR_STATUS) != 0 { s = s + 1; }
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE);
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER);

    // virtio-rng needs no feature bits; accept none.
    mmio_wr(regs, VMR_DRIVER_FEAT_SEL, 0);
    mmio_wr(regs, VMR_DRIVER_FEATURES, 0);
    mmio_wr(regs, VMR_DRIVER_FEAT_SEL, 1);
    mmio_wr(regs, VMR_DRIVER_FEATURES, 0);
    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK);
    if (mmio_rd(regs, VMR_STATUS) & STATUS_FEATURES_OK) != STATUS_FEATURES_OK { return 0; }

    // Single requestq (queue 0).
    mmio_wr(regs, VMR_QUEUE_SEL, 0);
    let max: u32 = mmio_rd(regs, VMR_QUEUE_NUM_MAX);
    if max == 0 { return 0; }
    var size: u32 = VQ_SIZE as u32;
    if max < size { size = max; }
    mmio_wr(regs, VMR_QUEUE_NUM, size);

    g_rng_avail.idx = 0;
    g_rng_avail.flags = 0;
    g_rng_used.idx = 0;
    g_rng_used.flags = 0;
    g_rng_last_used = 0;

    let desc_a: u64 = (&g_rng_desc[0]) as usize as u64;
    let avail_a: u64 = (&g_rng_avail) as usize as u64;
    let used_a: u64 = (&g_rng_used) as usize as u64;
    mmio_wr(regs, VMR_QUEUE_DESC_LOW, desc_a as u32);
    mmio_wr(regs, VMR_QUEUE_DESC_HIGH, (desc_a >> 32) as u32);
    mmio_wr(regs, VMR_QUEUE_DRV_LOW, avail_a as u32);
    mmio_wr(regs, VMR_QUEUE_DRV_HIGH, (avail_a >> 32) as u32);
    mmio_wr(regs, VMR_QUEUE_DEV_LOW, used_a as u32);
    mmio_wr(regs, VMR_QUEUE_DEV_HIGH, (used_a >> 32) as u32);
    barrier();
    mmio_wr(regs, VMR_QUEUE_READY, 1);

    mmio_wr(regs, VMR_STATUS, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK);
    return 1;
}

export fn vrng_fill(regs: usize, dst: usize, len_in: u32) -> u32 {
    var len: u32 = len_in;
    if len > 256 { len = 256; }
    var i: u32 = 0;
    while i < len {
        g_rng_dma[i as usize] = 0; // prove the device wrote
        i = i + 1;
    }

    g_rng_desc[0].addr = (&g_rng_dma[0]) as usize as u64;
    g_rng_desc[0].len = len;
    g_rng_desc[0].flags = VRING_DESC_F_WRITE;
    g_rng_desc[0].next = 0;

    let avail_slot: usize = (g_rng_avail.idx % VQ_SIZE) as usize;
    g_rng_avail.ring[avail_slot] = 0; // descriptor index 0
    barrier();
    g_rng_avail.idx = g_rng_avail.idx + 1;
    barrier();

    mmio_wr(regs, VMR_QUEUE_NOTIFY, 0); // kick queue 0

    let start: u64 = mc_read_ticks();
    while (mc_read_ticks() - start) < 50000000 { // ~5s at 10 MHz
        barrier();
        if g_rng_used.idx != g_rng_last_used {
            let slot: usize = (g_rng_last_used % VQ_SIZE) as usize;
            let wrote: u32 = g_rng_used.ring[slot].len;
            g_rng_last_used = g_rng_last_used + 1;
            // Ack any pending interrupt (we poll, but keep the device happy).
            let is: u32 = mmio_rd(regs, VMR_INTERRUPT_STATUS);
            if is != 0 { mmio_wr(regs, VMR_INTERRUPT_ACK, is); }
            var n: u32 = len;
            if wrote < n { n = wrote; }
            var k: u32 = 0;
            while k < n {
                unsafe { raw.store<u8>(phys(dst + (k as usize)), g_rng_dma[k as usize]); }
                k = k + 1;
            }
            return wrote;
        }
    }
    return 0;
}
