// S-mode/OpenSBI interrupt-backed virtio-net async RX completion.
//
// Posts a one-shot async RX buffer, sends an ARP request to QEMU slirp, takes the
// virtio-net S-mode PLIC interrupt, reaps the RX used ring with net_irq_reap,
// copies the received Ethernet frame into g_rx_frame, and drains the ready broker
// id through async_poll_many — the kernel-side shape that backs SYS_POLL.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "std/alloc/dma.mc";
import "std/addr.mc";
import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "kernel/drivers/irq/smode_plic.mc";
import "kernel/drivers/virtio/virtio_net_async.mc";
import "kernel/net/arp.mc";
import "kernel/lib/async.mc";
import "kernel/core/process.mc";

const VIRTIO_ID_NET: u32 = 1;
const PLIC_BASE: usize = 0x0c00_0000;
const VMMIO_SLOT0_BASE: usize = 0x1000_1000;
const VMMIO_SLOT_STRIDE: usize = 0x1000;
const SIE_SEIE: u64 = 0x200;
const SSTATUS_SIE: u64 = 0x2;
const SRC_IP: u32 = 0x0A00_020F;    // 10.0.2.15, QEMU slirp default guest IP
const TARGET_IP: u32 = 0x0A00_0202; // 10.0.2.2, QEMU slirp gateway

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
global g_irq_src: u32 = 0;
global g_irq_count: u32 = 0;
global g_reaped: u32 = 0;
global g_tx_frame: [64]u8;
global g_rx_frame: [2048]u8;

fn write_stvec(addr: usize) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "csrw stvec, %0" in("t0") addr: usize } }
    }
}

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

fn disable_s_interrupts_global() -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "csrc sstatus, %0" in("t0") SSTATUS_SIE: u64 } }
    }
}

fn wait_for_interrupt() -> void {
    unsafe { asm opaque volatile { "wfi" clobber("memory") } }
}

fn virtio_plic_source(addr: usize) -> u32 {
    let slot: usize = (addr - VMMIO_SLOT0_BASE) / VMMIO_SLOT_STRIDE;
    return (slot + 1) as u32;
}

#[irq_context]
fn net_smode_rx_external_irq() -> void {
    let plic: SModePlic = smode_plic_for_hart(PLIC_BASE, 0);
    let src: u32 = smode_plic_claim(plic);
    if src == g_irq_src {
        let n: u32 = net_irq_reap(&g_dev);
        g_reaped = g_reaped + n;
        g_irq_count = g_irq_count + 1;
    }
    smode_plic_complete(plic, src);
}

export fn net_smode_rx_on_irq(scause: u64) -> void {
    if smode_plic_is_external(scause) {
        net_smode_rx_external_irq();
        return;
    }
    sbi_puts("NET-SMODE-RXIRQ-BAD scause=");
    put_hex(scause);
    sbi_putchar(10);
    sbi_shutdown();
    while true {}
}

#[naked]
#[align(4)]
export fn s_trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr a0, scause\n call net_smode_rx_on_irq\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n sret"
    }
}

fn my_mac() -> MacAddr {
    return .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };
}

fn build_arp_frame() -> usize {
    var i: usize = 0;
    while i < 64 {
        g_tx_frame[i] = 0;
        i = i + 1;
    }
    let cpu_at: usize = (&g_tx_frame[0]) as usize;
    var dev: DmaAddr = uninit;
    unsafe { dev = (cpu_at as DmaAddr); }
    let view: CpuBuffer = .{ .dev_addr = dev, .cpu_addr = pa(cpu_at), .len = 64 };
    var mac: MacAddr = my_mac();
    let frame_len: usize = arp_write_request(&view, 12, &mac, SRC_IP, TARGET_IP);
    unsafe { forget_unchecked(view); }
    return 12 + frame_len;
}

