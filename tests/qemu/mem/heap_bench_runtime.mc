// Bare-metal riscv64 M-mode microbenchmark for the kernel heap's free path (Phase 2.1 of
// the performance refactor — killing the O(n^2) coalesce in kernel/core/heap.mc). Boots
// `-bios none` and, for each of ROUNDS rounds, allocates BCOUNT small blocks then frees them
// in an ADVERSARIAL interleaved order that first fragments the free list to its capacity and
// then forces heavy coalescing — exactly the shape the old multi-pass `while(changed)`
// re-scan pays O(n^2) for. Only the free sequence is timed (via the `rdcycle` CSR); the
// total is printed over the bare 16550 UART:
//
//   HEAPFREE-CYCLES <n>
//
// The interleaving:
//   Phase 1 — free the EVEN-index blocks. Each one's odd neighbours are still live, so
//     nothing coalesces and the free list fills to exactly HEAP_FREE_SLOTS (64) fragmented
//     holes (the O(n) store-and-scan path per free).
//   Phase 2 — free the ODD-index blocks. Every block now abuts a free hole on BOTH sides
//     (and the last reaches the bump frontier), so each free coalesces two neighbours — the
//     multi-pass path the legacy code re-scans all 64 slots for, once per merge.
//
// This is the before/after number the plan's "measure first" rule requires. NOT in m0 — run
// it explicitly (`zig build heap-bench`). Flip `HEAP_COMPACT_FREELIST` in heap.mc to compare
// the legacy (false) vs compacted (true) coalesce.
//
// The bench also self-checks correctness: after each round every block must be reclaimed, so
// `heap_available` must return to the pristine baseline. It prints HEAP-BENCH-DONE only when
// that held for every round; otherwise HEAP-BENCH-BALANCE-FAIL (which fails the harness).

import "std/addr.mc";
import "kernel/core/heap.mc";
import "tests/qemu/lib/test_report.mc";
import "std/fmt/fmt_sink.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;

// BCOUNT contiguous blocks; freeing the even indices first fills the free list with
// BCOUNT/2 non-coalescing holes, and BCOUNT/2 == HEAP_FREE_SLOTS (64) drives it to capacity.
const BCOUNT: usize = 128;
const BSIZE: usize = 64;         // multiple of BALIGN, so allocations pack with no gap
const BALIGN: usize = 16;
const ROUNDS: usize = 500;       // accumulate many free sequences for a stable cycle total
const POOL: usize = BCOUNT * BSIZE; // 8192 bytes carved exactly by BCOUNT allocations

// Over-allocate by 64 so the working base can round up to a 64-byte boundary.
global bench_pool: [POOL + 64]u8;
// Addresses of the BCOUNT blocks, so the free phase can revisit them in any order.
global bench_addrs: [BCOUNT]usize;

// heap.mc externs the KASAN shadow hooks (mc_ksan_poison/unpoison); a default (non-ksan) heap
// never calls them, and the compiler emits weak no-op stubs for the undefined externs, so no
// definition is needed here.

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
    let base: usize = align64((&bench_pool[0]) as usize);

    uputs("heap-bench booting (M-mode)\n");

    var total: u64 = 0;
    var ok_all: bool = true;

    var r: usize = 0;
    while r < ROUNDS {
        var h: Heap = heap_new(phys_range(pa(base), POOL));
        let baseline: usize = heap_available(&h);

        // ---- allocate BCOUNT contiguous blocks (NOT timed) ----
        var a: usize = 0;
        while a < BCOUNT {
            let p: PAddr = heap_alloc(&h, BSIZE, BALIGN);
            bench_addrs[a] = pa_value(p);
            a = a + 1;
        }

        // ---- timed: adversarial free sequence (fill to capacity, then coalesce heavily) ----
        let c0: u64 = rdcycle();
        // Phase 1: even indices — no coalesce (odd neighbours live) -> free list fills to 64.
        var e: usize = 0;
        while e < BCOUNT {
            heap_free(&h, pa(bench_addrs[e]), BSIZE);
            e = e + 2;
        }
        // Phase 2: odd indices — each abuts a hole on both sides (and the last reaches the
        // frontier), the multi-pass coalesce the legacy path re-scans all 64 slots for.
        var o: usize = 1;
        while o < BCOUNT {
            heap_free(&h, pa(bench_addrs[o]), BSIZE);
            o = o + 2;
        }
        let c1: u64 = rdcycle();
        total = total + (c1 - c0);

        // ---- correctness: every block reclaimed, availability back to baseline ----
        if heap_available(&h) != baseline {
            ok_all = false;
        }

        r = r + 1;
    }

    if ok_all {
        report("HEAPFREE-CYCLES ", total);
        uputs("HEAP-BENCH-DONE\n");
    } else {
        uputs("HEAP-BENCH-BALANCE-FAIL\n");
    }
    halt();
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
