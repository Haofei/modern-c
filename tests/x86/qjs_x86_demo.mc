// M7 "confined QuickJS agent on x86_64 ring-3" — MC side.
//
// The x86-64 analogue of tests/qemu/arch/qjs_smode_demo.mc (RISC-V M3). It is the same
// composition the S-mode fixture is — a real multi-segment ELF loader + the QuickJS syscall
// ABI (SYS_WRITE / SYS_READ §0 ingress / SYS_GETPID / SYS_SUBMIT / SYS_POLL + the mock
// broker) + a confinement proof — but built on the x86-64 paging stack rather than RISC-V:
//   - the loader is the GENERIC kernel/core/elf_loader.mc and user-copy is the GENERIC
//     kernel/core/uaccess_pt.mc; both resolve x86-64 paging via the arch-selection seam
//     (compiled with --arch=x86_64, R0b). Arch-specific leaf-PTE bits come from the paging
//     module's pte_flags_for_user hook;
//   - console output goes through an EXTERN mc_console_putc the x86 C runtime provides over
//     COM1 port-IO (the riscv path writes the 16550 UART MMIO via console.mc); since COM1 is
//     port-IO, the agent's user CR3 needs NO MMIO page (unlike the riscv S-mode fixture);
//   - the address space is built like M6's user_x86_demo.mc: app_build_x86 loads the agent's
//     own user pages, then adds the kernel's low-1-GiB identity window as SUPERVISOR-ONLY
//     2 MiB pages (PTE_W, no PTE_US) so the long-mode kernel + trap path survive the CR3
//     reload while staying unreachable from ring 3. The confinement proof is M6's "kernel
//     mapped but NOT user".
//
// app_build_x86 returns the CR3 (PML4 phys) through an out-pointer — no satp, and no
// >16-byte by-value struct return across the C-FFI boundary (the X2/M6 ABI note). All
// fixture-local consts/symbols are prefixed (QX_/qx_/app_*_x86) to avoid emit-c const-flatten
// collisions; there is no riscv app_run_demo imported here, so the names are fully disjoint.

import "kernel/core/elf_loader.mc"; // generic loader; arch PTE flags via --arch=x86_64
import "kernel/arch/x86_64/paging.mc";
import "kernel/core/heap.mc";
import "kernel/core/syscall.mc";
import "kernel/core/uaccess_pt.mc"; // arch-neutral page-table uaccess (resolves x86 paging via --arch)
import "std/addr.mc";
import "user/abi.mc"; // SYS_* numbers + E_* + ToolReq/ToolEvent — the single ABI source of truth

// The agent ELF is linked at 1 GiB (user_qjs_x86.ld), ABOVE the kernel's low-1-GiB supervisor
// identity window, so the agent's user VAs never collide with the kernel's supervisor pages.
const QX_USER_BASE: usize = 0x4000_0000;
// Upper bound for uaccess validation: must cover the agent's whole VA span from USER_BASE
// (multi-MiB engine image + the 8 MiB malloc arena + the 512 KiB stack, all in .bss right after
// the image). 1 GiB + 32 MiB gives ample headroom above the agent's top.
const QX_USER_LIMIT: usize = 0x4000_0000 + 0x0200_0000;
const QX_KBUF: usize = 256;
const QX_AGENT_PID: u64 = 7;
const QX_COMP_CAP: usize = 8;

// The kernel's low identity window (text/data/stack/heap/IDT/GDT + the frame `region` pool all
// live under 1 GiB), mapped supervisor-only (PTE_W, NO PTE_US) so the kernel survives the CR3
// reload yet ring 3 cannot reach it. 2 MiB huge pages, exactly like M6's user_x86_demo.mc. The
// agent sits at >= 1 GiB, so this whole window is the kernel's alone — no overlap, no skipping.
const QX_KERNEL_GIB: usize = 0x4000_0000;
const QX_HUGE_2MIB: usize = 0x20_0000;

// app_build status codes (typed LoadError preserved across the u64-CR3 C ABI boundary).
const QX_LS_OK: u32 = 0;
const QX_LS_BADELF: u32 = 1;
const QX_LS_TOOMANY: u32 = 2;
const QX_LS_NOFRAME: u32 = 3;
const QX_LS_BADSEG: u32 = 4;

global qx_heap: Heap;
global qx_pt: PageTable;
global qx_uas: UserAddrSpace;
global qx_syscalls: SyscallTable;
global qx_kbuf: [QX_KBUF]u8;
global qx_entry: u64;
global qx_load_status: u32;

