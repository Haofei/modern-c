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
// M5b.2: the REAL capability-checked FS tool path. The same app_run_demo broker that drives the
// mock ops also dispatches the three FS ops through the kernel's capability front door, proving
// allow/deny/audit end-to-end from pure JS.
import "kernel/fs/agent_fs.mc";     // agent_fs_call (allowlist -> budget -> path cap), TOOL_FS_*
import "kernel/fs/treefs.mc";       // Tree + tree_init / tree_mkdir
import "kernel/fs/fs_toolserver.mc"; // PathCap, pathcap_root, FS_WRITE/FS_READ
import "kernel/core/ipc_trace.mc";  // IpcTrace audit sink (allow + deny verdicts)
import "kernel/net/net_broker.mc";  // net_fetch + registry + NetCap (production tool surface op)
import "std/mask.mc";               // Mask32 allowlist (mask32_zero/mask32_set)

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

// Mock-broker completion slots. Each slot owns a kernel-resident result payload buffer of exactly
// RES_BYTES — the kernel never holds or copies more than the quota. Unlike a FIFO ring, a slot
// carries a `ready` tick: SYS_POLL advances a virtual clock and delivers the ready slot with the
// smallest ready tick, so completions can arrive OUT OF submit order (delay-driven reordering).
const DELAY_MAX: u64 = 64;                    // clamp on a request's delay, bounds the poll loop
global g_slot_active: [COMP_CAP]bool;         // slot in use
global g_slot_id: [COMP_CAP]u64;              // completion id REPORTED to the agent (bogus for SPURIOUS)
global g_slot_status: [COMP_CAP]i32;          // 0 | -errno
global g_slot_result: [COMP_CAP]i32;          // scalar result
global g_slot_outptr: [COMP_CAP]u64;          // where the result payload is copied OUT on poll
global g_slot_outcap: [COMP_CAP]u32;          // capacity the agent reserved at out_ptr
global g_slot_outlen: [COMP_CAP]u32;          // payload bytes actually produced
global g_slot_res: [COMP_CAP][RES_BYTES]u8;   // per-slot result payload (kernel-owned, bounded)
global g_slot_ready: [COMP_CAP]u64;           // virtual tick at which this slot becomes pollable
global g_clock: u64;                          // virtual broker clock (advances each SYS_POLL)
global g_active_count: usize;                 // active slots
global g_next_req: u64;                       // monotonic request-id counter
global g_reqbuf: [REQ_BYTES]u8;               // bounded copy-IN scratch for request payloads

// ----- M5b.2: the REAL capability-checked FS tool world (kernel-side authority) -----
// A confined agent has NO authority of its own; the kernel mints it here, before the agent runs.
// The workspace dir "/ws" is the only writable/readable subtree (a path cap rooted at it); the
// allowlist permits ONLY FS_WRITE + FS_READ — NOT FS_MKDIR — so a JS mkdir is Denied at the front
// door (allowlist), proving the deny path. agent_fs_call enforces allowlist -> budget -> path-cap
// and audits every verdict (allow + deny) into g_audit.
const FS_PATH_MAX: usize = 128; // bound on a tool path (kernel-resident copy)
global g_tree: Tree;            // the tool filesystem (kernel-owned)
global g_audit: IpcTrace;       // the capability audit sink (allow + deny verdicts)
global g_agent: AgentFs;        // the agent's FS authority: allowlist + budget + path cap
global g_fs_path: [FS_PATH_MAX]u8;  // kernel copy of the request path (agent_fs_call takes a kaddr)
global g_fs_data: [RES_BYTES]u8;    // kernel copy of the write data / staging for read bytes
global g_fs_ready: bool;        // app_build set up the broker world (defensive: deny if not)
global g_fs_async_override_ready: bool;

// ----- Brokered network tool world -----
// The production JS host exposes `host_net_fetch(endpoint, token)` through the same
// SYS_SUBMIT/SYS_POLL path as FS. This S-mode QuickJS image has no NIC attached yet, so it uses the
// shared network broker control plane with registered mock endpoints (`net_fetch`). The TCP-backed
// sibling (`net_fetch_tcp`) remains in `kernel/net/net_broker_tcp.mc` for NIC runtimes.
const EP_WEB: u32 = 1;
const EP_EVIL: u32 = 9;
global g_net_t: ProcTable;
global g_net_reg: EndpointRegistry;
global g_net_sb: Sandbox;
global g_net_cap: NetCap;
global g_net_ready: bool;
global g_net_override_ready: bool;
global g_net_async_override_ready: bool;

