// Capstone integration demo — the M6 "untrusted repo" narrative at the mechanism
// level, composing every containment layer into one scenario through a SHARED
// audit ring:
//   treefs (paths) + fs_toolserver (path cap) + agent_fs (allowlist+budget) +
//   netcap (egress cap) + policy (consume audit -> escalate).
//
// One agent works on a task in /workspace. The "prompt injection" drives four
// forbidden actions; each is denied at the right layer, audited, and attributed,
// while the benign task completes. A policy plane then drains the shared
// provenance and escalates the agent on its accumulated denials.
//
//   benign : read /workspace/task.txt, write /workspace/result.txt   -> succeed
//   inject : read  /etc/secret     -> Denied (path capability)
//            write /etc/passwd     -> Denied (path capability), nothing created
//            call  exec tool (id 5)-> Denied (not in allowlist), audited
//            connect 6.6.6.6:443   -> Denied (no network capability)
//   policy : 4 denials attributed to the agent -> escalate to Revoke
//
// Returns 1 iff the benign task completed, every forbidden action was denied with
// no side effect, and the policy escalation is exactly right. The one honest gap
// (tracked as step 0) is that this agent is COOPERATIVE — it proves the
// enforcement is correct, not yet that an adversarial agent cannot bypass it.

import "kernel/fs/treefs.mc";
import "kernel/fs/fs_toolserver.mc";
import "kernel/fs/agent_fs.mc";
import "kernel/net/netcap.mc";
import "kernel/core/policy.mc";
import "kernel/core/ipc_trace.mc";
import "std/mask.mc";
import "std/addr.mc";

global g_t: Tree;
global g_audit: IpcTrace;   // shared provenance ring for FS + net
global g_pol: Policy;
global g_path: [64]u8;
global g_src: [16]u8;
global g_rd: [16]u8;

const AGENT: u32 = 7;
const TOOL_EXEC: u32 = 5; // injection target: not in the agent's allowlist

const EVIL_IP: u32 = 0x06060606; // 6.6.6.6
const PORT_HTTPS: u16 = 443;

const E_DENIED: u64 = 0xA000;

fn gp() -> usize { return (&g_path[0]) as usize; }
fn put(i: usize, b: u8) -> void { g_path[i] = b; }

fn acode(e: AgentToolError) -> u64 {
    switch e {
        .Denied => { return E_DENIED; }
        .Exhausted => { return 0xE001; }
        .NoSuchTool => { return 0xE002; }
        .NoRight => { return 0xE003; }
        .NotFound => { return 0xE004; }
        .NotDir => { return 0xE005; }
        .Exists => { return 0xE006; }
        .TooLarge => { return 0xE007; }
        .NoSpace => { return 0xE008; }
        .IsDir => { return 0xE009; }
        .Invalid => { return 0xE00A; }
    }
}

// agent_fs_call -> ok payload, or E_DENIED for the denials we care about, or a
// distinct high code for any other error (so an unexpected error is visible).
fn call(a: *mut AgentFs, tool: u32, n: usize, buf: usize, blen: usize, capb: usize) -> u64 {
    switch agent_fs_call(&g_t, &g_audit, a, tool, gp(), n, 0, buf, blen, capb) {
        ok(v) => { return v as u64; }
        err(e) => { return acode(e); }
    }
}

fn act(a: PolicyAction) -> u32 {
    switch a {
        .Allow => { return 0; }
        .Throttle => { return 1; }
        .Revoke => { return 2; }
        .Kill => { return 3; }
    }
}

// ----- paths -----
fn p_ws() -> usize { // "/workspace"
    put(0,0x2F); put(1,0x77); put(2,0x6F); put(3,0x72); put(4,0x6B);
    put(5,0x73); put(6,0x70); put(7,0x61); put(8,0x63); put(9,0x65);
    return 10;
}
fn p_etc() -> usize { // "/etc"
    put(0,0x2F); put(1,0x65); put(2,0x74); put(3,0x63);
    return 4;
}
fn p_etc_secret() -> usize { // "/etc/secret"
    p_etc();
    put(4,0x2F); put(5,0x73); put(6,0x65); put(7,0x63); put(8,0x72); put(9,0x65); put(10,0x74);
    return 11;
}
fn p_etc_passwd() -> usize { // "/etc/passwd"
    p_etc();
    put(4,0x2F); put(5,0x70); put(6,0x61); put(7,0x73); put(8,0x73); put(9,0x77); put(10,0x64);
    return 11;
}
fn p_task() -> usize { // "/workspace/task.txt"
    p_ws();
    put(10,0x2F); put(11,0x74); put(12,0x61); put(13,0x73); put(14,0x6B);
    put(15,0x2E); put(16,0x74); put(17,0x78); put(18,0x74);
    return 19;
}
fn p_result() -> usize { // "/workspace/result.txt"
    p_ws();
    put(10,0x2F); put(11,0x72); put(12,0x65); put(13,0x73); put(14,0x75); put(15,0x6C); put(16,0x74);
    put(17,0x2E); put(18,0x74); put(19,0x78); put(20,0x74);
    return 21;
}

