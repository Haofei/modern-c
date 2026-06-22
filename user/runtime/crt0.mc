// user/runtime/crt0 — the userspace entry + syscall primitive for a confined MC/C app, in PURE MC
// (the all-MC replacement for crt0.c). Two things only:
//   - mc_ecall: the single syscall primitive. The RISC-V syscall ABI (a7=number, a0..a2=args) is
//     pinned IN THE ASM TEMPLATE — MC precise-asm operands lower with generic `"r"` constraints, so
//     the template `mv`s the values into the ABI registers, `ecall`s, reads a0 back, and CLOBBERS
//     the ABI regs (the exact idiom proven in kernel/arch/riscv64/sbi.mc). user/sys.mc calls this.
//   - _start: the ELF entry. Sets the loader-mapped user stack, calls `main`, exits with main's
//     return code via SYS_EXIT.
//
// Freestanding: no libc, no globals beyond the linker-defined stack symbol.
//
// SYS_EXIT = 3 (see user/abi.mc; matches the shared M-mode trap handler). Hardcoded in the naked
// _start template below — keep it in sync with abi.mc (this file is MC, like the x86/aarch64 qjs
// user runtimes, so it is excluded from the C-side abi-consistency grep).

// One syscall: a7=number, a0..a2=args, `ecall`, result in a0.
export fn mc_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv a7, %1\n mv a0, %2\n mv a1, %3\n mv a2, %4\n ecall\n mv %0, a0"
                out("t0") result: u64,
                in("t1") number: u64,
                in("t2") a0: u64,
                in("t3") a1: u64,
                in("t4") a2: u64,
                clobber("a0"), clobber("a1"), clobber("a2"), clobber("a7"),
                clobber("memory")
            }
        }
    }
    return result;
}

// crt0: the ELF entry. __user_stack_top is defined by user/runtime/user.ld at the top of the app's
// in-image stack (a NOBITS region the loader maps R|W|U and zeroes). `call main` enters the app's
// `export fn main() -> i32`; its a0 return code is passed to SYS_EXIT (=3).
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, __user_stack_top\n call main\n li a7, 3\n ecall\n 1: j 1b"
    }
}