fn net_ep_web(req: u32) -> u32 { return req + 100; }
fn net_ep_evil(req: u32) -> u32 { return req; }
fn net_agent_worker() -> void {}

fn net_override_noop_init() -> void {}
fn net_override_noop_fetch(endpoint_id: u32, token: u32) -> i32 {
    return E_DENIED as i32;
}
fn net_override_noop_submit(app_id: u64, endpoint_id: u32, token: u32) -> i32 {
    return E_DENIED as i32;
}
fn fs_override_noop_init() -> void {}
fn fs_override_noop_submit(app_id: u64, out_cap: u32) -> i32 {
    return E_DENIED as i32;
}
fn poll_hook_noop() -> void {}

global g_net_override_init: fn() -> void = net_override_noop_init;
global g_net_override_fetch: fn(u32, u32) -> i32 = net_override_noop_fetch;
global g_net_override_submit: fn(u64, u32, u32) -> i32 = net_override_noop_submit;
global g_poll_hook: fn() -> void = poll_hook_noop;
global g_fs_override_init: fn() -> void = fs_override_noop_init;
global g_fs_override_submit: fn(u64, u32) -> i32 = fs_override_noop_submit;
global g_fs_poll_hook: fn() -> void = poll_hook_noop;

// Find a free slot, or COMP_CAP if all are active.
fn broker_free_slot() -> usize {
    var i: usize = 0;
    while i < COMP_CAP {
        if !g_slot_active[i] {
            return i;
        }
        i = i + 1;
    }
    return COMP_CAP;
}

// Find the active slot whose REPORTED id == target, or COMP_CAP if none.
fn broker_slot_by_id(target: u64) -> usize {
    var i: usize = 0;
    while i < COMP_CAP {
        if g_slot_active[i] && g_slot_id[i] == target {
            return i;
        }
        i = i + 1;
    }
    return COMP_CAP;
}

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

// Map a capability-front-door error to the syscall ABI's negative-errno convention. Denied and
// NoRight (a policy/authority refusal) -> E_DENIED; Exhausted (budget spent) -> E_AGAIN
// (retryable, like back-pressure); NotFound -> -2 (ENOENT); everything else -> E_INVAL (-22).
fn fs_err_to_errno(e: AgentToolError) -> i32 {
    switch e {
        .Denied => { return E_DENIED as i32; }
        .NoRight => { return E_DENIED as i32; }
        .Exhausted => { return E_AGAIN as i32; }
        .NotFound => { return -2; } // ENOENT
        .NoSuchTool => { return -22; }
        .NotDir => { return -22; }
        .Exists => { return -22; }
        .TooLarge => { return -22; }
        .NoSpace => { return -22; }
        .IsDir => { return -22; }
        .Invalid => { return -22; }
    }
}

// Is `op` one of the REAL capability-checked FS ops?
fn is_fs_op(op: u32) -> bool {
    return op == TOOL_OP_FS_WRITE || op == TOOL_OP_FS_READ || op == TOOL_OP_FS_MKDIR;
}

fn net_err_to_errno(e: BrokerError) -> i32 {
    switch e {
        .Denied => { return E_DENIED as i32; }
        .Budget => { return E_AGAIN as i32; }
        .NoEndpoint => { return -2; } // ENOENT
    }
}

fn is_net_op(op: u32) -> bool {
    return op == TOOL_OP_NET_FETCH;
}

fn fs_path_is_irq_disk(path_len: usize) -> bool {
    if path_len != 8 {
        return false;
    }
    return g_fs_path[0] == 0x2F && g_fs_path[1] == 0x77 && g_fs_path[2] == 0x73 &&
        g_fs_path[3] == 0x2F && g_fs_path[4] == 0x64 && g_fs_path[5] == 0x69 &&
        g_fs_path[6] == 0x73 && g_fs_path[7] == 0x6B;
}

export fn app_net_override_set(init: fn() -> void, fetch: fn(u32, u32) -> i32) -> void {
    g_net_override_init = init;
    g_net_override_fetch = fetch;
    g_net_override_ready = true;
}

