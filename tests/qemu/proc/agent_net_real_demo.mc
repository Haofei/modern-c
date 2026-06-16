// AGENT-OS NETWORK MODEL, REAL TRANSPORT: ONE image that boots virtio-net under QEMU, then runs a
// SANDBOXED agent making a BROKERED, egress-checked, budgeted, AUDITED network call that puts REAL
// PACKETS ON THE WIRE. This is the capstone of agent_net_demo: the broker's policy is identical, but
// the dispatch goes through the genuine kernel/net/tcp_socket transport (net_fetch_tcp) instead of a
// mock fn pointer — the allowed fetch active-opens a real TCP connection to a live HTTP server
// reachable via the slirp gateway and reads its real 200 response.
//
// The story: a confined agent is spawned with a per-agent EGRESS ALLOWLIST of {web=1} (the exfil
// destination evil=9 EXISTS in the broker's registry — mapped to a different (ip,port) — but is NOT
// in the agent's allowlist) and a network-request budget of 2. It reaches the network ONLY through
// the broker (net_fetch_tcp), never a raw socket:
//   * fetch(web=1)   -> REAL TCP GET to (10.0.2.2, PORT) -> the server's 200 + body token     -> 'W'
//   * fetch(evil=9)  -> err(.Denied): EGRESS BLOCKED — NO packet is sent to evil's (ip,port)   -> 'D'
//   * fetch(web=1)   -> spends the last budget unit (also a real GET; we keep only the first body)
//   * fetch(web=1)   -> err(.Budget): the network budget bound holds                            -> 'B'
// Finally we DRAIN cap_audit() and assert exactly the dispatched egresses were recorded (web, web —
// each carrying the agent's pid + the endpoint id + NET_TAG); the Denied (evil) and Budget calls
// left NO audit entry -> 'A'. The control plane is REAL and the allowed transport is REAL.
//
// Boot scaffolding (virtio-net discovery, the bump DMA + vrings) lives in the C runtime
// (agent_net_real_runtime.c), which calls agent_net_real_main and prints the response + final token.

import "kernel/core/net_broker.mc";  // net_fetch_tcp + registry + NetCap (pulls agent/process/ipc_trace/mask/tcp_socket/virtio_net/ethernet)
import "std/bytes.mc";

const UART_BASE: usize = 0x1000_0000;

const OUR_IP: u32 = 0x0A00_020F;  // 10.0.2.15 (QEMU guest)
const GW_IP: u32 = 0x0A00_0202;   // 10.0.2.2  (QEMU slirp gateway → host where python listens)
const EVIL_IP: u32 = 0x0A00_0203; // 10.0.2.3  — a DIFFERENT dest; the Denied path must reach it NOT
const OUR_PORT: u16 = 0xC000;     // 49152, an ephemeral source port

// Endpoint ids (also the egress-allowlist bit indices).
const EP_WEB: u32 = 1;
const EP_EVIL: u32 = 9;
const EVIL_PORT: u16 = 0x0050; // 80 — never connected to (Denied before any socket work)

// The accumulated HTTP response from the FIRST allowed fetch (read back by the runtime).
const RESP_CAP: usize = 4096;
global g_resp: [RESP_CAP]u8;
global g_resp_len: usize;

// The GET request line. Host is the gateway address the guest connects to.
// "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n"
global g_req: [40]u8;
global g_req_len: usize;

// The broker registry, the agent's process table, and the socket (owns one connection).
global g_t: ProcTable;
global g_reg: EndpointRegistry;
global g_sock: TcpSocket;

// A scratch RX region for received frames + a response staging buffer the broker drains into.
const RXBUF_CAP: usize = 2048;
global g_rxbuf: [RXBUF_CAP]u8;
global g_stage: [RESP_CAP]u8;

fn uart_putc(b: u8) -> void {
    unsafe {
        raw.store<u8>(phys(UART_BASE), b);
    }
}

fn req_set(i: usize, c: u8) -> void {
    g_req[i] = c;
}

