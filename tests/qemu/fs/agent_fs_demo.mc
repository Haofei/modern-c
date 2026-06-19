// Acceptance demo (M6 shape, mechanism level) for the agent FS tool front door.
//
// One agent drives every action through agent_fs_call — the three-gate path
// (allowlist -> budget -> path capability). The fixture asserts the milestone's
// §6 acceptance vectors that this layer covers, each as a typed denial that is
// audited and attributable, while the benign task succeeds:
//   #6 benign task completes — write+read inside /workspace;
//   #2 workspace escape      — write to /etc DENIED by the path cap;
//   #1 secret exfiltration   — read of /etc/secret DENIED (agent holds no cap to it);
//   #5 tool-auth bypass      — calling an un-allowlisted tool id returns Denied,
//                              and (hardening) the denied attempt IS audited;
//   resource bound           — the call budget is enforced (Exhausted).
// (Vectors #3 network egress and #4 memory OOM are governed by the net-cap and
// quota mechanisms tracked for M5 and the gated governance keystone, not here.)
//
// Returns 1 iff every verdict, side effect, and audit record is exactly right.

import "kernel/fs/treefs.mc";
import "kernel/fs/fs_toolserver.mc";
import "kernel/fs/agent_fs.mc";
import "kernel/core/ipc_trace.mc";
import "std/mask.mc";
import "std/addr.mc";

global g_t: Tree;
global g_audit: IpcTrace;
global g_path: [64]u8;
global g_src: [16]u8;
global g_rd: [16]u8;

const AGENT: u32 = 7;
const TOOL_EXEC: u32 = 5; // not in the FS catalog and not allowlisted -> denied

// AgentToolError sentinels (distinct from 0..31 node indices / small counts).
const E_DENIED: u64 = 0xA000;
const E_EXHAUSTED: u64 = 0xA001;
const E_NOSUCHTOOL: u64 = 0xA002;
const E_NORIGHT: u64 = 0xA003;
const E_NOTFOUND: u64 = 0xA004;
const E_NOTDIR: u64 = 0xA005;
const E_EXISTS: u64 = 0xA006;
const E_TOOLARGE: u64 = 0xA007;
const E_NOSPACE: u64 = 0xA008;
const E_ISDIR: u64 = 0xA009;
const E_INVALID: u64 = 0xA00A;

fn acode(e: AgentToolError) -> u64 {
    switch e {
        .Denied => { return E_DENIED; }
        .Exhausted => { return E_EXHAUSTED; }
        .NoSuchTool => { return E_NOSUCHTOOL; }
        .NoRight => { return E_NORIGHT; }
        .NotFound => { return E_NOTFOUND; }
        .NotDir => { return E_NOTDIR; }
        .Exists => { return E_EXISTS; }
        .TooLarge => { return E_TOOLARGE; }
        .NoSpace => { return E_NOSPACE; }
        .IsDir => { return E_ISDIR; }
        .Invalid => { return E_INVALID; }
    }
}

fn gp() -> usize { return (&g_path[0]) as usize; }
fn put(i: usize, b: u8) -> void { g_path[i] = b; }

fn last_field(which: u32) -> u32 {
    let n: usize = ipc_trace_len(&g_audit);
    if n == 0 { return 0xFFFF_FFFF; }
    switch ipc_trace_get(&g_audit, n - 1) {
        ok(ev) => {
            if which == 0 { return ev.from; }
            if which == 1 { return ev.to; }
            return ev.tag;
        }
        err(e) => { return 0xFFFF_FFFF; }
    }
}
fn last_from() -> u32 { return last_field(0); }
fn last_verdict() -> u32 { return last_field(1); }
fn last_tag() -> u32 { return last_field(2); }

// agent_fs_call wrapper: ok payload, or a sentinel for the error.
fn call(a: *mut AgentFs, tool: u32, n: usize, off: usize, buf: usize, blen: usize, capb: usize) -> u64 {
    switch agent_fs_call(&g_t, &g_audit, a, tool, gp(), n, off, buf, blen, capb) {
        ok(v) => { return v as u64; }
        err(e) => { return acode(e); }
    }
}

// ----- path loaders -----

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
fn p_ws_notes() -> usize { // "/workspace/notes.txt"
    p_ws();
    put(10,0x2F); put(11,0x6E); put(12,0x6F); put(13,0x74); put(14,0x65); put(15,0x73);
    put(16,0x2E); put(17,0x74); put(18,0x78); put(19,0x74);
    return 20;
}

