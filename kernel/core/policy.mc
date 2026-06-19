// kernel/core/policy — the POLICY PLANE seed: consume the provenance/audit
// stream, decide control actions. (M5 mechanism; the kernel stays mechanism, the
// policy is the controller.)
//
// The capability layers (FS tool server, agent tool front door) append one audit
// record per authority decision — `from` = the agent, `to` = the verdict
// (ALLOW_VERDICT for allow, anything else for a denial), `tag` = the operation.
// This module is the DRAINER on the other side of that ring: it folds the events
// into per-agent allow/deny counters and maps accumulated DENIAL PRESSURE onto an
// escalating recommended action — Allow → Throttle → Revoke → Kill.
//
// It only DECIDES. Actuation (revoke a capability, throttle the budget, OOM-kill
// and reclaim the process) is the governance keystone's job — a controller wires
// `policy_decide` to `proc_oom_kill` / capability revocation. Keeping decision
// and actuation separate is the point: the policy plane is replaceable data, not
// kernel mechanism.

import "kernel/core/ipc_trace.mc";

const POL_MAX_AGENTS: usize = 8;

// The verdict code that counts as an ALLOW (matches the capability layers' V_ALLOW).
// Every other verdict value is treated as a denial — so both V_DENY and the front
// door's FD_DENY (each 0) fold into the deny counter.
const ALLOW_VERDICT: u32 = 1;

// Escalating control recommendation for an agent, by denial pressure.
enum PolicyAction {
    Allow,    // nominal — no denials of concern
    Throttle, // shrink the agent's budget / rate-limit it
    Revoke,   // revoke the offending capabilities
    Kill,     // OOM-kill + reclaim (governance keystone)
}

struct AgentStat {
    pid: u32,
    allows: u32,
    denies: u32,
    used: bool,
}

struct Policy {
    agents: [POL_MAX_AGENTS]AgentStat,
    throttle_at: u32, // denies >= this -> Throttle
    revoke_at: u32,   // denies >= this -> Revoke
    kill_at: u32,     // denies >= this -> Kill
    overflow: bool,   // more distinct agents observed than the table can hold
}

// Initialize with escalation thresholds (require throttle_at <= revoke_at <= kill_at).
export fn policy_init(p: *mut Policy, throttle_at: u32, revoke_at: u32, kill_at: u32) -> void {
    var i: usize = 0;
    while i < POL_MAX_AGENTS {
        p.agents[i].used = false;
        p.agents[i].pid = 0;
        p.agents[i].allows = 0;
        p.agents[i].denies = 0;
        i = i + 1;
    }
    p.throttle_at = throttle_at;
    p.revoke_at = revoke_at;
    p.kill_at = kill_at;
    p.overflow = false;
}

// Locate `pid`'s stat slot, allocating one on first sight. POL_MAX_AGENTS if the
// table is full (the caller records an overflow rather than losing the event).
fn find_or_add(p: *mut Policy, pid: u32) -> usize {
    var i: usize = 0;
    while i < POL_MAX_AGENTS {
        if p.agents[i].used {
            if p.agents[i].pid == pid {
                return i;
            }
        }
        i = i + 1;
    }
    var j: usize = 0;
    while j < POL_MAX_AGENTS {
        if !p.agents[j].used {
            p.agents[j].used = true;
            p.agents[j].pid = pid;
            p.agents[j].allows = 0;
            p.agents[j].denies = 0;
            return j;
        }
        j = j + 1;
    }
    return POL_MAX_AGENTS;
}

// Fold a single audit observation: an allow or a denial attributed to `from`.
export fn policy_observe(p: *mut Policy, from: u32, verdict: u32) -> void {
    let idx: usize = find_or_add(p, from);
    if idx == POL_MAX_AGENTS {
        p.overflow = true; // table full — the agent is untracked, flag the loss
        return;
    }
    if verdict == ALLOW_VERDICT {
        p.agents[idx].allows = p.agents[idx].allows + 1;
    } else {
        p.agents[idx].denies = p.agents[idx].denies + 1;
    }
}

// Drain the whole audit ring into the policy, consuming events. Returns the
// number folded. (Consuming is the controller model — it is THE drainer; the
// ring's `dropped` counter accounts for anything overwritten before this ran.)
export fn policy_scan(p: *mut Policy, trace: *mut IpcTrace) -> usize {
    var consumed: usize = 0;
    while true {
        switch ipc_trace_drain(trace) {
            ok(ev) => {
                policy_observe(p, ev.from, ev.to);
                consumed = consumed + 1;
            }
            err(e) => { break; }
        }
    }
    return consumed;
}

export fn policy_denies(p: *mut Policy, pid: u32) -> u32 {
    var i: usize = 0;
    while i < POL_MAX_AGENTS {
        if p.agents[i].used {
            if p.agents[i].pid == pid {
                return p.agents[i].denies;
            }
        }
        i = i + 1;
    }
    return 0;
}

export fn policy_allows(p: *mut Policy, pid: u32) -> u32 {
    var i: usize = 0;
    while i < POL_MAX_AGENTS {
        if p.agents[i].used {
            if p.agents[i].pid == pid {
                return p.agents[i].allows;
            }
        }
        i = i + 1;
    }
    return 0;
}

export fn policy_overflowed(p: *mut Policy) -> bool {
    return p.overflow;
}

// The recommended action for `pid`, by accumulated denial pressure. Checked
// highest-severity first so the thresholds escalate monotonically.
export fn policy_decide(p: *mut Policy, pid: u32) -> PolicyAction {
    let d: u32 = policy_denies(p, pid);
    if d >= p.kill_at {
        return .Kill;
    }
    if d >= p.revoke_at {
        return .Revoke;
    }
    if d >= p.throttle_at {
        return .Throttle;
    }
    return .Allow;
}
