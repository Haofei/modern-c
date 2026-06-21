// Bare-metal riscv64 M-mode per-process address-space runtime — in PURE MC (no C).
// The all-MC replacement for kernel/arch/riscv64/vmspace_runtime.c.
//
// M-mode builds three process page tables with the SAME existing MC `vmspace_setup`
// (kernel/core via the vmspace demo), delegates traps + opens PMP, and `mret`s into
// S-mode. There it "context-switches" between the three processes by loading each
// one's satp (proc_satp) and reads the shared test VA — each process sees its own
// value, proving each Process has an independent address space switched on the
// (would-be) context switch.
//
// The boot seam, bare-UART console, and the M->S privilege drop are shared MC
// (mmode_sdrop.mc); the real work (build three per-process page tables) is the
// unchanged MC vmspace module. The unused per-process context-switch primitives are
// stubbed in tests/qemu/mem/proc_ctx_stubs.mc (linked beside this object).

import "tests/qemu/mem/mmode_sdrop.mc";  // M->S privilege drop + satp activation
import "kernel/core/mmio_console.mc";    // put_str/put_hex over the bare 16550 UART
import "kernel/core/console.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;
const RT_TEST_VA: usize = 0xC000_0000;

global g_heap_region: [262144]u8;

// The vmspace demo (tests/qemu/mem/vmspace_demo.mc): builds three per-process page
// tables over the physical region, and returns process i's satp.
extern fn vmspace_setup(region_base: usize, region_len: usize) -> void;
extern fn vmspace_satp(idx: usize) -> u64;

// S-mode entry (reached via `mret`): switch to each process's address space in turn
// and read the shared test VA; each process must observe its own frame's value.
export fn s_main() -> void {
    var expect: [3]u32 = .{ 0xAAAA_0000, 0xBBBB_0001, 0xCCCC_0002 };
    var all_ok: bool = true;
    var i: usize = 0;
    while i < 3 {
        activate_satp(vmspace_satp(i)); // load process i's address space
        var v: u32 = 0;
        unsafe { v = raw.load<u32>(phys(RT_TEST_VA)); } // same VA, per-process frame
        put_str("proc ");
        console_putc((48 + i) as u8); // '0' + i
        put_str(" VA=");
        put_hex(v as u64);
        console_putc(10); // '\n'
        if v != expect[i] {
            all_ok = false;
        }
        i = i + 1;
    }
    if all_ok {
        put_str("VMSPACE-OK\n");
    } else {
        put_str("VMSPACE-BAD\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// M-mode boot: build the three per-process page tables (MC), then drop to S-mode.
export fn m_main() -> void {
    put_str("vmspace booting (M-mode)\n");
    vmspace_setup((&g_heap_region) as usize, 262144);
    put_str("per-process page tables built, dropping to S-mode\n");
    drop_to_smode((&s_main) as usize);
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode; `.text.start` pins `_start` there.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
