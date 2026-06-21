// Bare-metal riscv64 test entry for the user-mode shell demo
// (tests/qemu/lang/shell_user_demo.mc) — in PURE MC (no C). The all-MC replacement
// for kernel/arch/riscv64/shell_user_runtime.c.
//
// Drops to U-mode and enters the shell. The kernel logic (UART IRQ routing, wfi,
// syscalls) is all in MC (shell_user_demo.mc); this unit is just the test harness
// entry + the U-mode stack. `_start`, `mc_halt`, `puts_`, `usermode_setup`, and
// `enter_user` come from the shared runtimes linked beside this object
// (context_runtime.c + usermode_runtime.c); `shell_user` + `shell_irq_setup` come
// from the MC shell demo.

extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;
extern fn usermode_setup() -> void;
extern fn enter_user(entry: usize, user_sp: usize) -> void;
extern fn shell_user() -> u32;        // MC: the user-mode shell loop
extern fn shell_irq_setup() -> void;  // MC: enable UART RX IRQ -> PLIC -> mie.MEIE

// U-mode shell stack (16 KiB). 16-byte aligned for the RISC-V ABI.
global g_user_stack: [16384]u8;

export fn test_main() -> void {
    puts_("mc-shell (user mode) — builtins: echo true false top exit\n");
    usermode_setup();   // trap vector (UART ISR + ecalls), PMP, syscall table
    shell_irq_setup();  // MC: route the UART RX interrupt + unmask mie.MEIE
    let sp: usize = (&g_user_stack) as usize + 16384;
    enter_user((&shell_user) as usize, sp);
    mc_halt();
}
