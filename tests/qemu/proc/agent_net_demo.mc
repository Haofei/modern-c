// AGENT-OS NETWORK MODEL showcase: ONE image that boots the heap + console, then runs a SANDBOXED
// agent making BROKERED, egress-checked, budgeted, AUDITED NETWORK calls INLINE on the boot thread
// under REAL QEMU emulation. This demonstrates the agent-OS network model: a confined agent reaches
// ITS ALLOWED endpoints (e.g. the LLM/inference endpoint) but is BLOCKED from exfiltrating to a
// disallowed host.
//
// The story: a confined agent is spawned with a per-agent EGRESS ALLOWLIST of {llm=1, metrics=2}
// (the exfil destination evil=9 EXISTS in the broker's registry but is NOT in the agent's allowlist)
// and a network-request budget of 3. It then reaches the network ONLY through the broker (net_fetch),
// never a raw socket:
//   * net_fetch(llm=1, 7)    -> ok(107)        (reaches the LLM endpoint — the inference call) -> 'N'
//   * net_fetch(metrics=2,5) -> ok(5)          (reaches the metrics endpoint)                  -> 'M'
//   * net_fetch(evil=9, 999) -> err(.Denied)   (EGRESS BLOCKED — can't exfiltrate; no budget
//                                               spent, not audited as an egress)               -> 'D'
//   * net_fetch(llm=1, 8)    -> ok(108)        (spend the last budget unit)
//   * net_fetch(llm=1, 9)    -> err(.Budget)   (the network budget bound holds)                -> 'B'
// Finally we DRAIN cap_audit() and assert exactly the THREE DISPATCHED egresses were recorded
// (llm, metrics, llm — each carrying the agent's pid (from), the endpoint id (to), and NET_TAG);
// the Denied (evil) and Budget calls left NO audit entry -> 'A'. On full success the runtime prints
// AGENT-NET-OK.
//
// CONTROL plane is REAL (egress allowlist + budget + registry/lookup + audit + ordering); the PACKET
// SEND is MOCKED (each endpoint handler returns a simulated response — the QEMU image has no live
// peer; a real broker would tcp_connect/socket_recv via kernel/net). See net_broker.mc's header.
//
// Boot scaffolding (heap init, UART-as-console bring-up, the `export fn` entry the runtime calls,
// stage markers over the console, the returned success bitmask) mirrors agent_e2e_demo.mc exactly.

import "kernel/net/net_broker.mc";  // net_fetch + registry + NetCap (pulls agent/process/ipc_trace/mask)
import "kernel/core/heap.mc";
import "kernel/core/device.mc";
import "std/addr.mc";

const UART_BASE: usize = 0x1000_0000;

struct Uart { base: usize }

global g_chardevs: CharRegistry;
global g_uart: Uart;
global g_uart_id: usize;
global g_t: ProcTable;
global g_reg: EndpointRegistry;

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

// Mock endpoints: in-process handlers standing in for real network services reached over kernel/net.
// Inputs are kept small so the add cannot overflow (no checked-arith trap).
fn ep_llm(req: u32) -> u32 { return req + 100; } // id 1 — the inference endpoint (req -> req+100)
fn ep_metrics(req: u32) -> u32 { return req; }   // id 2 — a metrics sink (echoes the request)
fn ep_evil(req: u32) -> u32 { return req; }      // id 9 — an exfil destination (exists, NOT allowed)

// The agent's process entry. A no-op here: we drive the brokered network ABI directly from the boot
// thread (full U-mode execution of the agent is a later phase).
fn agent_worker() -> void {}