export fn app_net_override_set_async(init: fn() -> void, submit: fn(u64, u32, u32) -> i32, pump: fn() -> void) -> void {
    g_net_override_init = init;
    g_net_override_submit = submit;
    g_poll_hook = pump;
    g_net_async_override_ready = true;
    g_net_override_ready = true;
}

export fn app_net_async_complete(id: u64, status: i32, result: i32) -> void {
    let slot: usize = broker_slot_by_id(id);
    if slot == COMP_CAP {
        return;
    }
    if g_slot_status[slot] == (E_CANCELED as i32) {
        return;
    }
    g_slot_status[slot] = status;
    g_slot_result[slot] = result;
    g_slot_outlen[slot] = 0;
    g_slot_ready[slot] = g_clock;
}

export fn app_fs_override_set_async(init: fn() -> void, submit: fn(u64, u32) -> i32, pump: fn() -> void) -> void {
    g_fs_override_init = init;
    g_fs_override_submit = submit;
    g_fs_poll_hook = pump;
    g_fs_async_override_ready = true;
}

export fn app_fs_async_complete_word(id: u64, status: i32, result: i32, out_len: u32) -> void {
    let slot: usize = broker_slot_by_id(id);
    if slot == COMP_CAP {
        return;
    }
    if g_slot_status[slot] == (E_CANCELED as i32) {
        return;
    }
    g_slot_status[slot] = status;
    g_slot_result[slot] = result;
    g_slot_outlen[slot] = 0;
    if status == 0 {
        var n: u32 = out_len;
        if n > 4 {
            n = 4;
        }
        if n > g_slot_outcap[slot] {
            n = g_slot_outcap[slot];
        }
        let u: u32 = result as u32;
        if n > 0 { g_slot_res[slot][0] = (u & 0xFF) as u8; }
        if n > 1 { g_slot_res[slot][1] = ((u >> 8) & 0xFF) as u8; }
        if n > 2 { g_slot_res[slot][2] = ((u >> 16) & 0xFF) as u8; }
        if n > 3 { g_slot_res[slot][3] = ((u >> 24) & 0xFF) as u8; }
        g_slot_outlen[slot] = n;
    }
    g_slot_ready[slot] = g_clock;
}

// Network-tool hooks. The generic QuickJS runtime uses the shared broker control plane with
// mock endpoints so it does not need a NIC. A NIC-backed runtime registers an override with
// app_net_override_set to route `host_net_fetch` through `net_fetch_tcp` instead.
#[weak]
export fn app_net_tool_init() -> void {
    if g_net_override_ready {
        g_net_override_init();
        return;
    }
    proc_table_init(&g_net_t);
    cap_audit_init();
    endpoint_registry_init(&g_net_reg);
    switch endpoint_register(&g_net_reg, EP_WEB, net_ep_web) { ok(s) => {} err(e) => {} }
    switch endpoint_register(&g_net_reg, EP_EVIL, net_ep_evil) { ok(s) => {} err(e) => {} }
    let full: Mask32 = mask32_from(0xFFFF_FFFF);
    let no_tools: Mask32 = mask32_zero();
    g_net_sb = agent_spawn(&g_net_t, 0x1000, net_agent_worker, full, full, no_tools, 0);
    var net_allowed: Mask32 = mask32_zero();
    mask32_set(&net_allowed, EP_WEB);
    g_net_cap = .{ .allowed = net_allowed, .requests_left = 2 };
    g_net_ready = true;
}

#[weak]
export fn app_net_fetch_tool(endpoint_id: u32, token: u32) -> i32 {
    if g_net_override_ready {
        return g_net_override_fetch(endpoint_id, token);
    }
    if !g_net_ready {
        return E_DENIED as i32;
    }
    switch net_fetch(&g_net_t, &g_net_reg, &g_net_sb, &g_net_cap, endpoint_id, token) {
        ok(v) => { return v as i32; }
        err(e) => { return net_err_to_errno(e); }
    }
}

