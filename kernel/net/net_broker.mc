// kernel/core/net_broker — the AGENT-OS NETWORK EGRESS BROKER. A sandboxed agent NEVER touches a
// raw socket. To reach the network it calls this broker, which on its behalf:
//   * CAPABILITY-GATES the destination against the agent's per-agent EGRESS ALLOWLIST (the exfil
//     block — an agent may reach only the endpoint ids it was granted, e.g. the LLM/inference
//     endpoint, and is refused any other host);
//   * EGRESS-CHECKS + BUDGETS the request (a per-agent network-request budget bounds how many
//     outbound calls it can make);
//   * AUDITS every dispatched egress into the same capability-use trace (cap_audit) that kcall and
//     tool use are recorded in, so "who reached out, to which endpoint" is observable;
//   * then performs the I/O and returns the response.
//
// POLICY / TRANSPORT SPLIT. The broker's POLICY (egress allowlist check, budget bound, endpoint
// registry/lookup, audit record, and the check ordering) is generic and lives ONCE, in the shared
// helper net_policy_admit. The DISPATCH (transport) is injected:
//   * net_fetch     — the MOCK transport: each endpoint's `handler` (an in-process fn pointer)
//                     returns a SIMULATED response. Self-contained + host-testable on both backends;
//                     used by tests/qemu/proc/agent_net_demo (no live peer in that image).
//   * net_fetch_tcp — the REAL transport: after the SAME policy checks + audit, it active-opens a
//                     genuine TCP connection to the resolved endpoint's (dst_ip, dst_port) via
//                     kernel/net/tcp_socket, sends the request bytes, and drains the response —
//                     real packets on the wire under QEMU (tests/qemu/proc/agent_net_real_demo).
// Both entry points run policy IDENTICALLY: Denied BEFORE Budget BEFORE NoEndpoint; a denied
// destination spends no budget, sends NO packet, and is NOT audited as a real egress. The control
// plane is real in BOTH; only net_fetch's packet send is mocked.
//
// This layer is self-contained: it does NOT modify agent.mc or Process. The agent's NETWORK
// capability (`NetCap`: egress allowlist + request budget) lives here, layered beside the
// Sandbox's tool allowlist, not inside it.

import "kernel/core/agent.mc";      // Sandbox (pulls process.mc + ipc_trace.mc + std/mask.mc)
import "kernel/core/process.mc";    // ProcTable, proc_pid_at
import "kernel/core/ipc_trace.mc";  // ipc_trace_record (cap_audit() returns *mut IpcTrace)
import "kernel/net/tcp_socket.mc";  // TcpSocket + tcp_socket_connect/send/recv (the REAL transport)
import "kernel/net/ethernet.mc";    // MacAddr (the source/gateway MAC the real transport needs)
import "std/mask.mc";               // Mask32, mask32_contains

// Failure modes of a brokered network call, kept typed so a caller (or its logs) can distinguish
// them. Order of checks is Denied BEFORE Budget BEFORE NoEndpoint (see net_fetch). Named
// BrokerError (not NetError) to avoid colliding with kernel/net's NetError, which is now in this
// module's import closure via the real tcp_socket transport.
enum BrokerError {
    Denied,     // destination not in the agent's EGRESS ALLOWLIST — the exfil block; refused first,
                // before any budget is spent and without being audited as a real egress.
    NoEndpoint, // the destination id is not a registered endpoint (the broker can't reach it).
    Budget,     // the agent's network-request budget is exhausted (resource bound on network use).
}

// Maximum endpoints the broker's registry can hold. Small and fixed (no allocation) — a scaffold
// bound, mirroring agent.mc's MAX_TOOLS.
const MAX_ENDPOINTS: usize = 8;

// The tag stamped on every audited network egress, so net egress is distinguishable from tool/kcall
// use in the shared capability-use trace. (0x0E7 — a distinctive "net egress" marker.)
const NET_TAG: u32 = 0x0E7;

