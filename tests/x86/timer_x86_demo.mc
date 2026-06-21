// tests/x86/timer_x86_demo — minimal MC fixture for the x86-64 Local-APIC timer proof.
//
// Arch-neutral orchestration helpers the C runtime (kernel/arch/x86_64/timer_runtime.c) links
// against, mirroring how vm_runtime.c calls into MC (vm_x86_build): the runtime asks MC for the
// required tick threshold and the final pass/fail verdict, so a real MC object participates in the
// boot image. The interrupt machinery itself lives in the freestanding C runtime; this fixture
// supplies the policy (how many ticks count as proof, and whether the observed count passes).

// Prefixed const to avoid emit-c const-flatten collisions with other fixtures sharing a TU.
const TIMER_X86_TARGET: u32 = 3;

// The number of real LAPIC-timer interrupts the runtime must observe before declaring success.
export fn timer_target() -> u32 {
    return TIMER_X86_TARGET;
}

// Verdict: 1 iff at least `target` ticks were actually delivered (proving non-polled interrupt
// delivery via the Local APIC), else 0.
export fn timer_ok(ticks: u32) -> u32 {
    if ticks >= TIMER_X86_TARGET {
        return 1;
    }
    return 0;
}
