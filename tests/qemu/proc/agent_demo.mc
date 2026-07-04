// Mock agent runtime (kernel/core/agent). A SANDBOXED agent — an attenuated process plus a tool
// ALLOWLIST and a tool-call BUDGET — makes capability-checked, budget-bounded, AUDITED tool calls.
//
// This driver-mode host fixture (the C driver stubs the arch context primitives) proves the
// tool-call ABI end to end:
//   * tool calls dispatch and return correct results (echo, double);
//   * CAPABILITY CONFINEMENT: a tool not in the agent's allowlist is Denied — and Denied costs no
//     budget and is NOT dispatched (so it leaves no audit entry);
//   * an in-allowlist-but-unregistered tool is NoSuchTool;
//   * RESOURCE BOUND: after the budget is spent, a further allowed call is Exhausted;
//   * AUDIT: every DISPATCHED call is recorded into the capability-use trace (caller pid + tool id),
//     and the Denied call is absent from it.
//
// The mock tools are plain top-level fns (a real tool would be a service reached over IPC); the
// agent's "worker" entry is a no-op — on the host we never context-switch into it, we exercise the
// tool-call ABI directly from the bootstrap process.

import "kernel/core/agent.mc";
import "kernel/core/process.mc";
import "kernel/core/ipc_trace.mc";
import "std/mask.mc";

// Mock tools: in-process handlers standing in for real services. Inputs are kept small so the
// double's multiply cannot overflow (no checked-mult trap).
fn tool_echo(x: u32) -> u32 { return x; }
fn tool_double(x: u32) -> u32 { return x * 2; }
fn tool_secret(x: u32) -> u32 {
    let _x: u32 = x;
    return 0xBADC0DE;
} // the agent is NOT allowed to call this

// The agent's process entry. A no-op on the host (we drive the tool-call ABI directly rather than
// switching into the agent thread).
fn agent_worker() -> void {}

global g_t: ProcTable;
global g_reg: ToolRegistry;

export fn agent_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    cap_audit_init();
    tool_registry_init(&g_reg);

    // System tool registry: echo (id 1), double (id 2), and a secret tool (id 9) the agent will
    // NOT be allowed to call.
    switch tool_register(&g_reg, 1, tool_echo)   { ok(s) => {} err(e) => { pass = 0; } }
    switch tool_register(&g_reg, 2, tool_double) { ok(s) => {} err(e) => { pass = 0; } }
    switch tool_register(&g_reg, 9, tool_secret) { ok(s) => {} err(e) => { pass = 0; } }

    // Spawn a SANDBOXED agent. tool_mask = {1,2} (echo + double allowed; 9 is NOT — confinement).
    // call_budget = 3. allow/kcall subsets are full here (bootstrap has full authority, so the
    // attenuation is exercised by process.mc's own tests; this fixture focuses on the tool layer).
    var tool_mask: Mask32 = mask32_zero();
    mask32_set(&tool_mask, 1);
    mask32_set(&tool_mask, 2);
    let full: Mask32 = mask32_from(0xFFFF_FFFF);
    var sb: Sandbox = agent_spawn(&g_t, 0x1000, agent_worker, full, full, tool_mask, 3);

    // The agent's pid (its process slot's pid) — what the audit records as the caller.
    let agent_pid: u32 = proc_pid_at(&g_t, sb.slot);

    // (3) Allowed tool calls dispatch and return correct results. Consumes budget: 3 -> 1.
    switch agent_tool_call(&g_t, &g_reg, &sb, 1, 42) { ok(v) => { if v != 42 { pass = 0; } } err(e) => { pass = 0; } }
    switch agent_tool_call(&g_t, &g_reg, &sb, 2, 21) { ok(v) => { if v != 42 { pass = 0; } } err(e) => { pass = 0; } }

    // (4) CAPABILITY CONFINEMENT: tool 9 is not in the agent's allowlist -> Denied. Crucially this
    // must NOT consume budget (Denied is checked before the budget decrement). Record budget before.
    let budget_before_denied: u32 = sb.calls_left; // == 1
    switch agent_tool_call(&g_t, &g_reg, &sb, 9, 7) {
        ok(v) => { pass = 0; }
        err(e) => { if e != .Denied { pass = 0; } }
    }
    if sb.calls_left != budget_before_denied { pass = 0; } // Denied spent no budget

    // (5) UNREGISTERED: id 5 is in the agent's mask but not in the registry -> NoSuchTool. Put 5 in
    // the allowlist so the Denied check passes and we reach resolution. Budget is still 1, so the
    // budget check passes too; resolution then fails -> NoSuchTool (and spends no budget).
    mask32_set(&sb.tools, 5);
    let budget_before_nost: u32 = sb.calls_left; // == 1
    switch agent_tool_call(&g_t, &g_reg, &sb, 5, 0) {
        ok(v) => { pass = 0; }
        err(e) => { if e != .NoSuchTool { pass = 0; } }
    }
    if sb.calls_left != budget_before_nost { pass = 0; } // NoSuchTool spent no budget

    // (6) RESOURCE BOUND: budget is 1. One more allowed call (echo) succeeds -> budget 0; the next
    // allowed call is Exhausted.
    switch agent_tool_call(&g_t, &g_reg, &sb, 1, 99) { ok(v) => { if v != 99 { pass = 0; } } err(e) => { pass = 0; } }
    if sb.calls_left != 0 { pass = 0; }
    switch agent_tool_call(&g_t, &g_reg, &sb, 2, 5) {
        ok(v) => { pass = 0; }
        err(e) => { if e != .Exhausted { pass = 0; } }
    }

    // (7) AUDIT: exactly the THREE DISPATCHED calls were recorded — echo(1), double(2), echo(1) —
    // each carrying the agent's pid (from) and the tool id (tag). The Denied call (tool 9), the
    // NoSuchTool call (tool 5), and the Exhausted call (tool 2) were never dispatched, so they
    // leave no audit entry: 9 and 5 must NOT appear, and there are exactly 3 events.
    let aud: *mut IpcTrace = cap_audit();
    if ipc_trace_len(aud) != 3 { pass = 0; }
    let expect_tools: [3]u32 = .{ 1, 2, 1 };
    var i: usize = 0;
    while i < 3 {
        switch ipc_trace_drain(aud) {
            ok(ev) => {
                if ev.from != agent_pid { pass = 0; }       // caller = the agent
                if ev.tag != expect_tools[i] { pass = 0; }  // tool id
                if ev.to != 0 { pass = 0; }
                if ev.size != 0 { pass = 0; }
            }
            err(e) => { pass = 0; }
        }
        i = i + 1;
    }
    if ipc_trace_len(aud) != 0 { pass = 0; } // drained dry — no extra (Denied/NoSuchTool) entries

    return pass;
}