// One registered endpoint: a stable id, the slot-occupied flag, AND BOTH transport descriptors so
// either dispatch can resolve the SAME registry entry:
//   * `handler`           — the MOCK transport: an in-process fn pointer returning a simulated
//                           response (used by net_fetch);
//   * `dst_ip`/`dst_port` — the REAL transport descriptor: the (host, port) net_fetch_tcp
//                           active-opens a genuine TCP connection to (in network/host order as the
//                           tcp_socket layer expects: dst_ip is a u32 host address, dst_port a u16).
// A mock-only endpoint leaves dst_ip/dst_port zero; a real endpoint leaves handler unused. The
// registry is the single source of truth for both (endpoint_lookup returns the slot; the dispatch
// reads whichever descriptor it needs from it).
struct NetEndpoint {
    id: u32,
    handler: fn(u32) -> u32,
    dst_ip: u32,
    dst_port: u16,
    present: bool,
}

// The broker's ENDPOINT REGISTRY: the set of destinations the broker can reach (what EXISTS).
// Disjoint from any one agent's EGRESS ALLOWLIST — the registry says what destinations exist; a
// NetCap.allowed says which of them THAT agent may reach.
struct EndpointRegistry {
    eps: [MAX_ENDPOINTS]NetEndpoint,
}

// An agent's NETWORK CAPABILITY. Layered beside the Sandbox's tool allowlist (kept here, not in
// agent.mc / Process):
//   * `allowed`        — the EGRESS ALLOWLIST: bit `id` set ⇒ the agent may reach endpoint `id`;
//   * `requests_left`  — the network-request BUDGET: decremented per dispatched egress, Budget at zero.
struct NetCap {
    allowed: Mask32,    // egress allowlist (which endpoint ids the agent may reach)
    requests_left: u32, // remaining network-request budget (resource bound on network use)
}

// ----- endpoint registry -----

// Clear every registry slot to "free". Call once before registering endpoints.
export fn endpoint_registry_init(reg: *mut EndpointRegistry) -> void {
    var i: usize = 0;
    while i < MAX_ENDPOINTS {
        reg.eps[i].id = 0;
        reg.eps[i].dst_ip = 0;
        reg.eps[i].dst_port = 0;
        reg.eps[i].present = false;
        i = i + 1;
    }
}

