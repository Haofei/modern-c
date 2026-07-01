// Bare-metal riscv64 M-mode correctness gate for the word-aligned mem ops
// (Phase 1.1 of the performance refactor). Self-contained: boots `-bios none`,
// exercises std/mem's mem_copy/mem_set AND the freestanding C-ABI memcpy/memmove/
// memset (provided by the linked kernel/lib/freestanding.mc object), and asserts
// byte-exact results across the tricky lengths and alignments the word path splits
// on: 0,1,7,8,9,15,16,4096, aligned + misaligned src/dst (offset 1,3,7), and
// memmove overlap in both directions.
//
// Verdict over the bare 16550 UART: MEM-OK (all pass) / MEM-BAD (a mismatch) /
// MEM-TRAP (an unexpected fault — e.g. an unaligned u64 access on the word path).
//
// The freestanding mem* symbols are declared `extern` here (not imported) so this
// unit does not re-define them — the harness links kernel/lib/freestanding.mc,
// whose word-aligned bodies are the whole point of the test.

import "std/addr.mc";
import "std/mem.mc";
import "tests/qemu/lib/test_report.mc";

const RT_FINISHER: usize = 0x0010_0000; // SiFive test finisher
const RT_FINISHER_HALT: u32 = 0x5555;

// Word-aligned freestanding libc under test (linked from kernel/lib/freestanding.mc).
extern fn memcpy(d: usize, s: usize, n: usize) -> usize;
extern fn memmove(d: usize, s: usize, n: usize) -> usize;
extern fn memset(d: usize, c: i32, n: usize) -> usize;

// Backing buffers. Over-sized so offset (up to 7) + max len (4096) + guard fit.
const BUF_BYTES: usize = 4096 + 64;
const MV_BYTES: usize = 4096 + 128;
global src_buf: [BUF_BYTES + 8]u8;
global dst_buf: [BUF_BYTES + 8]u8;
global mv_buf: [MV_BYTES + 8]u8;

fn halt() -> void {
    unsafe { raw.store<u32>(phys(RT_FINISHER), RT_FINISHER_HALT); }
    while true {}
}

// A deterministic, position-dependent byte pattern (distinct per index mod 256).
fn pat(i: usize) -> u8 {
    return (((i * 31) + 7) & 0xFF) as u8;
}

fn rb(addr: usize) -> u8 {
    var b: u8 = 0;
    unsafe { b = raw.load<u8>(phys(addr)); }
    return b;
}
fn wb(addr: usize, v: u8) -> void {
    unsafe { raw.store<u8>(phys(addr), v); }
}

// Fill [base, base+len) with the pattern.
fn fill_pat(base: usize, len: usize) -> void {
    var j: usize = 0;
    while j < len {
        wb(base + j, pat(j));
        j = j + 1;
    }
}

// Zero [base, base+len) directly (independent of the code under test).
fn zero(base: usize, len: usize) -> void {
    var j: usize = 0;
    while j < len {
        wb(base + j, 0);
        j = j + 1;
    }
}

// One copy case for kind 0 = std mem_copy, kind 1 = freestanding memcpy. Uses two
// disjoint buffers (no overlap). Verifies the copied range byte-exact and that the
// bytes immediately before/after the destination were NOT touched.
fn copy_case(kind: u32, len: usize, s_off: usize, d_off: usize) -> bool {
    let src_base: usize = ((&src_buf[0]) as usize) + s_off;
    let dst_base: usize = ((&dst_buf[0]) as usize) + d_off;

    zero((&src_buf[0]) as usize, BUF_BYTES);
    zero((&dst_buf[0]) as usize, BUF_BYTES);
    fill_pat(src_base, len);

    if kind == 0 {
        mem_copy(pa(dst_base), pa(src_base), len);
    } else {
        let r: usize = memcpy(dst_base, src_base, len);
        if r != dst_base {
            return false; // memcpy must return dst
        }
    }

    // Copied range is byte-exact.
    var j: usize = 0;
    while j < len {
        if rb(dst_base + j) != pat(j) {
            return false;
        }
        j = j + 1;
    }
    // No overrun before / after the destination window.
    if d_off > 0 {
        if rb(dst_base - 1) != 0 {
            return false;
        }
    }
    if rb(dst_base + len) != 0 {
        return false;
    }
    return true;
}

// One mem_set / memset case. Fills a pre-poisoned window with `val` and checks
// byte-exact fill + untouched neighbours. kind 0 = std mem_set, 1 = freestanding memset.
fn set_case(kind: u32, len: usize, d_off: usize, val: u8) -> bool {
    let dst_base: usize = ((&dst_buf[0]) as usize) + d_off;
    // Poison the whole buffer with a different byte so a missed fill byte shows.
    var p: usize = 0;
    while p < BUF_BYTES {
        wb(((&dst_buf[0]) as usize) + p, 0xAA);
        p = p + 1;
    }

    if kind == 0 {
        mem_set(pa(dst_base), val, len);
    } else {
        let r: usize = memset(dst_base, val as i32, len);
        if r != dst_base {
            return false;
        }
    }

    var j: usize = 0;
    while j < len {
        if rb(dst_base + j) != val {
            return false;
        }
        j = j + 1;
    }
    if d_off > 0 {
        if rb(dst_base - 1) != 0xAA {
            return false;
        }
    }
    if rb(dst_base + len) != 0xAA {
        return false;
    }
    return true;
}

