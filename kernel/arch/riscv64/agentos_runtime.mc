// Bare-metal riscv64 M-mode boot entry for the agent-OS governance demo
// (tests/qemu/proc/agentos_demo.mc) — in PURE MC (no C). The all-MC replacement
// for kernel/arch/riscv64/agentos_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit supplies the physical region the
// kernel carves the heap from, calls agentos_main, and reports the stage bitmask —
// writing the bare 16550 UART directly. Prints AGENTOS-OK when the full keystone
// passed (heap + console up and the keystone fully passed: stages == 0x7).

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

// Write one byte to the bare 16550 UART transmit register.
fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

// Write a NUL-terminated string over the bare UART.
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

// Print a nibble (low 4 bits of v) as a lowercase hex digit.
fn uput_nibble(v: u32) -> void {
    let n: u32 = v & 0xf;
    if n < 10 {
        uputc((48 + n) as u8); // '0'..'9'
    } else {
        uputc((97 + (n - 10)) as u8); // 'a'..'f'
    }
}

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The agent-OS governance keystone (tests/qemu/proc/agentos_demo.mc): boots the
// heap + console, then runs the OOM-kill / reclaim keystone inline. Returns a stage
// bitmask (0x7 on full success).
extern fn agentos_main(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel carves the heap from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("\nagentos boot (governance keystone)\n");
    let stages: u32 = agentos_main((&g_heap_region) as usize, 262144);
    uputs("\nstages=0x");
    uput_nibble(stages >> 4);
    uput_nibble(stages);
    uputc(10); // '\n'
    if stages == 0x7 {
        uputs("AGENTOS-OK\n"); // heap + console up and the keystone fully passed
    } else {
        uputs("AGENTOS-INCOMPLETE\n");
    }
    mc_halt();
}
