// Bare-metal M-mode KCSAN data-race watchpoint runtime for the D2.3 demo — in PURE MC (no C).
// The all-MC replacement for kernel/arch/riscv64/csan_runtime.c.
//
// KCSAN model (a la the Linux Kernel Concurrency Sanitizer): an UNSYNCHRONIZED access does not
// lock; it briefly installs a *watchpoint* describing the location + access kind and watches it
// for a short window. If a concurrent context performs a conflicting access (the two overlap and
// at least one is a write) while the watchpoint is live, that is a data race. The MC compiler,
// under `--checks=csan`, wraps every unsynchronized raw.load/raw.store with mc_csan_read /
// mc_csan_write, which this module DEFINES. The SYNCHRONIZED `mc_race_*` accessors (what a scalar
// `global` lowers to) never call these hooks, so a properly-synchronized access never races.
//
// CONCURRENCY IS REAL: the racing context is a CLINT machine-timer IRQ that preempts the boot
// thread at an arbitrary instruction. When the IRQ fires while the boot thread holds a watchpoint,
// the IRQ-side access hook finds the live watchpoint set by the other context and traps. The watch
// window is widened so a tick is GUARANTEED to land inside the racy access (deterministic demo),
// but the interleaving is genuine asynchronous preemption.
//
// Built UN-instrumented (no MC_CHECKS): its own watchpoint-table reads/writes must never recurse
// through mc_csan_*. It DEFINES mc_csan_read / mc_csan_write (the compiler yields its weak stubs
// to these strong definitions). The demo (csan_demo.mc, --checks=csan) links beside this object.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

const FINISHER: usize = 0x0010_0000;
const FINISHER_HALT: u32 = 0x5555;

// CLINT machine timer (QEMU virt). A small interval so a tick reliably lands inside the boot
// thread's widened watch window.
const CLINT_MTIME: usize = 0x0200_BFF8;
const CLINT_MTIMECMP: usize = 0x0200_4000;
const TICK_INTERVAL: u64 = 2000;
const MCAUSE_M_TIMER: u64 = 0x8000_0000_0000_0007;

// Two contexts: the boot thread (id 0) and the timer IRQ (id 1). One watchpoint slot each — a
// context holds at most one in-flight access.
const CTX_MAIN: i32 = 0;
const CTX_IRQ: i32 = 1;

// Watchpoint table, as parallel globals (index 0 == MAIN, 1 == IRQ). size==0 means slot empty.
global wp_addr: [2]usize;
global wp_size: [2]usize;
global wp_is_write: [2]i32;
global wp_active: [2]i32;

// Current context id. CTX_IRQ around the MC IRQ-side call; CTX_MAIN otherwise.
global csan_ctx: i32 = 0;

// The shared word the race targets, in the managed pool.
global pool: [4096]u8;

global csan_armed: i32 = 0;
global race_reported: i32 = 0; // latches the result once the race is detected
global race_shared_addr: usize = 0;

// MC entry points (defined in csan_demo.mc, compiled with --checks=csan).
extern fn csan_race(shared: usize) -> u32;
extern fn csan_clean() -> u32;
extern fn csan_irq_unsync(shared: usize) -> u32;
extern fn csan_irq_sync() -> u32;

fn scenario_id() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "la %0, mc_scenario"
                out("r") v: u64
            }
        }
    }
    return v;
}

fn ranges_overlap(a: usize, alen: usize, b: usize, blen: usize) -> i32 {
    if a < b + blen && b < a + alen {
        return 1;
    }
    return 0;
}

// The conflict check shared by the read/write hooks. `is_write` is this access's kind. Scans the
// OTHER context's watchpoint; a live, overlapping watchpoint where at least one side is a write is
// a data race -> trap (-> CSAN-DETECTED via the trap vector).
fn csan_access(addr: usize, size: usize, is_write: i32) -> void {
    if csan_armed == 0 || size == 0 {
        return;
    }
    let self_ctx: i32 = csan_ctx;
    var other: i32 = 0;
    if self_ctx == CTX_MAIN { other = CTX_IRQ; } else { other = CTX_MAIN; }
    let s: usize = self_ctx as usize;
    let o: usize = other as usize;

    // 1. Conflict check against the other context's live watchpoint.
    if wp_active[o] != 0 && wp_size[o] != 0
        && ranges_overlap(addr, size, wp_addr[o], wp_size[o]) != 0
        && (is_write != 0 || wp_is_write[o] != 0) {
        race_reported = 1;
        unreachable; // data race -> M-mode trap -> "CSAN-DETECTED"
    }

    // 2. Install this context's watchpoint and watch it for a window. Only the boot thread widens
    //    the window (so a preempting tick lands inside); the IRQ does not spin.
    wp_addr[s] = addr;
    wp_size[s] = size;
    wp_is_write[s] = is_write;
    wp_active[s] = 1;

    if self_ctx == CTX_MAIN {
        // Watch window. A timer tick is guaranteed to fire within this spin, preempting into the
        // IRQ-side conflicting access while THIS watchpoint is still live. Re-check after too.
        var spin: i32 = 0;
        while spin < 20000 && race_reported == 0 {
            if wp_active[o] != 0 && wp_size[o] != 0
                && ranges_overlap(addr, size, wp_addr[o], wp_size[o]) != 0
                && (is_write != 0 || wp_is_write[o] != 0) {
                race_reported = 1;
                unreachable;
            }
            spin = spin + 1;
        }
    }

    // 3. Clear our watchpoint.
    wp_active[s] = 0;
    wp_size[s] = 0;
}

