// STEADY-STATE (re-armed) S-mode external interrupt delivery through the PLIC under
// REAL OpenSBI — the multi-shot companion to smode_plic_demo. Where smode_plic_demo is
// single-shot (one claimed+completed external IRQ), this RE-ARMS the UART THRE source in
// the handler and takes TARGET (=3) DISCRETE external interrupts, exercising the
// repeated trap→service→sret→re-trap path that interrupt-driven device drivers need.
//
// This path was the long-standing "C-backend S-mode async-IRQ reset": the C backend
// reset-looped here while LLVM was clean. Root cause (NOT a reset): the `#[naked]`
// trap vector was placed on a 2-byte boundary, and a RISC-V `stvec` base MUST be 4-byte
// aligned — the low two bits of stvec are the MODE field, so a 2-byte-aligned vector
// silently selects a reserved MODE and traps to the wrong PC. The fix is the
// `#[align(4)]` on the vector below (and `#[naked]` now defaults to 4-byte alignment),
// which makes the steady-state path pass parity-clean on BOTH backends.
//
// PASS requires the OpenSBI banner + `SMODE-PLIC-OK` + `IRQS` == 3.
//
// Pure S-mode (NO U-mode): every trap is taken with sstatus.SPP=1, so the vector saves a
// full integer frame on the kernel stack and does not swap sscratch.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";

const TARGET: u64 = 3;

// ----- 16550 UART (QEMU virt @ 0x1000_0000, PLIC source line 10) -----
const UART_IER: usize = 0x1000_0001;
const UART_IIR: usize = 0x1000_0002;
const UART_IER_ETBEI: u8 = 0x02;
const UART_IRQ: u32 = 10;

// ----- PLIC, hart 0 S-mode context (context 1) on QEMU virt -----
const PLIC_PRIORITY: usize = 0x0c00_0000;
const PLIC_S_ENABLE: usize = 0x0c00_2080;
const PLIC_S_THRESHOLD: usize = 0x0c20_1000;
const PLIC_S_CLAIM: usize = 0x0c20_1004;

const SCAUSE_S_EXT: u64 = 0x8000_0000_0000_0009;
const SIE_SEIE: u64 = 0x200;
const SSTATUS_SIE: u64 = 0x2;

global g_irqs: u64 = 0;

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
fn set_sstatus(bits: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe { asm precise volatile { "csrs sstatus, %0" in("t0") bits: u64 } }
    }
}
fn wait_for_interrupt() -> void {
    unsafe { asm opaque volatile { "wfi" clobber("memory") } }
}
fn io_fence() -> void {
    unsafe { asm opaque volatile { "fence iorw, iorw" clobber("memory") } }
}

fn uart_arm_thre() -> void {
    unsafe { raw.store<u8>(phys(UART_IER), UART_IER_ETBEI); }
}
fn uart_mask() -> void {
    unsafe {
        raw.store<u8>(phys(UART_IER), 0);
        let _iir: u8 = raw.load<u8>(phys(UART_IIR));
    }
}

fn plic_s_setup() -> void {
    unsafe {
        raw.store<u32>(phys(PLIC_PRIORITY + (UART_IRQ as usize) * 4), 1);
        raw.store<u32>(phys(PLIC_S_THRESHOLD), 0);
        let cur: u32 = raw.load<u32>(phys(PLIC_S_ENABLE));
        raw.store<u32>(phys(PLIC_S_ENABLE), cur | ((1 as u32) << UART_IRQ));
    }
}
fn plic_s_claim() -> u32 {
    unsafe { return raw.load<u32>(phys(PLIC_S_CLAIM)); }
}
fn plic_s_complete(line: u32) -> void {
    unsafe { raw.store<u32>(phys(PLIC_S_CLAIM), line); }
}

// S-external handler: claim, mask the source (de-assert), fence, complete, count, and —
// unless we have taken enough — RE-ARM the source for the next discrete interrupt.
export fn s_ext_trap(scause: u64) -> void {
    if scause == SCAUSE_S_EXT {
        let src: u32 = plic_s_claim();
        uart_mask();
        io_fence();
        plic_s_complete(src);
        if src == UART_IRQ {
            g_irqs = g_irqs + 1;
            if g_irqs < TARGET {
                uart_arm_thre();   // re-assert for the next discrete external interrupt
            }
        }
        return;
    }
    sbi_puts("SMODE-PLIC-BAD scause=");
    put_hex(scause);
    sbi_putchar(10);
    sbi_shutdown();
    while true {}
}

// Naked S-mode trap vector. `#[align(4)]` is REQUIRED: its address is written to `stvec`,
// whose low two bits are the MODE field, so the base must be 4-byte aligned. (`#[naked]`
// already defaults to 4-byte alignment; this is explicit for the load-bearing case.)
#[naked]
#[align(4)]
export fn s_trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr a0, scause\n call s_ext_trap\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n sret"
    }
}

export fn s_entry(hartid: u64, dtb: u64) -> void {
    sbi_puts("smode-plic-multishot: re-armed S-mode external IRQ via PLIC under OpenSBI\n");
    write_stvec((&s_trap_vector) as usize);
    plic_s_setup();
    set_sie(SIE_SEIE);
    set_sstatus(SSTATUS_SIE);
    uart_arm_thre();
    while g_irqs < TARGET {
        wait_for_interrupt();
    }
    sbi_puts("SMODE-PLIC IRQS=");
    put_dec(g_irqs);
    sbi_putchar(10);
    sbi_puts("SMODE-PLIC-OK\n");
    sbi_shutdown();
    while true {}
}

#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile { "la sp, _stack_top\n call s_entry\n 1: j 1b" }
}
