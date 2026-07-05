// QEMU boot demo for KASAN-style shadow-memory access-time UAF/OOB detection (D2.1).
//
// Compiled with `--checks=ksan`, so every raw.load/raw.store in this file is wrapped by
// the compiler with `mc_ksan_check(addr, size)`, which consults a shadow map and traps
// if the accessed bytes are poisoned. The KASAN heap (`heap_new_ksan`) poisons a block
// in the shadow on `heap_free` and unpoisons the user region on `heap_alloc`. So:
//
//   1. ksan_clean — alloc, write+read the user region in bounds (valid shadow), free.
//                   No access touches poison, so nothing traps.            -> KASAN-OK
//   2. ksan_uaf   — alloc, free, then READ the freed pointer. The read is an instrumented
//                   raw.load; the shadow byte for the freed block is poisoned, so
//                   mc_ksan_check traps BEFORE the load — access-time use-after-free
//                   detection (D2.4 redzones would NOT catch this: nothing is freed-then-
//                   accessed there, and free already succeeded).            -> trap
//   3. ksan_oob   — alloc N, then READ at offset N (one past the user region). That byte
//                   lies in the trailing redzone, poisoned in the shadow, so the
//                   instrumented load traps — access-time out-of-bounds.    -> trap
//
// The detection is real: mc_ksan_check reads the shadow byte for the exact address being
// dereferenced and traps via the language `unreachable`/`__builtin_trap`. The clean path
// never reaches a poisoned byte, so it never traps.

import "std/addr.mc";
import "kernel/core/heap.mc";

// A small struct laid over a heap block, used to prove the sanitizer now sees a struct-FIELD
// access that does NOT go through raw.load/raw.store. Reading `node.value` lowers to an ordinary
// struct-field load (a comma-expression `mc_ksan_check` wrap on the C backend / an instrumented
// `load` on LLVM) — exactly the path that was INVISIBLE to KASAN before this change. With the
// field instrumentation, that load now calls mc_ksan_check, so a use-after-free reached through
// a field traps at access time.
struct Node {
    value: u32,
}

// ---- 1. clean path: in-bounds use of a KASAN allocation ----
export fn ksan_clean(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_ksan(phys_range(pa(region), len));

    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);

    // In-bounds writes then reads of the user region — all valid shadow, no trap.
    var i: usize = 0;
    while i < n {
        unsafe {
            raw.store<u8>(pa_offset(p, i), 0x41);
        }
        i = i + 1;
    }
    var sum: u32 = 0;
    i = 0;
    while i < n {
        unsafe {
            sum = sum + (raw.load<u8>(pa_offset(p, i)) as u32);
        }
        i = i + 1;
    }

    heap_free(&h, p, n);
    if sum == 0 {
        return 0; // we wrote 0x41s; a zero sum would mean the reads were wrong
    }
    return 1;
}

// ---- 2. use-after-free: a real read of freed memory traps at access time ----
// Returns only if the shadow check did NOT fire (a failure); on a real UAF read the
// instrumented load traps and this never returns.
export fn ksan_uaf(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_ksan(phys_range(pa(region), len));

    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);
    heap_free(&h, p, n); // poisons [p-rz, p+n+rz) in the shadow

    // USE AFTER FREE: read the freed pointer. mc_ksan_check sees poisoned shadow -> trap.
    var v: u8 = 0;
    unsafe {
        v = raw.load<u8>(p);
    }
    return v as u32; // unreachable if detection works
}

// ---- 3. out-of-bounds: a read one past the user region traps at access time ----
export fn ksan_oob(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_ksan(phys_range(pa(region), len));

    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);

    // OUT OF BOUNDS: read at offset n (one past the user region) — lands in the trailing
    // redzone, poisoned in the shadow. The instrumented load traps.
    var v: u8 = 0;
    unsafe {
        v = raw.load<u8>(pa_offset(p, n));
    }
    return v as u32; // unreachable if detection works
}

// ---- 4. use-after-free through a STRUCT FIELD (not raw.load) ----
// Alloc a block, overlay a Node on it, free it, then read `node.value` — an ordinary
// struct-field load, NOT a raw.load. Before this change that load was uninstrumented and the
// UAF was MISSED; now the field load calls mc_ksan_check and traps on the poisoned shadow.
export fn ksan_field_uaf(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_ksan(phys_range(pa(region), len));

    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);
    heap_free(&h, p, n); // poisons the block in the shadow

    var v: u32 = 0;
    unsafe {
        let node: *Node = raw.ptr<Node>(pa_value(p));
        v = node.value; // STRUCT-FIELD load of freed memory -> mc_ksan_check traps
    }
    return v; // unreachable if detection works
}

