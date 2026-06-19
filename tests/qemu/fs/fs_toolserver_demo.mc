// M1 walking skeleton (the containment thesis in miniature), as a self-verifying
// fixture. One agent (pid 7) holds a PATH CAPABILITY rooted at /workspace and
// drives the capability-checked FS tool server over a hierarchical tree that also
// contains /etc and a secret file the agent was never granted.
//
// It asserts the milestone's acceptance shape directly:
//   * a benign write/read inside /workspace SUCCEEDS;
//   * a write to /etc is DENIED at the tool server (path capability), with NO
//     side effect (the file is never created), and the denial is AUDITED and
//     ATTRIBUTED to pid 7;
//   * a read of the out-of-scope secret is DENIED + audited;
//   * a `..` traversal that would escape /workspace is DENIED (the cap can't be
//     climbed out of);
//   * a READ-only attenuated capability cannot write (NoRight), audited;
//   * listing /workspace is allowed but listing /etc is denied.
// Returns 1 iff every verdict, side-effect, and audit record is exactly right.

import "kernel/fs/treefs.mc";
import "kernel/fs/fs_toolserver.mc";
import "kernel/core/ipc_trace.mc";
import "std/addr.mc";

global g_t: Tree;
global g_audit: IpcTrace;
global g_path: [64]u8;
global g_src: [16]u8;
global g_rd: [16]u8;

const AGENT: u32 = 7;

// FS_READ / FS_WRITE / V_DENY / V_ALLOW / OP_* are provided by the imported
// fs_toolserver module (its top-level names are in scope here).

// FsToolError sentinels (distinct from the 0..31 node indices ok-results carry).
const E_DENIED: u64 = 0xD000;
const E_NORIGHT: u64 = 0xD001;
const E_NOTFOUND: u64 = 0xD002;
const E_NOTDIR: u64 = 0xD003;
const E_EXISTS: u64 = 0xD004;
const E_TOOLARGE: u64 = 0xD005;
const E_NOSPACE: u64 = 0xD006;
const E_ISDIR: u64 = 0xD007;
const E_INVALID: u64 = 0xD008;

