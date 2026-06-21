// Boot entry + trap machinery for the F1 fault-isolation demo
// (tests/qemu/proc/fault_isolation_demo.mc) — in PURE MC (no C). The all-MC
// replacement for kernel/arch/riscv64/fault_isolation_runtime.c.
//
// The context-switch primitives, `_start`, and `mc_halt` come from the shared M-mode
// bring-up runtime (kernel/arch/riscv64/context_runtime.c, linked beside this object);
// `_start` sets the stack and calls `test_main`. This unit supplies the physical heap
// region, the REAL M-mode trap vector, the deliberate agent fault, and the post-fault
// report. Prints FAULT-ISOLATION-OK when the full containment keystone passed.
//
// The trap vector is the load-bearing piece: a synchronous illegal-instruction trap
// from the "agent" arrives here, we save caller state and call the MC handler
// `handle_agent_fault`, which classifies + CONTAINS the fault (kills+reclaims the
// faulting agent) and returns the PC to resume at — faulting PC + 4, so `mret` lands
// back in the kernel past the offending instruction. A return value of 0 means the
// fault was NOT attributable to an agent (the kernel's own fault) — we then panic+halt,
// the same fail-closed behavior the timer handler uses.
//
// The demo defines console_putc (via its imports); this runtime writes the bare 16550
// UART directly for its banners/diagnostics, so it does NOT import console.mc.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uputc(b);
        i = i + 1;
    }
}

// Lowercase-hex nibble for a 4-bit value.
fn hex_nibble(v: u64) -> u8 {
    let n: u64 = v & 0xf;
    if n < 10 {
        return ('0' as u64 + n) as u8;
    }
    return ('a' as u64 + (n - 10)) as u8;
}

// Print a 64-bit value as 16 lowercase hex digits over the bare UART.
fn puthex64(v: u64) -> void {
    var shift: i32 = 60;
    while shift >= 0 {
        uputc(hex_nibble(v >> (shift as u64)));
        shift = shift - 4;
    }
}

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The demo (tests/qemu/proc/fault_isolation_demo.mc).
extern fn fault_isolation_main(region_base: usize, region_len: usize) -> u32;
extern fn handle_agent_fault(mcause: u64, mepc: u64, mtval: u64) -> u64;

// 256 KiB physical heap region.
global g_heap_region: [262144]u8;

// MC-level trap handler: dispatch to the MC fault path, which returns the resume PC. A
// non-zero resume PC means the fault was contained (agent killed+reclaimed) — write it
// back into mepc so the asm stub `mret`s into the kernel past the faulting instruction.
// A zero means a fatal kernel fault: diagnose and halt (fail closed).
export fn agent_trap_dispatch(mcause: u64, mepc: u64, mtval: u64) -> void {
    let resume: u64 = handle_agent_fault(mcause, mepc, mtval);
    if resume == 0 {
        // Fatal kernel fault — not attributable to any agent. Fail closed.
        uputs("PANIC c=");
        puthex64(mcause);
        uputs(" p=");
        puthex64(mepc);
        uputs(" v=");
        puthex64(mtval);
        uputc(10); // '\n'
        mc_halt();
    }
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw mepc, %0"
                in("r") resume: u64
                clobber("memory")
            }
        }
    }
}

// Naked M-mode trap vector. A trap arrives at an arbitrary instruction boundary, so
// save a full integer-register frame, dispatch to agent_trap_dispatch with
// (mcause, mepc, mtval) — which may rewrite mepc to the recover PC — then restore and
// `mret`. Pinned to .text.mtrap so virt.ld aligns it to a 4-byte boundary.
#[naked]
#[section(".text.mtrap")]
export fn agent_trap_vector() -> void {
    asm opaque volatile {
        "addi sp, sp, -256\n sd ra, 0(sp)\n sd t0, 8(sp)\n sd t1, 16(sp)\n sd t2, 24(sp)\n sd t3, 32(sp)\n sd t4, 40(sp)\n sd t5, 48(sp)\n sd t6, 56(sp)\n sd a0, 64(sp)\n sd a1, 72(sp)\n sd a2, 80(sp)\n sd a3, 88(sp)\n sd a4, 96(sp)\n sd a5, 104(sp)\n sd a6, 112(sp)\n sd a7, 120(sp)\n sd s0, 128(sp)\n sd s1, 136(sp)\n sd s2, 144(sp)\n sd s3, 152(sp)\n sd s4, 160(sp)\n sd s5, 168(sp)\n sd s6, 176(sp)\n sd s7, 184(sp)\n sd s8, 192(sp)\n sd s9, 200(sp)\n sd s10, 208(sp)\n sd s11, 216(sp)\n csrr a0, mcause\n csrr a1, mepc\n csrr a2, mtval\n call agent_trap_dispatch\n ld ra, 0(sp)\n ld t0, 8(sp)\n ld t1, 16(sp)\n ld t2, 24(sp)\n ld t3, 32(sp)\n ld t4, 40(sp)\n ld t5, 48(sp)\n ld t6, 56(sp)\n ld a0, 64(sp)\n ld a1, 72(sp)\n ld a2, 80(sp)\n ld a3, 88(sp)\n ld a4, 96(sp)\n ld a5, 104(sp)\n ld a6, 112(sp)\n ld a7, 120(sp)\n ld s0, 128(sp)\n ld s1, 136(sp)\n ld s2, 144(sp)\n ld s3, 152(sp)\n ld s4, 160(sp)\n ld s5, 168(sp)\n ld s6, 176(sp)\n ld s7, 184(sp)\n ld s8, 192(sp)\n ld s9, 200(sp)\n ld s10, 208(sp)\n ld s11, 216(sp)\n addi sp, sp, 256\n mret"
    }
}

// Install the M-mode trap vector (mtvec). Called from the MC keystone before the agent
// faults.
export fn mc_install_trap_vector() -> void {
    unsafe {
        asm opaque volatile {
            "la t0, agent_trap_vector\n csrw mtvec, t0"
            clobber("t0"), clobber("memory")
        }
    }
}

// The deliberate agent fault: execute a guaranteed-illegal instruction (an all-zero
// word is an illegal encoding on RV64). This raises a synchronous "illegal
// instruction" exception (mcause=2), which traps into agent_trap_vector. We return ONLY
// because the handler contained it and resumed past this instruction (fault PC + 4
// lands on the trailing `ret`).
#[naked]
export fn mc_agent_fault() -> void {
    asm opaque volatile {
        ".word 0x00000000\n ret"
    }
}

export fn test_main() -> void {
    uputs("\nfault-isolation boot (containment keystone)\n");
    let base: usize = (&g_heap_region[0]) as usize;
    let stages: u32 = fault_isolation_main(base, 262144);
    uputs("\nstages=0x");
    uputc(hex_nibble((stages >> 4) as u64));
    uputc(hex_nibble(stages as u64));
    uputc(10); // '\n'
    if stages == 0x7 {
        uputs("FAULT-ISOLATION-OK\n"); // heap+console up and containment proven
    } else {
        uputs("FAULT-ISOLATION-INCOMPLETE\n");
    }
    mc_halt();
}