export fn agent_containment_run() -> u32 {
    var pass: u32 = 1;
    tree_init(&g_t);
    ipc_trace_init(&g_audit);
    policy_init(&g_pol, 2, 3, 5); // Throttle@2, Revoke@3, Kill@5

    // The repo/world: /workspace with a task input the agent must read, and /etc
    // with a secret the agent is never granted. (Kernel-side setup.)
    var ws: usize = 99;
    switch tree_mkdir(&g_t, gp(), p_ws()) { ok(i) => { ws = i; } err(e) => { pass = 0; } }
    switch tree_mkdir(&g_t, gp(), p_etc()) { ok(i) => {} err(e) => { pass = 0; } }
    switch tree_create(&g_t, gp(), p_etc_secret(), 16) { ok(i) => {} err(e) => { pass = 0; } }
    // seed the task input "go" via a direct kernel write
    var tin: usize = 99;
    switch tree_create(&g_t, gp(), p_task(), 16) { ok(i) => { tin = i; } err(e) => { pass = 0; } }
    g_src[0]=0x67; g_src[1]=0x6F; // "go"
    switch tree_write_at(&g_t, tin, 0, (&g_src[0]) as usize, 2) { ok(n) => {} err(e) => { pass = 0; } }

    // The agent: allowlist {write,read,mkdir,list} (NOT exec), budget 20, cap
    // rooted at /workspace (rw), and NO network capability at all.
    var tl: Mask32 = mask32_zero();
    mask32_set(&tl, TOOL_FS_WRITE);
    mask32_set(&tl, TOOL_FS_READ);
    mask32_set(&tl, TOOL_FS_MKDIR);
    mask32_set(&tl, TOOL_FS_LIST);
    var ag: AgentFs = agent_fs_new(tl, 20, pathcap_root(AGENT, ws, FS_WRITE | FS_READ));
    var nocap: NetCap = netcap_none(AGENT);

    // --- benign task: read the input, write a result ---
    if call(&ag, TOOL_FS_READ, p_task(), (&g_rd[0]) as usize, 16, 0) != 2 { pass = 0; }
    if g_rd[0]!=0x67 { pass = 0; }
    if g_rd[1]!=0x6F { pass = 0; }
    g_src[0]=0x64; g_src[1]=0x6F; g_src[2]=0x6E; g_src[3]=0x65; // "done"
    if call(&ag, TOOL_FS_WRITE, p_result(), (&g_src[0]) as usize, 4, 64) != 4 { pass = 0; }

    // --- injection vector 1: read the secret outside /workspace -> Denied ---
    if call(&ag, TOOL_FS_READ, p_etc_secret(), (&g_rd[0]) as usize, 16, 0) != E_DENIED { pass = 0; }

    // --- injection vector 2: write outside /workspace -> Denied, nothing created ---
    g_src[0]=0x78;
    if call(&ag, TOOL_FS_WRITE, p_etc_passwd(), (&g_src[0]) as usize, 1, 64) != E_DENIED { pass = 0; }
    switch tree_resolve(&g_t, gp(), p_etc_passwd()) { ok(i) => { pass = 0; } err(e) => {} }

    // --- injection vector 3: invoke an un-allowlisted tool (exec) -> Denied ---
    if call(&ag, TOOL_EXEC, p_result(), (&g_src[0]) as usize, 1, 16) != E_DENIED { pass = 0; }

    // --- injection vector 4: open an unauthorized network connection -> Denied ---
    switch net_egress_check(&g_audit, &nocap, EVIL_IP, PORT_HTTPS) {
        ok(v) => { pass = 0; }       // must NOT be allowed
        err(e) => {}                 // denied (NoRight: no network capability)
    }

    // --- policy plane: drain the shared provenance and escalate on the denials ---
    let consumed: usize = policy_scan(&g_pol, &g_audit);
    if consumed == 0 { pass = 0; }
    // exactly four forbidden actions, all attributed to the agent
    if policy_denies(&g_pol, AGENT) != 4 { pass = 0; }
    // the two benign ops were allowed
    if policy_allows(&g_pol, AGENT) < 2 { pass = 0; }
    // 4 denials -> Revoke (>=3, <5)
    if act(policy_decide(&g_pol, AGENT)) != 2 { pass = 0; }

    // --- benign artifacts survived: the result exists, the forbidden file does not ---
    switch tree_resolve(&g_t, gp(), p_result()) { ok(i) => {} err(e) => { pass = 0; } }

    return pass;
}