fn rx_looks_like_arp_reply(n: usize) -> bool {
    if n < 42 {
        return false;
    }
    if g_rx_frame[12] != 0x08 {
        return false;
    }
    if g_rx_frame[13] != 0x06 {
        return false;
    }
    if g_rx_frame[20] != 0x00 {
        return false;
    }
    if g_rx_frame[21] != 0x02 {
        return false;
    }
    return true;
}

export fn s_entry(hartid: u64, dtb: u64) -> void {
    sbi_puts("net-smode-rxirq: interrupt-backed async virtio-net RX under OpenSBI\n");
    write_stvec((&s_trap_vector) as usize);

    proc_table_init(&g_procs);
    async_init(&g_broker);

    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_NET);
    if !virtio_device_present(regs) {
        sbi_puts("NODEV\n");
        sbi_shutdown();
        while true {}
    }

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
        err(e) => {
            sbi_puts("NET-INIT-FAIL\n");
            sbi_shutdown();
            while true {}
        }
    }

    g_irq_src = virtio_plic_source(regs as usize);
    smode_plic_enable_line(smode_plic_for_hart(PLIC_BASE, 0), g_irq_src, 1, 0);
    set_sie(SIE_SEIE);
    enable_s_interrupts_global();

    let rx_ptr: usize = (&g_rx_frame[0]) as usize;
    let rx_id: u64 = net_recv_frame_async(&g_dev, rx_ptr, 2048);
    if rx_id == ASYNC_NO_ID {
        sbi_puts("NET-SMODE-RX-QUEUE-FULL\n");
        sbi_shutdown();
        while true {}
    }

    let frame_len: usize = build_arp_frame();
    let frame_ptr: usize = (&g_tx_frame[0]) as usize;
    let tx_id: u64 = net_send_frame_async(&g_dev, frame_ptr, frame_len);
    if tx_id == ASYNC_NO_ID {
        sbi_puts("NET-SMODE-TX-QUEUE-FULL\n");
        sbi_shutdown();
        while true {}
    }

    var ev: AsyncEvents = uninit;
    var tx_done: i32 = 0;
    var rx_len: usize = 0;
    var got_tx: bool = false;
    var got_rx: bool = false;
    var total_ready: usize = 0;
    var guard: u32 = 0;
    while (!got_rx || !got_tx) && guard < 8 {
        disable_s_interrupts_global();
        let nready: usize = async_poll_many(&g_broker, &ev, 2);
        if nready == 0 {
            wait_for_interrupt();
            enable_s_interrupts_global();
        } else {
            enable_s_interrupts_global();
            total_ready = total_ready + nready;
            var i: usize = 0;
            while i < nready {
                if ev.ev[i].id == tx_id {
                    tx_done = ev.ev[i].result;
                    got_tx = true;
                }
                if ev.ev[i].id == rx_id {
                    rx_len = ev.ev[i].result as usize;
                    got_rx = true;
                }
                i = i + 1;
            }
        }
        guard = guard + 1;
    }

    let arp_ok: bool = rx_looks_like_arp_reply(rx_len);
    sbi_puts("NET-SMODE-RXIRQ TX=");
    put_dec(tx_done as u64);
    sbi_puts(" RX=");
    put_dec(rx_len as u64);
    sbi_puts(" IRQS=");
    put_dec(g_irq_count as u64);
    sbi_puts(" REAPED=");
    put_dec(g_reaped as u64);
    sbi_puts(" POLL=");
    put_dec(total_ready as u64);
    sbi_putchar(10);

    if got_tx && tx_done == NET_TX_DONE && got_rx && rx_len >= 42 && arp_ok && g_irq_count > 0 && g_reaped > 0 {
        sbi_puts("NET-SMODE-RXIRQ-OK\n");
    } else {
        sbi_puts("NET-SMODE-RXIRQ-FAIL\n");
    }
    sbi_shutdown();
    while true {}
}

#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile { "la sp, _stack_top\n call s_entry\n 1: j 1b" }
}
