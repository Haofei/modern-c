// kernel/core/agent_abi — stable agent/tool syscall envelope.
//
// The syscall handlers and JS bindings can evolve internally, but the production surface needs
// a single versioned contract for submit/poll requests and typed completion status. This module
// keeps those wire-visible numbers in one place and validates requests before a broker sees them.
//
// VERSIONING POLICY (production-readiness-plan §4.2 / §3.1 item 2):
//   * AGENT_ABI_VERSION is the wire-contract version carried in every request/event `version`
//     field. The kernel rejects a request whose `version` != AGENT_ABI_VERSION with `badver`
//     (gated by agent_abi_demo.mc) — fail-closed, never silently reinterpret a foreign envelope.
//   * This is a SINGLE monotonic integer, not split major/minor: there is exactly one supported
//     wire contract at a time. The kernel does not multiplex old contracts.
//   * BUMP the version for ANY wire-incompatible change: adding/removing/reordering struct
//     fields, changing a field's width/meaning, changing an op number, or changing a status
//     code's meaning. Purely additive *behind a new op number* with unchanged structs does NOT
//     require a bump (an unknown op already returns `badop`); changing existing layout does.
//   * Status codes (agent_abi_status_*) are part of the contract — their numeric values are
//     frozen for a given version; reusing a number for a new meaning is a version bump.
//   * The op set (AGENT_OP_*) is append-only within a version; removing/renumbering an op is a
//     version bump. abi-consistency-test pins the syscall numbers against user/abi.mc so the
//     kernel and userspace cannot drift within a version.
//   * Compatibility model: an agent built for version N runs only on a kernel advertising
//     version N (query via agent_abi_version()). There is no forward/back-compat negotiation —
//     deployment pairs a kernel image with agents built for its ABI version (see §4.4 bundles).

const AGENT_ABI_VERSION: u32 = 1;

const AGENT_OP_READ: u32 = 1;
const AGENT_OP_WRITE: u32 = 2;
const AGENT_OP_MKDIR: u32 = 3;
const AGENT_OP_NET_FETCH: u32 = 4;
const AGENT_OP_SLEEP: u32 = 5;
const AGENT_OP_CANCEL: u32 = 6;

enum AgentAbiError {
    BadVersion,
    BadOp,
    BadLength,
    BackPressure,
    Denied,
    Canceled,
    Fault,
    NotFound,
    Exhausted,
}

struct AgentToolReq {
    version: u32,
    op: u32,
    request_id: u64,
    arg0: u64,
    arg1: u64,
    ptr: usize,
    len: usize,
    flags: u32,
}

struct AgentToolEvent {
    version: u32,
    request_id: u64,
    status: u32,
    result: u64,
    out_len: usize,
}

export fn agent_abi_version() -> u32 {
    return AGENT_ABI_VERSION;
}

export fn agent_abi_status_ok() -> u32 { return 0; }
export fn agent_abi_status_again() -> u32 { return 11; }
export fn agent_abi_status_denied() -> u32 { return 13; }
export fn agent_abi_status_canceled() -> u32 { return 125; }
export fn agent_abi_status_fault() -> u32 { return 14; }
export fn agent_abi_status_not_found() -> u32 { return 2; }
export fn agent_abi_status_exhausted() -> u32 { return 28; }
export fn agent_abi_status_badop() -> u32 { return 38; }
export fn agent_abi_status_badver() -> u32 { return 71; }

export fn agent_abi_error_status(e: AgentAbiError) -> u32 {
    switch e {
        .BadVersion => { return agent_abi_status_badver(); }
        .BadOp => { return agent_abi_status_badop(); }
        .BadLength => { return agent_abi_status_fault(); }
        .BackPressure => { return agent_abi_status_again(); }
        .Denied => { return agent_abi_status_denied(); }
        .Canceled => { return agent_abi_status_canceled(); }
        .Fault => { return agent_abi_status_fault(); }
        .NotFound => { return agent_abi_status_not_found(); }
        .Exhausted => { return agent_abi_status_exhausted(); }
    }
}

export fn agent_abi_is_known_op(op: u32) -> bool {
    if op == AGENT_OP_READ { return true; }
    if op == AGENT_OP_WRITE { return true; }
    if op == AGENT_OP_MKDIR { return true; }
    if op == AGENT_OP_NET_FETCH { return true; }
    if op == AGENT_OP_SLEEP { return true; }
    if op == AGENT_OP_CANCEL { return true; }
    return false;
}

export fn agent_abi_validate_req(req: *AgentToolReq, max_len: usize) -> Result<bool, AgentAbiError> {
    if req.version != AGENT_ABI_VERSION {
        return err(.BadVersion);
    }
    if !agent_abi_is_known_op(req.op) {
        return err(.BadOp);
    }
    if req.len > max_len {
        return err(.BadLength);
    }
    if req.op == AGENT_OP_CANCEL {
        if req.arg0 == 0 {
            return err(.BadOp);
        }
    }
    return ok(true);
}

export fn agent_abi_ok_event(request_id: u64, result: u64, out_len: usize) -> AgentToolEvent {
    return .{
        .version = AGENT_ABI_VERSION,
        .request_id = request_id,
        .status = agent_abi_status_ok(),
        .result = result,
        .out_len = out_len,
    };
}

export fn agent_abi_err_event(request_id: u64, e: AgentAbiError) -> AgentToolEvent {
    return .{
        .version = AGENT_ABI_VERSION,
        .request_id = request_id,
        .status = agent_abi_error_status(e),
        .result = 0,
        .out_len = 0,
    };
}