// Register endpoint `id` with `handler` in the first free slot. Returns the claimed slot index, or
// err(.NoEndpoint) if the registry is full (no free slot). Mirrors agent.mc's tool_register.
export fn endpoint_register(reg: *mut EndpointRegistry, id: u32, handler: fn(u32) -> u32) -> Result<usize, BrokerError> {
    var i: usize = 0;
    while i < MAX_ENDPOINTS {
        if !reg.eps[i].present {
            reg.eps[i].id = id;
            reg.eps[i].handler = handler;
            reg.eps[i].dst_ip = 0;   // mock endpoint — no real destination
            reg.eps[i].dst_port = 0;
            reg.eps[i].present = true;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.NoEndpoint); // registry full — no slot to claim
}

// Register a REAL endpoint `id` mapped to a destination (dst_ip, dst_port) the broker active-opens
// a TCP connection to under net_fetch_tcp. Mirrors endpoint_register, but carries the transport
// descriptor instead of a mock handler. `handler` is left a null fn pointer (never dispatched on the
// TCP path). Returns the claimed slot index, or err(.NoEndpoint) if the registry is full.
export fn endpoint_register_tcp(reg: *mut EndpointRegistry, id: u32, dst_ip: u32, dst_port: u16) -> Result<usize, BrokerError> {
    var i: usize = 0;
    while i < MAX_ENDPOINTS {
        if !reg.eps[i].present {
            reg.eps[i].id = id;
            reg.eps[i].dst_ip = dst_ip;
            reg.eps[i].dst_port = dst_port;
            reg.eps[i].present = true;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.NoEndpoint); // registry full — no slot to claim
}

// The real destination (ip, port) stored in registry slot `slot`. Pair with a successful
// endpoint_lookup. (Split out, like endpoint_handler_at, so endpoint_lookup's Result carries a plain
// index.) Returns ip; read the port with endpoint_dst_port_at.
export fn endpoint_dst_ip_at(reg: *mut EndpointRegistry, slot: usize) -> u32 {
    return reg.eps[slot].dst_ip;
}

export fn endpoint_dst_port_at(reg: *mut EndpointRegistry, slot: usize) -> u16 {
    return reg.eps[slot].dst_port;
}

// Resolve endpoint `id` to the registry SLOT that holds it; err(.NoEndpoint) if no present slot
// carries that id. (We return the slot index rather than the handler itself so the Result's
// ok-payload is a plain usize — a Result whose payload is a fn pointer is not emittable on the LLVM
// backend, and the registry is the single source of truth for the handler anyway. Fetch the handler
// with endpoint_handler_at(reg, slot).)
export fn endpoint_lookup(reg: *mut EndpointRegistry, id: u32) -> Result<usize, BrokerError> {
    var i: usize = 0;
    while i < MAX_ENDPOINTS {
        if reg.eps[i].present {
            if reg.eps[i].id == id {
                return ok(i);
            }
        }
        i = i + 1;
    }
    return err(.NoEndpoint);
}

// The handler stored in registry slot `slot`. Pair with a successful endpoint_lookup, which returns
// the slot to read. (Split out so endpoint_lookup's Result carries a plain index, not a fn pointer.)
export fn endpoint_handler_at(reg: *mut EndpointRegistry, slot: usize) -> fn(u32) -> u32 {
    return reg.eps[slot].handler;
}

// ----- the brokered network call -----

// THE BROKERED CALL. The single checked entry point through which a sandboxed agent reaches the
// network. Checks run in a deliberate order — egress-Denied BEFORE budget BEFORE NoEndpoint — so a
// disallowed destination is refused WITHOUT spending the agent's budget and WITHOUT being audited as
// a real egress (a blocked exfil attempt leaves no egress record):
//   1. egress check — the destination must be in the agent's egress allowlist (else Denied);
//   2. budget check — the agent must have network budget left (else Budget);
//   3. resolve      — the destination must be a registered endpoint (else NoEndpoint);
//   4. audit        — record the (about-to-dispatch) egress into the capability-use trace,
//                     from = the agent's pid, to = the endpoint id, tag = NET_TAG, size = req;
//   5. charge + dispatch — spend one request unit, run the handler (MOCKED packet send), return
//                     its simulated response.
// ----- THE POLICY (shared by both transports) -----
//
// Run the broker's POLICY for one brokered call and, on admission, RESOLVE + AUDIT + CHARGE,
// returning the registry SLOT the transport should dispatch to. This is the single place the
// egress/budget/audit ordering lives, so the mock and the real transport are policed IDENTICALLY:
//   1. egress check — destination in the agent's egress allowlist (else Denied: no budget, no audit,
//                     and — critically for the real transport — NO packet, since we return before any
//                     socket work);
//   2. budget check — agent has network-request budget left (else Budget);
//   3. resolve      — destination is a registered endpoint (else NoEndpoint);
//   4. audit        — record the (about-to-dispatch) egress into cap_audit (from = agent pid,
//                     to = endpoint id, tag = NET_TAG, size = req). Only ADMITTED calls are audited;
//   5. charge       — spend one request unit.
// Returns ok(slot) once steps 1–5 have all succeeded (so the caller need only dispatch); err(...)
// otherwise, with NO side effects (no audit, no charge) on any failure path.
fn net_policy_admit(t: *mut ProcTable, reg: *mut EndpointRegistry, sb: *mut Sandbox, nc: *mut NetCap, endpoint_id: u32, req: u32) -> Result<usize, BrokerError> {
    // 1. egress check: not in the agent's egress allowlist ⇒ Denied (the exfil block — no side
    //    effects, no budget spent, no egress audited, NO packet on the wire).
    if !mask32_contains(&nc.allowed, endpoint_id) {
        return err(.Denied);
    }
    // 2. budget check: out of network-request budget ⇒ Budget (resource bound).
    if nc.requests_left == 0 {
        return err(.Budget);
    }
    // 3. resolve: unregistered destination ⇒ NoEndpoint. (After Denied so an out-of-allowlist id
    //    never reveals whether it is registered; after budget so a resolution failure spends none.)
    switch endpoint_lookup(reg, endpoint_id) {
        ok(slot) => {
            // 4. audit: only ADMITTED egresses are recorded into the shared provenance trace.
            ipc_trace_record(cap_audit(), proc_pid_at(t, sb.slot), endpoint_id, NET_TAG, req);
            // 5. charge: spend one request unit. The transport-specific dispatch follows in the caller.
            nc.requests_left = nc.requests_left - 1;
            return ok(slot);
        }
        err(e) => { return err(e); } // NoEndpoint — not in the registry; no budget spent, no audit.
    }
}

// THE BROKERED CALL (MOCK transport). Runs the shared policy, then dispatches the resolved slot's
// in-process handler (the MOCKED packet send) and returns its simulated response. Used by
// agent_net_demo, where the QEMU image has no live peer.
export fn net_fetch(t: *mut ProcTable, reg: *mut EndpointRegistry, sb: *mut Sandbox, nc: *mut NetCap, endpoint_id: u32, req: u32) -> Result<u32, BrokerError> {
    switch net_policy_admit(t, reg, sb, nc, endpoint_id, req) {
        ok(slot) => {
            // Dispatch: the MOCK transport — run the resolved handler, return its simulated response.
            let handler: fn(u32) -> u32 = endpoint_handler_at(reg, slot); // initialized, never uninit
            let resp: u32 = handler(req);
            return ok(resp);
        }
        err(e) => { return err(e); } // Denied / Budget / NoEndpoint — no dispatch, no packet.
    }
}

// THE BROKERED CALL (REAL TCP transport). Runs the EXACT SAME policy as net_fetch (Denied before
// Budget before NoEndpoint; a Denied call sends NO packet and is not audited), then dispatches over
// a genuine TCP connection: it active-opens the socket to the resolved endpoint's (dst_ip, dst_port),
// sends `req_len` request bytes from `req_src`, and drains the response into `resp_dst`/`resp_max`.
// The caller supplies the bound socket, the source MAC, the resolved gateway MAC, the guest source
// IP + ephemeral source port, and the RX scratch region the socket receives frames into (the same
// shape http_get_demo uses). `req` (the audit size, an application request token) is recorded by the
// policy; the bytes actually sent are `req_src`/`req_len`.
//
// Returns ok(resp_len) — the number of response bytes drained into resp_dst (>0 on a real reply) —
// or err(.NoEndpoint) if the TCP active-open/send fails after admission (the dispatch could not
// reach the resolved endpoint). Policy failures return Denied/Budget/NoEndpoint as usual, BEFORE any
// socket work, so a denied destination never touches the wire.
export fn net_fetch_tcp(
    t: *mut ProcTable, reg: *mut EndpointRegistry, sb: *mut Sandbox, nc: *mut NetCap,
    endpoint_id: u32, req: u32,
    sock: *mut TcpSocket,
    src_mac: *MacAddr, gw_mac: *MacAddr, src_ip: u32, src_port: u16,
    req_src: usize, req_len: usize,
    resp_dst: usize, resp_max: usize,
) -> Result<u32, BrokerError> {
    switch net_policy_admit(t, reg, sb, nc, endpoint_id, req) {
        ok(slot) => {
            // Dispatch: the REAL transport. Resolve the destination, then put packets on the wire.
            let dst_ip: u32 = endpoint_dst_ip_at(reg, slot);
            let dst_port: u16 = endpoint_dst_port_at(reg, slot);

            // Active-open (SYN → SYN-ACK → ACK → ESTABLISHED) to the resolved endpoint.
            if tcp_socket_connect(sock, src_mac, gw_mac, src_ip, dst_ip, src_port, dst_port) == 0 {
                return err(.NoEndpoint); // could not reach the resolved endpoint
            }
            // Send the request bytes as one PSH|ACK segment.
            if tcp_socket_send(sock, req_src, req_len) == 0xFFFF_FFFF {
                return err(.NoEndpoint); // TX failure after connect
            }
            // Drain the response: the socket layer reassembles multi-record segments and ACKs them.
            var total: usize = 0;
            while true {
                if total >= resp_max {
                    break;
                }
                let n: u32 = tcp_socket_recv(sock, resp_dst + total, resp_max - total);
                if n == 0 {
                    break; // clean EOF (FIN)
                }
                if n == 0xFFFF_FFFF {
                    break; // timeout / no more segments
                }
                total = total + (n as usize);
            }
            return ok(total as u32);
        }
        err(e) => { return err(e); } // Denied / Budget / NoEndpoint — no dispatch, NO packet on the wire.
    }
}
