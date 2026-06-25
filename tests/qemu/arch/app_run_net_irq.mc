// S-mode virtio-net IRQ-backed provider for the production JS `host_net_fetch` surface.
//
// app_run_demo owns SYS_SUBMIT/SYS_POLL and the user-copy rules. This module registers an
// async net override: SYS_SUBMIT allocates a normal app_run_demo completion slot, this module
// submits a virtio-net TX request, the S-mode PLIC interrupt reaps the used ring, and the
// app_run_demo poll hook publishes the completion to SYS_POLL.

import "kernel/drivers/irq/smode_plic.mc";
import "kernel/drivers/virtio/virtio_net_async.mc";
import "kernel/net/arp.mc";

const VIRTIO_ID_NET: u32 = 1;
const PLIC_BASE: usize = 0x0c00_0000;
const VMMIO_SLOT0_BASE: usize = 0x1000_1000;
const VMMIO_SLOT_STRIDE: usize = 0x1000;
const SIE_SEIE: u64 = 0x200;
const SSTATUS_SIE: u64 = 0x2;
const EP_WEB: u32 = 1;
const FRAME_LEN: usize = 64;
const NET_IRQ_E_AGAIN: i32 = -11;
const NET_IRQ_E_DENIED: i32 = -13;

extern fn app_net_override_set_async(init: fn() -> void, submit: fn(u64, u32, u32) -> i32, pump: fn() -> void) -> void;
extern fn app_net_async_complete(id: u64, status: i32, result: i32) -> void;
extern fn smode_external_irq_set(handler: fn() -> void) -> void;

global g_irq_configured: bool;
global g_irq_ready: bool;
global g_regs_base: usize;
global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_tx_map: NetReqMap;
global g_tx_pool: NetBufPool;
global g_rx_map: NetReqMap;
global g_rx_pool: NetBufPool;
global g_rxq: Virtq;
global g_rxdesc: DescTable;
global g_rxavail: VringAvail;
global g_rxused: VringUsed;
global g_txq: Virtq;
global g_txdesc: DescTable;
global g_txavail: VringAvail;
global g_txused: VringUsed;
global g_dev: NetAsyncDev;
global g_irq_src: u32;
global g_irq_count: u32;
global g_reaped: u32;
global g_requests_left: u32;
global g_pending_dev_id: u64;
global g_pending_app_id: u64;
global g_pending: bool;
global g_frame: [FRAME_LEN]u8;
global g_events: AsyncEvents;

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

fn my_mac() -> MacAddr {
    return .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };
}

fn build_arp_frame() -> usize {
    var i: usize = 0;
    while i < FRAME_LEN {
        g_frame[i] = 0;
        i = i + 1;
    }
    let cpu_at: usize = (&g_frame[0]) as usize;
    var dev: DmaAddr = uninit;
    unsafe { dev = cpu_at as DmaAddr; }
    let view: CpuBuffer = .{ .dev_addr = dev, .cpu_addr = pa(cpu_at), .len = FRAME_LEN };
    var mac: MacAddr = my_mac();
    let eth_len: usize = arp_write_request(&view, 12, &mac, 0x0A00_020F, 0x0A00_0202);
    unsafe { forget_unchecked(view); }
    return 12 + eth_len;
}

fn app_net_irq_start() -> void {
    g_irq_ready = false;
    g_pending = false;
    g_pending_dev_id = ASYNC_NO_ID;
    g_pending_app_id = 0;
    g_irq_count = 0;
    g_reaped = 0;
    g_requests_left = 1;
    if !g_irq_configured {
        return;
    }

    proc_table_init(&g_procs);
    async_init(&g_broker);

    var regs: MmioPtr<VirtioMmio> = uninit;
    unsafe { regs = g_regs_base as MmioPtr<VirtioMmio>; }
    g_rxq.desc = &g_rxdesc;
    g_rxq.avail = &g_rxavail;
    g_rxq.used = &g_rxused;
    g_txq.desc = &g_txdesc;
    g_txq.avail = &g_txavail;
    g_txq.used = &g_txused;
    g_dev = .{
        .regs = regs,
        .rxq = &g_rxq,
        .txq = &g_txq,
        .tx_map = &g_tx_map,
        .tx_pool = &g_tx_pool,
        .rx_map = &g_rx_map,
        .rx_pool = &g_rx_pool,
        .broker = &g_broker,
        .procs = &g_procs,
    };
    switch net_async_init(&g_dev) {
        ok(up) => {}
        err(e) => { return; }
    }

    g_irq_src = virtio_plic_source(regs as usize);
    smode_plic_enable_line(smode_plic_for_hart(PLIC_BASE, 0), g_irq_src, 1, 0);
    smode_external_irq_set(app_net_irq_on_irq);
    set_sie(SIE_SEIE);
    enable_s_interrupts_global();
    g_irq_ready = true;
}

fn app_net_irq_submit(app_id: u64, endpoint_id: u32, token: u32) -> i32 {
    if !g_irq_ready {
        return NET_IRQ_E_DENIED;
    }
    if endpoint_id != EP_WEB {
        return NET_IRQ_E_DENIED;
    }
    if g_requests_left == 0 {
        return NET_IRQ_E_AGAIN;
    }
    if g_pending {
        return NET_IRQ_E_AGAIN;
    }

    let frame_len: usize = build_arp_frame();
    let frame_ptr: usize = (&g_frame[0]) as usize;
    let dev_id: u64 = net_send_frame_async(&g_dev, frame_ptr, frame_len);
    if dev_id == ASYNC_NO_ID {
        return NET_IRQ_E_AGAIN;
    }
    g_requests_left = g_requests_left - 1;
    g_pending_dev_id = dev_id;
    g_pending_app_id = app_id;
    g_pending = true;
    return 0;
}

fn app_net_irq_pump() -> void {
    let n: usize = async_poll_many(&g_broker, &g_events, 4);
    var i: usize = 0;
    while i < n {
        if g_pending && g_events.ev[i].id == g_pending_dev_id {
            app_net_async_complete(g_pending_app_id, 0, g_events.ev[i].result);
            g_pending = false;
        }
        i = i + 1;
    }
}

fn app_net_irq_on_irq() -> void {
    let plic: SModePlic = smode_plic_for_hart(PLIC_BASE, 0);
    let src: u32 = smode_plic_claim(plic);
    if src == g_irq_src {
        let n: u32 = net_irq_reap(&g_dev);
        g_reaped = g_reaped + n;
        g_irq_count = g_irq_count + 1;
    }
    smode_plic_complete(plic, src);
}

export fn app_net_irq_config(regs_base: usize) -> void {
    g_regs_base = regs_base;
    g_irq_configured = true;
    app_net_override_set_async(app_net_irq_start, app_net_irq_submit, app_net_irq_pump);
}
