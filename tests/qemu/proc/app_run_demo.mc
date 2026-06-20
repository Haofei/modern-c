// Load a REAL multi-segment app ELF (built by tools/user/build-app.sh from an MC `main`)
// into an ISOLATED Sv39 space via elf_load_image, register the userspace syscall ABI, and
// return the satp to activate. The C runtime (app_runtime.c) sets satp + enter_user; SYS_EXIT
// is handled by the shared M-mode trap (usermode_runtime.c). The kernel is NOT mapped in the
// agent's address space — that omission is the confinement; the agent reaches the kernel only
// through `ecall`, and SYS_WRITE's user buffer is copied in through the agent's page table
// (copy_from_user_pt), never dereferenced raw.

import "kernel/core/elf_loader.mc";
import "kernel/arch/riscv64/paging.mc";
import "kernel/core/heap.mc";
import "kernel/core/syscall.mc";
import "kernel/core/uaccess.mc";
import "kernel/core/console.mc";
import "std/addr.mc";
import "user/abi.mc"; // SYS_* numbers + E_AGAIN/E_FAULT — the single ABI source of truth

const SATP_SV39: u64 = 0x8000_0000_0000_0000;
const COMP_CAP: usize = 8;
const USER_BASE: usize = 0x10000;
// Upper bound for uaccess validation. Must cover the agent's whole VA span — for the QuickJS
// agent that includes the multi-MiB heap arena + stack high in .bss, so a small app's 1 MiB is
// far too low (SYS_WRITE buffers live above it). 16 MiB covers the confined-agent images.
const USER_LIMIT: usize = 0x0100_0000;
const KBUF: usize = 256;
const AGENT_PID: u64 = 7;

// app_build status codes: the loader's typed LoadError, preserved across the u64-satp C ABI
// boundary so callers (and tests) can tell WHY a load failed rather than seeing a bare 0.
const LS_OK: u32 = 0;
const LS_BADELF: u32 = 1;   // LoadError.BadElf — header / program-header table rejected
const LS_TOOMANY: u32 = 2;  // LoadError.TooManyPages — a segment exceeds MAX_SEGMENT_PAGES
const LS_NOFRAME: u32 = 3;  // LoadError.NoFrame — heap exhausted (root, leaf, or interior table)
const LS_BADSEG: u32 = 4;   // LoadError.BadSegment — absurd/overlapping vaddr/memsz/filesz

global g_heap: Heap;
global g_pt: PageTable;
global g_uas: UserAddrSpace;
global g_syscalls: SyscallTable;
global g_kbuf: [KBUF]u8;
global g_entry: u64;
global g_load_status: u32; // last app_build outcome (LS_*), readable via app_build_status()

// Result-payload buffer sizes (mirror MAX_REQ_BYTES / MAX_RES_BYTES; usize for array sizing).
const REQ_BYTES: usize = 256;
const RES_BYTES: usize = 256;

// Pending-completion ring (FIFO via head + count, so dequeue never shifts the payload buffers).
// Each slot owns a kernel-resident result payload buffer of exactly RES_BYTES — the kernel never
// holds or copies more than the quota, so a hostile agent cannot make it move unbounded data.
global g_pend_id: [COMP_CAP]u64;             // request id
global g_pend_status: [COMP_CAP]i32;         // 0 | -errno
global g_pend_result: [COMP_CAP]i32;         // scalar result
global g_pend_outptr: [COMP_CAP]u64;         // where the result payload is copied OUT on poll
global g_pend_outcap: [COMP_CAP]u32;         // capacity the agent reserved at out_ptr
global g_pend_outlen: [COMP_CAP]u32;         // payload bytes actually produced
global g_pend_res: [COMP_CAP][RES_BYTES]u8;  // per-slot result payload (kernel-owned, bounded)
global g_pend_head: usize;                   // index of the oldest pending completion
global g_pend_count: usize;                  // number of pending completions
global g_next_req: u64;                      // monotonic request-id counter
global g_reqbuf: [REQ_BYTES]u8;              // bounded copy-IN scratch for request payloads

// Forge a UserPtr<u8> from a user-supplied integer address (the uaccess idiom): re-tagging
// an int into the UserPtr class needs `unsafe`; copy_from_user_pt still validates it per-page.
fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe {
        p = a as UserPtr<u8>;
    }
    return p;
}

// SYS_WRITE(fd, buf, len): copy the user buffer in through the agent's page table, then emit
// it to the console. Capped at the kernel staging buffer. Returns bytes written, or -E_FAULT
// on a bad user pointer (copy_from_user_pt fails closed, writing nothing) — distinct from a
// legitimate 0-byte write, per the ABI's negative-errno convention.
fn sys_write(fd: u64, buf: u64, len: u64) -> u64 {
    var n: usize = len as usize;
    if n > KBUF {
        n = KBUF;
    }
    let dst: PAddr = pa((&g_kbuf[0]) as usize);
    switch copy_from_user_pt(&g_uas, dst, uptr(buf as usize), n) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }
    var i: usize = 0;
    while i < n {
        console_putc(g_kbuf[i]);
        i = i + 1;
    }
    return n as u64;
}