// SYS_SUBMIT helper for the REAL FS ops (M5b.2). The ToolReq has already been copied in and its
// hard size bounds checked. We copy the request payload (path[+data]) into kernel buffers, map the
// op to a TOOL_FS_* id, and call agent_fs_call — the capability front door (allowlist -> budget ->
// path cap). The completion slot is armed READY IMMEDIATELY (ready tick = g_clock), so the first
// SYS_POLL delivers it. On ok(n): status=0, result=n; for FS_READ the read bytes are staged into
// the slot result payload (out_len=n) so sys_poll copies them to out_ptr. On err(e): status = the
// mapped negative errno, no payload. Returns the request id (>=0), or -errno on a copy fault.
fn fs_submit(req: *ToolReq) -> u64 {
    if !g_fs_ready {
        return bitcast<u64>(E_DENIED);
    }

    // arg = path length; in_payload = path[0..arg] then data[arg..in_len] (write only).
    let path_len: usize = req.arg as usize;
    let in_len: usize = req.in_len as usize;
    // Validate: the path fits its kernel buffer, the path is within the in-payload, and the data
    // tail fits its kernel buffer. A malformed split is E_INVAL (not retryable).
    if path_len == 0 || path_len > FS_PATH_MAX || path_len > in_len {
        let einval: i64 = -22; // EINVAL: malformed path/payload split
        return bitcast<u64>(einval);
    }
    let data_len: usize = in_len - path_len;
    if data_len > RES_BYTES {
        return bitcast<u64>(E_NOCAP);
    }

    // Copy the request payload IN once (TOCTOU-safe snapshot), then split it into the kernel
    // path/data buffers — agent_fs_call/fs_tool_* take KERNEL addresses, never user pointers.
    if in_len > 0 {
        switch copy_from_user_pt(&g_uas, pa((&g_reqbuf[0]) as usize), uptr(req.in_ptr as usize), in_len) {
            ok(v) => {}
            err(e) => { return bitcast<u64>(E_FAULT); }
        }
    }
    var i: usize = 0;
    while i < path_len {
        g_fs_path[i] = g_reqbuf[i];
        i = i + 1;
    }
    var j: usize = 0;
    while j < data_len {
        g_fs_data[j] = g_reqbuf[path_len + j];
        j = j + 1;
    }

    // Back-pressure: no free completion slot (retryable). Take it BEFORE dispatch so an FS call's
    // result has a home; agent_fs_call has no side effect that leaks if we then fail (it hasn't run).
    let slot: usize = broker_free_slot();
    if slot == COMP_CAP {
        return bitcast<u64>(E_AGAIN);
    }

    // Map op -> TOOL_FS_* id. For FS_READ, `n`/capacity is the agent's out_cap (read up to that);
    // for FS_WRITE it is data_len (bytes to write) with capacity = path's reserve.
    var tool_id: u32 = TOOL_FS_WRITE;
    var n_arg: usize = data_len;          // bytes to write (write) / read budget (read)
    var capacity: usize = RES_BYTES;      // file reserve on create (write) / unused (read/mkdir)
    let data_kaddr: usize = (&g_fs_data[0]) as usize;
    let path_kaddr: usize = (&g_fs_path[0]) as usize;
    if req.op == TOOL_OP_FS_READ {
        tool_id = TOOL_FS_READ;
        n_arg = req.out_cap as usize; // read at most what the agent reserved at out_ptr
        if n_arg > RES_BYTES {
            n_arg = RES_BYTES;
        }
    } else if req.op == TOOL_OP_FS_MKDIR {
        tool_id = TOOL_FS_MKDIR;
        n_arg = 0;
    }

    let id: u64 = g_next_req;
    g_next_req = g_next_req + 1;
    g_slot_active[slot] = true;
    g_slot_id[slot] = id;
    g_slot_status[slot] = 0;
    g_slot_result[slot] = 0;
    g_slot_outptr[slot] = req.out_ptr;
    g_slot_outcap[slot] = req.out_cap;
    g_slot_outlen[slot] = 0;
    g_slot_ready[slot] = g_clock; // READY NOW — the first poll delivers the FS completion
    g_active_count = g_active_count + 1;

    if g_fs_async_override_ready && req.op == TOOL_OP_FS_READ && fs_path_is_irq_disk(path_len) {
        g_slot_ready[slot] = 0xFFFF_FFFF_FFFF_FFFF; // pending until the device-backed pump completes it
        let rc_async: i32 = g_fs_override_submit(id, req.out_cap);
        if rc_async == 0 {
            return id;
        }
        g_slot_status[slot] = rc_async;
        g_slot_result[slot] = 0;
        g_slot_outlen[slot] = 0;
        g_slot_ready[slot] = g_clock;
        return id;
    }

    switch agent_fs_call(&g_tree, &g_audit, &g_agent, tool_id, path_kaddr, path_len, 0, data_kaddr, n_arg, capacity) {
        ok(got) => {
            g_slot_status[slot] = 0;
            g_slot_result[slot] = got as i32;
            // FS_READ: the bytes the server read live in g_fs_data; stage them into the slot's
            // result payload so sys_poll copies them OUT to the request's out_ptr.
            if req.op == TOOL_OP_FS_READ {
                var n: usize = got;
                if n > RES_BYTES {
                    n = RES_BYTES;
                }
                if n > (req.out_cap as usize) {
                    n = req.out_cap as usize;
                }
                var k: usize = 0;
                while k < n {
                    g_slot_res[slot][k] = g_fs_data[k];
                    k = k + 1;
                }
                g_slot_outlen[slot] = n as u32;
            }
        }
        err(e) => {
            g_slot_status[slot] = fs_err_to_errno(e);
            g_slot_result[slot] = 0;
            g_slot_outlen[slot] = 0;
        }
    }
    return id;
}

