// Self-verifying fixture for the policy plane (kernel/core/policy).
//
// Fills an audit ring with allow/deny records attributed to several agents
// (exactly the shape the FS tool server + agent front door emit), drains it into
// the policy, and asserts the per-agent counters and the escalating
// Allow/Throttle/Revoke/Kill decisions — plus the table-overflow flag when more
// distinct agents are seen than the policy can track. Returns 1 iff all hold.

import "kernel/core/policy.mc";
import "kernel/core/ipc_trace.mc";

global g_audit: IpcTrace;
global g_pol: Policy;
global g_pol2: Policy;

const V_ALLOW: u32 = 1;
const V_DENY: u32 = 0;

// Encode an action so the C side compares a scalar.
fn act(a: PolicyAction) -> u32 {
    switch a {
        .Allow => { return 0; }
        .Throttle => { return 1; }
        .Revoke => { return 2; }
        .Kill => { return 3; }
    }
}
fn decide(pid: u32) -> u32 {
    return act(policy_decide(&g_pol, pid));
}

fn rec(from: u32, verdict: u32) -> void {
    ipc_trace_record(&g_audit, from, verdict, 0, 0);
}

export fn policy_run() -> u32 {
    var pass: u32 = 1;
    ipc_trace_init(&g_audit);
    // Thresholds: Throttle at 2 denials, Revoke at 3, Kill at 5.
    policy_init(&g_pol, 2, 3, 5);

    // Agent 7: 1 allow, 4 denials. Agent 9: 2 allows, 0 denials. (7 events < ring cap 16.)
    rec(7, V_ALLOW);
    rec(7, V_DENY); rec(7, V_DENY); rec(7, V_DENY); rec(7, V_DENY);
    rec(9, V_ALLOW); rec(9, V_ALLOW);

    let consumed: usize = policy_scan(&g_pol, &g_audit);
    if consumed != 7 { pass = 0; }
    if ipc_trace_len(&g_audit) != 0 { pass = 0; } // fully drained

    // Counters folded correctly.
    if policy_allows(&g_pol, 7) != 1 { pass = 0; }
    if policy_denies(&g_pol, 7) != 4 { pass = 0; }
    if policy_allows(&g_pol, 9) != 2 { pass = 0; }
    if policy_denies(&g_pol, 9) != 0 { pass = 0; }

    // Decisions: agent 7 has 4 denials -> Revoke (>=3, <5); agent 9 -> Allow.
    if decide(7) != 2 { pass = 0; } // Revoke
    if decide(9) != 0 { pass = 0; } // Allow

    // One more denial pushes agent 7 to 5 -> Kill.
    policy_observe(&g_pol, 7, V_DENY);
    if policy_denies(&g_pol, 7) != 5 { pass = 0; }
    if decide(7) != 3 { pass = 0; } // Kill

    // Throttle boundary: a fresh agent with exactly 2 denials -> Throttle.
    policy_observe(&g_pol, 5, V_DENY);
    policy_observe(&g_pol, 5, V_DENY);
    if decide(5) != 1 { pass = 0; } // Throttle

    // An unobserved agent decides Allow (no denial pressure).
    if decide(123) != 0 { pass = 0; }

    // Overflow: a fresh policy seeing more distinct agents than it can hold flags
    // the loss (and the untracked agent still decides Allow, never a false Kill).
    policy_init(&g_pol2, 2, 3, 5);
    var pid: u32 = 100;
    while pid < 111 { // 11 distinct agents > POL_MAX_AGENTS (8)
        policy_observe(&g_pol2, pid, V_DENY);
        pid = pid + 1;
    }
    if !policy_overflowed(&g_pol2) { pass = 0; }
    // The first 8 distinct agents are tracked: agent 100's single denial folded.
    if policy_denies(&g_pol2, 100) != 1 { pass = 0; }
    // A dropped (overflowed) agent is untracked: reads as 0 denials and decides
    // Allow — a full table never manufactures a denial it didn't see.
    if policy_denies(&g_pol2, 110) != 0 { pass = 0; }
    if act(policy_decide(&g_pol2, 110)) != 0 { pass = 0; } // Allow (fail-safe)

    return pass;
}
