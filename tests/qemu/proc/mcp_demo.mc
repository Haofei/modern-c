// Self-verifying fixture for the MCP-compatible façade (kernel/core/mcp).
//
// Advertises MCP method names bound to native capability-checked tools, then
// drives them by NAME and asserts that MCP invocation enforces MC capabilities:
//   "fs/write" on /workspace -> allowed; on /etc -> denied by the path cap;
//   "fs/read"  on the secret -> denied;
//   an unadvertised method    -> NoSuchTool (MC never hosts a tool it didn't bind);
//   a method bound to a tool the agent lacks in its allowlist -> Denied.
// MCP is the compatibility layer; the verdicts come from MC capabilities. Returns
// 1 iff every outcome is exactly right.

import "kernel/core/mcp.mc";
import "kernel/fs/treefs.mc";
import "kernel/fs/fs_toolserver.mc";
import "kernel/fs/agent_fs.mc";
import "kernel/core/ipc_trace.mc";
import "std/mask.mc";
import "std/addr.mc";

global g_t: Tree;
global g_audit: IpcTrace;
global g_cat: McpCatalog;
global g_agent: AgentFs;
global g_path: [64]u8;
global g_name: [32]u8;
global g_src: [16]u8;

const AGENT: u32 = 7;
const E_DENIED: u64 = 0xA000;
const E_NOSUCH: u64 = 0xA002;

fn pcode(e: AgentToolError) -> u64 {
    switch e {
        .Denied => { return E_DENIED; }
        .Exhausted => { return 0xA001; }
        .NoSuchTool => { return E_NOSUCH; }
        .NoRight => { return 0xA003; }
        .NotFound => { return 0xA004; }
        .NotDir => { return 0xA005; }
        .Exists => { return 0xA006; }
        .TooLarge => { return 0xA007; }
        .NoSpace => { return 0xA008; }
        .IsDir => { return 0xA009; }
        .Invalid => { return 0xA00A; }
    }
}

fn gp() -> usize { return (&g_path[0]) as usize; }
fn pput(i: usize, b: u8) -> void { g_path[i] = b; }
fn gn() -> usize { return (&g_name[0]) as usize; }
fn nput(i: usize, b: u8) -> void { g_name[i] = b; }

// Invoke an MCP method by name on the path currently in g_path.
fn mcall(name_len: usize, path_len: usize) -> u64 {
    switch mcp_call(&g_cat, &g_t, &g_audit, &g_agent, gn(), name_len, gp(), path_len, 0, (&g_src[0]) as usize, 1, 64) {
        ok(v) => { return v as u64; }
        err(e) => { return pcode(e); }
    }
}

// ----- method names -----
fn n_write() -> usize { // "fs/write"
    nput(0,0x66); nput(1,0x73); nput(2,0x2F); nput(3,0x77); nput(4,0x72); nput(5,0x69); nput(6,0x74); nput(7,0x65);
    return 8;
}
fn n_read() -> usize { // "fs/read"
    nput(0,0x66); nput(1,0x73); nput(2,0x2F); nput(3,0x72); nput(4,0x65); nput(5,0x61); nput(6,0x64);
    return 7;
}
fn n_exec() -> usize { // "fs/exec" (bound to a tool the agent does NOT hold)
    nput(0,0x66); nput(1,0x73); nput(2,0x2F); nput(3,0x65); nput(4,0x78); nput(5,0x65); nput(6,0x63);
    return 7;
}
fn n_bogus() -> usize { // "evil/x" (never advertised)
    nput(0,0x65); nput(1,0x76); nput(2,0x69); nput(3,0x6C); nput(4,0x2F); nput(5,0x78);
    return 6;
}

// ----- paths -----
fn p_ws() -> usize {
    pput(0,0x2F); pput(1,0x77); pput(2,0x6F); pput(3,0x72); pput(4,0x6B);
    pput(5,0x73); pput(6,0x70); pput(7,0x61); pput(8,0x63); pput(9,0x65);
    return 10;
}
fn p_etc() -> usize {
    pput(0,0x2F); pput(1,0x65); pput(2,0x74); pput(3,0x63);
    return 4;
}
fn p_ws_f() -> usize { // "/workspace/f"
    p_ws();
    pput(10,0x2F); pput(11,0x66);
    return 12;
}
fn p_etc_x() -> usize { // "/etc/x"
    p_etc();
    pput(4,0x2F); pput(5,0x78);
    return 6;
}
fn p_etc_secret() -> usize { // "/etc/secret"
    p_etc();
    pput(4,0x2F); pput(5,0x73); pput(6,0x65); pput(7,0x63); pput(8,0x72); pput(9,0x65); pput(10,0x74);
    return 11;
}

const TOOL_FS_EXEC: u32 = 5; // a native tool id the agent's allowlist omits

export fn mcp_run() -> u32 {
    var pass: u32 = 1;
    tree_init(&g_t);
    ipc_trace_init(&g_audit);

    // World: /workspace + /etc/secret.
    var ws: usize = 0;
    switch tree_mkdir(&g_t, gp(), p_ws()) { ok(i) => { ws = i; } err(e) => { pass = 0; } }
    switch tree_mkdir(&g_t, gp(), p_etc()) { ok(i) => {} err(e) => { pass = 0; } }
    switch tree_create(&g_t, gp(), p_etc_secret(), 16) { ok(i) => {} err(e) => { pass = 0; } }

    // The agent: allowlist {write, read} (NOT exec), cap rooted at /workspace.
    var tl: Mask32 = mask32_zero();
    mask32_set(&tl, TOOL_FS_WRITE);
    mask32_set(&tl, TOOL_FS_READ);
    g_agent = agent_fs_new(tl, 16, pathcap_root(AGENT, ws, FS_WRITE | FS_READ));

    // Advertise MCP tools bound to native tool ids.
    mcp_init(&g_cat);
    if !mcp_register(&g_cat, gn(), n_write(), TOOL_FS_WRITE) { pass = 0; }
    if !mcp_register(&g_cat, gn(), n_read(), TOOL_FS_READ) { pass = 0; }
    if !mcp_register(&g_cat, gn(), n_exec(), TOOL_FS_EXEC) { pass = 0; }

    // "fs/write" on /workspace -> allowed (the benign write).
    let nl_w: usize = n_write();
    if mcall(nl_w, p_ws_f()) != 1 { pass = 0; }

    // "fs/write" on /etc -> denied by the path capability.
    let nl_w2: usize = n_write();
    if mcall(nl_w2, p_etc_x()) != E_DENIED { pass = 0; }

    // "fs/read" on the secret -> denied (agent holds no cap there).
    let nl_r: usize = n_read();
    if mcall(nl_r, p_etc_secret()) != E_DENIED { pass = 0; }

    // "fs/exec" is advertised but bound to a tool the agent's allowlist omits ->
    // Denied at the front door (MCP can't widen authority).
    let nl_e: usize = n_exec();
    if mcall(nl_e, p_ws_f()) != E_DENIED { pass = 0; }

    // An unadvertised method -> NoSuchTool (MC never hosts a tool it didn't bind).
    let nl_b: usize = n_bogus();
    if mcall(nl_b, p_ws_f()) != E_NOSUCH { pass = 0; }

    return pass;
}
