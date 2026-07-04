// kernel/core/agent — a minimal but genuine AGENT-RUNTIME scaffold. An "agent" here is a
// confined process that makes capability-checked, resource-bounded, AUDITED tool calls. This
// layer ties together three mechanisms that already exist on the Process:
//   * attenuated authority  — proc_spawn_attenuated: the agent's kernel-op + IPC authority is a
//                             SUBSET of its spawner's (child caps = parent ∩ subset; confinement);
//   * a per-process memory quota — proc_macct / proc_charge_mem (the resource bound on memory);
// and adds, on top, the TOOL layer this file owns:
//   * a tool ALLOWLIST       — which tool ids the agent may invoke (capability confinement at the
//                             tool boundary, distinct from kernel-op authority);
//   * a tool-call BUDGET     — how many tool calls the agent may make (a resource bound on tool use);
//   * an AUDIT record        — every dispatched tool call is appended to the capability-use trace
//                             (cap_audit), so tool use is observable exactly like kcall authority use.
//
// SCAFFOLD — what is MOCK vs. what a real version would do:
//   * Real tools are SERVICES reached over IPC (a tool call is a request message to a server
//     process, mediated and audited by the IPC layer). This mock uses in-process fn-pointer
//     handlers (`fn(u32) -> u32`) so the whole thing is self-contained and host-testable on both
//     backends, with no message plumbing. The phased follow-up (R1 tool ABI, R2 real tools)
//     replaces the registry's fn-pointer dispatch with an IPC call to a tool server.
//   * The tool ALLOWLIST is a 32-bit Mask32 (tool id = bit index). A real manifest (R3) would
//     name tools and carry per-tool argument schemas; here an id is just a small integer.
//   * The registry is a flat fixed array (no allocation) — adequate for a scaffold; a real system
//     would discover tools from a manifest at agent-spawn time.

import "kernel/core/process.mc";   // ProcTable, proc_spawn_attenuated, proc_pid_at
import "kernel/core/ipc_trace.mc";  // ipc_trace_record (cap_audit() returns *mut IpcTrace)
import "std/mask.mc";               // Mask32, mask32_contains

// Failure modes of a tool call, kept typed so a caller (or its logs) can distinguish them.
pub enum ToolError {
    Denied,      // the tool id is not in the agent's tool allowlist — refused without side effects
    NoSuchTool,  // the tool id is not registered in the system's tool registry
    Exhausted,   // the agent's tool-call budget is used up (resource bound hit)
}

// Maximum tools the system registry can hold. Small and fixed (no allocation) — a scaffold bound.
const MAX_TOOLS: usize = 8;

// One registered tool: a stable id, its handler, and whether the slot is occupied. In the mock a
// handler is an in-process fn pointer; in a real system this would be a service endpoint to a tool
// server (and `handler` a request schema), reached over IPC.
pub struct ToolEntry {
    id: u32,
    handler: fn(u32) -> u32,
    present: bool,
}

// The system-wide TOOL REGISTRY: the set of tools the system offers. Disjoint from any one agent's
// ALLOWLIST — the registry says what exists; an agent's Sandbox.tools says what THAT agent may call.
pub struct ToolRegistry {
    tools: [MAX_TOOLS]ToolEntry,
}

// A SANDBOX = a confined agent. The agent's kernel-op authority and memory quota live on its
// Process (attenuated kcall_mask/allow_mask + macct, set by agent_spawn via proc_spawn_attenuated);
// this struct adds the tool-layer confinement:
//   * `tools`      — the tool ALLOWLIST: bit `id` set ⇒ the agent may call tool `id`;
//   * `calls_left` — the tool-call BUDGET: decremented per dispatched call, Exhausted at zero.
pub struct Sandbox {
    slot: usize,     // the agent's process slot (its identity in the ProcTable)
    tools: Mask32,   // tool allowlist (capability confinement at the tool boundary)
    calls_left: u32, // remaining tool-call budget (resource bound on tool use)
}

// ----- tool registry -----

// Clear every registry slot to "free". Call once before registering tools.
pub fn tool_registry_init(r: *mut ToolRegistry) -> void {
    var i: usize = 0;
    while i < MAX_TOOLS {
        r.tools[i].id = 0;
        r.tools[i].present = false;
        i = i + 1;
    }
}

