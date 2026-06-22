// Host-native logic test for the Sv39 page-table implementation
// (kernel/arch/riscv64/paging.mc). The page-table math — three-level walk, PTE
// encode/decode, interior-table allocation, translate/unmap — is fully portable;
// only `sfence_vma_page` contains a riscv `sfence.vma`, which the host assembler
// cannot encode. The harness (tools/mem/paging-test.sh) compiles this module with
// `--stub-asm` so that one instruction lowers to a host-neutral stub (a TLB fence is
// a no-op for this single-threaded host test), then links the trivial C harness in
// paging-test.sh that supplies a physical pool and the trap stubs.
//
// Keeping the driver in MC means NO C-side struct mirroring: the `Heap` (whose layout
// — a 64-entry free list plus the redzone/ksan profile fields — drifts as the
// allocator evolves) and `PageTable` live entirely inside MC. The C side only sees
// `paging_host_test(pool_start, pool_len) -> u32`. Returns 0 on success, or a nonzero
// code identifying the first failed check so a failure points at the exact assertion.

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const R: u64 = 2; // PTE readable
const W: u64 = 4; // PTE writable
const X: u64 = 8; // PTE executable

// Build a page table over `[pool_start, pool_start+pool_len)` and exercise the Sv39
// map / translate / unmap paths over multiple top-level regions and shared interior
// tables. The pool plays the role of physical memory the heap carves table frames from.
export fn paging_host_test(pool_start: usize, pool_len: usize) -> u32 {
    let rng: PhysRange = phys_range(pa(pool_start), pool_len);
    var h: Heap = heap_new(rng);
    var pt: PageTable = page_table_new(&h);

    let v0: usize = 0x1000_0000;
    let p0: usize = 0x8020_0000;
    page_table_map(&pt, &h, va(v0), pa(p0), R | W | X);
    if pa_value(page_table_translate(&pt, va(v0))) != p0 { return 1; }
    // Page offset preserved through translation.
    if pa_value(page_table_translate(&pt, va(v0 + 0x123))) != p0 + 0x123 { return 2; }

    // A second mapping in a different top-level region (allocates new interior tables).
    page_table_map(&pt, &h, va(0x4000_0000), pa(0x8030_0000), R);
    if pa_value(page_table_translate(&pt, va(0x4000_0000))) != 0x8030_0000 { return 3; }
    if pa_value(page_table_translate(&pt, va(v0))) != p0 { return 4; } // first still valid

    // An adjacent page in the same region (shares the interior tables).
    page_table_map(&pt, &h, va(v0 + 0x1000), pa(p0 + 0x5000), R | W);
    if pa_value(page_table_translate(&pt, va(v0 + 0x1000))) != p0 + 0x5000 { return 5; }
    if pa_value(page_table_translate(&pt, va(v0))) != p0 { return 6; }

    // Unmap one page; its neighbour (sharing interior tables) stays mapped.
    if !page_table_is_mapped(&pt, va(v0)) { return 7; }
    page_table_unmap(&pt, va(v0));
    if page_table_is_mapped(&pt, va(v0)) { return 8; }
    if !page_table_is_mapped(&pt, va(v0 + 0x1000)) { return 9; }
    if pa_value(page_table_translate(&pt, va(v0 + 0x1000))) != p0 + 0x5000 { return 10; }

    return 0;
}
