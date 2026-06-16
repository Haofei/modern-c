// Boot entry + trap machinery for the F1 fault-isolation demo
// (tests/qemu/proc/fault_isolation_demo.mc). The context-switch primitives, UART, mc_halt, and
// _start come from context_runtime.c; this supplies the physical heap region, the REAL M-mode
// trap vector, the deliberate agent fault, and the post-fault report. Prints FAULT-ISOLATION-OK
// when the full containment keystone passed.
//
// The trap vector is the load-bearing piece: a synchronous illegal-instruction trap from the
// "agent" arrives here, we save caller state and call the MC handler `handle_agent_fault`, which
// classifies + CONTAINS the fault (kills+reclaims the faulting agent) and returns the PC to resume
// at — faulting PC + 4, so `mret` lands back in the kernel past the offending instruction. The
// faulting agent's domain is gone; the kernel and the other agents run on. A return value of 0
// means the fault was NOT attributable to an agent (the kernel's own fault) — we then panic+halt,
// the same fail-closed behavior the timer handler uses. WITHOUT the handler's recover-PC, an
// `mret` would resume AT the faulting instruction and re-trap forever, and the naive default is to
// halt — that is the kernel-halt this demo proves we avoid.
#include <stdint.h>
#include <stddef.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

// MC entry points (tests/qemu/proc/fault_isolation_demo.mc).
uint32_t fault_isolation_main(uintptr_t region_base, uintptr_t region_len);
uint64_t handle_agent_fault(uint64_t mcause, uint64_t mepc, uint64_t mtval);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

static void puthex64(uint64_t v) {
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

// C-level trap handler: dispatch to the MC fault path, which returns the resume PC. A non-zero
// resume PC means the fault was contained (agent killed+reclaimed) — write it back into mepc so
// the asm stub `mret`s into the kernel past the faulting instruction. A zero means a fatal kernel
// fault: diagnose and halt (fail closed). Returning installs the new mepc via the CSR directly so
// the naked stub stays a pure save/dispatch/restore/mret.
__attribute__((used)) void agent_trap_dispatch(uint64_t mcause, uint64_t mepc, uint64_t mtval) {
    uint64_t resume = handle_agent_fault(mcause, mepc, mtval);
    if (resume == 0) {
        // Fatal kernel fault — not attributable to any agent. Fail closed.
        puts_("PANIC c="); puthex64(mcause);
        puts_(" p="); puthex64(mepc);
        puts_(" v="); puthex64(mtval);
        putc_('\n');
        mc_halt();
    }
    __asm__ volatile("csrw mepc, %0" ::"r"(resume) : "memory");
}

// M-mode trap vector. A trap arrives at an arbitrary instruction boundary, so we save a full
// integer-register frame, dispatch to agent_trap_dispatch with (mcause, mepc, mtval) — which may
// rewrite mepc to the recover PC — then restore and `mret`.
__attribute__((naked, aligned(4))) static void agent_trap_vector(void) {
    __asm__ volatile(
        "addi sp, sp, -256\n"
        "sd ra,  0(sp)\n"  "sd t0,  8(sp)\n"  "sd t1, 16(sp)\n"  "sd t2, 24(sp)\n"
        "sd t3, 32(sp)\n"  "sd t4, 40(sp)\n"  "sd t5, 48(sp)\n"  "sd t6, 56(sp)\n"
        "sd a0, 64(sp)\n"  "sd a1, 72(sp)\n"  "sd a2, 80(sp)\n"  "sd a3, 88(sp)\n"
        "sd a4, 96(sp)\n"  "sd a5,104(sp)\n"  "sd a6,112(sp)\n"  "sd a7,120(sp)\n"
        "sd s0,128(sp)\n"  "sd s1,136(sp)\n"  "sd s2,144(sp)\n"  "sd s3,152(sp)\n"
        "sd s4,160(sp)\n"  "sd s5,168(sp)\n"  "sd s6,176(sp)\n"  "sd s7,184(sp)\n"
        "sd s8,192(sp)\n"  "sd s9,200(sp)\n"  "sd s10,208(sp)\n" "sd s11,216(sp)\n"
        "csrr a0, mcause\n"
        "csrr a1, mepc\n"
        "csrr a2, mtval\n"
        "call agent_trap_dispatch\n"
        "ld ra,  0(sp)\n"  "ld t0,  8(sp)\n"  "ld t1, 16(sp)\n"  "ld t2, 24(sp)\n"
        "ld t3, 32(sp)\n"  "ld t4, 40(sp)\n"  "ld t5, 48(sp)\n"  "ld t6, 56(sp)\n"
        "ld a0, 64(sp)\n"  "ld a1, 72(sp)\n"  "ld a2, 80(sp)\n"  "ld a3, 88(sp)\n"
        "ld a4, 96(sp)\n"  "ld a5,104(sp)\n"  "ld a6,112(sp)\n"  "ld a7,120(sp)\n"
        "ld s0,128(sp)\n"  "ld s1,136(sp)\n"  "ld s2,144(sp)\n"  "ld s3,152(sp)\n"
        "ld s4,160(sp)\n"  "ld s5,168(sp)\n"  "ld s6,176(sp)\n"  "ld s7,184(sp)\n"
        "ld s8,192(sp)\n"  "ld s9,200(sp)\n"  "ld s10,208(sp)\n" "ld s11,216(sp)\n"
        "addi sp, sp, 256\n"
        "mret\n");
}

// Install the M-mode trap vector (mtvec). Called from the MC keystone before the agent faults.
__attribute__((used)) void mc_install_trap_vector(void) {
    __asm__ volatile("csrw mtvec, %0" ::"r"((uintptr_t)&agent_trap_vector) : "memory");
}

// The deliberate agent fault: execute a guaranteed-illegal instruction (all-zero word is an
// illegal encoding on RV64). This raises a synchronous "illegal instruction" exception (mcause=2),
// which traps into agent_trap_vector. We return ONLY because the handler contained it and resumed
// past this instruction. The trailing `ret` is the normal function epilogue the compiler emits;
// the resume PC (fault PC + 4) lands on it.
__attribute__((naked, used)) void mc_agent_fault(void) {
    __asm__ volatile(
        ".word 0x00000000\n" // illegal instruction -> synchronous trap (the agent's fault)
        "ret\n");
}

__attribute__((used)) void test_main(void) {
    puts_("\nfault-isolation boot (containment keystone)\n");
    uint32_t stages = fault_isolation_main((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nstages=0x");
    putc_("0123456789abcdef"[(stages >> 4) & 0xf]);
    putc_("0123456789abcdef"[stages & 0xf]);
    putc_('\n');
    if (stages == 0x7) puts_("FAULT-ISOLATION-OK\n"); // heap+console up and containment proven
    else puts_("FAULT-ISOLATION-INCOMPLETE\n");
    mc_halt();
}
