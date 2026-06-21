// Bare-metal riscv64 M-mode test entry for the symbol/backtrace demo
// (tests/qemu/lang/symbols_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/backtrace_runtime.c.
//
// Two halves of a symbolized backtrace: nested calls build a real frame stack, the
// deepest frame walks the RISC-V frame-pointer chain (s0/fp: [fp-8] = saved ra,
// [fp-16] = saved caller fp) to capture return addresses, then each is symbolized
// through the MC symbol table (st_init/st_add/st_index from symbols_demo.mc).
//
// The level1/level2/level3 functions are `#[noinline]` so three distinct physical
// call frames exist for the frame-pointer walk to see (>=3 captured, >=2 resolved).
// The harness also builds with `-fno-omit-frame-pointer` so s0 is maintained as the
// frame pointer — exactly what the C version required.
//
// This unit installs its own M-mode `_start` (naked, `.text.start`): with `-bios
// none` QEMU jumps here in M-mode; it sets the stack and calls `test_main`.

import "kernel/core/mmio_console.mc";
import "kernel/core/console.mc";

// SiFive test finisher: writing this code powers the machine off / ends the run.
const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;

// MC symbol table wrappers (tests/qemu/lang/symbols_demo.mc), linked beside this object.
extern fn st_init() -> void;
extern fn st_add(addr: u64, id: u32) -> u32;
extern fn st_index(pc: u64) -> u64;

const RT_MAXF: usize = 16;
const RT_NO_INDEX: u64 = 0xFFFF_FFFF_FFFF_FFFF; // st_index returns (u64)-1 on a miss.

global g_frames: [16]u64;
global g_nframes: i32;
global g_resolved: i32;

// Read the current frame pointer (s0/fp).
fn read_fp() -> u64 {
    var v: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "mv %0, s0"
                out("r") v: u64
            }
        }
    }
    return v;
}

// Walk the frame-pointer chain from the current frame; returns the number of return
// addresses captured. At each frame the saved ra lives at fp-8 and the saved caller
// fp at fp-16; the stack grows down so the chain must ascend (prev > fp) or we stop.
fn capture_backtrace(max: i32) -> i32 {
    var fp: u64 = read_fp();
    var n: i32 = 0;
    while n < max && fp != 0 {
        var ra: u64 = 0;
        var prev: u64 = 0;
        unsafe {
            ra = raw.load<u64>(phys((fp - 8) as usize));    // saved ra at fp-8
            prev = raw.load<u64>(phys((fp - 16) as usize));  // saved fp at fp-16
        }
        g_frames[n as usize] = ra;
        n = n + 1;
        if prev <= fp {
            break; // the chain must ascend
        }
        fp = prev;
    }
    return n;
}

#[noinline]
fn level3() -> void {
    g_nframes = capture_backtrace(RT_MAXF as i32);
    g_resolved = 0;
    var i: i32 = 0;
    while i < g_nframes {
        if st_index(g_frames[i as usize]) != RT_NO_INDEX {
            g_resolved = g_resolved + 1;
        }
        i = i + 1;
    }
}

#[noinline]
fn level2() -> void {
    level3();
}

#[noinline]
fn level1() -> void {
    level2();
}

export fn test_main() -> void {
    put_str("backtrace booting\n");
    // Build a symbol table from the (sorted) level function addresses.
    st_init();
    var addrs: [3]u64 = .{
        (&level1) as usize as u64,
        (&level2) as usize as u64,
        (&level3) as usize as u64,
    };
    // Tiny ascending sort of the 3 addresses (the symbol table requires them sorted).
    var i: usize = 0;
    while i < 2 {
        var j: usize = 0;
        while j < 2 - i {
            if addrs[j] > addrs[j + 1] {
                let t: u64 = addrs[j];
                addrs[j] = addrs[j + 1];
                addrs[j + 1] = t;
            }
            j = j + 1;
        }
        i = i + 1;
    }
    st_add(addrs[0], 1);
    st_add(addrs[1], 2);
    st_add(addrs[2], 3);

    level1(); // nest 3 deep, capture + symbolize at the bottom

    put_str("BT frames=");
    put_dec(g_nframes as u64);
    put_str(" resolved=");
    put_dec(g_resolved as u64);
    console_putc(10); // '\n'
    // >=3 frames proves the unwind; >=2 resolved proves symbolization of the inner
    // level2/level3 return addresses.
    if g_nframes >= 3 && g_resolved >= 2 {
        put_str("BT-OK\n");
    }
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// QEMU `-bios none` jumps to 0x80000000 in M-mode. `#[section(".text.start")]` pins
// `_start` there (virt.ld: `*(.text.start)` first, `ENTRY(_start)`). Set the stack
// and call into the kernel; never returns.
#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call test_main\n 1: j 1b"
    }
}
