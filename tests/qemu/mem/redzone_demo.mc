// QEMU boot demo for the heap-redzone + stack-canary hardening (D2.4).
//
// The C runtime hands us a real, writable physical pool and calls these entry points
// in order, printing a marker after each:
//
//   1. redzone_clean    — redzoned heap: alloc, write *within* bounds, free. The
//                         guard bands stay intact, free succeeds, returns 1.  -> D2.4-OK
//   2. canary_demo      — arm a stack guard, smash it, guard_check must trap.  -> trap
//   3. redzone_overflow — redzoned heap: alloc, then write ONE byte past the user
//                         region (a genuine out-of-bounds store into the trailing
//                         redzone), then free. heap_free re-reads the poison, finds
//                         it clobbered, and traps.                            -> trap
//
// The detection is real: `heap_free`/`heap_check_block` read the guard bytes back
// from memory and compare against the poison pattern. The trap is the language's
// `unreachable`, which the runtime turns into a "DETECTED" print + halt. Nothing in
// the success path prints DETECTED, so the marker can only appear if a real OOB write
// was caught.

import "std/addr.mc";
import "kernel/core/heap.mc";
import "std/canary.mc";

// ---- 1. clean path: in-bounds use of a redzoned allocation ----
export fn redzone_clean(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_redzoned(phys_range(pa(region), len));

    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);

    // Write every byte of the user region (in bounds) — guards untouched.
    var i: usize = 0;
    while i < n {
        unsafe {
            raw.store<u8>(pa_offset(p, i), 0x41);
        }
        i = i + 1;
    }

    // An explicit mid-life check passes, and free passes (no trap).
    heap_check_block(&h, p, n);
    heap_free(&h, p, n);
    return 1;
}

// ---- 2. stack canary: a smashed guard is caught at the check point ----
// Returns only if the canary check did NOT fire (which would be a failure); on a
// real (smashed) guard, guard_check traps and this never returns.
export fn canary_demo() -> u32 {
    var g: StackGuard = guard_new();
    if !guard_ok(&g) {
        return 0; // fresh guard must be valid
    }
    guard_smash(&g);     // simulate an overflow clobbering the frame boundary
    guard_check(&g);     // must trap: canary corrupted
    return 0;            // unreachable if the check works
}

// ---- 3. overflow path: a real OOB write into the trailing redzone is detected ----
// Allocates `n` bytes, then stores at offset `n` (one past the user region) — a
// genuine buffer overflow into the trailing guard band — and frees. `heap_free`
// verifies the redzone, finds the poison byte overwritten, and traps. Never returns.
export fn redzone_overflow(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_redzoned(phys_range(pa(region), len));

    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);

    // Out-of-bounds write: one byte past the end of the user region. This lands in the
    // trailing redzone, overwriting a poison byte.
    unsafe {
        raw.store<u8>(pa_offset(p, n), 0x00);
    }

    heap_free(&h, p, n); // detects the clobbered redzone and traps
    return 0;            // unreachable if detection works
}
