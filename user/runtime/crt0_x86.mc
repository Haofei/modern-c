// user/runtime/crt0_x86 — the x86-64 userspace entry + syscall primitive for an MC/QuickJS agent
// (M7), in PURE MC (the all-MC replacement for crt0_x86.c). The x86-64 sibling of crt0.mc:
//   - mc_ecall: RAX=number, RDI/RSI/RDX=args, `int $0x80`, result in RAX — matching the M6 kernel
//     trap dispatcher (kernel/arch/x86_64/user_runtime.c). Values feed via generic `"r"` operands,
//     `mov`'d into the ABI registers in the template, then RAX read back; the ABI regs are clobbered.
//   - _start: set RSP to the loader-mapped stack top (__user_stack_top), 16-byte align it (System V),
//     call main, SYS_EXIT(main()).
//
// SYS_EXIT = 3 (user/abi.mc); hardcoded in the naked _start below — keep in sync with abi.mc.

export fn mc_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64 {
    var result: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mov %1, %%rax\n mov %2, %%rdi\n mov %3, %%rsi\n mov %4, %%rdx\n int $0x80\n mov %%rax, %0"
                out("r") result: u64,
                in("r") number: u64,
                in("r") a0: u64,
                in("r") a1: u64,
                in("r") a2: u64,
                clobber("rax"), clobber("rdi"), clobber("rsi"), clobber("rdx"),
                clobber("rcx"), clobber("r11"), clobber("memory")
            }
        }
    }
    return result;
}

// crt0: the ELF entry. __user_stack_top (link script user_qjs_x86.ld) tops the in-image stack (a
// NOBITS region the loader maps R|W|U). Set RSP, 16-byte align (System V), call main, SYS_EXIT(=3).
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "lea __user_stack_top(%rip), %rsp\n and $-16, %rsp\n xor %rbp, %rbp\n call main\n movslq %eax, %rdi\n mov $3, %rax\n int $0x80\n 1: hlt\n jmp 1b"
    }
}
