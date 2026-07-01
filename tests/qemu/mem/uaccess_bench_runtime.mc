// Bare-metal riscv64 M-mode microbenchmark for the page-table-aware uaccess hot path
// (Phase 2.4 of the performance refactor). Boots `-bios none`, builds a software Sv39
// page table mapping a large multi-page user buffer, then copies that whole buffer
// through copy_to_user_pt / copy_from_user_pt ITERS times, timing each with the
// `rdcycle` CSR and printing the totals over the bare 16550 UART:
//
//   UACCESS-TO-CYCLES <n>     (copy_to_user_pt:   kernel -> user, PTE_U + PTE_W checked)
//   UACCESS-FROM-CYCLES <n>   (copy_from_user_pt: user -> kernel, PTE_U + PTE_R checked)
//   UACCESS-SMALL-CYCLES <n>  (many tiny 8-byte copies: the walk-dominated regime where the
//                              single-pass change shows — large copies are mem_copy-bound)
//   UACCESS-CYCLES <n>        (TO + FROM sum — the large-copy before/after number)
//
// The page-table walk is done entirely in software (no satp), so this runs `-bios none`
// like mem-bench. NOT in m0 — run it explicitly (`zig build uaccess-bench`). This is the
// before/after measurement the plan's "measure first" rule requires for the single-pass
// (fold validate+copy, one walk per page) change to copy_pages.

import "std/addr.mc";
import "std/mem.mc";
import "kernel/core/uaccess.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "tests/qemu/lib/test_report.mc";
import "std/fmt/fmt_sink.mc";

const RT_FINISHER: usize = 0x0010_0000;
const RT_FINISHER_HALT: u32 = 0x5555;

const PAGE: usize = 4096;
const PAGES: usize = 256;             // 256 * 4 KiB = 1 MiB user buffer (multi-page, multi-walk)
const BUF: usize = PAGES * PAGE;      // bytes copied per iteration
const ITERS: usize = 32;              // 32 MiB moved per direction
const SMALL_ITERS: usize = 2000000;   // small-copy regime: per-call walk dominates the tiny copy
const USER_VA: usize = 0x1000_0000;   // base of the mapped user region

// Heap backs the page table structural frames + the PAGES user data frames (~1.1 MiB).
global g_pool: [2 * 1024 * 1024]u8;
// Kernel-side buffer for the copies (the other end of every copy_*_user_pt).
global g_kbuf: [BUF]u8;

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

fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe { p = a as UserPtr<u8>; }
    return p;
}

fn report(label: *const u8, cycles: u64) -> void {
    uputs(label);
    fmt_put_dec(uputc, cycles);
    uputc(10); // '\n'
}

export fn m_main() -> void {
    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 2 * 1024 * 1024));
    var pt: PageTable = page_table_new(&heap);

    // Map PAGES contiguous user-accessible pages (PTE_U | R | W), each backed by a real frame.
    var i: usize = 0;
    while i < PAGES {
        let frame: PAddr = heap_alloc(&heap, PAGE, PAGE);
        page_table_map(&pt, &heap, va(USER_VA + i * PAGE), frame, PTE_R | PTE_W | PTE_U);
        i = i + 1;
    }

    let kbuf: PAddr = pa((&g_kbuf[0]) as usize);
    // Seed the kernel buffer so the copies move real bytes.
    mem_set(kbuf, 0xA5, BUF);

    var uas: UserAddrSpace = user_addr_space(&pt, 0, USER_VA + BUF);

    uputs("uaccess-bench booting (M-mode)\n");

    // --- copy_to_user_pt: kernel -> user, BUF bytes, ITERS times ---
    var bad: u32 = 0;
    let t0: u64 = rdcycle();
    i = 0;
    while i < ITERS {
        switch copy_to_user_pt(&uas, uptr(USER_VA), kbuf, BUF) {
            ok(v) => {}
            err(e) => { bad = 1; }
        }
        i = i + 1;
    }
    let t1: u64 = rdcycle();

    // --- copy_from_user_pt: user -> kernel, BUF bytes, ITERS times ---
    let f0: u64 = rdcycle();
    i = 0;
    while i < ITERS {
        switch copy_from_user_pt(&uas, kbuf, uptr(USER_VA), BUF) {
            ok(v) => {}
            err(e) => { bad = 1; }
        }
        i = i + 1;
    }
    let f1: u64 = rdcycle();

    // --- SMALL-copy regime: the common syscall shape (fetch a small struct / short buffer).
    // Here the per-call page-table walk dominates the tiny mem_copy, so the single-pass
    // (fewer walks per page) change is visible. SMALL_ITERS 8-byte copies through
    // copy_from_user_pt (1 page, 1 walk on the fast path vs 2 in the old re-validate+translate).
    let small_len: usize = 8;
    let s0: u64 = rdcycle();
    i = 0;
    while i < SMALL_ITERS {
        switch copy_from_user_pt(&uas, kbuf, uptr(USER_VA), small_len) {
            ok(v) => {}
            err(e) => { bad = 1; }
        }
        i = i + 1;
    }
    let s1: u64 = rdcycle();

    if bad != 0 {
        uputs("UACCESS-BENCH-BAD\n");
        halt();
    }

    report("UACCESS-TO-CYCLES ", t1 - t0);
    report("UACCESS-FROM-CYCLES ", f1 - f0);
    report("UACCESS-SMALL-CYCLES ", s1 - s0);
    report("UACCESS-CYCLES ", (t1 - t0) + (f1 - f0));

    uputs("UACCESS-BENCH-DONE\n");
    halt();
}

#[naked]
#[section(".text.start")]
export fn _start() -> void {
    asm opaque volatile {
        "la sp, _stack_top\n call m_main\n 1: j 1b"
    }
}
