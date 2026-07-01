// Bare-metal riscv64 M-mode microbenchmark for the mem hot path (Phase 0 of the
// performance refactor). Boots `-bios none`, copies a 1 MiB buffer 64x via std/mem's
// mem_copy and fills it 64x via mem_set, timing each with the `rdcycle` CSR, and
// prints the totals over the bare 16550 UART:
//
//   MEMCPY-CYCLES <n>
//   MEMSET-CYCLES <n>
//
// This is the before/after number the plan's "measure first" rule requires. NOT in
// m0 — run it explicitly (`zig build mem-bench`). Buffers are 64-byte aligned so the
// word-aligned bulk path is actually exercised (byte-base globals would skip it).

import "std/addr.mc";
import "std/mem.mc";
import "tests/qemu/lib/test_report.mc";
import "std/fmt/fmt_sink.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;
const MIB: usize = 1024 * 1024;
const ITERS: usize = 64;

// Over-allocate by 64 so the working base can round up to a 64-byte boundary.
global bench_src: [MIB + 64]u8;
global bench_dst: [MIB + 64]u8;

fn halt() -> void {
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

fn rdcycle() -> u64 {
    var c: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "rdcycle %0"
                out("t0") c: u64
            }
        }
    }
    return c;
}

fn align64(v: usize) -> usize {
    return (v + 63) & ~(63 as usize);
}

fn report(label: *const u8, cycles: u64) -> void {
    uputs(label);
    fmt_put_dec(uputc, cycles);
    uputc(10); // '\n'
}

export fn m_main() -> void {
    let src: usize = align64((&bench_src[0]) as usize);
    let dst: usize = align64((&bench_dst[0]) as usize);

    // Seed src so the copy moves real bytes (and to fault in the pages).
    var j: usize = 0;
    while j < MIB {
        unsafe { raw.store<u8>(phys(src + j), (j & 0xFF) as u8); }
        j = j + 1;
    }
    // Touch dst too so page-fault-in cost is out of the timed window.
    mem_set(pa(dst), 0, MIB);

    uputs("mem-bench booting (M-mode)\n");

    // --- MEMCPY: 1 MiB copied ITERS times ---
    let c0: u64 = rdcycle();
    var i: usize = 0;
    while i < ITERS {
        mem_copy(pa(dst), pa(src), MIB);
        i = i + 1;
    }
    let c1: u64 = rdcycle();
    report("MEMCPY-CYCLES ", c1 - c0);

    // --- MEMSET: 1 MiB filled ITERS times ---
    let s0: u64 = rdcycle();
    i = 0;
    while i < ITERS {
        mem_set(pa(dst), 0x5A, MIB);
        i = i + 1;
    }
    let s1: u64 = rdcycle();
    report("MEMSET-CYCLES ", s1 - s0);

    uputs("MEM-BENCH-DONE\n");
    halt();
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