// Result-payload buffer sizes (mirror MAX_REQ_BYTES / MAX_RES_BYTES).
const QX_REQ_BYTES: usize = 256;
const QX_RES_BYTES: usize = 256;
const QX_DELAY_MAX: u64 = 64;

global qx_slot_active: [QX_COMP_CAP]bool;
global qx_slot_id: [QX_COMP_CAP]u64;
global qx_slot_status: [QX_COMP_CAP]i32;
global qx_slot_result: [QX_COMP_CAP]i32;
global qx_slot_outptr: [QX_COMP_CAP]u64;
global qx_slot_outcap: [QX_COMP_CAP]u32;
global qx_slot_outlen: [QX_COMP_CAP]u32;
global qx_slot_res: [QX_COMP_CAP][QX_RES_BYTES]u8;
global qx_slot_ready: [QX_COMP_CAP]u64;
global qx_clock: u64;
global qx_active_count: usize;
global qx_next_req: u64;
global qx_reqbuf: [QX_REQ_BYTES]u8;

// The x86 console: COM1 port-IO, provided by the C runtime (qjs_user_runtime.c). Unlike riscv's
// MMIO console_putc, this is an extern — so no MMIO page is mapped in the agent's CR3.
extern fn mc_console_putc(c: u8) -> void;

fn qx_free_slot() -> usize {
    var i: usize = 0;
    while i < QX_COMP_CAP {
        if !qx_slot_active[i] {
            return i;
        }
        i = i + 1;
    }
    return QX_COMP_CAP;
}

fn qx_slot_by_id(target: u64) -> usize {
    var i: usize = 0;
    while i < QX_COMP_CAP {
        if qx_slot_active[i] && qx_slot_id[i] == target {
            return i;
        }
        i = i + 1;
    }
    return QX_COMP_CAP;
}

// Forge a UserPtr<u8> from a user-supplied integer address (the uaccess idiom): re-tagging an
// int into the UserPtr class needs `unsafe`; copy_*_user_pt still validates it per-page.
fn qx_uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe {
        p = a as UserPtr<u8>;
    }
    return p;
}

// SYS_WRITE(fd, buf, len): copy the user buffer in through the agent's page table, emit it via
// COM1. Returns bytes written, or -E_FAULT on a bad user pointer.
fn qx_sys_write(fd: u64, buf: u64, len: u64) -> u64 {
    var n: usize = len as usize;
    if n > QX_KBUF {
        n = QX_KBUF;
    }
    let dst: PAddr = pa((&qx_kbuf[0]) as usize);
    switch copy_from_user_pt(&qx_uas, dst, qx_uptr(buf as usize), n) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }
    var i: usize = 0;
    while i < n {
        mc_console_putc(qx_kbuf[i]);
        i = i + 1;
    }
    return n as u64;
}

fn qx_sys_getpid(a: u64, b: u64, c: u64) -> u64 {
    return QX_AGENT_PID;
}

// The agent source the kernel holds (embedded by the harness): returns its kernel address and
// length. A weak default in the C runtime returns nothing for tests that embed no agent.
extern fn mc_agent_source(out_len: *mut usize) -> usize;

// SYS_READ(buf, max): §0 ingress — copy the kernel-held agent source into the agent's buffer
// (through its page table), capped at `max`. Returns bytes delivered.
fn qx_sys_read(buf: u64, max: u64, c: u64) -> u64 {
    var src_len: usize = 0;
    let src_addr: usize = mc_agent_source(&src_len);
    if src_addr == 0 || src_len == 0 {
        return 0;
    }
    var n: usize = src_len;
    if n > (max as usize) {
        n = max as usize;
    }
    switch copy_to_user_pt(&qx_uas, qx_uptr(buf as usize), pa(src_addr), n) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }
    return n as u64;
}

