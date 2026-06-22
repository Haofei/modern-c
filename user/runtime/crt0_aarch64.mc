// user/runtime/crt0_aarch64 — the AArch64 userspace entry + syscall primitive for an MC/QuickJS
// agent (M9), in PURE MC (the all-MC replacement for crt0_aarch64.c). The AArch64 sibling of
// crt0.mc / crt0_x86.mc:
//   - mc_ecall: x8=number, x0/x1/x2=args, `svc #0`, result in x0 — matching the M8/M9 kernel EL1
//     SVC dispatcher. Values feed via generic `"r"` operands, `mov`'d into the ABI registers in the
//     template, then x0 read back; the ABI regs are clobbered.
//   - _start: set SP to the loader-mapped stack top (__user_stack_top), 16-byte align it (AAPCS64),
//     call main, SYS_EXIT(main()).
//
// SYS_EXIT = 3 (user/abi.mc); hardcoded in the naked _start below — keep in sync with abi.mc.

export fn mc_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov x8, %1\n mov x0, %2\n mov x1, %3\n mov x2, %4\n svc #0\n mov %0, x0"
                out("r") result: u64,
                in("r") number: u64,
                in("r") a0: u64,
                in("r") a1: u64,
                in("r") a2: u64,
                clobber("x0"), clobber("x1"), clobber("x2"), clobber("x8"),
                clobber("memory")
            }
        }
    }
    return result;
}

// crt0: the ELF entry. __user_stack_top (link script user_qjs_aarch64.ld) tops the in-image stack
// (a NOBITS region the loader maps EL0 R|W). Set SP, 16-byte align (AAPCS64), call main,
// SYS_EXIT(=3). SP can't be an AND operand, so align in x0 then move to SP.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "ldr x0, =__user_stack_top\n and x0, x0, #-16\n mov sp, x0\n mov x29, #0\n mov x30, #0\n bl main\n sxtw x0, w0\n mov x8, #3\n svc #0\n 1: wfe\n b 1b"
    }
}
