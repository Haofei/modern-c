// TCP-backed production JS net tool provider.
//
// qjs_net_real_runtime calls app_net_real_config before app_build(). This object then registers
// real init/fetch callbacks with app_run_demo's app_net_override_set seam, so the generic
// SYS_SUBMIT/SYS_POLL path dispatches host_net_fetch through net_fetch_tcp without pulling
// virtio/DMA code into the default mock-net app runtime.

import "kernel/net/net_broker_tcp.mc";
import "user/abi.mc";

const OUR_IP: u32 = 0x0A00_020F;  // 10.0.2.15 (QEMU guest)
const GW_IP: u32 = 0x0A00_0202;   // 10.0.2.2  (QEMU slirp gateway -> host)
const EVIL_IP: u32 = 0x0A00_0203; // denied endpoint, never contacted
const OUR_PORT_BASE: u16 = 0xC100;
const EVIL_PORT: u16 = 0x0050;
const EP_WEB: u32 = 1;
const EP_EVIL: u32 = 9;
const REQ_CAP: usize = 40;
const RESP_CAP: usize = 4096;
const RXBUF_CAP: usize = 2048;

extern fn app_net_override_set(init: fn() -> void, fetch: fn(u32, u32) -> i32) -> void;

global g_real_configured: bool;
global g_real_ready: bool;
global g_real_regs_base: usize;
global g_real_rxq: *mut Virtq;
global g_real_txq: *mut Virtq;
global g_real_port: u16;
global g_real_src_port: u16;
global g_real_dev: NetDevice;
global g_real_sock: TcpSocket;
global g_real_src_mac: MacAddr;
global g_real_gw_mac: MacAddr;
global g_real_t: ProcTable;
global g_real_reg: EndpointRegistry;
global g_real_sb: Sandbox;
global g_real_cap: NetCap;
global g_real_req: [REQ_CAP]u8;
global g_real_req_len: usize;
global g_real_resp: [RESP_CAP]u8;
global g_real_rxbuf: [RXBUF_CAP]u8;

fn req_set(i: usize, c: u8) -> void {
    g_real_req[i] = c;
}

// Build "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n".
fn build_request() -> void {
    req_set(0, 0x47);  req_set(1, 0x45);  req_set(2, 0x54);  req_set(3, 0x20);
    req_set(4, 0x2F);  req_set(5, 0x20);
    req_set(6, 0x48);  req_set(7, 0x54);  req_set(8, 0x54);  req_set(9, 0x50);
    req_set(10, 0x2F); req_set(11, 0x31); req_set(12, 0x2E); req_set(13, 0x30);
    req_set(14, 0x0D); req_set(15, 0x0A);
    req_set(16, 0x48); req_set(17, 0x6F); req_set(18, 0x73); req_set(19, 0x74);
    req_set(20, 0x3A); req_set(21, 0x20);
    req_set(22, 0x31); req_set(23, 0x30); req_set(24, 0x2E);
    req_set(25, 0x30); req_set(26, 0x2E);
    req_set(27, 0x32); req_set(28, 0x2E);
    req_set(29, 0x32);
    req_set(30, 0x0D); req_set(31, 0x0A);
    req_set(32, 0x0D); req_set(33, 0x0A);
    g_real_req_len = 34;
}

fn real_net_worker() -> void {}

fn broker_err_to_errno(e: BrokerError) -> i32 {
    switch e {
        .Denied => { return E_DENIED as i32; }
        .Budget => { return E_AGAIN as i32; }
        .NoEndpoint => { return -2; }
    }
}

fn app_net_real_start() -> void {
    g_real_ready = false;
    if !g_real_configured {
        return;
    }
    build_request();

    var regs: MmioPtr<VirtioMmio> = uninit;
    unsafe { regs = g_real_regs_base as MmioPtr<VirtioMmio>; }
    g_real_dev = .{ .regs = regs, .rxq = g_real_rxq, .txq = g_real_txq };
    switch nic_init(&g_real_dev) {
        ok(up) => {}
        err(e) => { return; }
    }

    g_real_src_mac = .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };
    g_real_gw_mac = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } };
    switch nic_arp_resolve(&g_real_dev, &g_real_src_mac, OUR_IP, GW_IP) {
        ok(m) => { g_real_gw_mac = m; }
        err(e) => { return; }
    }

    tcp_socket_init(&g_real_sock, &g_real_dev, (&g_real_rxbuf[0]) as usize, RXBUF_CAP);

    proc_table_init(&g_real_t);
    cap_audit_init();
    endpoint_registry_init(&g_real_reg);
    switch endpoint_register_tcp(&g_real_reg, EP_WEB, GW_IP, g_real_port) { ok(s) => {} err(e) => { return; } }
    switch endpoint_register_tcp(&g_real_reg, EP_EVIL, EVIL_IP, EVIL_PORT) { ok(s) => {} err(e) => { return; } }

    let full: Mask32 = mask32_from(0xFFFF_FFFF);
    let no_tools: Mask32 = mask32_zero();
    g_real_sb = agent_spawn(&g_real_t, 0x1000, real_net_worker, full, full, no_tools, 0);
    var allowed: Mask32 = mask32_zero();
    mask32_set(&allowed, EP_WEB);
    g_real_cap = .{ .allowed = allowed, .requests_left = 1 };
    g_real_ready = true;
}

fn app_net_real_fetch_tool(endpoint_id: u32, token: u32) -> i32 {
    if !g_real_ready {
        return E_DENIED as i32;
    }
    let reqaddr: usize = (&g_real_req[0]) as usize;
    let respaddr: usize = (&g_real_resp[0]) as usize;
    let sport: u16 = g_real_src_port;
    g_real_src_port = g_real_src_port + 1;
    switch net_fetch_tcp(&g_real_t, &g_real_reg, &g_real_sb, &g_real_cap, endpoint_id, token,
                         &g_real_sock, &g_real_src_mac, &g_real_gw_mac, OUR_IP, sport,
                         reqaddr, g_real_req_len, respaddr, RESP_CAP) {
        ok(n) => { return n as i32; }
        err(e) => { return broker_err_to_errno(e); }
    }
}

export fn app_net_real_config(regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq, dst_port: u16) -> void {
    g_real_regs_base = regs as usize;
    g_real_rxq = rxq;
    g_real_txq = txq;
    g_real_port = dst_port;
    g_real_src_port = OUR_PORT_BASE;
    g_real_configured = true;
    app_net_override_set(app_net_real_start, app_net_real_fetch_tool);
}
