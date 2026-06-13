// kernel/core/mmap — anonymous memory mapping. `mmap_anon` allocates a fresh page and
// maps it into a page table at a chosen virtual address, so that VA now resolves to new
// RAM; `munmap` removes the mapping. This is the kernel mechanism a process/VM server
// uses to grow address spaces on demand (vs the eager identity mapping).

import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const PAGE: usize = 4096;

// Map a fresh anonymous page at `virt` with `flags`; returns the backing frame, or a
// typed `MapError` (e.g. `AlreadyMapped`) if `virt` is already mapped — the caller
// chose the address, so a clash is a recoverable runtime condition, not a kernel bug.
export fn mmap_anon(pt: *mut PageTable, h: *mut Heap, virt: VAddr, flags: u64) -> Result<PAddr, MapError> {
    let frame: PAddr = heap_alloc(h, PAGE, PAGE);
    page_table_try_map(pt, h, virt, frame, flags)?; // propagate MisalignedAddress/AlreadyMapped/...
    return ok(frame);
}

// Remove a mapping; `virt` no longer resolves.
export fn munmap(pt: *mut PageTable, virt: VAddr) -> void {
    page_table_unmap(pt, virt);
}