// SYS_SUBMIT helper for the brokered network op. arg = endpoint id; flags = request token/audit
// size. The completion is READY NOW and carries the broker response scalar, or a mapped -errno.
fn net_submit(req: *ToolReq) -> u64 {
    if !g_net_ready && !g_net_override_ready && !g_net_async_override_ready {
        return bitcast<u64>(E_DENIED);
    }

    let slot: usize = broker_free_slot();
    if slot == COMP_CAP {
        return bitcast<u64>(E_AGAIN);
    }

    let id: u64 = g_next_req;
    g_next_req = g_next_req + 1;
    g_slot_active[slot] = true;
    g_slot_id[slot] = id;
    g_slot_status[slot] = 0;
    g_slot_result[slot] = 0;
    g_slot_outptr[slot] = req.out_ptr;
    g_slot_outcap[slot] = req.out_cap;
    g_slot_outlen[slot] = 0;
    g_slot_ready[slot] = g_clock; // sync default: first poll delivers the brokered completion
    g_active_count = g_active_count + 1;

    if g_net_async_override_ready {
        g_slot_ready[slot] = 0xFFFF_FFFF_FFFF_FFFF; // pending until the device-backed pump completes it
        let rc_async: i32 = g_net_override_submit(id, req.arg as u32, req.flags);
        if rc_async == 0 {
            return id;
        }
        g_slot_status[slot] = rc_async;
        g_slot_result[slot] = 0;
        g_slot_ready[slot] = g_clock;
        return id;
    }

    let rc: i32 = app_net_fetch_tool(req.arg as u32, req.flags);
    if rc >= 0 {
            g_slot_status[slot] = 0;
            g_slot_result[slot] = rc;
    } else {
        g_slot_status[slot] = rc;
        g_slot_result[slot] = 0;
    }
    return id;
}

