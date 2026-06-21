// tests/arm/vm_arm_demo — AArch64 stage-1 EL1 4 KiB-granule paging proof of life.
//
// Build a FRESH page table via kernel/arch/aarch64/paging:
//   * identity-map low RAM (QEMU virt RAM base = 0x40000000) with 2 MiB blocks (L2 block
//     leaves) so the running kernel — linked at 0x40000000, with text/data/stack and the
//     page-table heap all in low RAM — STAYS mapped when the MMU turns on (otherwise the next
//     instruction fetch faults);
//   * map the PL011 UART page (0x09000000) as Device memory so prints survive MMU enable;
//   * map one CHOSEN high test VA (translation-only, outside the identity range) to a freshly-
//     allocated frame holding a sentinel value.
//
// Returns the TTBR0_EL1 root that activates this table, plus a software self-check
// (page_table_lookup over the built table, BEFORE any MMU enable) asserting that
// translate(DEMO_TEST_VA) == sentinel frame, that the kernel leaf is NOT EL0-accessible, and that
// the UART/identity sanity translations hold. The runtime then enables the MMU and reads the
// sentinel back THROUGH DEMO_TEST_VA, so a correct readback proves the tables translate in hardware.
//
// Results flow back through caller-provided out-pointers (no by-value struct return across the
// C FFI — the >16-byte sret ABI diverges between MC's C and LLVM backends).

import "kernel/arch/aarch64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const DEMO_RAM_BASE: usize = 0x4000_0000;       // QEMU virt RAM base
const DEMO_IDENTITY_LEN: usize = 0x400_0000;    // identity-map 64 MiB of low RAM as 2 MiB blocks
const DEMO_BLOCK_2MIB: usize = 0x20_0000;       // 2 MiB
const DEMO_UART_PA: usize = 0x0900_0000;        // PL011 UART (Device memory)
const DEMO_TEST_VA: usize = 0x10_0000_0000;     // 64 GiB — translation-only, outside identity
const DEMO_TEST_VALUE: u32 = 0xCAFE_BABE;

// Build the page table and report results through caller-provided out-pointers. Writes the
// TTBR0_EL1 root to activate and the physical frame DEMO_TEST_VA resolves to, and RETURNS a
// software-walk verdict computed before MMU enable (1 = software translate matched and the
// kernel page is correctly non-user; 0 = software walk disagreed).
export fn vm_arm_build(region_base: usize, region_len: usize, out_ttbr0: *mut u64, out_test_phys: *mut u64) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    var pt: PageTable = page_table_new(&heap);

    // Identity-map low RAM with 2 MiB blocks. Kernel Normal-memory RWX (PXN=0 so the text it
    // executes is fetchable through these blocks); NOT EL0-accessible (AP=0b00).
    var off: usize = 0;
    while off < DEMO_IDENTITY_LEN {
        let addr: usize = DEMO_RAM_BASE + off;
        page_table_map_block_2mib(&pt, &heap, va(addr), pa(addr), FLAGS_KERNEL_RWX);
        off = off + DEMO_BLOCK_2MIB;
    }

    // Map the PL011 UART page as Device memory (kernel RW, no execute) so prints survive.
    page_table_map(&pt, &heap, va(DEMO_UART_PA), pa(DEMO_UART_PA), FLAGS_DEVICE);

    // A test frame with a known sentinel, mapped at a translation-only high VA (kernel data).
    let tf: PAddr = heap_alloc(&heap, 4096, 4096);
    unsafe {
        raw.store<u32>(tf, DEMO_TEST_VALUE);
    }
    page_table_map(&pt, &heap, va(DEMO_TEST_VA), tf, FLAGS_KERNEL_DATA);

    // --- software self-check over the built table, BEFORE any MMU enable ---
    var sw_ok: u32 = 1;
    switch page_table_lookup(&pt, va(DEMO_TEST_VA)) {
        ok(m) => {
            if !pa_eq(mapping_phys(&m), tf) { sw_ok = 0; } // translate must hit the frame
            if mapping_is_user(&m) { sw_ok = 0; }          // kernel leaf must NOT be EL0-accessible
        }
        err(e) => { sw_ok = 0; } // DEMO_TEST_VA must resolve in the freshly built table
    }
    // Sanity: a low identity VA must translate to itself (2 MiB block path), kernel-only.
    let probe: usize = DEMO_RAM_BASE + 0x20_0000; // 2 MiB into RAM
    switch page_table_lookup(&pt, va(probe)) {
        ok(m) => {
            if !pa_eq(mapping_phys(&m), pa(probe)) { sw_ok = 0; }
            if mapping_is_user(&m) { sw_ok = 0; }
        }
        err(e) => { sw_ok = 0; }
    }
    // Sanity: the UART page must translate to itself.
    switch page_table_lookup(&pt, va(DEMO_UART_PA)) {
        ok(m) => {
            if !pa_eq(mapping_phys(&m), pa(DEMO_UART_PA)) { sw_ok = 0; }
        }
        err(e) => { sw_ok = 0; }
    }

    *out_ttbr0 = page_table_ttbr0(&pt);
    *out_test_phys = pa_value(tf) as u64;
    return sw_ok;
}