// One memmove overlap case within a single buffer. `s_off`/`d_off` are offsets into
// mv_buf; ranges may overlap. After the move, dst[j] must equal the ORIGINAL src[j],
// which is pat(s_off_index + j) — computed from the formula, since the source bytes
// may be overwritten during an overlapping move.
fn move_case(len: usize, s_off: usize, d_off: usize) -> bool {
    let region: usize = (&mv_buf[0]) as usize;
    // Re-establish the pattern across the whole working span each time.
    fill_pat(region, MV_BYTES);

    let src_base: usize = region + s_off;
    let dst_base: usize = region + d_off;
    let r: usize = memmove(dst_base, src_base, len);
    if r != dst_base {
        return false;
    }

    var j: usize = 0;
    while j < len {
        // original src[j] lived at index (s_off + j) in the freshly-filled region.
        if rb(dst_base + j) != pat(s_off + j) {
            return false;
        }
        j = j + 1;
    }
    return true;
}

// The four boundary offsets (0 aligned; 1/3/7 misaligned) as an index helper.
fn off_at(k: u32) -> usize {
    if k == 0 { return 0; }
    if k == 1 { return 1; }
    if k == 2 { return 3; }
    return 7;
}

// The boundary lengths the word path splits on.
fn len_at(k: u32) -> usize {
    if k == 0 { return 0; }
    if k == 1 { return 1; }
    if k == 2 { return 7; }
    if k == 3 { return 8; }
    if k == 4 { return 9; }
    if k == 5 { return 15; }
    if k == 6 { return 16; }
    return 4096;
}

// Copy: both kinds × all lengths × all src/dst offsets.
fn run_copy_all() -> bool {
    var li: u32 = 0;
    while li < 8 {
        let len: usize = len_at(li);
        var si: u32 = 0;
        while si < 4 {
            var di: u32 = 0;
            while di < 4 {
                let so: usize = off_at(si);
                let doff: usize = off_at(di);
                if !copy_case(0, len, so, doff) { return false; }
                if !copy_case(1, len, so, doff) { return false; }
                di = di + 1;
            }
            si = si + 1;
        }
        li = li + 1;
    }
    return true;
}

// Set: both kinds × all lengths × all dst offsets, several fill values.
fn run_set_all() -> bool {
    var li: u32 = 0;
    while li < 8 {
        let len: usize = len_at(li);
        var di: u32 = 0;
        while di < 4 {
            let doff: usize = off_at(di);
            if !set_case(0, len, doff, 0x5C) { return false; }
            if !set_case(1, len, doff, 0x5C) { return false; }
            if !set_case(0, len, doff, 0x00) { return false; }
            if !set_case(1, len, doff, 0xFF) { return false; }
            di = di + 1;
        }
        li = li + 1;
    }
    return true;
}

// memmove overlap, both directions + non-overlap + d==s, across lengths.
fn run_move_all() -> bool {
    var li: u32 = 0;
    while li < 8 {
        let len: usize = len_at(li);
        // dst > src, overlapping (internal backward copy). shift by 3 (misaligned pair).
        if !move_case(len, 0, 3) { return false; }
        // dst < src, overlapping (internal forward copy).
        if !move_case(len, 3, 0) { return false; }
        // aligned overlapping pair (word path): shift by 8.
        if !move_case(len, 8, 0) { return false; }
        if !move_case(len, 0, 8) { return false; }
        // non-overlapping and degenerate d==s.
        if !move_case(len, 0, 2048) { return false; }
        if !move_case(len, 16, 16) { return false; }
        li = li + 1;
    }
    return true;
}

// Run every combination; return 1 iff all pass.
export fn mem_ops_run() -> u32 {
    if !run_copy_all() { return 0; }
    if !run_set_all() { return 0; }
    if !run_move_all() { return 0; }
    return 1;
}

// ---- M-mode boot + trap plumbing (mirrors the uaccess/redzone runtimes) ----

export fn on_trap() -> void {
    uputs("MEM-TRAP\n");
    halt();
}

#[naked]
#[section(".text.mtrap")]
export fn trap_vector() -> void {
    asm opaque volatile {
        "call on_trap\n 1: j 1b"
    }
}

export fn m_main() -> void {
    let vec: usize = (&trap_vector) as usize;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "csrw mtvec, %0"
                in("t0") vec: usize
            }
        }
    }
    uputs("mem-ops correctness gate booting (M-mode)\n");
    let r: u32 = mem_ops_run();
    if r == 1 {
        uputs("MEM-OK\n");
    } else {
        uputs("MEM-BAD\n");
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