// SYS_SUBMIT(req_ptr): start a non-blocking mock tool op described by a ToolReq the agent points
// at. Snapshot-copy the struct in, validate payload sizes against the hard quotas, copy the
// request payload into a bounded kernel buffer, arm a completion slot with a delay-driven ready
// tick (so completions can arrive out of submit order). Returns the request id, or a -errno.
fn qx_sys_submit(req_ptr: u64, b: u64, c: u64) -> u64 {
    var req: ToolReq = uninit;
    let rsz: usize = sizeof(ToolReq);
    switch copy_from_user_pt(&qx_uas, pa((&req) as usize), qx_uptr(req_ptr as usize), rsz) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }

    if req.in_len > MAX_REQ_BYTES {
        return bitcast<u64>(E_NOCAP);
    }
    if req.out_cap > MAX_RES_BYTES {
        return bitcast<u64>(E_NOCAP);
    }

    if req.op == TOOL_OP_CANCEL {
        let s: usize = qx_slot_by_id(req.arg);
        if s == QX_COMP_CAP {
            return bitcast<u64>(E_DENIED);
        }
        qx_slot_status[s] = E_CANCELED as i32;
        qx_slot_result[s] = 0;
        qx_slot_outlen[s] = 0;
        qx_slot_ready[s] = qx_clock;
        return 0;
    }

    if req.op != TOOL_OP_SUM && req.op != TOOL_OP_ECHO && req.op != TOOL_OP_TIMEOUT && req.op != TOOL_OP_SPURIOUS {
        return bitcast<u64>(E_DENIED);
    }

    let slot: usize = qx_free_slot();
    if slot == QX_COMP_CAP {
        return bitcast<u64>(E_AGAIN);
    }

    let in_len: usize = req.in_len as usize;
    if in_len > 0 {
        switch copy_from_user_pt(&qx_uas, pa((&qx_reqbuf[0]) as usize), qx_uptr(req.in_ptr as usize), in_len) {
            ok(v) => {}
            err(e) => { return bitcast<u64>(E_FAULT); }
        }
    }

    let id: u64 = qx_next_req;
    qx_next_req = qx_next_req + 1;
    var delay: u64 = req.flags as u64;
    if delay > QX_DELAY_MAX {
        delay = QX_DELAY_MAX;
    }
    qx_slot_active[slot] = true;
    qx_slot_id[slot] = id;
    qx_slot_status[slot] = 0;
    qx_slot_outptr[slot] = req.out_ptr;
    qx_slot_outcap[slot] = req.out_cap;
    qx_slot_outlen[slot] = 0;
    qx_slot_ready[slot] = qx_clock + delay;
    qx_active_count = qx_active_count + 1;

    if req.op == TOOL_OP_SUM {
        let mask: u64 = 0x7FFF_FFFF;
        let a32: u32 = (req.arg & mask) as u32;
        qx_slot_result[slot] = (a32 + 2) as i32;
    } else if req.op == TOOL_OP_ECHO {
        var n: usize = in_len;
        if n > (req.out_cap as usize) {
            n = req.out_cap as usize;
        }
        var i: usize = 0;
        while i < n {
            qx_slot_res[slot][i] = qx_reqbuf[i];
            i = i + 1;
        }
        qx_slot_outlen[slot] = n as u32;
        qx_slot_result[slot] = n as i32;
    } else if req.op == TOOL_OP_TIMEOUT {
        qx_slot_status[slot] = E_TIMEDOUT as i32;
        qx_slot_result[slot] = 0;
    } else {
        qx_slot_result[slot] = 0;
        qx_slot_id[slot] = id + 1000000;
    }

    return id;
}

// SYS_POLL(event_ptr): advance the virtual clock, deliver the READY completion with the
// smallest ready tick (out-of-order delivery), copy the result payload OUT then a ToolEvent
// OUT. Returns 1 (delivered), 0 (nothing ready), or -E_FAULT.
fn qx_sys_poll(ev_ptr: u64, b: u64, c: u64) -> u64 {
    qx_clock = qx_clock + 1;
    if qx_active_count == 0 {
        return 0;
    }

    var best: usize = QX_COMP_CAP;
    var i: usize = 0;
    while i < QX_COMP_CAP {
        if qx_slot_active[i] && qx_slot_ready[i] <= qx_clock {
            if best == QX_COMP_CAP || qx_slot_ready[i] < qx_slot_ready[best] || (qx_slot_ready[i] == qx_slot_ready[best] && qx_slot_id[i] < qx_slot_id[best]) {
                best = i;
            }
        }
        i = i + 1;
    }
    if best == QX_COMP_CAP {
        return 0;
    }

    let outlen: usize = qx_slot_outlen[best] as usize;

    if outlen > 0 {
        switch copy_to_user_pt(&qx_uas, qx_uptr(qx_slot_outptr[best] as usize), pa((&qx_slot_res[best][0]) as usize), outlen) {
            ok(v) => {}
            err(e) => { return bitcast<u64>(E_FAULT); }
        }
    }

    var ev: ToolEvent = uninit;
    ev.id = qx_slot_id[best];
    ev.status = qx_slot_status[best];
    ev.result = qx_slot_result[best];
    ev.out_len = qx_slot_outlen[best];
    ev.reserved = 0;
    let esz: usize = sizeof(ToolEvent);
    switch copy_to_user_pt(&qx_uas, qx_uptr(ev_ptr as usize), pa((&ev) as usize), esz) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }

    qx_slot_active[best] = false;
    qx_active_count = qx_active_count - 1;
    return 1;
}

