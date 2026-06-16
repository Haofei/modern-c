// QEMU boot demo for KMSAN-style uninitialized-HEAP-memory-use detection (D2.2).
//
// Built on the D2.1 ksan shadow. Compiled with `--checks=msan`, so every raw.store in
// this file is wrapped by the compiler with `mc_ksan_store(addr, size)` (which marks the
// written bytes initialized in the shadow), and every raw.load is wrapped with
// `mc_ksan_check(addr, size)` (which, under the msan runtime, traps if the bytes are still
// UNINIT — never written since allocation — as well as freed/redzone-poisoned).
//
// The runtime hands out heap regions via `kmsan_alloc(size)`, which marks the returned
// region UNINIT in the shadow (allocated but never written). Then:
//
//   1. kmsan_clean — alloc, WRITE every byte (each store marks it initialized), then READ.
//                    Every read hits initialized shadow, so nothing traps.   -> KMSAN-OK
//   2. kmsan_uninit — alloc, then READ a byte WITHOUT writing it first. The read is an
//                    instrumented raw.load; its shadow byte is still UNINIT, so
//                    mc_ksan_check traps BEFORE the load — uninitialized-use detection. -> trap
//
// The detection is real: mc_ksan_check reads the shadow init-state byte for the exact
// address being dereferenced and traps via __builtin_trap. The clean path writes every byte
// before reading it, so its shadow is initialized and it never traps.

import "std/addr.mc";

// The runtime-provided bump allocator over the shadowed pool. Returns a fresh region of
// `size` bytes, marked UNINIT in the shadow. (Plain C in kmsan_runtime.c.)
extern fn kmsan_alloc(size: usize) -> usize;

// ---- 1. clean path: write-before-read of a fresh allocation ----
export fn kmsan_clean() -> u32 {
    let n: usize = 64;
    let p: usize = kmsan_alloc(n);

    // WRITE every byte first — each store marks its shadow byte initialized.
    var i: usize = 0;
    while i < n {
        unsafe {
            raw.store<u8>(pa_offset(pa(p), i), 0x41);
        }
        i = i + 1;
    }
    // Now READ them back — all initialized, no trap.
    var sum: u32 = 0;
    i = 0;
    while i < n {
        unsafe {
            sum = sum + (raw.load<u8>(pa_offset(pa(p), i)) as u32);
        }
        i = i + 1;
    }
    if sum == 0 {
        return 0; // we wrote 0x41s; a zero sum would mean the reads were wrong
    }
    return 1;
}

// ---- 2. uninitialized read: a read of never-written heap memory traps ----
// Returns only if the shadow check did NOT fire (a failure); on a real uninit read the
// instrumented load traps and this never returns.
export fn kmsan_uninit() -> u32 {
    let n: usize = 64;
    let p: usize = kmsan_alloc(n);

    // USE OF UNINIT: read a byte we never wrote. Its shadow is still UNINIT -> mc_ksan_check
    // traps before the load.
    var v: u8 = 0;
    unsafe {
        v = raw.load<u8>(pa_offset(pa(p), 8));
    }
    return v as u32; // unreachable if detection works
}
