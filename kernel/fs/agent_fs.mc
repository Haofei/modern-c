// kernel/fs/agent_fs — the agent-facing TOOL DISPATCH front door (M3 seed).
//
// An agent never calls the FS tool server directly with raw authority; it calls
// THIS, presenting only a tool id and arguments. The front door enforces the two
// agent-boundary controls — a tool ALLOWLIST (which tool ids this agent may
// invoke) and a call BUDGET (how many calls it may make) — and only then hands a
// permitted call to the capability-checked FS tool server, which applies the
// PATH capability. So a call must clear THREE gates to do anything:
//   1. allowlist  — the tool id is in the agent's allowed set (else Denied);
//   2. budget     — the agent has calls left (else Exhausted);
//   3. path cap   — the FS tool server authorizes the target path (else Denied).
//
// This is the structure the milestone calls "tool execution is a separate
// principal": the agent holds an endpoint + allowlist; the server holds the
// authority. (Here the "endpoint" is a direct call for host-testability; the
// real form is IPC to a server process — the dispatch and the checks are
// identical either way.)
//
// Hardening over the existing in-process agent ABI: that ABI audits only
// DISPATCHED calls, so a denied tool id leaves no trace. This front door audits
// the DENIED attempts too (allowlist / budget / unknown-tool), so an agent
// probing for tools it may not call is fully recorded and attributable — closing
// the gap the milestone flags in acceptance #5.

import "kernel/fs/fs_toolserver.mc";
import "kernel/core/ipc_trace.mc";
import "std/mask.mc";

// Tool ids = bit indices in the allowlist. 0..3 are the FS catalog; higher ids
// (exec/net/...) are not served here and exist to be denied.
const TOOL_FS_WRITE: u32 = 0;
const TOOL_FS_READ: u32 = 1;
const TOOL_FS_MKDIR: u32 = 2;
const TOOL_FS_LIST: u32 = 3;
const TOOL_CATALOG_MAX: u32 = 3; // highest id with a handler

// Verdict + a synthetic op code for front-door audit records. The FS catalog ops
// reuse the server's OP_* tags; a denied/unknown tool is logged with its raw id
// plus this bias so it is distinguishable from a served op in the trace.
const FD_DENY: u32 = 0;
const FD_TOOL_TAG_BIAS: u32 = 0x1000;

// An agent's FS-tool authority: the allowlist, the remaining call budget, and
// the path capability the server will enforce. All three travel together.
struct AgentFs {
    tools: Mask32,
    calls_left: u32,
    cap: PathCap,
}

enum AgentToolError {
    Denied,      // tool id not in the allowlist, OR path cap refused the target
    Exhausted,   // call budget spent
    NoSuchTool,  // allowlisted id has no handler in the catalog
    NoRight,     // path cap lacks the needed right
    NotFound,
    NotDir,
    Exists,
    TooLarge,
    NoSpace,
    IsDir,
    Invalid,
}

// Construct an agent's FS-tool authority by value (allowlist + budget + cap).
export fn agent_fs_new(tools: Mask32, budget: u32, cap: PathCap) -> AgentFs {
    return .{ .tools = tools, .calls_left = budget, .cap = cap };
}

fn map_fs(e: FsToolError) -> AgentToolError {
    switch e {
        .Denied => { return .Denied; }
        .NoRight => { return .NoRight; }
        .NotFound => { return .NotFound; }
        .NotDir => { return .NotDir; }
        .Exists => { return .Exists; }
        .TooLarge => { return .TooLarge; }
        .NoSpace => { return .NoSpace; }
        .IsDir => { return .IsDir; }
        .Invalid => { return .Invalid; }
    }
}

fn fd_audit(sink: *mut IpcTrace, a: *mut AgentFs, tool_id: u32) -> void {
    // Attribute the denied attempt to the agent, tagging the probed tool id.
    ipc_trace_record(sink, a.cap.agent_pid, FD_DENY, FD_TOOL_TAG_BIAS + tool_id, 0);
}

// THE TOOL-CALL FRONT DOOR. Checks run allowlist -> budget -> resolve before any
// dispatch, so a forbidden tool is refused WITHOUT spending budget, and every
// pre-dispatch refusal is audited and attributed. A permitted call charges one
// budget unit and is handed to the FS tool server (which applies the path cap
// and audits the capability verdict itself).
export fn agent_fs_call(t: *mut Tree, sink: *mut IpcTrace, a: *mut AgentFs, tool_id: u32, path: usize, path_len: usize, offset: usize, buf: usize, n: usize, capacity: usize) -> Result<usize, AgentToolError> {
    // 1. allowlist: not permitted -> Denied (audited; no budget spent).
    if !mask32_contains(&a.tools, tool_id) {
        fd_audit(sink, a, tool_id);
        return err(.Denied);
    }
    // 2. budget: out of calls -> Exhausted (audited).
    if a.calls_left == 0 {
        fd_audit(sink, a, tool_id);
        return err(.Exhausted);
    }
    // 3. resolve: allowlisted but no handler -> NoSuchTool (audited; no charge).
    if tool_id > TOOL_CATALOG_MAX {
        fd_audit(sink, a, tool_id);
        return err(.NoSuchTool);
    }
    // 4. charge one budget unit, then dispatch to the capability FS server.
    a.calls_left = a.calls_left - 1;
    if tool_id == TOOL_FS_WRITE {
        switch fs_tool_write(t, sink, &a.cap, path, path_len, offset, buf, n, capacity) {
            ok(w) => { return ok(w); }
            err(e) => { return err(map_fs(e)); }
        }
    }
    if tool_id == TOOL_FS_READ {
        switch fs_tool_read(t, sink, &a.cap, path, path_len, offset, buf, n) {
            ok(r) => { return ok(r); }
            err(e) => { return err(map_fs(e)); }
        }
    }
    if tool_id == TOOL_FS_MKDIR {
        switch fs_tool_mkdir(t, sink, &a.cap, path, path_len) {
            ok(i) => { return ok(i); }
            err(e) => { return err(map_fs(e)); }
        }
    }
    // tool_id == TOOL_FS_LIST (the only remaining catalog id)
    switch fs_tool_list_count(t, sink, &a.cap, path, path_len) {
        ok(c) => { return ok(c); }
        err(e) => { return err(map_fs(e)); }
    }
}

export fn agent_fs_calls_left(a: *mut AgentFs) -> u32 {
    return a.calls_left;
}