// SYS_SUBMIT(req_ptr): start a non-blocking tool op described by a ToolReq the agent points at.
// The struct is copied IN once (TOCTOU-safe snapshot), its payload sizes are validated against
// the hard quotas, and its request payload is copied into a bounded kernel-owned buffer. The mock
// broker assigns the completion a `ready` tick = now + req.flags(delay), so completions can become
// ready out of submit order. Returns the request id (>=0), or a negative errno:
//   -E_FAULT  the request struct or its payload pointer is unreadable
//   -E_NOCAP  a payload size exceeds its hard quota (MAX_REQ_BYTES / MAX_RES_BYTES)
//   -E_DENIED the op selector is not an allowed tool op (policy), or CANCEL's target is unknown
//   -E_AGAIN  all completion slots are active (back-pressure, retryable)
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

    // CANCEL: complete the in-flight request whose reported id == arg with -E_CANCELED, ready now.
    // It enqueues NO new request (returns 0 = accepted), or -E_DENIED if the target is unknown.
    if req.op == TOOL_OP_CANCEL {
        let s: usize = broker_slot_by_id(req.arg);
        if s == COMP_CAP {
            return bitcast<u64>(E_DENIED);
        }
        g_slot_status[s] = E_CANCELED as i32;
        g_slot_result[s] = 0;
        g_slot_outlen[s] = 0;
        g_slot_ready[s] = g_clock; // ready immediately so the cancellation is observed promptly
        return 0;
    }

    // REAL FS ops (M5b.2): dispatch through the capability front door. These complete READY NOW.
    if is_fs_op(req.op) {
        return fs_submit(&req);
    }

    // Brokered network op: shared egress allowlist + budget + audit control plane, surfaced through
    // the production JS SYS_SUBMIT/SYS_POLL tool ABI.
    if is_net_op(req.op) {
        return net_submit(&req);
    }

    // Op policy: only the known mock request ops are permitted (EACCES otherwise).
    if req.op != TOOL_OP_SUM && req.op != TOOL_OP_ECHO && req.op != TOOL_OP_TIMEOUT && req.op != TOOL_OP_SPURIOUS {
        return bitcast<u64>(E_DENIED);
    }

    // Back-pressure: no free completion slot (EAGAIN, retryable) — enqueue nothing.
    let slot: usize = broker_free_slot();
    if slot == COMP_CAP {
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

    // Allocate the request id and arm the slot. The delay (req.flags, clamped) drives reordering.
    let id: u64 = g_next_req;
    g_next_req = g_next_req + 1;
    var delay: u64 = req.flags as u64;
    if delay > DELAY_MAX {
        delay = DELAY_MAX;
    }
    g_slot_active[slot] = true;
    g_slot_id[slot] = id;
    g_slot_status[slot] = 0;
    g_slot_outptr[slot] = req.out_ptr;
    g_slot_outcap[slot] = req.out_cap;
    g_slot_outlen[slot] = 0;
    g_slot_ready[slot] = g_clock + delay;
    g_active_count = g_active_count + 1;

    if req.op == TOOL_OP_SUM {
        // Deterministic smoke op: result = arg + 2 (masked low bits so a hostile arg can't trap).
        let mask: u64 = 0x7FFF_FFFF;
        let a32: u32 = (req.arg & mask) as u32;
        g_slot_result[slot] = (a32 + 2) as i32;
    } else if req.op == TOOL_OP_ECHO {
        // ECHO: result payload = the request payload, truncated to out_cap; scalar = bytes echoed.
        var n: usize = in_len;
        if n > (req.out_cap as usize) {
            n = req.out_cap as usize;
        }
        var i: usize = 0;
        while i < n {
            g_slot_res[slot][i] = g_reqbuf[i];
            i = i + 1;
        }
        g_slot_outlen[slot] = n as u32;
        g_slot_result[slot] = n as i32;
    } else if req.op == TOOL_OP_TIMEOUT {
        // Completes (after its delay) with a timeout status — the agent's promise rejects.
        g_slot_status[slot] = E_TIMEDOUT as i32;
        g_slot_result[slot] = 0;
    } else {
        // SPURIOUS (test-only): the completion carries a BOGUS id so the host hits its fatal
        // "unknown completion id" path. submit still returns the REAL id (what the host registers).
        g_slot_result[slot] = 0;
        g_slot_id[slot] = id + 1000000;
    }

    return id;
}