// Build "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n" into g_req.
fn build_request() -> void {
    req_set(0, 0x47);  req_set(1, 0x45);  req_set(2, 0x54);  req_set(3, 0x20);  // "GET "
    req_set(4, 0x2F);  req_set(5, 0x20);                                        // "/ "
    req_set(6, 0x48);  req_set(7, 0x54);  req_set(8, 0x54);  req_set(9, 0x50);  // "HTTP"
    req_set(10, 0x2F); req_set(11, 0x31); req_set(12, 0x2E); req_set(13, 0x30); // "/1.0"
    req_set(14, 0x0D); req_set(15, 0x0A);                                       // CRLF
    req_set(16, 0x48); req_set(17, 0x6F); req_set(18, 0x73); req_set(19, 0x74); // "Host"
    req_set(20, 0x3A); req_set(21, 0x20);                                       // ": "
    req_set(22, 0x31); req_set(23, 0x30); req_set(24, 0x2E);                    // "10."
    req_set(25, 0x30); req_set(26, 0x2E);                                       // "0."
    req_set(27, 0x32); req_set(28, 0x2E);                                       // "2."
    req_set(29, 0x32);                                                          // "2"
    req_set(30, 0x0D); req_set(31, 0x0A);                                       // CRLF
    req_set(32, 0x0D); req_set(33, 0x0A);                                       // CRLF (end of headers)
    g_req_len = 34;
}

// Copy n bytes from the staging buffer region `src` into g_resp.
fn resp_capture(src: usize, n: usize) -> void {
    g_resp_len = 0;
    var rr: ByteReader = byte_reader(phys(src), n);
    var i: usize = 0;
    while i < n {
        if g_resp_len < RESP_CAP {
            g_resp[g_resp_len] = br_u8(&rr, i);
            g_resp_len = g_resp_len + 1;
        }
        i = i + 1;
    }
}

// The agent's process entry. A no-op: we drive the brokered network ABI directly from the boot
// thread (full U-mode execution of the agent is a later phase), exactly as agent_net_demo does.
fn agent_worker() -> void {}

