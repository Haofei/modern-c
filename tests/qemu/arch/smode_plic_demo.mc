// REAL S-mode EXTERNAL interrupt delivery through the PLIC under OpenSBI — in PURE
// MC (no C). The companion to smode_timer_demo: that proves the S-mode *timer*
// interrupt (CLINT/SBI-TIME, delivered straight to the hart); this proves an
// S-mode *external device* interrupt routed through the PLIC — the path that lets
// virtio/net be interrupt-driven instead of polled.
//
// A flat S-mode kernel (booted by REAL OpenSBI at 0x80200000, satp=0 Bare) drives
// the 16550 UART's "transmit-holding-register-empty" (THRE) interrupt as a
// deterministic source — exactly how Linux S-mode drives the same ns16550 at
// 0x1000_0000 with PLIC line 10. It programs the PLIC **S-mode context** (context 1
// = hart 0 S-mode: enable @ +0x2080, threshold/claim @ +0x201000), opens sie.SEIE +
// sstatus.SIE, and enables the UART THRE interrupt. THR is empty at idle, so the
// line asserts immediately, the PLIC raises an S-mode external interrupt (scause=9),
// and the trap handler claims line 10, masks the source at the device, and completes
// at the PLIC. It parks in `wfi`, so a no-delivery bug HANGS into the QEMU timeout
// rather than busy-polling; once the real external interrupt has been
// claimed+completed it reports `SMODE-PLIC IRQS=<n>` + `SMODE-PLIC-OK` and shuts down.
//
// Single-shot by design (TARGET=1). One delivered+claimed+completed external
// interrupt is the integration proof: PLIC S-context routing, sie.SEIE / SEIP, the
// claim returning the right source id, and complete. Cycling the *same* level
// source many times is a QEMU PLIC-gateway corner case (re-arm vs complete edge
// detection) that adds nothing to the proof, so the handler is single-shot: it masks
// the source (ETBEI=0) and never re-arms.
//
// Pure S-mode (NO U-mode): every trap is taken with sstatus.SPP=1, so the trap
// vector does NOT swap sscratch — it saves a full integer frame on the kernel stack.

import "kernel/arch/riscv64/sbi.mc";
import "kernel/arch/riscv64/sbi_console.mc";
import "kernel/drivers/irq/smode_plic.mc";

const TARGET: u64 = 1;

// ----- 16550 UART (QEMU virt @ 0x1000_0000, PLIC source line 10) -----
const UART_IER: usize = 0x1000_0001;   // interrupt-enable register (THR+1)
const UART_IIR: usize = 0x1000_0002;   // interrupt-identification register (read)
const UART_IER_ETBEI: u8 = 0x02;       // bit 1: enable THR-empty interrupt
const UART_IRQ: u32 = 10;              // QEMU virt UART0 PLIC source

// ----- PLIC, hart 0 S-mode context (context 1) on QEMU virt -----
const PLIC_BASE: usize = 0x0c00_0000;

// sie.SEIE = bit 9 (S-mode external interrupt enable); sstatus.SIE = bit 1.
const SIE_SEIE: u64 = 0x200;
const SSTATUS_SIE: u64 = 0x2;

// Count of external interrupts claimed+completed; written from the ISR.
global g_irqs: u64 = 0;

// ---- CSR / hart primitives (MC inline asm) ----

fn write_stvec(addr: usize) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw stvec, %0"
                in("t0") addr: usize
            }
        }
    }
}

fn set_sie(bits: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrs sie, %0"
                in("t0") bits: u64
            }
        }
    }
}

fn set_sstatus(bits: u64) -> void {
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrs sstatus, %0"
                in("t0") bits: u64
            }
        }
    }
}

fn wait_for_interrupt() -> void {
    unsafe {
        asm opaque volatile {
            "wfi"
            clobber("memory")
        }
    }
}

