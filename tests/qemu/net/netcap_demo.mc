// Self-verifying fixture for capability-gated network egress (kernel/net/netcap).
//
// Asserts milestone acceptance #3 at the capability level: an agent with NO
// network capability cannot reach any destination (default deny), an agent
// granted exactly one destination reaches that one and nothing else, port
// wildcards work, attenuation only narrows, and every verdict is audited and
// attributed to the agent. Returns 1 iff all hold.

import "kernel/net/netcap.mc";
import "kernel/core/ipc_trace.mc";

global g_audit: IpcTrace;

const AGENT: u32 = 7;
// NET_CONNECT / NV_DENY / NV_ALLOW come from the imported netcap module.

// Two destinations (host byte order IPv4) + ports.
const IP_A: u32 = 0x0A000005; // 10.0.0.5
const IP_B: u32 = 0x08080808; // 8.8.8.8
const PORT_HTTPS: u16 = 443;
const PORT_HTTP: u16 = 80;

fn nerr(e: NetError) -> u32 {
    switch e {
        .Denied => { return 10; }
        .NoRight => { return 11; }
        .Full => { return 12; }
    }
}

// egress check -> 2 = ok(allow), or a sentinel for the error.
fn egress(cap: *NetCap, ip: u32, port: u16) -> u32 {
    switch net_egress_check(&g_audit, cap, ip, port) {
        ok(v) => { return 2; }
        err(e) => { return nerr(e); }
    }
}

fn last_from() -> u32 {
    let n: usize = ipc_trace_len(&g_audit);
    if n == 0 { return 0xFFFF_FFFF; }
    switch ipc_trace_get(&g_audit, n - 1) {
        ok(ev) => { return ev.from; }
        err(e) => { return 0xFFFF_FFFF; }
    }
}
fn last_verdict() -> u32 {
    let n: usize = ipc_trace_len(&g_audit);
    if n == 0 { return 0xFFFF_FFFF; }
    switch ipc_trace_get(&g_audit, n - 1) {
        ok(ev) => { return ev.to; }
        err(e) => { return 0xFFFF_FFFF; }
    }
}

export fn netcap_run() -> u32 {
    var pass: u32 = 1;
    ipc_trace_init(&g_audit);

    // --- default deny: an agent with no net cap reaches nothing ---
    var none: NetCap = netcap_none(AGENT);
    if egress(&none, IP_B, PORT_HTTPS) != 11 { pass = 0; } // NoRight (no NET_CONNECT)
    if last_from() != AGENT { pass = 0; }
    if last_verdict() != NV_DENY { pass = 0; }

    // --- granted exactly one destination: that one allowed, others denied ---
    var cap: NetCap = netcap_connect(AGENT);
    if !netcap_allow(&cap, IP_A, PORT_HTTPS) { pass = 0; }

    if egress(&cap, IP_A, PORT_HTTPS) != 2 { pass = 0; } // allowed
    if last_verdict() != NV_ALLOW { pass = 0; }
    if last_from() != AGENT { pass = 0; }

    if egress(&cap, IP_B, PORT_HTTPS) != 10 { pass = 0; } // different host -> Denied
    if last_verdict() != NV_DENY { pass = 0; }
    if egress(&cap, IP_A, PORT_HTTP) != 10 { pass = 0; }  // same host, wrong port -> Denied
    if last_verdict() != NV_DENY { pass = 0; }

    // --- port wildcard (port 0 = any port on that host) ---
    var wild: NetCap = netcap_connect(AGENT);
    if !netcap_allow(&wild, IP_A, 0) { pass = 0; }
    if egress(&wild, IP_A, PORT_HTTP) != 2 { pass = 0; }  // any port allowed
    if egress(&wild, IP_A, PORT_HTTPS) != 2 { pass = 0; }
    if egress(&wild, IP_B, PORT_HTTP) != 10 { pass = 0; } // still host-scoped

    // --- table-full mint is rejected (capacity is NETCAP_MAX = 4) ---
    var full: NetCap = netcap_connect(AGENT);
    if !netcap_allow(&full, IP_A, 1) { pass = 0; }
    if !netcap_allow(&full, IP_A, 2) { pass = 0; }
    if !netcap_allow(&full, IP_A, 3) { pass = 0; }
    if !netcap_allow(&full, IP_A, 4) { pass = 0; }
    if netcap_allow(&full, IP_A, 5) { pass = 0; } // 5th -> table full, rejected

    // --- attenuation only narrows: keep one dest, drop the rest + drop rights ---
    var two: NetCap = netcap_connect(AGENT);
    if !netcap_allow(&two, IP_A, PORT_HTTPS) { pass = 0; }
    if !netcap_allow(&two, IP_B, PORT_HTTPS) { pass = 0; }
    // narrow to just IP_A:443, keeping NET_CONNECT
    var narrowed: NetCap = netcap_attenuate(&two, IP_A, PORT_HTTPS, NET_CONNECT);
    if egress(&narrowed, IP_A, PORT_HTTPS) != 2 { pass = 0; }  // kept
    if egress(&narrowed, IP_B, PORT_HTTPS) != 10 { pass = 0; } // dropped -> Denied
    // narrowing rights to 0 removes connect entirely
    var noconn: NetCap = netcap_attenuate(&two, IP_A, PORT_HTTPS, 0);
    if egress(&noconn, IP_A, PORT_HTTPS) != 11 { pass = 0; } // NoRight
    // attenuating to a dest the parent never had grants nothing
    var empty: NetCap = netcap_attenuate(&two, 0x01020304, PORT_HTTPS, NET_CONNECT);
    if egress(&empty, 0x01020304, PORT_HTTPS) != 10 { pass = 0; } // Denied (no dest carried)

    return pass;
}
