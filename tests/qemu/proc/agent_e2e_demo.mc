// END-TO-END agent-on-OS showcase: ONE image that boots the heap + console, then runs a
// realistic SANDBOXED-AGENT story INLINE on the boot thread under REAL QEMU emulation. This
// ties the whole agent-OS stack together: boot -> governance (proc table + cap audit) ->
// sandbox (attenuated process + tool allowlist + call budget) -> the tool-call ABI ->
// capability/budget enforcement -> audit.
//
// The story: a confined agent is spawned with an attenuated authority, a tool allowlist of
// {load, process} (the forbidden `net` tool is NOT in its mask), and a tool-call budget of 4.
// It then does useful work through agent_tool_call:
//   * load    -> ok(21)           (an allowed tool dispatches)        -> 'L'
//   * process -> ok(42)           (process doubles its input)         -> 'P'
//   * net     -> err(.Denied)     (sandbox blocks the forbidden tool) -> 'D'
//   * load    -> ok(21)           (spend budget)                      -> 'L'
//   * process -> ok(42)           (spend the last budget unit)        -> 'P'
//   * load    -> err(.Exhausted)  (the budget bound holds)            -> 'X'
// Finally we DRAIN cap_audit() and assert exactly the FOUR dispatched calls were recorded
// (load, process, load, process), each carrying the agent's pid (from) and the tool id (tag);
// the Denied and Exhausted calls left NO audit entry -> 'A'. On full success the runtime prints
// AGENT-E2E-OK.
//
// Boot scaffolding (heap init, UART-as-console bring-up, the `export fn` entry the runtime calls,
// stage markers over the console, the returned success bitmask) mirrors agentos_demo.mc exactly.

import "kernel/core/agent.mc";      // pulls process.mc + ipc_trace.mc + std/mask.mc
import "kernel/core/heap.mc";
import "kernel/bus/chardev.mc";
import "std/addr.mc";

const UART_BASE: usize = 0x1000_0000;

struct Uart { base: usize }

global g_chardevs: CharRegistry;
global g_uart: Uart;
global g_uart_id: usize;
global g_t: ProcTable;
global g_reg: ToolRegistry;

impl CharDevice for Uart {
    fn putc(self: *Uart, b: u8) -> void {
        unsafe {
            raw.store<u8>(phys(self.base), b);
        }
    }
}

// Print one byte through the registered console driver (the driver framework in use).
fn say(c: u8) -> void {
    chardev_putc(&g_chardevs, g_uart_id, c);
}

// Mock tools: in-process handlers standing in for real services reached over IPC. Inputs are
// kept small so process's add cannot overflow (no checked-arith trap).
fn tool_load(x: u32) -> u32 { return 21; }            // id 1 — returns a fixed input
fn tool_process(x: u32) -> u32 { return x + x; }      // id 2 — doubles its input (21 -> 42)
fn tool_net(x: u32) -> u32 { return x; }              // id 9 — forbidden by default (not in mask)

// The agent's process entry. A no-op here: we drive the tool-call ABI directly from the boot
// thread (full U-mode execution of the agent is a later phase).
fn agent_worker() -> void {}

