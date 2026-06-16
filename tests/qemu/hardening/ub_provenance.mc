// UB class: pointer provenance (in C, forging a pointer from an integer, or out-of-object
// pointer arithmetic, has no defined provenance and is UB under the abstract machine).
// MC handling: DEFINED AWAY / CONTAINED by typed address classes — `PAddr` (std/addr) is an
// opaque physical-address class whose ONLY integer boundary is the explicit `pa(usize)` /
// `pa_value(PAddr)` pair; offsetting is `pa_offset` and differencing is `pa_diff`, which
// lower to plain `uintptr_t` arithmetic (well-defined; no pointer-provenance reliance).  The
// emitted C never depends on the abstract-machine provenance of a forged pointer.  This
// fixture stays within one backing object and round-trips an address through the class.
import "std/addr.mc";

global g_region: [8]u8;

export fn ub_provenance_run() -> u32 {
    var pass: u32 = 1;
    var i: usize = 0;
    while i < 8 { g_region[i] = (i as u8); i = i + 1; }

    let base: PAddr = pa((&g_region[0]) as usize);
    let third: PAddr = pa_offset(base, 3);            // within the object
    // pa_diff recovers the offset as plain uintptr_t arithmetic, no provenance laundering.
    if pa_diff(base, third) != 3 { pass = 0; }
    // The usize<->PAddr boundary is explicit and reversible within the object.
    if pa_value(third) != pa_value(base) + 3 { pass = 0; }
    return pass;
}