fn sys_getpid(a: u64, b: u64, c: u64) -> u64 {
    return AGENT_PID;
}

// The agent source the kernel holds (embedded by the harness): returns its kernel address and
// length. A weak default in the kernel runtime returns nothing for tests that embed no agent.
extern fn mc_agent_source(out_len: *mut usize) -> usize;

// SYS_READ(buf, max): §0 ingress — copy the kernel-held agent source into the agent's buffer
// (through its page table), capped at `max`. Returns bytes delivered. This is how the host gets
// its agent.js without the host ELF embedding it.
fn sys_read(buf: u64, max: u64, c: u64) -> u64 {
    var src_len: usize = 0;
    let src_addr: usize = mc_agent_source(&src_len);
    if src_addr == 0 || src_len == 0 {
        return 0;
    }
    var n: usize = src_len;
    if n > (max as usize) {
        n = max as usize;
    }
    switch copy_to_user_pt(&g_uas, uptr(buf as usize), pa(src_addr), n) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); } // bad user buffer, distinct from 0-byte EOF
    }
    return n as u64;
}

// SYS_SUBMIT(req_ptr): start a non-blocking tool op described by a ToolReq the agent points at.
// The struct is copied IN once (TOCTOU-safe snapshot), its payload sizes are validated against
// the hard quotas, and its request payload is copied into a bounded kernel-owned buffer — so the
// real copy-in / size-validation path runs even for the mock ops. The completion is computed and
// enqueued immediately (the mock broker; delays/reordering arrive with the broker op). Returns
// the request id (>=0), or a negative errno:
//   -E_FAULT  the request struct or its payload pointer is unreadable
//   -E_NOCAP  a payload size exceeds its hard quota (MAX_REQ_BYTES / MAX_RES_BYTES)
//   -E_DENIED the op selector is not an allowed tool op (policy)
//   -E_AGAIN  the completion ring is full (back-pressure, retryable)
fn sys_submit(req_ptr: u64, b: u64, c: u64) -> u64 {
    // Copy the request struct in as a single kernel-owned snapshot.
    var req: ToolReq = uninit;
    let rsz: usize = sizeof(ToolReq);
    switch copy_from_user_pt(&g_uas, pa((&req) as usize), uptr(req_ptr as usize), rsz) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); }
    }

    // Hard capacity bounds (ENOBUFS-class: not retryable, the agent must ask for less).
    if req.in_len > MAX_REQ_BYTES {
        return bitcast<u64>(E_NOCAP);
    }
    if req.out_cap > MAX_RES_BYTES {
        return bitcast<u64>(E_NOCAP);
    }

    // Op policy: only the known mock ops are permitted (EACCES otherwise).
    if req.op != TOOL_OP_SUM && req.op != TOOL_OP_ECHO {
        return bitcast<u64>(E_DENIED);
    }

    // Back-pressure: no slot in the completion ring (EAGAIN, retryable) — enqueue nothing.
    if g_pend_count >= (MAX_INFLIGHT as usize) {
        return bitcast<u64>(E_AGAIN);
    }

    // Copy the request payload IN to the bounded scratch (size already validated <= REQ_BYTES).
    let in_len: usize = req.in_len as usize;
    if in_len > 0 {
        switch copy_from_user_pt(&g_uas, pa((&g_reqbuf[0]) as usize), uptr(req.in_ptr as usize), in_len) {
            ok(v) => {}
            err(e) => { return bitcast<u64>(E_FAULT); }
        }
    }

    // Allocate the request id + ring slot, then compute the completion (immediate, mock).
    let id: u64 = g_next_req;
    g_next_req = g_next_req + 1;
    let slot: usize = (g_pend_head + g_pend_count) % COMP_CAP;
    g_pend_id[slot] = id;
    g_pend_status[slot] = 0;
    g_pend_outptr[slot] = req.out_ptr;
    g_pend_outcap[slot] = req.out_cap;

    if req.op == TOOL_OP_SUM {
        // Deterministic smoke op: result = arg + 2 (masked low bits so a hostile arg can't trap).
        let mask: u64 = 0x7FFF_FFFF;
        let a32: u32 = (req.arg & mask) as u32;
        g_pend_result[slot] = (a32 + 2) as i32;
        g_pend_outlen[slot] = 0;
    } else {
        // ECHO: result payload = the request payload, truncated to out_cap; scalar = bytes echoed.
        var n: usize = in_len;
        if n > (req.out_cap as usize) {
            n = req.out_cap as usize;
        }
        var i: usize = 0;
        while i < n {
            g_pend_res[slot][i] = g_reqbuf[i];
            i = i + 1;
        }
        g_pend_outlen[slot] = n as u32;
        g_pend_result[slot] = n as i32;
    }

    g_pend_count = g_pend_count + 1;
    return id;
}