export fn agent_fs_run() -> u32 {
    var pass: u32 = 1;
    tree_init(&g_t);
    ipc_trace_init(&g_audit);

    // World: the agent's /workspace, plus /etc with a secret it is never granted.
    var ws: usize = 99;
    switch tree_mkdir(&g_t, gp(), p_ws()) { ok(i) => { ws = i; } err(e) => { pass = 0; } }
    switch tree_mkdir(&g_t, gp(), p_etc()) { ok(i) => {} err(e) => { pass = 0; } }
    switch tree_create(&g_t, gp(), p_etc_secret(), 32) { ok(i) => {} err(e) => { pass = 0; } }

    // The agent: allowlist {write,read,mkdir,list}, budget 10, cap rooted at /workspace (rw).
    var tl: Mask32 = mask32_zero();
    mask32_set(&tl, TOOL_FS_WRITE);
    mask32_set(&tl, TOOL_FS_READ);
    mask32_set(&tl, TOOL_FS_MKDIR);
    mask32_set(&tl, TOOL_FS_LIST);
    var ag: AgentFs = agent_fs_new(tl, 10, pathcap_root(AGENT, ws, FS_WRITE | FS_READ));

    // #6 benign task completes: write then read back inside /workspace.
    g_src[0]=0x68; g_src[1]=0x69; // "hi"
    if call(&ag, TOOL_FS_WRITE, p_ws_notes(), 0, (&g_src[0]) as usize, 2, 64) != 2 { pass = 0; }
    if last_verdict() != V_ALLOW { pass = 0; }
    if last_from() != AGENT { pass = 0; }
    if call(&ag, TOOL_FS_READ, p_ws_notes(), 0, (&g_rd[0]) as usize, 16, 0) != 2 { pass = 0; }
    if g_rd[0]!=0x68 { pass = 0; }
    if g_rd[1]!=0x69 { pass = 0; }

    // #2 workspace escape: write to /etc DENIED, no side effect.
    g_src[0]=0x7A;
    if call(&ag, TOOL_FS_WRITE, p_etc_passwd(), 0, (&g_src[0]) as usize, 1, 64) != E_DENIED { pass = 0; }
    if last_verdict() != V_DENY { pass = 0; }
    switch tree_resolve(&g_t, gp(), p_etc_passwd()) { ok(i) => { pass = 0; } err(e) => {} } // never created

    // #1 secret exfiltration: read /etc/secret DENIED (agent holds no cap to it).
    if call(&ag, TOOL_FS_READ, p_etc_secret(), 0, (&g_rd[0]) as usize, 16, 0) != E_DENIED { pass = 0; }
    if last_verdict() != V_DENY { pass = 0; }

    // #5 tool-auth bypass: an un-allowlisted tool id returns Denied — AND the
    // denied attempt is audited and attributed (the front-door hardening).
    let before: usize = ipc_trace_len(&g_audit);
    if call(&ag, TOOL_EXEC, p_ws_notes(), 0, (&g_src[0]) as usize, 1, 16) != E_DENIED { pass = 0; }
    if ipc_trace_len(&g_audit) != before + 1 { pass = 0; }      // the denied probe WAS recorded
    if last_from() != AGENT { pass = 0; }                       // attributed to the agent
    if last_verdict() != FD_DENY { pass = 0; }
    if last_tag() != FD_TOOL_TAG_BIAS + TOOL_EXEC { pass = 0; } // which tool was probed

    // resource bound: a budget-1 agent gets exactly one call, then Exhausted.
    var tw: Mask32 = mask32_zero();
    mask32_set(&tw, TOOL_FS_WRITE);
    var ab: AgentFs = agent_fs_new(tw, 1, pathcap_root(AGENT, ws, FS_WRITE | FS_READ));
    g_src[0]=0x6B; // 'k'
    if call(&ab, TOOL_FS_WRITE, p_ws_notes(), 0, (&g_src[0]) as usize, 1, 64) != 1 { pass = 0; }
    if agent_fs_calls_left(&ab) != 0 { pass = 0; }
    if call(&ab, TOOL_FS_WRITE, p_ws_notes(), 0, (&g_src[0]) as usize, 1, 64) != E_EXHAUSTED { pass = 0; }

    return pass;
}
