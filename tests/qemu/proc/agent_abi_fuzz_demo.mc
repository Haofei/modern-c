import "kernel/core/agent_abi.mc";
import "kernel/core/syscall.mc";

const FUZZ_ITERS: usize = 4096;
const MAX_LEN: usize = 192;
const SYS_FUZZ_ADD: usize = 3;
const SYS_FUZZ_XOR: usize = 7;
const SYS_ENOSYS_EXPECTED: u64 = 0xFFFF_FFFF_FFFF_FFFF;

global g_syscalls: SyscallTable;

fn fuzz_next(state: *mut u64) -> u64 {
    // Keep the generator inside a small modulus so MC's checked arithmetic never
    // traps while still producing enough bit variation to cover every validation
    // branch below.
    let x: u64 = *state;
    let next: u64 = ((x * 48271) + 1) % 2_147_483_647;
    *state = next;
    return next;
}

fn known_op_from_slot(slot: u64) -> u32 {
    if slot == 0 { return 1; }
    if slot == 1 { return 2; }
    if slot == 2 { return 3; }
    if slot == 3 { return 4; }
    if slot == 4 { return 5; }
    return 6;
}

fn expected_req_status(req: *AgentToolReq) -> u32 {
    if req.version != agent_abi_version() {
        return agent_abi_status_badver();
    }
    if !agent_abi_is_known_op(req.op) {
        return agent_abi_status_badop();
    }
    if req.len > MAX_LEN {
        return agent_abi_status_fault();
    }
    if req.op == 6 && req.arg0 == 0 {
        return agent_abi_status_badop();
    }
    return agent_abi_status_ok();
}

fn check_req(req: *mut AgentToolReq) -> bool {
    let expected: u32 = expected_req_status(req);
    switch agent_abi_validate_req(req, MAX_LEN) {
        ok(v) => {
            if expected != agent_abi_status_ok() { return false; }
            if !v { return false; }
            return true;
        }
        err(e) => {
            if expected == agent_abi_status_ok() { return false; }
            return agent_abi_error_status(e) == expected;
        }
    }
}

fn build_req(bits: u64, i: usize) -> AgentToolReq {
    let op_slot: u64 = (bits >> 8) & 7;
    var op: u32 = known_op_from_slot(op_slot);
    if op_slot >= 6 {
        op = (200 + op_slot) as u32;
    }
    var version: u32 = agent_abi_version();
    if (bits & 1) != 0 {
        version = version + 1;
    }
    let len: usize = ((bits >> 16) & 255) as usize;
    var cancel_target: u64 = bits >> 24;
    if ((bits >> 2) & 1) != 0 {
        cancel_target = 0;
    }
    return .{
        .version = version,
        .op = op,
        .request_id = 0xA000 + (i as u64),
        .arg0 = cancel_target,
        .arg1 = bits ^ 0x55AA_1234,
        .ptr = ((bits >> 4) & 0xFFFF) as usize,
        .len = len,
        .flags = (bits >> 32) as u32,
    };
}

fn sys_add(a: u64, b: u64, c: u64) -> u64 {
    return a + b + c;
}

fn sys_xor(a: u64, b: u64, c: u64) -> u64 {
    return (a ^ b) + c;
}

fn check_syscall_dispatch(number: u64, a: u64, b: u64, c: u64) -> bool {
    let got: u64 = syscall_dispatch(&g_syscalls, number, a, b, c);
    if number == SYS_FUZZ_ADD as u64 {
        return got == a + b + c;
    }
    if number == SYS_FUZZ_XOR as u64 {
        return got == (a ^ b) + c;
    }
    return got == SYS_ENOSYS_EXPECTED;
}

export fn agent_abi_fuzz_run() -> u32 {
    var state: u64 = 1_234_567;
    var i: usize = 0;
    var ok_count: u32 = 0;
    var badver_count: u32 = 0;
    var badop_count: u32 = 0;
    var badlen_count: u32 = 0;

    while i < FUZZ_ITERS {
        let bits: u64 = fuzz_next(&state);
        var req: AgentToolReq = build_req(bits, i);
        let expected: u32 = expected_req_status(&req);
        if !check_req(&req) { return 0; }
        if expected == agent_abi_status_ok() { ok_count = ok_count + 1; }
        if expected == agent_abi_status_badver() { badver_count = badver_count + 1; }
        if expected == agent_abi_status_badop() { badop_count = badop_count + 1; }
        if expected == agent_abi_status_fault() { badlen_count = badlen_count + 1; }

        let ev_ok: AgentToolEvent = agent_abi_ok_event(req.request_id, bits, req.len);
        if ev_ok.version != agent_abi_version() { return 0; }
        if ev_ok.request_id != req.request_id { return 0; }
        if ev_ok.status != agent_abi_status_ok() { return 0; }
        if ev_ok.result != bits { return 0; }
        if ev_ok.out_len != req.len { return 0; }

        let ev_err: AgentToolEvent = agent_abi_err_event(req.request_id, .Denied);
        if ev_err.version != agent_abi_version() { return 0; }
        if ev_err.request_id != req.request_id { return 0; }
        if ev_err.status != agent_abi_status_denied() { return 0; }
        if ev_err.result != 0 || ev_err.out_len != 0 { return 0; }

        i = i + 1;
    }

    if ok_count == 0 || badver_count == 0 || badop_count == 0 || badlen_count == 0 {
        return 0;
    }

    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_FUZZ_ADD, sys_add);
    syscall_register(&g_syscalls, SYS_FUZZ_XOR, sys_xor);

    i = 0;
    var unknown_count: u32 = 0;
    while i < FUZZ_ITERS {
        let bits: u64 = fuzz_next(&state);
        let number: u64 = (bits >> 3) & 31;
        let a: u64 = bits & 0xFFFF;
        let b: u64 = (bits >> 16) & 0xFFFF;
        let c: u64 = (bits >> 32) & 0xFFFF;
        if !check_syscall_dispatch(number, a, b, c) { return 0; }
        if number != SYS_FUZZ_ADD as u64 && number != SYS_FUZZ_XOR as u64 {
            unknown_count = unknown_count + 1;
        }
        i = i + 1;
    }
    if unknown_count == 0 { return 0; }
    return 1;
}