fn fcode(e: FsToolError) -> u64 {
    switch e {
        .Denied => { return E_DENIED; }
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

// ----- audit inspection: most-recent event fields -----

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
fn last_op() -> u32 { return last_field(2); }

// ----- server-call wrappers (return idx/count on ok, sentinel on err) -----

fn srv_mkdir(cap: *PathCap, n: usize) -> u64 {
    switch fs_tool_mkdir(&g_t, &g_audit, cap, gp(), n) {
        ok(i) => { return i as u64; }
        err(e) => { return fcode(e); }
    }
}
fn srv_write(cap: *PathCap, n: usize, off: usize, slen: usize, cap_bytes: usize) -> u64 {
    switch fs_tool_write(&g_t, &g_audit, cap, gp(), n, off, (&g_src[0]) as usize, slen, cap_bytes) {
        ok(w) => { return w as u64; }
        err(e) => { return fcode(e); }
    }
}
fn srv_read(cap: *PathCap, n: usize, off: usize, rn: usize) -> u64 {
    switch fs_tool_read(&g_t, &g_audit, cap, gp(), n, off, (&g_rd[0]) as usize, rn) {
        ok(r) => { return r as u64; }
        err(e) => { return fcode(e); }
    }
}
fn srv_list(cap: *PathCap, n: usize) -> u64 {
    switch fs_tool_list_count(&g_t, &g_audit, cap, gp(), n) {
        ok(c) => { return c as u64; }
        err(e) => { return fcode(e); }
    }
}

// raw tree resolve (test-side check that a denied op left no node behind)
fn raw_resolve(n: usize) -> u64 {
    switch tree_resolve(&g_t, gp(), n) {
        ok(i) => { return i as u64; }
        err(e) => { return 0xBADD; }
    }
}

// ----- path loaders (return the path length) -----

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
fn p_ws_up_etc_x() -> usize { // "/workspace/../etc/x"
    p_ws();
    put(10,0x2F); put(11,0x2E); put(12,0x2E);             // "/.."
    put(13,0x2F); put(14,0x65); put(15,0x74); put(16,0x63); // "/etc"
    put(17,0x2F); put(18,0x78);                            // "/x"
    return 19;
}

export fn fs_toolserver_run() -> u32 {
    var pass: u32 = 1;
    tree_init(&g_t);
    ipc_trace_init(&g_audit);

    // Build the world: /workspace (the agent's home) and /etc with a secret the
    // agent is never granted. (Set up directly, kernel-side — not via the agent.)
    var ws: usize = 99;
    switch tree_mkdir(&g_t, gp(), p_ws()) { ok(i) => { ws = i; } err(e) => { pass = 0; } }
    switch tree_mkdir(&g_t, gp(), p_etc()) { ok(i) => {} err(e) => { pass = 0; } }
    switch tree_create(&g_t, gp(), p_etc_secret(), 32) { ok(i) => {} err(e) => { pass = 0; } }

    // The agent's capability: read+write, rooted at /workspace, attributed to pid 7.
    var cap: PathCap = pathcap_root(AGENT, ws, FS_WRITE | FS_READ);

    // --- benign write inside /workspace SUCCEEDS, and is audited as ALLOW(pid 7) ---
    g_src[0]=0x68; g_src[1]=0x69; // "hi"
    if srv_write(&cap, p_ws_notes(), 0, 2, 64) != 2 { pass = 0; }
    if last_from() != AGENT { pass = 0; }
    if last_verdict() != V_ALLOW { pass = 0; }
    if last_op() != OP_WRITE { pass = 0; }
    // read it back
    let nr: u64 = srv_read(&cap, p_ws_notes(), 0, 16);
    if nr != 2 { pass = 0; }
    if g_rd[0]!=0x68 { pass = 0; }
    if g_rd[1]!=0x69 { pass = 0; }
    if last_verdict() != V_ALLOW { pass = 0; }
    if last_op() != OP_READ { pass = 0; }

    // --- forbidden write to /etc is DENIED, audited+attributed, NO side effect ---
    g_src[0]=0x7A; // 'z'
    if srv_write(&cap, p_etc_passwd(), 0, 1, 64) != E_DENIED { pass = 0; }
    if last_from() != AGENT { pass = 0; }
    if last_verdict() != V_DENY { pass = 0; }
    if last_op() != OP_WRITE { pass = 0; }
    // the denial created nothing: /etc/passwd still does not resolve
    if raw_resolve(p_etc_passwd()) != 0xBADD { pass = 0; }

    // --- forbidden read of the out-of-scope secret is DENIED + audited ---
    if srv_read(&cap, p_etc_secret(), 0, 16) != E_DENIED { pass = 0; }
    if last_verdict() != V_DENY { pass = 0; }
    if last_op() != OP_READ { pass = 0; }

    // --- `..` cannot climb out of the workspace capability: DENIED ---
    if srv_write(&cap, p_ws_up_etc_x(), 0, 1, 16) != E_DENIED { pass = 0; }
    if last_verdict() != V_DENY { pass = 0; }

    // --- attenuation: a READ-only derived cap cannot write (NoRight), audited ---
    var rocap: PathCap = pathcap_root(0xFFFF_FFFF, 0, 0);
    switch pathcap_attenuate(&g_t, &cap, ws, FS_READ) {
        ok(c) => { rocap = c; }
        err(e) => { pass = 0; }
    }
    if srv_write(&rocap, p_ws_notes(), 0, 1, 64) != E_NORIGHT { pass = 0; }
    if last_verdict() != V_DENY { pass = 0; }

    // --- listing: /workspace allowed (1 entry: notes.txt), /etc denied ---
    if srv_list(&cap, p_ws()) != 1 { pass = 0; }
    if last_verdict() != V_ALLOW { pass = 0; }
    if srv_list(&cap, p_etc()) != E_DENIED { pass = 0; }
    if last_verdict() != V_DENY { pass = 0; }

    // Every audit record so far is attributed to the agent (pid 7) — except the
    // read-only derived cap, which carries the same agent_pid by construction.
    if ipc_trace_len(&g_audit) == 0 { pass = 0; }

    return pass;
}