// The end-to-end agent-on-OS story, driven inline on the boot thread.
fn run_e2e() -> bool {
    var pass: bool = true;
    proc_table_init(&g_t);
    cap_audit_init();
    tool_registry_init(&g_reg);

    // System tool registry: load (1), process (2), and net (9 — the forbidden tool).
    switch tool_register(&g_reg, 1, tool_load)    { ok(s) => {} err(e) => { pass = false; } }
    switch tool_register(&g_reg, 2, tool_process) { ok(s) => {} err(e) => { pass = false; } }
    switch tool_register(&g_reg, 9, tool_net)     { ok(s) => {} err(e) => { pass = false; } }

    // Spawn a SANDBOXED agent, confined: tool_mask = {1,2} (load + process; net=9 NOT allowed),
    // call_budget = 4. allow/kcall subsets are full (bootstrap has full authority; the tool layer
    // is what this demo exercises).
    var tool_mask: Mask32 = mask32_zero();
    mask32_set(&tool_mask, 1);
    mask32_set(&tool_mask, 2);
    let full: Mask32 = mask32_from(0xFFFF_FFFF);
    var sb: Sandbox = agent_spawn(&g_t, 0x1000, agent_worker, full, full, tool_mask, 4);
    let agent_pid: u32 = proc_pid_at(&g_t, sb.slot);
    if pass { say(0x53); } // 'S' — agent spawned confined (attenuated caps + tool allowlist + budget)

    // --- the agent's tool-call loop (doing useful work) ---

    // load -> ok(21)
    switch agent_tool_call(&g_t, &g_reg, &sb, 1, 0) {
        ok(v) => { if v != 21 { pass = false; } say(0x4C); } // 'L'
        err(e) => { pass = false; }
    }
    // process(21) -> ok(42)
    switch agent_tool_call(&g_t, &g_reg, &sb, 2, 21) {
        ok(v) => { if v != 42 { pass = false; } say(0x50); } // 'P'
        err(e) => { pass = false; }
    }
    // net -> err(.Denied): the sandbox blocks the forbidden tool, with no budget spent.
    let budget_before_denied: u32 = sb.calls_left; // == 2
    switch agent_tool_call(&g_t, &g_reg, &sb, 9, 0) {
        ok(v) => { pass = false; }
        err(e) => { if e != .Denied { pass = false; } say(0x44); } // 'D'
    }
    if sb.calls_left != budget_before_denied { pass = false; } // Denied spent no budget

    // two more allowed calls spend the remaining budget: load -> ok(21), process -> ok(42).
    switch agent_tool_call(&g_t, &g_reg, &sb, 1, 0) {
        ok(v) => { if v != 21 { pass = false; } say(0x4C); } // 'L'
        err(e) => { pass = false; }
    }
    switch agent_tool_call(&g_t, &g_reg, &sb, 2, 21) {
        ok(v) => { if v != 42 { pass = false; } say(0x50); } // 'P'
        err(e) => { pass = false; }
    }
    if sb.calls_left != 0 { pass = false; } // budget fully spent

    // one more allowed call -> err(.Exhausted): the budget bound holds.
    switch agent_tool_call(&g_t, &g_reg, &sb, 1, 0) {
        ok(v) => { pass = false; }
        err(e) => { if e != .Exhausted { pass = false; } say(0x58); } // 'X'
    }

    // --- audit: all tool verdicts were recorded. Dispatched calls are Allow
    // events tagged by tool id; Denied/Exhausted requests are Deny events tagged
    // by rejection kind with the raw tool id in size. ---
    let aud: *mut IpcTrace = cap_audit();
    if ipc_trace_len(aud) != 6 { pass = false; }
    let expect_to: [6]u32 = .{ TOOL_AUDIT_ALLOW, TOOL_AUDIT_ALLOW, TOOL_AUDIT_DENY, TOOL_AUDIT_ALLOW, TOOL_AUDIT_ALLOW, TOOL_AUDIT_DENY };
    let expect_tags: [6]u32 = .{ 1, 2, TOOL_AUDIT_DENIED_TAG, 1, 2, TOOL_AUDIT_EXHAUSTED_TAG };
    let expect_size: [6]u32 = .{ 0, 0, 9, 0, 0, 1 };
    var i: usize = 0;
    while i < 6 {
        switch ipc_trace_drain(aud) {
            ok(ev) => {
                if ev.from != agent_pid { pass = false; } // caller = the agent
                if ev.to != expect_to[i] { pass = false; }
                if ev.tag != expect_tags[i] { pass = false; }
                if ev.size != expect_size[i] { pass = false; }
            }
            err(e) => { pass = false; }
        }
        i = i + 1;
    }
    if ipc_trace_len(aud) != 0 { pass = false; } // drained dry
    if pass { say(0x41); } // 'A' — audit correct (exactly the dispatched tool-use transcript)

    return pass;
}

export fn agent_e2e_main(region_base: usize, region_len: usize) -> u32 {
    var stages: u32 = 0;

    // 1) Heap allocator.
    var heap: Heap = uninit;
    heap_init_untracked(&heap, phys_range(pa(region_base), region_len));
    let probe: PAddr = heap_alloc(&heap, 64, 16);
    if pa_value(probe) != 0 {
        stages = stages | 0x1;
    }

    // 2) Driver framework: register the UART as the console device.
    char_registry_init(&g_chardevs);
    g_uart.base = UART_BASE;
    g_uart_id = register_chardev(&g_chardevs, &g_uart);
    stages = stages | 0x2;
    say(0x31); // '1' — heap + console are up

    // 3) The end-to-end sandboxed-agent story, inline on the boot thread.
    if run_e2e() {
        stages = stages | 0x4;
        say(0x32); // '2' — e2e story passed
    }

    return stages;
}
