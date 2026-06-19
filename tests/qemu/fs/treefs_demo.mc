// Self-verifying fixture for the hierarchical tree filesystem (kernel/fs/treefs).
//
// Drives a single global Tree through directory creation, nested file
// create/write/read, absolute path resolution, `.`/`..` traversal (including the
// no-escape-above-root property the sandbox relies on), getdents-style listing,
// and every typed-error path (Exists / NotFound / NotDir / TooLarge /
// InvalidName). Returns 1 iff every assertion holds, so the host driver asserts
// a single scalar.

import "kernel/fs/treefs.mc";
import "std/addr.mc";

global g_t: Tree;
global g_path: [64]u8;
global g_src: [16]u8;
global g_rd: [16]u8;

// Error sentinels: node indices are 0..31, so these never collide with an idx.
const E_NOSPACE: u64 = 0xF001;
const E_NAMELONG: u64 = 0xF002;
const E_NOTFOUND: u64 = 0xF003;
const E_NOTDIR: u64 = 0xF004;
const E_TOOLARGE: u64 = 0xF005;
const E_BADINDEX: u64 = 0xF006;
const E_EXISTS: u64 = 0xF007;
const E_INVALID: u64 = 0xF008;
const E_ISDIR: u64 = 0xF009;

fn ecode(e: TreeError) -> u64 {
    switch e {
        .NoSpace => { return E_NOSPACE; }
        .NameTooLong => { return E_NAMELONG; }
        .NotFound => { return E_NOTFOUND; }
        .NotDir => { return E_NOTDIR; }
        .TooLarge => { return E_TOOLARGE; }
        .BadIndex => { return E_BADINDEX; }
        .Exists => { return E_EXISTS; }
        .InvalidName => { return E_INVALID; }
        .IsDir => { return E_ISDIR; }
    }
}

fn gp() -> usize {
    return (&g_path[0]) as usize;
}

fn put(i: usize, b: u8) -> void {
    g_path[i] = b;
}

fn do_mkdir(n: usize) -> u64 {
    switch tree_mkdir(&g_t, gp(), n) {
        ok(i) => { return i as u64; }
        err(e) => { return ecode(e); }
    }
}

fn do_create(n: usize, cap: usize) -> u64 {
    switch tree_create(&g_t, gp(), n, cap) {
        ok(i) => { return i as u64; }
        err(e) => { return ecode(e); }
    }
}

fn do_resolve(n: usize) -> u64 {
    switch tree_resolve(&g_t, gp(), n) {
        ok(i) => { return i as u64; }
        err(e) => { return ecode(e); }
    }
}

fn do_write(idx: usize, off: usize, n: usize) -> u64 {
    switch tree_write_at(&g_t, idx, off, (&g_src[0]) as usize, n) {
        ok(m) => { return m as u64; }
        err(e) => { return ecode(e); }
    }
}

// ----- path loaders (return the path length) -----

// "/workspace"
fn p_ws() -> usize {
    put(0,0x2F); put(1,0x77); put(2,0x6F); put(3,0x72); put(4,0x6B);
    put(5,0x73); put(6,0x70); put(7,0x61); put(8,0x63); put(9,0x65);
    return 10;
}
// "/etc"
fn p_etc() -> usize {
    put(0,0x2F); put(1,0x65); put(2,0x74); put(3,0x63);
    return 4;
}
// "/workspace/a.txt"
fn p_ws_a() -> usize {
    p_ws();
    put(10,0x2F); put(11,0x61); put(12,0x2E); put(13,0x74); put(14,0x78); put(15,0x74);
    return 16;
}
// "/nope"
fn p_nope() -> usize {
    put(0,0x2F); put(1,0x6E); put(2,0x6F); put(3,0x70); put(4,0x65);
    return 5;
}
// "/etc/x/y"  (parent /etc/x is absent)
fn p_etc_x_y() -> usize {
    p_etc();
    put(4,0x2F); put(5,0x78); put(6,0x2F); put(7,0x79);
    return 8;
}
// "/workspace/sub"
fn p_ws_sub() -> usize {
    p_ws();
    put(10,0x2F); put(11,0x73); put(12,0x75); put(13,0x62);
    return 14;
}
// "/workspace/sub/f"
fn p_ws_sub_f() -> usize {
    p_ws_sub();
    put(14,0x2F); put(15,0x66);
    return 16;
}
// "/workspace/../etc"
fn p_ws_up_etc() -> usize {
    p_ws();
    put(10,0x2F); put(11,0x2E); put(12,0x2E);            // "/.."
    put(13,0x2F); put(14,0x65); put(15,0x74); put(16,0x63); // "/etc"
    return 17;
}
// "/workspace/../../etc"  (second ".." would escape root — must clamp)
fn p_ws_up_up_etc() -> usize {
    p_ws();
    put(10,0x2F); put(11,0x2E); put(12,0x2E);            // "/.."
    put(13,0x2F); put(14,0x2E); put(15,0x2E);            // "/.."
    put(16,0x2F); put(17,0x65); put(18,0x74); put(19,0x63); // "/etc"
    return 20;
}
// "/workspace/a.txt/z"  (descend into a file)
fn p_ws_a_z() -> usize {
    p_ws_a();
    put(16,0x2F); put(17,0x7A);
    return 18;
}
// "/workspace/."
fn p_ws_dot() -> usize {
    p_ws();
    put(10,0x2F); put(11,0x2E);
    return 12;
}
// "/etc/small"
fn p_etc_small() -> usize {
    p_etc();
    put(4,0x2F); put(5,0x73); put(6,0x6D); put(7,0x61); put(8,0x6C); put(9,0x6C);
    return 10;
}

