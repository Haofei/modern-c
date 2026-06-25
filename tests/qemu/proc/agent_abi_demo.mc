import "kernel/core/agent_abi.mc";

export fn agent_abi_run() -> u32 {
    var pass: u32 = 1;

    var req: AgentToolReq = .{
        .version = agent_abi_version(),
        .op = 4,
        .request_id = 77,
        .arg0 = 1,
        .arg1 = 2,
        .ptr = 0x1000,
        .len = 64,
        .flags = 0,
    };

    switch agent_abi_validate_req(&req, 128) {
        ok(v) => {}
        err(e) => { pass = 0; }
    }

    req.version = 99;
    switch agent_abi_validate_req(&req, 128) {
        ok(v) => { pass = 0; }
        err(e) => { if agent_abi_error_status(e) != agent_abi_status_badver() { pass = 0; } }
    }
    req.version = agent_abi_version();

    req.op = 999;
    switch agent_abi_validate_req(&req, 128) {
        ok(v) => { pass = 0; }
        err(e) => { if agent_abi_error_status(e) != agent_abi_status_badop() { pass = 0; } }
    }
    req.op = 1;

    req.len = 129;
    switch agent_abi_validate_req(&req, 128) {
        ok(v) => { pass = 0; }
        err(e) => { if agent_abi_error_status(e) != agent_abi_status_fault() { pass = 0; } }
    }
    req.len = 64;

    req.op = 6;
    req.arg0 = 0;
    switch agent_abi_validate_req(&req, 128) {
        ok(v) => { pass = 0; }
        err(e) => { if agent_abi_error_status(e) != agent_abi_status_badop() { pass = 0; } }
    }

    let ok_ev: AgentToolEvent = agent_abi_ok_event(77, 42, 5);
    if ok_ev.version != agent_abi_version() { pass = 0; }
    if ok_ev.request_id != 77 { pass = 0; }
    if ok_ev.status != agent_abi_status_ok() { pass = 0; }
    if ok_ev.result != 42 { pass = 0; }
    if ok_ev.out_len != 5 { pass = 0; }

    let deny_ev: AgentToolEvent = agent_abi_err_event(78, .Denied);
    if deny_ev.status != agent_abi_status_denied() { pass = 0; }
    if deny_ev.request_id != 78 { pass = 0; }
    if deny_ev.result != 0 { pass = 0; }

    if agent_abi_error_status(.BackPressure) != agent_abi_status_again() { pass = 0; }
    if agent_abi_error_status(.Canceled) != agent_abi_status_canceled() { pass = 0; }
    if agent_abi_error_status(.Exhausted) != agent_abi_status_exhausted() { pass = 0; }
    return pass;
}