// =====================================================================================
// PER-ACCESS-PATH VERIFICATION SCENARIOS (empirical coverage audit).
// Each scenario performs a bad (use-after-free / out-of-bounds) access through ONE access
// path. The runtime arms+poisons the shadow, then calls the scenario; if the instrumentation
// hooked that path the access traps (KASAN-DETECTED), otherwise the function returns and the
// driver prints a *-MISSED marker. This turns the doc's read-the-code claims into observed
// trap/no-trap facts.
// =====================================================================================

// ---- pointer struct-field STORE to freed memory (doc claims MISS: emitAssignTarget
//      suppresses the load hook, and there is no store hook on the field path) ----
export fn ksan_field_store(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_ksan(phys_range(pa(region), len));
    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);
    heap_free(&h, p, n); // poison the block
    unsafe {
        let node: *Node = raw.ptr<Node>(pa_value(p));
        node.value = 0xCAFE; // STRUCT-FIELD store of freed memory
    }
    return 1; // reached iff the store was NOT instrumented (a MISS)
}

// ---- array-index LOAD of freed memory through a struct-field array (doc claims DETECT) ----
struct Arr {
    cells: [16]u32,
}
export fn ksan_arr_load(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_ksan(phys_range(pa(region), len));
    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);
    heap_free(&h, p, n); // poison the block
    var v: u32 = 0;
    unsafe {
        let a: *Arr = raw.ptr<Arr>(pa_value(p));
        v = a.cells[3]; // ARRAY-INDEX load of freed memory
    }
    return v; // unreachable if detection works
}

// ---- array-index STORE to freed memory (doc claims MISS) ----
export fn ksan_arr_store(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_ksan(phys_range(pa(region), len));
    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);
    heap_free(&h, p, n); // poison the block
    unsafe {
        let a: *Arr = raw.ptr<Arr>(pa_value(p));
        a.cells[3] = 0xBEEF; // ARRAY-INDEX store of freed memory
    }
    return 1; // reached iff the array store was NOT instrumented (a MISS)
}

// ---- scalar GLOBAL load (doc claims DETECT: a scalar global read lowers to mc_race_load_*,
//      which carries mc_ksan_check). The runtime arms+poisons the shadow over &ksan_global,
//      so the instrumented read of a poisoned global must trap. ----
global ksan_global: u32 = 0xABCD;
// The runtime arms+poisons the shadow over &ksan_global; since the emitted global is `static`
// (file-local), expose its address from MC so the C driver can target it.
export fn ksan_global_address() -> usize {
    return (&ksan_global) as usize;
}
export fn ksan_global_load() -> u32 {
    return ksan_global; // mc_race_load_u32 -> mc_ksan_check(&ksan_global, 4) -> trap if poisoned
}

// ---- scalar GLOBAL store (doc claims DETECT: mc_race_store_* carries mc_ksan_check on the
//      non-msan ksan profile) ----
export fn ksan_global_store() -> u32 {
    ksan_global = 0x1234; // mc_race_store_u32 -> mc_ksan_check(&ksan_global, 4) -> trap if poisoned
    return 1; // reached iff the global store was NOT instrumented (a MISS)
}

// ---- stack LOCAL access (doc claims MISS: stack locals are plain C locals, never routed
//      through a hook, and their addresses are outside the armed pool anyway) ----
export fn ksan_stack_local() -> u32 {
    var x: u32 = 0;
    x = 7;
    return x; // ordinary local read/write; no hook -> always returns (a MISS by design)
}

// ---- access OUTSIDE the armed ksan pool (doc claims FAIL-OPEN: a UAF on memory the shadow
//      does not cover is waved through because mc_ksan_check returns early when addr is not in
//      [shadow_base, shadow_end)). The runtime arms the shadow over a DIFFERENT region than the
//      one this heap lives in, so the freed-read addr is out of shadow scope. ----
export fn ksan_outside_pool(region: usize, len: usize) -> u32 {
    var h: Heap = heap_new_ksan(phys_range(pa(region), len));
    let n: usize = 64;
    let p: PAddr = heap_alloc(&h, n, 16);
    heap_free(&h, p, n); // poison would happen, but shadow is armed elsewhere
    var v: u8 = 0;
    unsafe {
        v = raw.load<u8>(p); // UAF read, but addr is outside the armed shadow -> waved through
    }
    return v as u32; // reached iff the access was waved through (fail-open)
}