// SYS_POLL(event_ptr): drain ONE ready completion. Copies the result payload OUT to the request's
// reserved out_ptr (bounded by what was produced), then copies a ToolEvent OUT to event_ptr.
// Returns 1 (delivered), 0 (nothing ready), or -E_FAULT (a destination is unwritable).
//
// Both copies happen BEFORE the ring head advances: if either faults, the completion is left
// intact at the head so it is not lost (a payload re-copy on a later retry is idempotent).
fn sys_poll(ev_ptr: u64, b: u64, c: u64) -> u64 {
    if g_pend_count == 0 {
        return 0;
    }
    let h: usize = g_pend_head;
    let outlen: usize = g_pend_outlen[h] as usize;

    // (1) result payload -> the originating request's out_ptr (only if the op produced bytes).
    if outlen > 0 {
        switch copy_to_user_pt(&g_uas, uptr(g_pend_outptr[h] as usize), pa((&g_pend_res[h][0]) as usize), outlen) {
            ok(v) => {}
            err(e) => { return bitcast<u64>(E_FAULT); }
        }
    }

    // (2) the ToolEvent -> the poll buffer.
    var ev: ToolEvent = uninit;
    ev.id = g_pend_id[h];
    ev.status = g_pend_status[h];
    ev.result = g_pend_result[h];
    ev.out_len = g_pend_outlen[h];
    ev.reserved = 0;
    let esz: usize = sizeof(ToolEvent);
    switch copy_to_user_pt(&g_uas, uptr(ev_ptr as usize), pa((&ev) as usize), esz) {
        ok(v) => {}
        err(e) => { return bitcast<u64>(E_FAULT); } // completion intact at the head
    }

    // delivered — advance the ring head (no payload shifting needed).
    g_pend_head = (g_pend_head + 1) % COMP_CAP;
    g_pend_count = g_pend_count - 1;
    return 1;
}

// Register the userspace ABI handlers. Called by usermode_setup() (the shared C trap
// bring-up) before the app runs; the handlers reference g_uas, which app_build sets before
// any ecall can occur.
export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_WRITE as usize, sys_write);
    syscall_register(&g_syscalls, SYS_READ as usize, sys_read);
    syscall_register(&g_syscalls, SYS_GETPID as usize, sys_getpid);
    syscall_register(&g_syscalls, SYS_SUBMIT as usize, sys_submit);
    syscall_register(&g_syscalls, SYS_POLL as usize, sys_poll);
}

// Called by the C trap for each ecall (number a7, args a0..a2). SYS_EXIT is handled by the
// trap before this; everything else dispatches through the registered table.
export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}

// Build the agent's isolated address space from the app image, register the ABI, return the
// satp to activate. Returns 0 on a malformed/hostile image — but records the SPECIFIC failure
// class in g_load_status (readable via app_build_status), so a loader failure is no longer
// collapsed indistinguishably to 0. Every allocation here is fallible: a hostile image cannot
// trap the kernel, only produce a typed status.
export fn app_build(image_base: usize, image_len: usize, region_base: usize, region_len: usize) -> u64 {
    g_load_status = LS_OK;
    g_heap = heap_new(phys_range(pa(region_base), region_len));

    // Root page table fallibly: even root-frame exhaustion is a typed NoFrame, not a trap.
    switch page_table_try_new(&g_heap) {
        ok(pt) => { g_pt = pt; }
        err(e) => { g_load_status = LS_NOFRAME; return 0; }
    }

    switch elf_load_image(image_base, image_len, &g_pt, &g_heap) {
        ok(e) => { g_entry = e; }
        err(e) => {
            switch e {
                .BadElf => { g_load_status = LS_BADELF; }
                .TooManyPages => { g_load_status = LS_TOOMANY; }
                .NoFrame => { g_load_status = LS_NOFRAME; }
                .BadSegment => { g_load_status = LS_BADSEG; }
            }
            return 0;
        }
    }

    g_uas = user_addr_space(&g_pt, USER_BASE, USER_LIMIT);

    let root: PAddr = page_table_root(&g_pt);
    return SATP_SV39 | ((pa_value(root) >> 12) as u64);
}

// The typed outcome of the most recent app_build (LS_*). The C runtime prints this on a load
// failure so the specific cause is visible, instead of a bare APP-LOAD-FAIL.
export fn app_build_status() -> u32 {
    return g_load_status;
}

export fn app_entry() -> u64 {
    return g_entry;
}

// Confinement proof: NO kernel VA is mapped in the agent's address space. The kernel image and
// its 16 MiB frame `region` live from `kernel_va` (0x8000_0000) upward, so a single probe is weak
// evidence — sweep several representative VAs across that range. If ANY is reachable through the
// agent's page table, the kernel leaked into the agent and confinement is broken.
export fn app_kernel_unmapped(kernel_va: usize) -> u32 {
    var off: usize = 0;
    // 0, 2, 8, 16, 24 MiB above the kernel base — covers the kernel text/data + the region pool.
    var probes: [5]usize = uninit;
    probes[0] = 0;
    probes[1] = 0x0020_0000;
    probes[2] = 0x0080_0000;
    probes[3] = 0x0100_0000;
    probes[4] = 0x0180_0000;
    var i: usize = 0;
    while i < 5 {
        off = probes[i];
        if page_table_is_mapped(&g_pt, va(kernel_va + off)) {
            return 0; // leaked
        }
        i = i + 1;
    }
    return 1; // none mapped -> confined
}
