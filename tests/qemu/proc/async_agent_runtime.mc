// Bare-metal riscv64 M-mode timer/trap wiring for the broker-backed async/await demo
// (tests/qemu/proc/async_agent_demo.mc), in PURE MC. The context-switch primitive, UART
// (putc_/puts_), `mc_halt`, and `_start` (-> test_main) live in the shared M-mode bring-up runtime
// (context_runtime.c, linked beside this object). Here: the CLINT one-shot timer, the full-frame
// M-mode trap vector, and `test_main`.
//
// Unlike the single-completion async-irq demo, here the timer is RE-ARMED by the ISR
// (`agent_on_timer`) after each completion, so a sequence of `await`s each get their own
// completion interrupt — the task sleeps in `wfi` between them.

const RT_CLINT_MTIME: usize = 0x0200_BFF8;    // CLINT mtime MMIO
const RT_CLINT_MTIMECMP: usize = 0x0200_4000; // CLINT mtimecmp[0] MMIO
const RT_TIMER_DELAY: u64 = 500000;           // ~50ms at the 10MHz virt timebase
const RT_MCAUSE_M_TIMER: u64 = 0x8000_0000_0000_0007;
const RT_MIE_MTIE: usize = 0x80;    // machine timer interrupt enable (mie.MTIE)
const RT_MSTATUS_MIE: usize = 0x8;  // machine global interrupt enable (mstatus.MIE)

extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;

// MC entry points (tests/qemu/proc/async_agent_demo.mc).
extern fn agent_on_timer() -> void;
extern fn async_agent_demo(region_base: usize, region_len: usize) -> u32;

fn disarm_timer() -> void {
    let mtie: usize = RT_MIE_MTIE;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrc mie, %0"
                in("r") mtie: usize
            }
        }
    }
}

// Dispatcher invoked by the trap vector once the interrupted frame is saved. The machine timer is
// single-shot per arm (disarm here; the ISR re-arms if another request is in flight). Anything
// else fails closed (halts).
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
    if mcause == RT_MCAUSE_M_TIMER {
        disarm_timer();     // clear MTIE; agent_on_timer re-arms if there is more in flight
        agent_on_timer();  // complete the in-flight request (IRQ-safe), re-arm for the next
        return;
    }
    mc_halt();
}

// M-mode trap vector. A timer interrupt arrives at an arbitrary instruction, so the full integer
// frame plus mepc/mstatus are saved before dispatch and restored after.
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr t0, mepc\n sd t0, 224(sp)\n csrr t0, mstatus\n sd t0, 232(sp)\n call trap_entry\n ld t0, 224(sp)\n csrw mepc, t0\n ld t0, 232(sp)\n csrw mstatus, t0\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n mret"
    }
}

// Install the trap vector, arm ONE timer compare, and enable machine timer interrupts. Re-callable
// from the ISR to re-arm for the next in-flight request — so its body is #[irq_context] too
// (CSR asm + MMIO load/store only, no calls), matching the extern decl in the demo.
#[irq_context]
export fn mc_timer_arm_oneshot() -> void {
    let vec: usize = (&trap_vector) as usize;
    let mtie: usize = RT_MIE_MTIE;
    let mie_bit: usize = RT_MSTATUS_MIE;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw mtvec, %0"
                in("r") vec: usize
            }
        }
    }
    var now: u64 = 0;
    unsafe {
        now = raw.load<u64>(phys(RT_CLINT_MTIME));
        raw.store<u64>(phys(RT_CLINT_MTIMECMP), now + RT_TIMER_DELAY);
    }
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrs mie, %0"
                in("r") mtie: usize
            }
            asm precise volatile {
                "csrs mstatus, %0"
                in("r") mie_bit: usize
            }
        }
    }
}

export fn test_main() -> void {
    puts_("async-agent booting\n");
    let r: u32 = async_agent_demo(0, 0);
    puts_("\nresult=");
    putc_((48 + ((r / 10) % 10)) as u8);
    putc_((48 + (r % 10)) as u8);
    putc_(10); // '\n'
    if r == 1 {
        puts_("ASYNC-AGENT-OK\n");
    } else {
        puts_("ASYNC-AGENT-FAIL\n");
    }
    mc_halt();
}
