// S-mode/OpenSBI interrupt-backed virtio-blk async completion.
//
// This is the S-mode counterpart to tests/qemu/proc/async_blk_demo.mc. It proves
// the block device completion path can run as an S-mode external interrupt:
// submit an async virtio-blk read, park in wfi, claim the PLIC source through
// kernel/drivers/irq/smode_plic.mc, reap the used ring with blk_irq_reap, and
// drain the ready broker id through async_poll_many — the kernel-side shape that
// backs SYS_POLL.

import "std/virtio.mc";
import "std/virtqueue.mc";
import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "kernel/arch/riscv64/sbi_virtio_probe.mc";
import "kernel/drivers/irq/smode_plic.mc";
import "kernel/drivers/virtio/virtio_blk_async.mc";
import "kernel/lib/async.mc";
import "kernel/core/process.mc";

const VIRTIO_ID_BLK: u32 = 2;
const PLIC_BASE: usize = 0x0c00_0000;
const VMMIO_SLOT0_BASE: usize = 0x1000_1000;
const VMMIO_SLOT_STRIDE: usize = 0x1000;
const SIE_SEIE: u64 = 0x200;
const SSTATUS_SIE: u64 = 0x2;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_map: BlkReqMap;
global g_pool: BlkBufPool;
global g_vq: Virtq;
global g_desc: DescTable;
global g_avail: VringAvail;
global g_used: VringUsed;
global g_dev: BlkAsyncDev;
global g_irq_src: u32 = 0;
global g_irq_count: u32 = 0;
global g_reaped: u32 = 0;

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

// The PLIC source line for a virtio-mmio device at `addr` on QEMU virt: slot N -> source N+1.
fn virtio_plic_source(addr: usize) -> u32 {
    let slot: usize = (addr - VMMIO_SLOT0_BASE) / VMMIO_SLOT_STRIDE;
    return (slot + 1) as u32;
}

#[irq_context]
fn blk_smode_external_irq() -> void {
    let plic: SModePlic = smode_plic_for_hart(PLIC_BASE, 0);
    let src: u32 = smode_plic_claim(plic);
    if src == g_irq_src {
        let n: u32 = blk_irq_reap(&g_dev);
        g_reaped = g_reaped + n;
        g_irq_count = g_irq_count + 1;
    }
    smode_plic_complete(plic, src);
}

export fn blk_smode_on_irq(scause: u64) -> void {
    if smode_plic_is_external(scause) {
        blk_smode_external_irq();
        return;
    }
    sbi_puts("BLK-SMODE-IRQ-BAD scause=");
    put_hex(scause);
    sbi_putchar(10);
    sbi_shutdown();
    while true {}
}

#[naked]
#[align(4)]
export fn s_trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr a0, scause\n call blk_smode_on_irq\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n sret"
    }
}

export fn s_entry(hartid: u64, dtb: u64) -> void {
    sbi_puts("blk-smode-irq: interrupt-backed async virtio-blk under OpenSBI\n");
    write_stvec((&s_trap_vector) as usize);

    proc_table_init(&g_procs);
    async_init(&g_broker);

    let regs: MmioPtr<VirtioMmio> = find_virtio_device(VIRTIO_ID_BLK);
    if !virtio_device_present(regs) {
        sbi_puts("NODEV\n");
        sbi_shutdown();
        while true {}
    }

    g_vq.desc = &g_desc;
    g_vq.avail = &g_avail;
    g_vq.used = &g_used;
    g_dev = .{
        .regs = regs,
        .vq = &g_vq,
        .map = &g_map,
        .pool = &g_pool,
        .broker = &g_broker,
        .procs = &g_procs,
    };

    switch blk_async_init(&g_dev) {
        ok(up) => {}
        err(e) => {
            sbi_puts("BLK-INIT-FAIL\n");
            sbi_shutdown();
            while true {}
        }
    }

    g_irq_src = virtio_plic_source(regs as usize);
    smode_plic_enable_line(smode_plic_for_hart(PLIC_BASE, 0), g_irq_src, 1, 0);
    set_sie(SIE_SEIE);
    enable_s_interrupts_global();

    let id: u64 = blk_read_sector_async(&g_dev, 0);
    if id == ASYNC_NO_ID {
        sbi_puts("BLK-SMODE-QUEUE-FULL\n");
        sbi_shutdown();
        while true {}
    }

    var ev: AsyncEvents = uninit;
    var nready: usize = 0;
    var guard: u32 = 0;
    while nready == 0 && guard < 4 {
        disable_s_interrupts_global();
        nready = async_poll_many(&g_broker, &ev, 1);
        if nready == 0 {
            wait_for_interrupt();
            enable_s_interrupts_global();
        } else {
            enable_s_interrupts_global();
        }
        guard = guard + 1;
    }

    var word: i32 = 0;
    var got_id: bool = false;
    if nready > 0 {
        word = ev.ev[0].result;
        got_id = ev.ev[0].id == id;
    }
    let uword: u32 = word as u32;
    sbi_puts("BLK-SMODE-IRQ WORD=");
    sbi_putchar((uword & 0xFF) as u8);
    sbi_putchar(((uword >> 8) & 0xFF) as u8);
    sbi_putchar(((uword >> 16) & 0xFF) as u8);
    sbi_putchar(((uword >> 24) & 0xFF) as u8);
    sbi_putchar(10);
    sbi_puts("BLK-SMODE-IRQ IRQS=");
    put_dec(g_irq_count as u64);
    sbi_puts(" REAPED=");
    put_dec(g_reaped as u64);
    sbi_puts(" POLL=");
    put_dec(nready as u64);
    sbi_putchar(10);

    if word == 0x4B53_4944 && g_irq_count > 0 && g_reaped > 0 && nready == 1 && got_id {
        sbi_puts("BLK-SMODE-IRQ-OK\n");
    } else {
        sbi_puts("BLK-SMODE-IRQ-FAIL\n");
    }
    sbi_shutdown();
    while true {}
}

#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile { "la sp, _stack_top\n call s_entry\n 1: j 1b" }
}
