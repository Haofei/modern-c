// Bare-metal riscv64 M-mode trap wiring for the DEVICE-BACKED async/await NETWORK demo
// (tests/qemu/proc/async_net_demo.mc), in PURE MC. The context-switch primitive, UART
// (putc_/puts_), `mc_halt`, and `_start` (-> test_main) live in the shared M-mode bring-up runtime
// (context_runtime.mc, linked beside this object). Here: the full-frame M-mode trap vector, an
// external-interrupt dispatcher, and `test_main`.
//
// Like async_blk_runtime, the completion source is a virtio DEVICE interrupt routed through the PLIC
// and taken as a MACHINE EXTERNAL interrupt (mcause = 0x8000…000B) — here the virtio-NET TX
// used-ring IRQ. The dispatcher emits the 'i' trace char (proving the completion ran in INTERRUPT
// context, from the device — not a polling loop) and calls into the demo's `net_on_irq`, which
// claims the PLIC source, reaps the TX used ring (async_completing the broker id), and completes at
// the PLIC.

const RT_MCAUSE_M_EXT: u64 = 0x8000_0000_0000_000B; // machine external interrupt (PLIC)

extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;

// MC entry points (tests/qemu/proc/async_net_demo.mc).
#[irq_context]
extern fn net_on_irq() -> void;
extern fn async_net_demo() -> u32;

// Dispatcher invoked by the trap vector once the interrupted frame is saved. A machine external
// interrupt is the virtio-net device IRQ; anything else fails closed (halts). The 'i' trace char
// proves a real device interrupt was taken in interrupt context.
export fn trap_entry() -> void {
    var mcause: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrr %0, mcause"
                out("r") mcause: u64
            }
        }
    }
    if mcause == RT_MCAUSE_M_EXT {
        putc_(105); // 'i' — device IRQ taken in INTERRUPT context
        net_on_irq();
        return;
    }
    mc_halt();
}

// M-mode trap vector. An external interrupt arrives at an arbitrary instruction, so the full integer
// frame plus mepc/mstatus are saved before dispatch and restored after.
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr t0, mepc\n sd t0, 224(sp)\n csrr t0, mstatus\n sd t0, 232(sp)\n call trap_entry\n ld t0, 224(sp)\n csrw mepc, t0\n ld t0, 232(sp)\n csrw mstatus, t0\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n mret"
    }
}

// Install the trap vector. Called from test_main before enabling interrupts.
export fn install_trap_vector() -> void {
    let vec: usize = (&trap_vector) as usize;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw mtvec, %0"
                in("r") vec: usize
            }
        }
    }
}

export fn test_main() -> void {
    puts_("async-net booting\n");
    install_trap_vector();
    let r: u32 = async_net_demo();
    puts_("\nresult=");
    putc_((r & 0xFF) as u8);
    putc_(10); // '\n'
    // A successful TX completion delivers NET_TX_DONE (1).
    if r == 1 {
        puts_("ASYNC-NET-OK\n");
    } else {
        puts_("ASYNC-NET-FAIL\n");
    }
    mc_halt();
}
