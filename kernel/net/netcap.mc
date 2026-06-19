// kernel/net/netcap — capability-gated network egress (milestone acceptance #3).
//
// The thesis says an agent reaches the network only through a capability-checked
// tool, and an agent that holds no network capability cannot open a connection at
// all. This is the egress capability and its mediation, modelled exactly like the
// FS PathCap: a NetCap names the destinations an agent may connect to; an egress
// request is checked against it and every verdict (allow AND deny) is audited and
// attributed. The DEFAULT is deny-all — an agent minted with `netcap_none` has no
// reachable destination, so the (gated, real) TCP/TLS stack is simply unreachable
// for it. Authority is added only kernel-side and only NARROWS under attenuation.
//
// Destinations are exact IPv4 host + port, with port 0 meaning "any port on that
// host". That is deliberately coarse — the point here is the capability GATE in
// front of egress, not a routing policy language; richer matching (CIDR, DNS
// name, SNI) layers on later without changing the gate's shape.

import "kernel/core/ipc_trace.mc";

const NETCAP_MAX: usize = 4; // destinations a single cap can name

// Rights a network capability may carry (attenuation only clears bits).
const NET_CONNECT: u32 = 1;

// Verdict + op codes for the audit trail (same convention as the FS layers:
// to=verdict, tag=op; ALLOW verdict is 1 so the policy plane folds it correctly).
const NV_DENY: u32 = 0;
const NV_ALLOW: u32 = 1;
const OP_NET_CONNECT: u32 = 0x2000;

struct NetDest {
    ip: u32,   // IPv4, host byte order
    port: u16, // 0 == any port on `ip`
    used: bool,
}

struct NetCap {
    agent_pid: u32,
    rights: u32,
    dests: [NETCAP_MAX]NetDest,
    count: usize,
}

enum NetError {
    Denied,  // no destination in the cap matches the request
    NoRight, // cap lacks NET_CONNECT
    Full,    // destination table full (mint-time)
}

// Mint a deny-all capability (no destinations, no rights): the agent cannot reach
// the network at all. This is the default an untrusted agent receives.
export fn netcap_none(agent_pid: u32) -> NetCap {
    var c: NetCap = uninit;
    c.agent_pid = agent_pid;
    c.rights = 0;
    c.count = 0;
    var i: usize = 0;
    while i < NETCAP_MAX {
        c.dests[i].used = false;
        c.dests[i].ip = 0;
        c.dests[i].port = 0;
        i = i + 1;
    }
    return c;
}

// Mint a connect-capable capability with no destinations yet (add them with
// netcap_allow). Kernel-side only — an agent has no widening constructor.
export fn netcap_connect(agent_pid: u32) -> NetCap {
    var c: NetCap = netcap_none(agent_pid);
    c.rights = NET_CONNECT;
    return c;
}

// Authorize destination `ip:port` (port 0 = any port on `ip`). Kernel-side mint
// operation; false if the destination table is full.
export fn netcap_allow(c: *mut NetCap, ip: u32, port: u16) -> bool {
    if c.count >= NETCAP_MAX {
        return false;
    }
    c.dests[c.count].ip = ip;
    c.dests[c.count].port = port;
    c.dests[c.count].used = true;
    c.count = c.count + 1;
    return true;
}

fn dest_matches(c: *NetCap, ip: u32, port: u16) -> bool {
    var i: usize = 0;
    while i < c.count {
        if c.dests[i].used {
            if c.dests[i].ip == ip {
                if c.dests[i].port == 0 {
                    return true; // any port on this host
                }
                if c.dests[i].port == port {
                    return true;
                }
            }
        }
        i = i + 1;
    }
    return false;
}

fn net_audit(sink: *mut IpcTrace, c: *NetCap, verdict: u32, port: u16) -> void {
    ipc_trace_record(sink, c.agent_pid, verdict, OP_NET_CONNECT, port as u32);
}

// THE EGRESS GATE. Authorize an outbound connection to `ip:port` against `cap`,
// auditing the verdict attributed to the agent. ok(true) means the (real) net
// stack may proceed; any error means it must not — nothing leaves the host.
export fn net_egress_check(sink: *mut IpcTrace, cap: *NetCap, ip: u32, port: u16) -> Result<bool, NetError> {
    if (cap.rights & NET_CONNECT) != NET_CONNECT {
        net_audit(sink, cap, NV_DENY, port);
        return err(.NoRight);
    }
    if !dest_matches(cap, ip, port) {
        net_audit(sink, cap, NV_DENY, port);
        return err(.Denied);
    }
    net_audit(sink, cap, NV_ALLOW, port);
    return ok(true);
}

// Attenuate to a capability that keeps only the destinations also present in the
// requested subset AND a subset of rights. There is no widening: a destination
// not already authorized cannot be added here, and rights are intersected.
export fn netcap_attenuate(cap: *NetCap, keep_ip: u32, keep_port: u16, rights_keep: u32) -> NetCap {
    var out: NetCap = netcap_none(cap.agent_pid);
    out.rights = cap.rights & rights_keep;
    // Carry over only the (single) destination being narrowed to, and only if the
    // parent already authorized it.
    if dest_matches(cap, keep_ip, keep_port) {
        netcap_allow(&out, keep_ip, keep_port);
    }
    return out;
}