// The agent-OS real-network story. `dst_port` is the live server port (slirp 10.0.2.2:dst_port).
// Returns a stage bitmask: bit0 = web fetch got the real body; bit1 = evil Denied; bit2 = Budget;
// bit3 = audit correct (the full pass is 0xF).
export fn agent_net_real_main(
    regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq, dst_port: u16,
) -> u32 {
    var stages: u32 = 0;
    build_request();
    g_resp_len = 0;

    // Bring the NIC up and ARP-resolve the gateway ONCE; the socket reuses the resolved gw MAC.
    var dev: NetDevice = .{ .regs = regs, .rxq = rxq, .txq = txq };
    switch nic_init(&dev) {
        ok(up) => {}
        err(e) => { return stages; }
    }
    var src_mac: MacAddr = .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };
    var gw_mac: MacAddr = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } };
    switch nic_arp_resolve(&dev, &src_mac, OUR_IP, GW_IP) {
        ok(m) => { gw_mac = m; }
        err(e) => { return stages; }
    }

    // Bind the socket to the device + RX scratch region (the broker connects through it).
    let rxaddr: usize = (&g_rxbuf[0]) as usize;
    tcp_socket_init(&g_sock, &dev, rxaddr, RXBUF_CAP);

    // The broker's control plane.
    proc_table_init(&g_t);
    cap_audit_init();
    endpoint_registry_init(&g_reg);

    // The registry: web=1 → the live server (10.0.2.2, dst_port); evil=9 → a DIFFERENT dest that
    // EXISTS but the agent isn't allowed to reach (the Denied path must put nothing on the wire to it).
    var ok_reg: bool = true;
    switch endpoint_register_tcp(&g_reg, EP_WEB, GW_IP, dst_port)     { ok(s) => {} err(e) => { ok_reg = false; } }
    switch endpoint_register_tcp(&g_reg, EP_EVIL, EVIL_IP, EVIL_PORT) { ok(s) => {} err(e) => { ok_reg = false; } }
    if !ok_reg {
        return stages;
    }

    // Spawn a SANDBOXED agent (full kcall/allow authority — the network layer is what we exercise).
    let full: Mask32 = mask32_from(0xFFFF_FFFF);
    let no_tools: Mask32 = mask32_zero();
    var sb: Sandbox = agent_spawn(&g_t, 0x1000, agent_worker, full, full, no_tools, 0);
    let agent_pid: u32 = proc_pid_at(&g_t, sb.slot);

    // The agent's NETWORK CAPABILITY: egress allowlist {web=1} (NOT evil=9), budget 2.
    var allowed: Mask32 = mask32_zero();
    mask32_set(&allowed, EP_WEB);
    var nc: NetCap = .{ .allowed = allowed, .requests_left = 2 };

    let reqaddr: usize = (&g_req[0]) as usize;
    let stageaddr: usize = (&g_stage[0]) as usize;

    // --- fetch(web): a REAL brokered TCP GET to the live server. ---
    switch net_fetch_tcp(&g_t, &g_reg, &sb, &nc, EP_WEB, 7,
                         &g_sock, &src_mac, &gw_mac, OUR_IP, OUR_PORT,
                         reqaddr, g_req_len, stageaddr, RESP_CAP) {
        ok(n) => {
            if n > 0 {
                resp_capture(stageaddr, n as usize); // keep the real body for the runtime to print
                stages = stages | 0x1;
                uart_putc(0x57); // 'W' — the allowed agent reached the web endpoint over real TCP
            }
        }
        err(e) => {}
    }

    // --- fetch(evil): EGRESS BLOCKED. evil exists in the registry (mapped to EVIL_IP), but it is
    // NOT in the agent's allowlist — Denied BEFORE any socket work, so NO packet hits EVIL_IP. ---
    let budget_before_denied: u32 = nc.requests_left; // == 1
    switch net_fetch_tcp(&g_t, &g_reg, &sb, &nc, EP_EVIL, 999,
                         &g_sock, &src_mac, &gw_mac, OUR_IP, OUR_PORT,
                         reqaddr, g_req_len, stageaddr, RESP_CAP) {
        ok(n) => {}
        err(e) => {
            if e == .Denied {
                if nc.requests_left == budget_before_denied { // Denied spent no budget
                    stages = stages | 0x2;
                    uart_putc(0x44); // 'D'
                }
            }
        }
    }

    // --- fetch(web) again: spends the last budget unit (a second real GET; body discarded). Use a
    // FRESH ephemeral source port so the slirp gateway treats it as a new connection (the previous
    // HTTP/1.0 connection closed, and its 4-tuple may linger in TIME_WAIT). ---
    switch net_fetch_tcp(&g_t, &g_reg, &sb, &nc, EP_WEB, 8,
                         &g_sock, &src_mac, &gw_mac, OUR_IP, OUR_PORT + 1,
                         reqaddr, g_req_len, stageaddr, RESP_CAP) {
        ok(n) => {}
        err(e) => {}
    }

    // --- fetch(web) once more: budget exhausted ⇒ Budget (the bound holds, no packet). ---
    switch net_fetch_tcp(&g_t, &g_reg, &sb, &nc, EP_WEB, 9,
                         &g_sock, &src_mac, &gw_mac, OUR_IP, OUR_PORT,
                         reqaddr, g_req_len, stageaddr, RESP_CAP) {
        ok(n) => {}
        err(e) => {
            if e == .Budget {
                stages = stages | 0x4;
                uart_putc(0x42); // 'B'
            }
        }
    }

    // --- audit: exactly the TWO DISPATCHED egresses (web, web), each carrying the agent's pid
    // (from), the endpoint id (to), and NET_TAG. The Denied (evil) + Budget calls left no entry. ---
    let aud: *mut IpcTrace = cap_audit();
    var audit_ok: bool = true;
    if ipc_trace_len(aud) != 2 { audit_ok = false; }
    let expect_req: [2]u32 = .{ 7, 8 };
    var i: usize = 0;
    while i < 2 {
        switch ipc_trace_drain(aud) {
            ok(ev) => {
                if ev.from != agent_pid { audit_ok = false; }   // caller = the agent
                if ev.to != EP_WEB { audit_ok = false; }        // only the web endpoint was reached
                if ev.tag != NET_TAG { audit_ok = false; }      // net egress tag
                if ev.size != expect_req[i] { audit_ok = false; }
            }
            err(e) => { audit_ok = false; }
        }
        i = i + 1;
    }
    if ipc_trace_len(aud) != 0 { audit_ok = false; } // drained dry — no Denied/Budget (evil) entries
    if audit_ok {
        stages = stages | 0x8;
        uart_putc(0x41); // 'A'
    }

    return stages;
}

// Accessors for the runtime to read back the captured real response body.
export fn agent_net_real_resp_len() -> usize {
    return g_resp_len;
}

export fn agent_net_real_resp_byte(i: usize) -> u8 {
    if i < g_resp_len {
        return g_resp[i];
    }
    return 0;
}
