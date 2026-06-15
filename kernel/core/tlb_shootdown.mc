// kernel/core/tlb_shootdown — the arch-neutral bookkeeping for a multi-core TLB shootdown.
//
// When one core changes a mapping (unmap / permission downgrade), every other core that may
// have cached the old translation must flush it before the change is considered complete. The
// IPI that wakes those cores and the actual TLB flush are per-architecture (kernel/arch/*);
// what is arch-neutral — and what a bug here corrupts memory safety — is the coordination: WHICH
// cores must flush, and waiting until they have all acknowledged. That is this module: a
// shootdown carries a `targets` core-mask (all cores but the initiator) and an `acked` mask, and
// is complete once every target has acked. Built on the checked `Mask32` bit-set.

import "std/mask.mc";
import "std/math.mc"; // wrapping_shl_u32

const TLB_MAX_CORES: u32 = 32; // a Mask32 tracks up to 32 cores

struct Shootdown {
    va: usize,       // start of the virtual range being flushed (provenance for the target cores)
    len: usize,      // length of the range
    targets: Mask32, // cores that must flush (every core except the initiator)
    acked: Mask32,   // cores that have flushed and acknowledged
}

// Begin a shootdown initiated by `initiator` across `ncores` cores for the range [va, va+len):
// every core but the initiator becomes a target, and none has acked yet.
export fn shootdown_begin(s: *mut Shootdown, initiator: u32, ncores: u32, va: usize, len: usize) -> void {
    s.va = va;
    s.len = len;
    s.targets = mask32_zero();
    s.acked = mask32_zero();
    var c: u32 = 0;
    while c < ncores {
        if c != initiator {
            mask32_set(&s.targets, c);
        }
        c = c + 1;
    }
}

// Record that `core` has flushed its TLB and acknowledged. A non-target ack is ignored (only
// target cores gate completion).
export fn shootdown_ack(s: *mut Shootdown, core: u32) -> void {
    if mask32_contains(&s.targets, core) {
        mask32_set(&s.acked, core);
    }
}

// The cores still outstanding: targets that have not yet acked.
fn shootdown_remaining(s: *mut Shootdown) -> u32 {
    return mask32_raw(&s.targets) & (~mask32_raw(&s.acked));
}

// How many target cores have not yet acked (0 = done).
export fn shootdown_pending(s: *mut Shootdown) -> u32 {
    let rem: u32 = shootdown_remaining(s);
    var n: u32 = 0;
    var b: u32 = 0;
    while b < TLB_MAX_CORES {
        if (rem & wrapping_shl_u32(1, b)) != 0 {
            n = n + 1;
        }
        b = b + 1;
    }
    return n;
}

// True once every target core has acknowledged — the initiator may proceed.
export fn shootdown_complete(s: *mut Shootdown) -> bool {
    return shootdown_remaining(s) == 0;
}