// The agent-OS network-model story, driven inline on the boot thread.
fn run_net() -> bool {
    var pass: bool = true;
    proc_table_init(&g_t);
    cap_audit_init();
    endpoint_registry_init(&g_reg);

    // The broker's endpoint registry: the destinations that EXIST. llm (1), metrics (2), and evil
    // (9 — an exfil destination that exists but the agent isn't allowed to reach).
    switch endpoint_register(&g_reg, 1, ep_llm)     { ok(s) => {} err(e) => { pass = false; } }
    switch endpoint_register(&g_reg, 2, ep_metrics) { ok(s) => {} err(e) => { pass = false; } }
    switch endpoint_register(&g_reg, 9, ep_evil)    { ok(s) => {} err(e) => { pass = false; } }

    // Spawn a SANDBOXED agent (full kcall/allow authority — the network layer is what this demo
    // exercises; tool allowlist empty, call budget 0, unused here).
    let full: Mask32 = mask32_from(0xFFFF_FFFF);
    let no_tools: Mask32 = mask32_zero();
    var sb: Sandbox = agent_spawn(&g_t, 0x1000, agent_worker, full, full, no_tools, 0);
    let agent_pid: u32 = proc_pid_at(&g_t, sb.slot);

    // Build the agent's NETWORK CAPABILITY: egress allowlist {1,2} (may reach llm + metrics, NOT
    // evil=9), network-request budget 3.
    var allowed: Mask32 = mask32_zero();
    mask32_set(&allowed, 1);
    mask32_set(&allowed, 2);
    var nc: NetCap = .{ .allowed = allowed, .requests_left = 3 };
    if pass { say(0x53); } // 'S' — agent spawned confined with an egress allowlist

    // --- the agent's network loop (reaching the network only through the broker) ---

    // llm(7) -> ok(107): reaches the LLM endpoint (the inference call).
    switch net_fetch(&g_t, &g_reg, &sb, &nc, 1, 7) {
        ok(v) => { if v != 107 { pass = false; } say(0x4E); } // 'N'
        err(e) => { pass = false; }
    }
    // metrics(5) -> ok(5): reaches the metrics endpoint.
    switch net_fetch(&g_t, &g_reg, &sb, &nc, 2, 5) {
        ok(v) => { if v != 5 { pass = false; } say(0x4D); } // 'M'
        err(e) => { pass = false; }
    }
    // evil(999) -> err(.Denied): EGRESS BLOCKED. The destination exists in the registry, but it is
    // not in the agent's egress allowlist — refused without spending budget or being audited.
    let budget_before_denied: u32 = nc.requests_left; // == 1
    switch net_fetch(&g_t, &g_reg, &sb, &nc, 9, 999) {
        ok(v) => { pass = false; }
        err(e) => { if e != .Denied { pass = false; } say(0x44); } // 'D'
    }
    if nc.requests_left != budget_before_denied { pass = false; } // Denied spent no budget

    // one more allowed call spends the last budget unit: llm(8) -> ok(108).
    switch net_fetch(&g_t, &g_reg, &sb, &nc, 1, 8) {
        ok(v) => { if v != 108 { pass = false; } }
        err(e) => { pass = false; }
    }
    if nc.requests_left != 0 { pass = false; } // budget fully spent

    // one more allowed call -> err(.Budget): the network budget bound holds.
    switch net_fetch(&g_t, &g_reg, &sb, &nc, 1, 9) {
        ok(v) => { pass = false; }
        err(e) => { if e != .Budget { pass = false; } say(0x42); } // 'B'
    }

    // --- audit: exactly the THREE DISPATCHED egresses were recorded (llm, metrics, llm), each
    // carrying the agent's pid (from), the endpoint id (to), and NET_TAG (tag); size = the request.
    // The Denied (evil) and Budget calls were never dispatched, so they leave no audit entry. ---
    let aud: *mut IpcTrace = cap_audit();
    if ipc_trace_len(aud) != 3 { pass = false; }
    let expect_ep: [3]u32 = .{ 1, 2, 1 };
    let expect_req: [3]u32 = .{ 7, 5, 8 };
    var i: usize = 0;
    while i < 3 {
        switch ipc_trace_drain(aud) {
            ok(ev) => {
                if ev.from != agent_pid { pass = false; }     // caller = the agent
                if ev.to != expect_ep[i] { pass = false; }    // endpoint id reached
                if ev.tag != NET_TAG { pass = false; }        // net egress tag
                if ev.size != expect_req[i] { pass = false; } // the request
            }
            err(e) => { pass = false; }
        }
        i = i + 1;
    }
    if ipc_trace_len(aud) != 0 { pass = false; } // drained dry — no Denied/Budget entries (evil absent)
    if pass { say(0x41); } // 'A' — audit correct (exactly the dispatched egress transcript)

    return pass;
}

export fn agent_net_main(region_base: usize, region_len: usize) -> u32 {
    var stages: u32 = 0;

    // 1) Heap allocator.
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
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

    // 3) The agent-OS network-model story, inline on the boot thread.
    if run_net() {
        stages = stages | 0x4;
        say(0x32); // '2' — network story passed
    }

    return stages;
}