// Register the userspace ABI handlers. Called by the C trap bring-up before the app runs.
export fn syscall_setup() -> void {
    syscall_init(&qx_syscalls);
    syscall_register(&qx_syscalls, SYS_WRITE as usize, qx_sys_write);
    syscall_register(&qx_syscalls, SYS_READ as usize, qx_sys_read);
    syscall_register(&qx_syscalls, SYS_GETPID as usize, qx_sys_getpid);
    syscall_register(&qx_syscalls, SYS_SUBMIT as usize, qx_sys_submit);
    syscall_register(&qx_syscalls, SYS_POLL as usize, qx_sys_poll);
}

// Called by the C trap for each int-0x80 syscall (number RAX, args RDI/RSI/RDX). SYS_EXIT is
// handled by the trap before this; everything else dispatches through the registered table.
export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&qx_syscalls, number, arg0, arg1, arg2);
}

// Build the agent's isolated x86-64 space from the app image: load the QuickJS ELF (its own
// user pages only) via the x86 loader, then add the kernel's low-1-GiB supervisor-only identity
// window so the kernel survives the CR3 reload. Returns 1 on success and writes the CR3 (PML4
// phys) through `out_cr3`; on a load failure returns 0 and records the cause in qx_load_status.
export fn app_build_x86(image_base: usize, image_len: usize, region_base: usize, region_len: usize, out_cr3: *mut u64) -> u32 {
    qx_load_status = QX_LS_OK;
    *out_cr3 = 0;
    qx_heap = heap_new(phys_range(pa(region_base), region_len));

    switch page_table_try_new(&qx_heap) {
        ok(pt) => { qx_pt = pt; }
        err(e) => { qx_load_status = QX_LS_NOFRAME; return 0; }
    }

    switch elf_load_image(image_base, image_len, &qx_pt, &qx_heap) {
        ok(e) => { qx_entry = e; }
        err(e) => {
            switch e {
                .BadElf => { qx_load_status = QX_LS_BADELF; }
                .TooManyPages => { qx_load_status = QX_LS_TOOMANY; }
                .NoFrame => { qx_load_status = QX_LS_NOFRAME; }
                .BadSegment => { qx_load_status = QX_LS_BADSEG; }
            }
            return 0;
        }
    }

    // Kernel identity window: the full low 1 GiB as 2 MiB huge pages, writable but NOT user (US
    // clear), so the long-mode kernel (image + stack + heap + GDT/IDT + the frame `region` pool,
    // all under 1 GiB) keeps running after the CR3 reload while staying unreachable from ring 3.
    // The agent lives at >= 1 GiB (a different PDPT slot), so there is no overlap with these pages.
    let kflags: u64 = PTE_W; // present added by the API; US clear => kernel-only page
    var off: usize = 0;
    while off < QX_KERNEL_GIB {
        page_table_map_2mib(&qx_pt, &qx_heap, va(off), pa(off), kflags);
        off = off + QX_HUGE_2MIB;
    }

    qx_uas = user_addr_space(&qx_pt, QX_USER_BASE, QX_USER_LIMIT);
    *out_cr3 = page_table_cr3(&qx_pt);
    return 1;
}

export fn app_build_status_x86() -> u32 {
    return qx_load_status;
}

export fn app_entry_x86() -> u64 {
    return qx_entry;
}

// Confinement proof (M6 form): a kernel VA is mapped (so long mode + the trap path survive the
// CR3 reload) but is NOT user-accessible (no PTE_US at every level), so a ring-3 touch faults.
// Returns 1 iff the kernel page lacks user access.
export fn app_kernel_not_user_x86(kernel_va: usize) -> u32 {
    switch page_table_lookup(&qx_pt, va(kernel_va)) {
        ok(m) => { if mapping_is_user(&m) { return 0; } return 1; }
        err(e) => { return 0; } // unmapped: the kernel couldn't run — not proven
    }
}

// Confinement proof #2: the agent's own entry (code) page IS user-accessible.
export fn app_entry_is_user_x86() -> u32 {
    switch page_table_lookup(&qx_pt, va(qx_entry as usize)) {
        ok(m) => { if mapping_is_user(&m) { return 1; } return 0; }
        err(e) => { return 0; }
    }
}

