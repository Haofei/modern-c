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
// CONTROL PLANE vs. DATA PLANE — what is REAL vs. what is MOCKED here:
//   * The CONTROL plane is REAL: the egress allowlist check, the budget bound, the endpoint
//     registry/lookup, the audit record, and the check ordering are exactly what a production
//     broker enforces.
//   * The PACKET SEND is MOCKED: each endpoint's `handler` returns a SIMULATED response, because
//     the QEMU test image has no live network peer. A real broker would, at the dispatch step,
//     `tcp_connect(host, port)` / `socket_send` / `socket_recv` to the resolved endpoint's
//     host:port via kernel/net — the registry would map an endpoint id to a (host, port, schema)
//     instead of to an in-process fn pointer.
//
// This layer is self-contained: it does NOT modify agent.mc or Process. The agent's NETWORK
// capability (`NetCap`: egress allowlist + request budget) lives here, layered beside the
// Sandbox's tool allowlist, not inside it.

import "kernel/core/agent.mc";      // Sandbox (pulls process.mc + ipc_trace.mc + std/mask.mc)
import "kernel/core/process.mc";    // ProcTable, proc_pid_at
import "kernel/core/ipc_trace.mc";  // ipc_trace_record (cap_audit() returns *mut IpcTrace)
import "std/mask.mc";               // Mask32, mask32_contains

// Failure modes of a brokered network call, kept typed so a caller (or its logs) can distinguish
// them. Order of checks is Denied BEFORE Budget BEFORE NoEndpoint (see net_fetch).
enum NetError {
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

// One registered endpoint: a stable id, its handler, and whether the slot is occupied. In the mock
// a handler is an in-process fn pointer returning a simulated response; in a real broker this would
// be an endpoint descriptor (host, port, request schema) the broker connects to over kernel/net.
struct NetEndpoint {
    id: u32,
    handler: fn(u32) -> u32,
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
        reg.eps[i].present = false;
        i = i + 1;
    }
}

// Register endpoint `id` with `handler` in the first free slot. Returns the claimed slot index, or
// err(.NoEndpoint) if the registry is full (no free slot). Mirrors agent.mc's tool_register.
export fn endpoint_register(reg: *mut EndpointRegistry, id: u32, handler: fn(u32) -> u32) -> Result<usize, NetError> {
    var i: usize = 0;
    while i < MAX_ENDPOINTS {
        if !reg.eps[i].present {
            reg.eps[i].id = id;
            reg.eps[i].handler = handler;
            reg.eps[i].present = true;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.NoEndpoint); // registry full — no slot to claim
}

// Resolve endpoint `id` to the registry SLOT that holds it; err(.NoEndpoint) if no present slot
// carries that id. (We return the slot index rather than the handler itself so the Result's
// ok-payload is a plain usize — a Result whose payload is a fn pointer is not emittable on the LLVM
// backend, and the registry is the single source of truth for the handler anyway. Fetch the handler
// with endpoint_handler_at(reg, slot).)
export fn endpoint_lookup(reg: *mut EndpointRegistry, id: u32) -> Result<usize, NetError> {
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
export fn net_fetch(t: *mut ProcTable, reg: *mut EndpointRegistry, sb: *mut Sandbox, nc: *mut NetCap, endpoint_id: u32, req: u32) -> Result<u32, NetError> {
    // 1. egress check: not in the agent's egress allowlist ⇒ Denied (the exfil block — no side
    //    effects, no budget spent, no egress audited).
    if !mask32_contains(&nc.allowed, endpoint_id) {
        return err(.Denied);
    }
    // 2. budget check: out of network-request budget ⇒ Budget (resource bound).
    if nc.requests_left == 0 {
        return err(.Budget);
    }
    // 3. resolve: unregistered destination ⇒ NoEndpoint. (Checked after Denied so an out-of-allowlist
    //    id never reveals whether it is registered, and after budget so a resolution failure spends
    //    no budget and is not audited.) endpoint_lookup returns the registry SLOT (a plain usize);
    //    we read the handler from it after audit+charge, so no fn-pointer local is ever needed
    //    (a fn-pointer Result payload / local is not emittable on the LLVM backend).
    switch endpoint_lookup(reg, endpoint_id) {
        ok(slot) => {
            // 4. audit: a network egress is a capability use — record it into the SAME provenance
            //    trace kcall/tool use is recorded in (cap_audit). from = the agent's pid,
            //    to = the endpoint id, tag = NET_TAG, size = the request. Only DISPATCHED egresses
            //    are recorded; the Denied/Budget/NoEndpoint returns above leave no entry.
            ipc_trace_record(cap_audit(), proc_pid_at(t, sb.slot), endpoint_id, NET_TAG, req);
            // 5. charge + dispatch: spend one request unit, then run the resolved handler. The
            //    handler is the MOCKED packet send — a real broker would tcp_connect/socket_recv to
            //    the endpoint's host:port via kernel/net here and return the peer's response.
            nc.requests_left = nc.requests_left - 1;
            let handler: fn(u32) -> u32 = endpoint_handler_at(reg, slot); // initialized, never uninit
            let resp: u32 = handler(req);
            return ok(resp);
        }
        err(e) => { return err(e); } // NoEndpoint — not in the registry; no budget spent, no audit.
    }
}