// The compiler-emitted hooks. Strong definitions override the weak no-op stubs.
export fn mc_csan_read(addr: usize, size: usize) -> void {
    csan_access(addr, size, 0);
}
export fn mc_csan_write(addr: usize, size: usize) -> void {
    csan_access(addr, size, 1);
}

fn mtime_now() -> u64 {
    var v: u64 = 0;
    unsafe { v = raw.load<u64>(phys(CLINT_MTIME)); }
    return v;
}

fn timer_rearm() -> void {
    let next: u64 = mtime_now() + TICK_INTERVAL;
    unsafe { raw.store<u64>(phys(CLINT_MTIMECMP), next); }
}

fn read_mcause() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrr %0, mcause"
                out("r") v: u64
            }
        }
    }
    return v;
}

// What the timer IRQ does on each tick. RACE: an UNSYNCHRONIZED write to the shared word
// (instrumented -> watchpoint -> conflict-detects the boot thread's live watchpoint). CLEAN: a
// SYNCHRONIZED race-accessor write (no watchpoint -> never conflicts).
export fn trap_entry() -> void {
    let mcause: u64 = read_mcause();
    if mcause != MCAUSE_M_TIMER {
        halt();
    }
    timer_rearm();
    // Run the IRQ-side conflicting access AS THE IRQ CONTEXT.
    csan_ctx = CTX_IRQ;
    let sc: u64 = scenario_id();
    if sc == 2 {
        let _u: u32 = csan_irq_unsync(race_shared_addr); // instrumented -> may trap
    } else {
        let _u: u32 = csan_irq_sync();                   // synchronized -> never traps
    }
    csan_ctx = CTX_MAIN;
}

// Dispatch: a machine-timer interrupt drives preemption (trap_entry, which may detect the race
// and trap). Any non-timer trap here is that trap (the data-race detection) -> CSAN-DETECTED.
export fn trap_dispatch() -> void {
    let mcause: u64 = read_mcause();
    if mcause == MCAUSE_M_TIMER {
        trap_entry();
        return;
    }
    // Non-timer trap == the data-race trap (CSAN-DETECTED) or a real fault.
    put_str("CSAN-DETECTED\n");
    halt();
}

// Naked M-mode trap vector: a timer interrupt arrives at an arbitrary instruction, so save the
// full integer frame before dispatch, restore, and `mret`. The data-race trap (a non-timer
// cause) routes to trap_dispatch which reports and halts (never returns). Same frame layout as
// mmode_timer_demo.mc. 4-byte aligned via its own `.text.mtrap` section.
#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n call trap_dispatch\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n mret"
    }
}

fn timer_start() -> void {
    unsafe {
        asm opaque volatile {
            "la t0, trap_vector\n csrw mtvec, t0"
            clobber("t0")
        }
    }
    timer_rearm();
    unsafe {
        asm opaque volatile {
            "li t0, 0x80\n csrs mie, t0"   // MTIE (bit 7)
            clobber("t0")
        }
    }
    unsafe {
        asm opaque volatile {
            "li t0, 0x8\n csrs mstatus, t0" // MIE (bit 3)
            clobber("t0")
        }
    }
}

export fn m_main() -> void {
    race_shared_addr = (&pool) as usize;
    csan_armed = 1;
    timer_start();

    let sc: u64 = scenario_id();
    if sc == 2 {
        put_str("csan race demo booting (M-mode)\n");
        put_str("race: unsynchronized boot-thread access vs preempting timer-IRQ access...\n");
        // The boot thread repeatedly does the UNSYNCHRONIZED access; a timer tick preempts into
        // the conflicting IRQ access while the watchpoint is live -> CSAN-DETECTED (traps in
        // csan_access, never returns). If detection FAILS, csan_race returns and we print MISSED.
        let _u: u32 = csan_race((&pool) as usize);
        put_str("RACE-MISSED\n");
    } else {
        put_str("csan clean demo booting (M-mode)\n");
        put_str("clean: synchronized (mc_race_*) boot-thread access vs synchronized timer IRQ...\n");
        let v: u32 = csan_clean();
        if v != 0 {
            put_str("CSAN-OK\n"); // synchronized accesses set no watchpoint -> no race detected
        } else {
            put_str("CSAN-BAD\n");
        }
    }
    halt();
}

fn halt() -> void {
    unsafe { raw.store<u32>(phys(FINISHER), FINISHER_HALT); }
    while true {}
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
