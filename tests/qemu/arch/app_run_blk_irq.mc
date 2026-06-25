// S-mode virtio-blk IRQ-backed provider for the production JS `host_fs_read` surface.
//
// app_run_demo owns SYS_SUBMIT/SYS_POLL and all user-copy rules. This module registers an
// async FS override for `/ws/disk`: SYS_SUBMIT allocates a normal app_run_demo completion slot,
// this module submits a virtio-blk sector read, the S-mode PLIC interrupt reaps the used ring,
// and the app_run_demo poll hook publishes the sector word to SYS_POLL as FS_READ bytes.

import "kernel/drivers/irq/smode_plic.mc";
import "kernel/drivers/virtio/virtio_blk_async.mc";

const VIRTIO_ID_BLK: u32 = 2;
const PLIC_BASE: usize = 0x0c00_0000;
const VMMIO_SLOT0_BASE: usize = 0x1000_1000;
const VMMIO_SLOT_STRIDE: usize = 0x1000;
const SIE_SEIE: u64 = 0x200;
const SSTATUS_SIE: u64 = 0x2;
const BLK_IRQ_E_AGAIN: i32 = -11;
const BLK_IRQ_E_DENIED: i32 = -13;

extern fn app_fs_override_set_async(init: fn() -> void, submit: fn(u64, u32) -> i32, pump: fn() -> void) -> void;
extern fn app_fs_async_complete_word(id: u64, status: i32, result: i32, out_len: u32) -> void;
extern fn smode_external_irq_set(handler: fn() -> void) -> void;

global g_blk_irq_configured: bool;
global g_blk_irq_ready: bool;
global g_blk_regs_base: usize;
global g_blk_procs: ProcTable;
global g_blk_broker: AsyncBroker;
global g_blk_map: BlkReqMap;
global g_blk_pool: BlkBufPool;
global g_blk_vq: Virtq;
global g_blk_desc: DescTable;
global g_blk_avail: VringAvail;
global g_blk_used: VringUsed;
global g_blk_dev: BlkAsyncDev;
global g_blk_irq_src: u32;
global g_blk_irq_count: u32;
global g_blk_reaped: u32;
global g_blk_requests_left: u32;
global g_blk_pending_dev_id: u64;
global g_blk_pending_app_id: u64;
global g_blk_pending: bool;
global g_blk_events: AsyncEvents;

fn set_sie(bits: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "csrs sie, %0" in("t0") bits: u64 } }
    }
}

fn enable_s_interrupts_global() -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "csrs sstatus, %0" in("t0") SSTATUS_SIE: u64 } }
    }
}

fn virtio_plic_source(addr: usize) -> u32 {
    let slot: usize = (addr - VMMIO_SLOT0_BASE) / VMMIO_SLOT_STRIDE;
    return (slot + 1) as u32;
}

fn app_blk_irq_start() -> void {
    g_blk_irq_ready = false;
    g_blk_pending = false;
    g_blk_pending_dev_id = ASYNC_NO_ID;
    g_blk_pending_app_id = 0;
    g_blk_irq_count = 0;
    g_blk_reaped = 0;
    g_blk_requests_left = 1;
    if !g_blk_irq_configured {
        return;
    }

    proc_table_init(&g_blk_procs);
    async_init(&g_blk_broker);

    var regs: MmioPtr<VirtioMmio> = uninit;
    unsafe { regs = g_blk_regs_base as MmioPtr<VirtioMmio>; }
    g_blk_vq.desc = &g_blk_desc;
    g_blk_vq.avail = &g_blk_avail;
    g_blk_vq.used = &g_blk_used;
    g_blk_dev = .{
        .regs = regs,
        .vq = &g_blk_vq,
        .map = &g_blk_map,
        .pool = &g_blk_pool,
        .broker = &g_blk_broker,
        .procs = &g_blk_procs,
    };
    switch blk_async_init(&g_blk_dev) {
        ok(up) => {}
        err(e) => { return; }
    }

    g_blk_irq_src = virtio_plic_source(regs as usize);
    smode_plic_enable_line(smode_plic_for_hart(PLIC_BASE, 0), g_blk_irq_src, 1, 0);
    smode_external_irq_set(app_blk_irq_on_irq);
    set_sie(SIE_SEIE);
    enable_s_interrupts_global();
    g_blk_irq_ready = true;
}

fn app_blk_irq_submit(app_id: u64, out_cap: u32) -> i32 {
    if !g_blk_irq_ready {
        return BLK_IRQ_E_DENIED;
    }
    if out_cap == 0 {
        return BLK_IRQ_E_DENIED;
    }
    if g_blk_requests_left == 0 {
        return BLK_IRQ_E_AGAIN;
    }
    if g_blk_pending {
        return BLK_IRQ_E_AGAIN;
    }

    let dev_id: u64 = blk_read_sector_async(&g_blk_dev, 0);
    if dev_id == ASYNC_NO_ID {
        return BLK_IRQ_E_AGAIN;
    }
    g_blk_requests_left = g_blk_requests_left - 1;
    g_blk_pending_dev_id = dev_id;
    g_blk_pending_app_id = app_id;
    g_blk_pending = true;
    return 0;
}

fn app_blk_irq_pump() -> void {
    let n: usize = async_poll_many(&g_blk_broker, &g_blk_events, 4);
    var i: usize = 0;
    while i < n {
        if g_blk_pending && g_blk_events.ev[i].id == g_blk_pending_dev_id {
            app_fs_async_complete_word(g_blk_pending_app_id, 0, g_blk_events.ev[i].result, 4);
            g_blk_pending = false;
        }
        i = i + 1;
    }
}

fn app_blk_irq_on_irq() -> void {
    let plic: SModePlic = smode_plic_for_hart(PLIC_BASE, 0);
    let src: u32 = smode_plic_claim(plic);
    if src == g_blk_irq_src {
        let n: u32 = blk_irq_reap(&g_blk_dev);
        g_blk_reaped = g_blk_reaped + n;
        g_blk_irq_count = g_blk_irq_count + 1;
    }
    smode_plic_complete(plic, src);
}

export fn app_blk_irq_config(regs_base: usize) -> void {
    g_blk_regs_base = regs_base;
    g_blk_irq_configured = true;
    app_fs_override_set_async(app_blk_irq_start, app_blk_irq_submit, app_blk_irq_pump);
}