export fn treefs_run() -> u32 {
    var pass: u32 = 1;
    tree_init(&g_t);

    // mkdir /workspace -> node 1
    if do_mkdir(p_ws()) != 1 { pass = 0; }
    if !tree_is_dir(&g_t, 1) { pass = 0; }
    // duplicate -> Exists, no node consumed
    if do_mkdir(p_ws()) != E_EXISTS { pass = 0; }

    // mkdir /etc -> node 2
    if do_mkdir(p_etc()) != 2 { pass = 0; }

    // create /workspace/a.txt -> node 3 (a file)
    if do_create(p_ws_a(), 64) != 3 { pass = 0; }
    if !tree_is_file(&g_t, 3) { pass = 0; }
    if tree_is_dir(&g_t, 3) { pass = 0; }

    // write "hello" and read it back
    g_src[0]=0x68; g_src[1]=0x65; g_src[2]=0x6C; g_src[3]=0x6C; g_src[4]=0x6F;
    if do_write(3, 0, 5) != 5 { pass = 0; }
    if tree_size(&g_t, 3) != 5 { pass = 0; }
    let n: usize = tree_read_at(&g_t, 3, 0, (&g_rd[0]) as usize, 16);
    if n != 5 { pass = 0; }
    if g_rd[0]!=0x68 { pass = 0; }
    if g_rd[1]!=0x65 { pass = 0; }
    if g_rd[2]!=0x6C { pass = 0; }
    if g_rd[3]!=0x6C { pass = 0; }
    if g_rd[4]!=0x6F { pass = 0; }

    // resolution
    if do_resolve(p_ws_a()) != 3 { pass = 0; }
    if do_resolve(p_ws()) != 1 { pass = 0; }
    if do_resolve(p_etc()) != 2 { pass = 0; }
    if do_resolve(p_nope()) != E_NOTFOUND { pass = 0; }

    // create with a missing parent dir -> NotFound (no node consumed)
    if do_create(p_etc_x_y(), 8) != E_NOTFOUND { pass = 0; }

    // nested mkdir + file -> nodes 4, 5
    if do_mkdir(p_ws_sub()) != 4 { pass = 0; }
    if do_create(p_ws_sub_f(), 16) != 5 { pass = 0; }

    // /workspace now has two children (a.txt, sub)
    if tree_child_count(&g_t, 1) != 2 { pass = 0; }

    // ".." traversal resolves to /etc
    if do_resolve(p_ws_up_etc()) != 2 { pass = 0; }
    // ".." cannot climb above root: still lands on /etc, no escape
    if do_resolve(p_ws_up_up_etc()) != 2 { pass = 0; }

    // descending into a file is NotDir, not a wild read
    if do_resolve(p_ws_a_z()) != E_NOTDIR { pass = 0; }
    // a final "." component is an invalid name to create
    if do_mkdir(p_ws_dot()) != E_INVALID { pass = 0; }

    // capacity is enforced: small file, oversized write -> TooLarge
    if do_create(p_etc_small(), 4) != 6 { pass = 0; }
    if do_write(6, 0, 8) != E_TOOLARGE { pass = 0; }

    // listing exposes child node indices and names
    let c0: usize = child_idx(1, 0);
    let c1: usize = child_idx(1, 1);
    if !both_in_3_4(c0, c1) { pass = 0; }

    return pass;
}

fn child_idx(dir: usize, k: usize) -> usize {
    switch tree_child_at(&g_t, dir, k) {
        ok(i) => { return i; }
        err(e) => { return 0xFF; }
    }
}

// The two children of /workspace are exactly nodes 3 (a.txt) and 4 (sub).
fn both_in_3_4(a: usize, b: usize) -> bool {
    if a == 3 {
        return b == 4;
    }
    if a == 4 {
        return b == 3;
    }
    return false;
}
