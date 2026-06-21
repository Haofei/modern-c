// kernel/arch/riscv64/sbi — the SBI (Supervisor Binary Interface) seam in PURE MC.
//
// An S-mode kernel booted by REAL OpenSBI talks to the firmware through `ecall`.
// The SBI ABI puts the extension id (EID) in a7, the function id (FID) in a6, and
// args in a0/a1; the result comes back in a0. This module is the single audited
// home for that `ecall` shim plus the handful of calls the bare-metal images use:
// legacy console putchar / shutdown, and the TIME extension's set-timer.
//
// THE ECALL IDIOM. MC's precise-asm operands lower with GENERIC `"r"` constraints
// (the `out(...)`/`in(...)` register names are provenance/verification only, NOT
// hard pinning). So we CANNOT name a0/a6/a7 as operands and expect them pinned.
// Instead we place the values into the ABI registers IN THE TEMPLATE (`mv a7,%1`
// ...), `ecall`, then read a0 back into the output operand — and we CLOBBER the
// hard ABI registers (a0/a1/a6/a7) so the register allocator will not choose them
// for any operand (which would make the template's `mv` self-overwrite). The
// operands themselves land in caller-saved temporaries the allocator is free to
// pick. This is the keystone idiom reused across the all-MC kernel sweep.

import "std/addr.mc";

// Legacy SBI extension ids (each is its own EID with fid 0).
const SBI_EXT_CONSOLE_PUTCHAR: u64 = 1;   // legacy console putchar
const SBI_EXT_SHUTDOWN: u64 = 8;          // legacy system shutdown
// SBI TIME extension: EID "TIME" = 0x54494D45, fid 0, arg0 = absolute stime.
const SBI_EXT_TIME: u64 = 0x5449_4D45;

// The raw SBI ecall. Args go in a0/a1/a6/a7; the result returns in a0. See the
// module header for why the placement is done in the template + the ABI regs are
// clobbered (MC precise-asm operands are generic `"r"`, not pinned).
export fn sbi_ecall(ext: u64, fid: u64, arg0: u64, arg1: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv a7, %1\n mv a6, %2\n mv a0, %3\n mv a1, %4\n ecall\n mv %0, a0"
                out("t0") result: u64,
                in("t1") ext: u64,
                in("t2") fid: u64,
                in("t3") arg0: u64,
                in("t4") arg1: u64,
                clobber("a0"), clobber("a1"), clobber("a6"), clobber("a7"),
                clobber("memory")
            }
        }
    }
    return result;
}

// Print one byte over the SBI console (legacy EID 1).
export fn sbi_putchar(c: u8) -> void {
    let _ignore: u64 = sbi_ecall(SBI_EXT_CONSOLE_PUTCHAR, 0, c as u64, 0);
}

// Print a NUL-terminated string over the SBI console.
export fn sbi_puts(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(pa(base + i)); }
        if b == 0 {
            break;
        }
        sbi_putchar(b);
        i = i + 1;
    }
}

// Shut the machine down (legacy EID 8). Does not return on real OpenSBI.
export fn sbi_shutdown() -> void {
    let _ignore: u64 = sbi_ecall(SBI_EXT_SHUTDOWN, 0, 0, 0);
}

// Program the next S-mode timer interrupt to fire at absolute `stime` (TIME ext).
// Setting a new deadline also clears the pending STIP, so re-arming inside the
// handler dismisses the interrupt.
export fn sbi_set_timer(stime: u64) -> void {
    let _ignore: u64 = sbi_ecall(SBI_EXT_TIME, 0, stime, 0);
}
