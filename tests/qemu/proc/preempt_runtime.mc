// Bare-metal riscv64 M-mode timer/trap wiring for the preemptive scheduler demo
// (tests/qemu/proc/preempt_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/preempt_runtime.c.
//
// The context-switch primitive, thread priming, UART (putc_/puts_), `mc_halt`, and
// `_start` (-> test_main) live in the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object). Here: the CLINT
// timer, the full-frame M-mode trap vector that drives preemption, and `test_main`.

const RT_CLINT_MTIME: usize = 0x0200_BFF8;    // CLINT mtime MMIO
const RT_CLINT_MTIMECMP: usize = 0x0200_4000; // CLINT mtimecmp[0] MMIO
const RT_TICK_INTERVAL: u64 = 1000000;        // ~0.1s at the 10MHz virt timebase
const RT_MCAUSE_M_TIMER: u64 = 0x8000_0000_0000_0007;
const RT_MIE_MTIE: usize = 0x80;    // machine timer interrupt enable (mie.MTIE)
const RT_MSTATUS_MIE: usize = 0x8;  // machine global interrupt enable (mstatus.MIE)

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;

// MC entry points (tests/qemu/proc/preempt_demo.mc).
extern fn timer_preempt() -> void;
extern fn preempt_demo(region_base: usize, region_len: usize) -> u32;

export fn mc_timer_rearm() -> void {
    var now: u64 = 0;
    unsafe {
        now = raw.load<u64>(phys(RT_CLINT_MTIME));
        raw.store<u64>(phys(RT_CLINT_MTIMECMP), now + RT_TICK_INTERVAL);
    }
}

// Dispatcher invoked by the trap vector once the interrupted frame is saved. Only the
// machine timer is configured; anything else fails closed (halts).
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
        timer_preempt(); // counts, rearms, and round-robins (may switch threads)
    } else {
        mc_halt();
    }
}

// M-mode trap vector. A timer interrupt arrives at an arbitrary instruction, so the
// full integer frame is saved before dispatch and restored after (on resume —
// `trap_entry` may switch to another thread and only return when this thread is
// scheduled again). mepc/mstatus are saved per-frame because a context switch inside
// trap_entry can resume a *different* thread that is itself mid-trap.
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr t0, mepc\n sd t0, 224(sp)\n csrr t0, mstatus\n sd t0, 232(sp)\n call trap_entry\n ld t0, 224(sp)\n csrw mepc, t0\n ld t0, 232(sp)\n csrw mstatus, t0\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n mret"
    }
}

// Install the trap vector, arm the first tick, and enable machine timer interrupts.
export fn mc_timer_start() -> void {
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
    mc_timer_rearm();
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

// Backing store for the kernel heap (thread stacks): 256 KiB.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    puts_("preempt booting\n");
    let ticks: u32 = preempt_demo((&g_heap_region) as usize, 262144);
    puts_("\nPREEMPT-OK ");
    putc_((48 + ((ticks / 10) % 10)) as u8);
    putc_((48 + (ticks % 10)) as u8);
    putc_(10); // '\n'
    mc_halt();
}
