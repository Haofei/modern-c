// Page-table-aware user/kernel copies. Unlike the numeric `UserSpace` (which only
// range-checks against [base,limit)), `UserAddrSpace` translates every user virtual
// address through a real Sv39 page table and validates PTE_U + PTE_R/PTE_W page by
// page — so a kernel-only page, an unmapped hole, or a range that runs off the end of
// a mapped page is rejected and nothing is copied. The walk is in software (no satp),
// so this runs on the host harness.

import "kernel/core/uaccess.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

global g_pool: [131072]u8; // backs the page table + the mapped frames

const USER_VA: usize = 0x1000_0000;     // a user-accessible page
const KERN_VA: usize = 0x2000_0000;     // a kernel-only page (no PTE_U)
const UNMAPPED_VA: usize = 0x3000_0000; // never mapped
const N: usize = 8;

fn write_bytes(addr: PAddr, first: u8, n: usize) -> void {
    var i: usize = 0;
    while i < n {
        unsafe { raw.store<u8>(pa_offset(addr, i), first + (i as u8)); }
        i = i + 1;
    }
}

fn bytes_are(addr: PAddr, first: u8, n: usize) -> bool {
    var i: usize = 0;
    while i < n {
        var v: u8 = 0;
        unsafe { v = raw.load<u8>(pa_offset(addr, i)); }
        if v != (first + (i as u8)) {
            return false;
        }
        i = i + 1;
    }
    return true;
}

export fn uaccess_pt_run() -> u32 {
    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 131072));
    var pt: PageTable = page_table_new(&heap);
    var pass: u32 = 1;

    // A user page and a kernel-only page, each backed by a real frame.
    let uframe: PAddr = heap_alloc(&heap, 4096, 4096);
    let kframe: PAddr = heap_alloc(&heap, 4096, 4096);
    page_table_map(&pt, &heap, va(USER_VA), uframe, PTE_R | PTE_W | PTE_U); // user-accessible
    page_table_map(&pt, &heap, va(KERN_VA), kframe, PTE_R | PTE_W);         // no PTE_U

    let ksrc: PAddr = heap_alloc(&heap, 64, 8);
    let kdst: PAddr = heap_alloc(&heap, 64, 8);
    write_bytes(ksrc, 0xA0, N);

    var uas: UserAddrSpace = user_addr_space(&pt, 0, 0x4000_0000);

    // copy_to_user: the bytes must land in the user frame.
    switch copy_to_user_pt(&uas, USER_VA as UserPtr<u8>, ksrc, N) {
        ok(v) => { if !bytes_are(uframe, 0xA0, N) { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // copy_from_user: read the same bytes back into a kernel buffer.
    switch copy_from_user_pt(&uas, kdst, USER_VA as UserPtr<u8>, N) {
        ok(v) => { if !bytes_are(kdst, 0xA0, N) { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // The remaining cases must all FAIL CLOSED: the call returns an error and copies
    // nothing. We stamp the buffers with a sentinel and require them untouched.
    write_bytes(kdst, 0x5A, N);
    write_bytes(kframe, 0x5A, N); // the kernel-only frame's current contents

    // A kernel-only page (no PTE_U) must be rejected (NotUserPage); its frame is not
    // written even though the source `ksrc` holds different bytes.
    switch copy_to_user_pt(&uas, KERN_VA as UserPtr<u8>, ksrc, N) {
        ok(v) => { pass = 0; }
        err(e) => { if !bytes_are(kframe, 0x5A, N) { pass = 0; } } // rejected: kframe untouched
    }

    // An unmapped VA must be rejected (NotMapped); the kernel dst stays the sentinel.
    switch copy_from_user_pt(&uas, kdst, UNMAPPED_VA as UserPtr<u8>, N) {
        ok(v) => { pass = 0; }
        err(e) => { if !bytes_are(kdst, 0x5A, N) { pass = 0; } } // nothing copied in
    }

    // A range that starts in the mapped user page but runs off its end into the next
    // (unmapped) page must be rejected wholesale — nothing copied (the sentinel holds).
    let straddle: usize = USER_VA + 4096 - 4;
    switch copy_from_user_pt(&uas, kdst, straddle as UserPtr<u8>, N) {
        ok(v) => { pass = 0; }
        err(e) => { if !bytes_are(kdst, 0x5A, N) { pass = 0; } }
    }

    return pass;
}