// SYS_POLL(events_ptr, max_arg, timeout): the VECTOR completion drain. Advances the virtual clock
// up to (1 + timeout) times, and on each advance delivers every READY completion (smallest ready
// tick first — out-of-order delivery, a short-delay op finishes before an earlier long-delay one)
// into the ToolEvent[] at events_ptr (the i-th event at offset i*sizeof(ToolEvent)), up to `max`.
// Each delivery copies the result payload OUT to the request's reserved out_ptr, then the ToolEvent
// OUT. Returns the count delivered (0..max), or -E_FAULT if the FIRST event copy faults (count==0).
//
// max_arg==0 is treated as 1 (single-event back-compat). With (max==1, timeout==0) the result is
// identical to the original single-event form: one clock tick, deliver at most one ready slot.
//
// Both copies for a delivery happen BEFORE the slot is freed: on a fault, the slot stays active so
// the completion is not lost. If a fault happens after some events were already delivered, we keep
// them — return the partial count rather than -E_FAULT (already-delivered events are not retracted).
fn sys_poll(events_ptr: u64, max_arg: u64, timeout: u64) -> u64 {
    var want: usize = max_arg as usize;
    if max_arg == 0 {
        want = 1; // back-compat: a1==0 means a single event
    }
    var count: usize = 0;

    // Outer loop: advance the clock at most (1 + timeout) times, draining each tick fully.
    var steps: u64 = 0;
    let max_steps: u64 = 1 + timeout;
    while steps < max_steps {
        steps = steps + 1;
        g_clock = g_clock + 1; // virtual time progresses, so every armed slot eventually becomes ready
        g_poll_hook();
        g_fs_poll_hook();

        // Inner drain: deliver ready slots (smallest ready tick, tie-break by id) until `want` is
        // reached or none are ready at this clock value.
        while count < want {
            if g_active_count == 0 {
                break;
            }
            var best: usize = COMP_CAP;
            var i: usize = 0;
            while i < COMP_CAP {
                if g_slot_active[i] && g_slot_ready[i] <= g_clock {
                    if best == COMP_CAP || g_slot_ready[i] < g_slot_ready[best] || (g_slot_ready[i] == g_slot_ready[best] && g_slot_id[i] < g_slot_id[best]) {
                        best = i;
                    }
                }
                i = i + 1;
            }
            if best == COMP_CAP {
                break; // active slots exist but none ready at this clock value
            }

            let outlen: usize = g_slot_outlen[best] as usize;

            // (1) result payload -> the originating request's out_ptr (only if the op produced bytes).
            if outlen > 0 {
                switch copy_to_user_pt(&g_uas, uptr(g_slot_outptr[best] as usize), pa((&g_slot_res[best][0]) as usize), outlen) {
                    ok(v) => {}
                    err(e) => {
                        if count > 0 { return count as u64; } // keep already-delivered events
                        return bitcast<u64>(E_FAULT);
                    }
                }
            }

            // (2) the ToolEvent -> events_ptr + count*sizeof(ToolEvent) (the count-th slot in the array).
            var ev: ToolEvent = uninit;
            ev.id = g_slot_id[best];
            ev.status = g_slot_status[best];
            ev.result = g_slot_result[best];
            ev.out_len = g_slot_outlen[best];
            ev.reserved = 0;
            let esz: usize = sizeof(ToolEvent);
            switch copy_to_user_pt(&g_uas, uptr((events_ptr as usize) + count * esz), pa((&ev) as usize), esz) {
                ok(v) => {}
                err(e) => {
                    if count > 0 { return count as u64; } // slot stays active; keep delivered events
                    return bitcast<u64>(E_FAULT);
                }
            }

            // delivered — free the slot.
            g_slot_active[best] = false;
            g_active_count = g_active_count - 1;
            count = count + 1;
        }

        if count == want || g_active_count == 0 {
            break; // satisfied the batch, or nothing left to wait for
        }
    }

    return count as u64;
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

    // M5b.2: stand up the REAL capability-checked FS tool world before the agent can issue any
    // SYS_SUBMIT. The agent gets a path cap rooted at "/ws" with read+write rights, and an
    // allowlist of {FS_WRITE, FS_READ} ONLY — so an FS_MKDIR op is Denied at the front door
    // (allowlist) without spending budget, and that denial is audited. Budget 16 calls.
    tree_init(&g_tree);
    ipc_trace_init(&g_audit);
    var ws_idx: usize = 0;
    // "/ws" = 0x2F 0x77 0x73
    g_fs_path[0] = 0x2F;
    g_fs_path[1] = 0x77;
    g_fs_path[2] = 0x73;
    switch tree_mkdir(&g_tree, (&g_fs_path[0]) as usize, 3) {
        ok(i) => { ws_idx = i; }
        err(e) => {}
    }
    var allow: Mask32 = mask32_zero();
    mask32_set(&allow, TOOL_FS_WRITE);
    mask32_set(&allow, TOOL_FS_READ); // NOT TOOL_FS_MKDIR — mkdir is the deny case
    g_agent = agent_fs_new(allow, 16, pathcap_root(AGENT_PID as u32, ws_idx, FS_WRITE | FS_READ));
    g_fs_ready = true;
    if g_fs_async_override_ready {
        g_fs_override_init();
    }

    // Production tool-surface network broker. The default weak hook registers mock endpoints;
    // NIC-backed runtime gates override it with a TCP transport.
    app_net_tool_init();

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