// Full I/O + memory fence: order a device-register store (e.g. masking the source)
// before a later store to a different device (the PLIC complete), so QEMU's device
// models observe them in program order regardless of how either backend schedules
// the two MMIO stores.
fn io_fence() -> void {
    unsafe {
        asm opaque volatile {
            "fence iorw, iorw"
            clobber("memory")
        }
    }
}

// ---- UART THRE source control ----
//
// QEMU's 16550 raises the THR-empty interrupt while ETBEI is set and THR is empty
// (the idle state), so enabling ETBEI asserts the UART's PLIC line. The handler
// de-asserts the source by clearing ETBEI (`uart_mask`); the IIR read clears the
// pending-interrupt latch.

// Enable (arm) the THR-empty interrupt: ETBEI=1 over an empty THR asserts the line.
fn uart_arm_thre() -> void {
    unsafe { raw.store<u8>(phys(UART_IER), UART_IER_ETBEI); }
}

// Mask the source: clear ETBEI so the UART's PLIC line de-asserts, and read IIR to
// clear the pending-interrupt latch. The handler issues an `io_fence` after this so
// the de-assert is ordered before the PLIC `complete`.
fn uart_mask() -> void {
    unsafe {
        raw.store<u8>(phys(UART_IER), 0);
        let _iir: u8 = raw.load<u8>(phys(UART_IIR));
    }
}

// S-mode trap handler. On an S-external interrupt: claim the PLIC source, mask it at
// the device (ETBEI=0) so it cannot re-fire, `io_fence` to order the de-assert
// before the PLIC complete, complete, and count. Single-shot: it never re-arms (see
// the file header). On ANY other cause (a real fault) fail closed: report and shut
// down rather than spin.
export fn s_ext_trap(scause: u64) -> void {
    if smode_plic_is_external(scause) {
        let plic: SModePlic = smode_plic_for_hart(PLIC_BASE, 0);
        let src: u32 = smode_plic_claim(plic);
        uart_mask();            // de-assert the source (ETBEI=0) so it cannot re-fire...
        io_fence();             // ...ordered before the PLIC complete below
        smode_plic_complete(plic, src); // complete whatever we claimed
        if src == UART_IRQ {
            g_irqs = g_irqs + 1;
        }
        return;
    }
    sbi_puts("SMODE-PLIC-BAD scause=");
    put_hex(scause);
    sbi_putchar(10);
    sbi_shutdown();
    while true {}
}

// Naked S-mode trap vector — pure S-mode (SPP=1 always), so no sscratch swap: save
// a full integer frame on the kernel stack, pass scause to `s_ext_trap`, restore,
// `sret`.
#[naked]
export fn s_trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr a0, scause\n call s_ext_trap\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n sret"
    }
}

export fn s_entry(_hartid: u64, _dtb: u64) -> void {
    sbi_puts("smode-plic: S-mode external IRQ via PLIC under OpenSBI\n");

    write_stvec((&s_trap_vector) as usize);

    // Program the PLIC S-mode context to route UART line 10 to this hart.
    smode_plic_enable_line(smode_plic_for_hart(PLIC_BASE, 0), UART_IRQ, 1, 0);

    // Enable S-external interrupts (sie.SEIE), then global S-interrupts (sstatus.SIE).
    set_sie(SIE_SEIE);
    set_sstatus(SSTATUS_SIE);

    // Arm the source: ETBEI=1 over an empty THR asserts the UART's PLIC line, so the
    // PLIC raises an S-external interrupt the handler claims+completes. Park in `wfi`;
    // a no-delivery bug hangs here into the QEMU timeout rather than busy-polling
    // (which would mask a missing interrupt).
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

// OpenSBI enters in S-mode at 0x80200000 with a0=hartid, a1=dtb. Set the stack but
// do NOT clobber a0/a1 before the call. `#[section(".text.boot")]` pins `_start` to
// 0x80200000 (sbi.ld: `KEEP(*(.text.boot))` first), where OpenSBI jumps.
#[naked]
#[section(".text.boot")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call s_entry\n 1: j 1b"
    }
}
