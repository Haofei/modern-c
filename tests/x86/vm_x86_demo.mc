// tests/x86/vm_x86_demo — x86-64 4-level paging proof of life.
//
// Build a FRESH PML4 via kernel/arch/x86_64/paging:
//   * identity-map the low 1 GiB with 2 MiB huge pages (PD-level PTE_PS) so the running
//     kernel — loaded at 1 MiB, with text/data/stack/heap all under 1 GiB — STAYS mapped
//     when we load the new CR3 (otherwise the next instruction fetch faults);
//   * map one CHOSEN high test VA (3 GiB, reachable ONLY through translation, not covered
//     by the identity range) to a freshly-allocated frame holding a sentinel value.
//
// Returns the CR3 (PML4 physical address) that activates this table, plus a software
// self-check (page_table_lookup over the built table, BEFORE any CR3 reload) asserting
// vm_translate(TEST_VA) == sentinel frame AND the kernel leaf is NOT user-accessible.
// The runtime then loads CR3 and reads the sentinel back THROUGH TEST_VA, so a correct
// readback proves the page tables actually translate in hardware.

import "kernel/arch/x86_64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const DEMO_GIB: usize = 0x4000_0000;
const DEMO_HUGE_2MIB: usize = 0x20_0000;
const TEST_VA: usize = 0xC000_0000;     // 3 GiB — outside the identity-mapped low 1 GiB
const TEST_VALUE: u32 = 0xCAFE_BABE;

// x86 PTE flags re-declared locally as `pub` consts come through the import; reference the
// imported names directly. (PTE_P/PTE_W/PTE_US are module consts in paging.mc; the demo
// only needs the writable/user combos it passes to map calls, expressed via the API.)

// Build the page table and report results through caller-provided out-pointers (avoids a
// by-value struct return across the C FFI, whose System-V sret ABI differs between MC's two
// backends). Writes the CR3 to activate and the physical frame TEST_VA resolves to, and
// RETURNS a software-walk verdict computed before activation (1 = software translate matched
// and the kernel page is correctly non-user; 0 = software walk disagreed).
export fn vm_x86_build(region_base: usize, region_len: usize, out_cr3: *mut u64, out_test_phys: *mut u64) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    var pt: PageTable = page_table_new(&heap);

    // Identity-map the low 1 GiB with 2 MiB huge pages. Kernel-only: writable, NOT user
    // (we pass PTE_W only; US stays clear on the leaf, so mapping_is_user is false here).
    let kflags: u64 = 2; // PTE_W (present is added by the API); US clear => kernel page
    var off: usize = 0;
    while off < DEMO_GIB {
        page_table_map_2mib(&pt, &heap, va(off), pa(off), kflags);
        off = off + DEMO_HUGE_2MIB;
    }

    // A test frame with a known sentinel, mapped at a translation-only high VA.
    let tf: PAddr = heap_alloc(&heap, 4096, 4096);
    unsafe {
        raw.store<u32>(tf, TEST_VALUE);
    }
    page_table_map(&pt, &heap, va(TEST_VA), tf, kflags); // kernel page, writable

    // --- software self-check over the built table, BEFORE any CR3 reload ---
    var sw_ok: u32 = 1;
    switch page_table_lookup(&pt, va(TEST_VA)) {
        ok(m) => {
            if !pa_eq(mapping_phys(&m), tf) { sw_ok = 0; } // translate must hit the frame
            if mapping_is_user(&m) { sw_ok = 0; }          // kernel leaf must NOT be user
        }
        err(e) => { sw_ok = 0; } // TEST_VA must resolve in the freshly built table
    }
    // Sanity: a low identity VA must translate to itself (2 MiB huge-page path).
    switch page_table_lookup(&pt, va(0x10_0000)) { // 1 MiB
        ok(m) => {
            if !pa_eq(mapping_phys(&m), pa(0x10_0000)) { sw_ok = 0; }
            if mapping_is_user(&m) { sw_ok = 0; }
        }
        err(e) => { sw_ok = 0; }
    }

    *out_cr3 = page_table_cr3(&pt);
    *out_test_phys = pa_value(tf) as u64;
    return sw_ok;
}