// Register tool `id` with `handler` in the first free slot. Returns the claimed slot index, or
// err(.Exhausted) if the registry is full (no free slot). Does NOT dedupe ids — the registry is
// a set of slots, and tool_lookup returns the first matching id.
pub fn tool_register(r: *mut ToolRegistry, id: u32, handler: fn(u32) -> u32) -> Result<usize, ToolError> {
    var i: usize = 0;
    while i < MAX_TOOLS {
        if !r.tools[i].present {
            r.tools[i].id = id;
            r.tools[i].handler = handler;
            r.tools[i].present = true;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.Exhausted); // registry full — no slot to claim
}

// Resolve tool `id` to the registry SLOT that holds it; err(.NoSuchTool) if no present slot carries
// that id. (We return the slot index rather than the handler itself so the Result's ok-payload is a
// plain usize — a Result whose payload is a fn pointer is not emittable on the LLVM backend, and the
// registry is the single source of truth for the handler anyway. Fetch the handler with
// tool_handler_at(r, slot).)
pub fn tool_lookup(r: *mut ToolRegistry, id: u32) -> Result<usize, ToolError> {
    var i: usize = 0;
    while i < MAX_TOOLS {
        if r.tools[i].present {
            if r.tools[i].id == id {
                return ok(i);
            }
        }
        i = i + 1;
    }
    return err(.NoSuchTool);
}

// The handler stored in registry slot `slot`. Pair with a successful tool_lookup, which returns the
// slot to read. (Split out so tool_lookup's Result carries a plain index, not a fn pointer.)
pub fn tool_handler_at(r: *mut ToolRegistry, slot: usize) -> fn(u32) -> u32 {
    return r.tools[slot].handler;
}

// ----- sandbox: spawn + tool-call ABI -----

// Spawn a SANDBOXED agent. The agent's process is created via proc_spawn_attenuated, so its
// kernel-op + IPC authority is the INTERSECTION of the spawner's authority and the requested
// subsets (it can never exceed its spawner — confinement). The returned Sandbox layers the
// tool-allowlist (`tool_mask`) and tool-call budget (`call_budget`) on top. Together:
//   sandbox = attenuated process (kcall/allow caps + memory quota) + tool allowlist + call budget.
pub fn agent_spawn(t: *mut ProcTable, stack_top: usize, entry: fn() -> void, allow_subset: Mask32, kcall_subset: Mask32, tool_mask: Mask32, call_budget: u32) -> Sandbox {
    let pid: u32 = proc_spawn_attenuated(t, stack_top, entry, allow_subset, kcall_subset);
    return .{ .slot = pid as usize, .tools = tool_mask, .calls_left = call_budget };
}

// THE TOOL-CALL ABI. The single checked entry point through which a sandboxed agent invokes a
// tool. Checks run in a deliberate order — Denied BEFORE budget BEFORE NoSuchTool — so a forbidden
// tool is refused WITHOUT consuming the agent's budget, and only a dispatched call is audited:
//   1. capability check — tool id must be in the agent's allowlist (else Denied);
//   2. budget check     — the agent must have calls left (else Exhausted);
//   3. resolve          — the tool must be registered (else NoSuchTool);
//   4. audit            — record the (about-to-dispatch) call into the capability-use trace,
//                         from = the agent's pid, tag = tool id (a tool call IS authority use);
//   5. charge + dispatch — spend one budget unit, run the handler, return its result.
pub fn agent_tool_call(t: *mut ProcTable, reg: *mut ToolRegistry, sb: *mut Sandbox, tool_id: u32, arg: u32) -> Result<u32, ToolError> {
    // 1. capability check: not in the agent's tool allowlist ⇒ Denied (no side effects, no budget spent).
    if !mask32_contains(&sb.tools, tool_id) {
        return err(.Denied);
    }
    // 2. budget check: out of tool-call budget ⇒ Exhausted (resource bound).
    if sb.calls_left == 0 {
        return err(.Exhausted);
    }
    // 3. resolve: unregistered tool ⇒ NoSuchTool. (Checked after Denied so an out-of-allowlist id
    //    never reveals whether it is registered, and after budget so a resolution failure spends
    //    no budget and is not audited.) tool_lookup returns the registry SLOT (a plain usize);
    //    we read the handler from it after audit+charge, so no fn-pointer local is ever needed
    //    (a fn-pointer Result payload / local is not emittable on the LLVM backend).
    switch tool_lookup(reg, tool_id) {
        ok(slot) => {
            // 4. audit: a tool call is a capability use — record it into the SAME provenance trace
            //    kcall uses (cap_audit). from = the agent's pid, tag = the tool id. Only DISPATCHED
            //    calls are recorded; the Denied/Exhausted/NoSuchTool returns above leave no entry.
            ipc_trace_record(cap_audit(), proc_pid_at(t, sb.slot), 0, tool_id, 0);
            // 5. charge + dispatch: spend one budget unit, run the resolved handler, return its result.
            sb.calls_left = sb.calls_left - 1;
            let handler: fn(u32) -> u32 = tool_handler_at(reg, slot); // initialized, never uninit
            let result: u32 = handler(arg);
            return ok(result);
        }
        err(e) => { return err(e); } // NoSuchTool — not in the registry; no budget spent, no audit.
    }
}
