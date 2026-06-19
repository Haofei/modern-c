// kernel/fs/fs_toolserver — the capability-checked FS tool server (M1's heart).
//
// This is the *enforcement layer* of the agent-containment thesis. An agent does
// not touch the tree filesystem directly; it asks this server to act on a path,
// presenting a PATH CAPABILITY. The server resolves the path, checks that the
// target lies within the capability's authorized subtree AND that the capability
// carries the needed right, performs the operation only if both hold, and
// records EVERY verdict — allow and deny — into a provenance trace attributed to
// the agent. A write to `/etc` by an agent whose capability roots at
// `/workspace` is denied here, before any byte moves, and the denial is audited
// and attributable. That single property is the milestone in miniature.
//
// A PathCap is a value capability: it can only be ATTENUATED (narrowed to a
// sub-subtree and/or fewer rights), never widened — `pathcap_attenuate` ANDs the
// rights and requires the new root to sit inside the old one. There is no
// operation that grows authority, so a confined agent cannot escalate by
// deriving caps.
//
// The server is deliberately transport-agnostic: it takes the tree and an audit
// sink as parameters rather than reaching for globals, so the kernel wires in the
// real `cap_audit()` ring while a host fixture can drive a private trace and
// assert on it. (In the full system these calls arrive as IPC to a separate
// principal; this module is the mediation that IPC dispatches to.)

import "kernel/fs/treefs.mc";
import "kernel/core/ipc_trace.mc";

// Rights a path capability may carry (bitset; attenuation only clears bits).
const FS_READ: u32 = 1;
const FS_WRITE: u32 = 2;

// Verdict codes recorded in the audit event's `to` field.
const V_DENY: u32 = 0;
const V_ALLOW: u32 = 1;

// Operation codes recorded in the audit event's `tag` field.
const OP_WRITE: u32 = 1;
const OP_READ: u32 = 2;
const OP_MKDIR: u32 = 3;
const OP_LIST: u32 = 4;

// A path capability: authority over a subtree of the tree filesystem, attributed
// to an agent. `root` is the authorized subtree root (a tree node index); a path
// is in-scope iff the resolved node is `root` or a descendant of it. `rights`
// gates read vs write. `agent_pid` is carried for attribution in the audit trail.
struct PathCap {
    agent_pid: u32,
    root: usize,
    rights: u32,
}

enum FsToolError {
    Denied,    // target is outside the capability's subtree
    NoRight,   // capability lacks the required right (read/write)
    NotFound,  // path (or an intermediate) does not exist
    NotDir,    // an intermediate component is a file, not a directory
    Exists,    // create target already exists
    TooLarge,  // write/create exceeds capacity
    NoSpace,   // node table full
    IsDir,     // file op on a directory
    Invalid,   // malformed path / empty name
}

fn map_tree_err(e: TreeError) -> FsToolError {
    switch e {
        .NotFound => { return .NotFound; }
        .NotDir => { return .NotDir; }
        .Exists => { return .Exists; }
        .TooLarge => { return .TooLarge; }
        .NoSpace => { return .NoSpace; }
        .NameTooLong => { return .NoSpace; }
        .BadIndex => { return .NotFound; }
        .InvalidName => { return .Invalid; }
        .IsDir => { return .IsDir; }
    }
}

// ----- capabilities: mint (kernel-side) + monotone attenuation -----

// Mint a root capability over subtree `root` with `rights`, attributed to
// `agent_pid`. Minting is a kernel-side act (the agent receives the result); the
// agent has no constructor that widens authority.
export fn pathcap_root(agent_pid: u32, root: usize, rights: u32) -> PathCap {
    return .{ .agent_pid = agent_pid, .root = root, .rights = rights };
}

// Is `node` within the subtree rooted at `root` (root itself counts)? Walk
// parents toward the tree root; because `..`/resolution can never climb above
// the tree root, this terminates. A node outside the subtree reaches ROOT
// without passing through `root`.
fn within_cap(t: *mut Tree, node: usize, root: usize) -> bool {
    var c: usize = node;
    var steps: usize = 0;
    // The tree holds at most MAX_NODES nodes, so any root-ward walk terminates
    // well within this bound; the cap keeps the loop definitely-returning.
    while steps < 64 {
        if c == root {
            return true;
        }
        if c == 0 { // ROOT (treefs node 0): reached the top without hitting `root`
            return false;
        }
        c = tree_parent(t, c);
        steps = steps + 1;
    }
    return false;
}

// Attenuate `cap` to a narrower capability: `sub_root` must lie within the
// current subtree, and rights are intersected with `rights_keep`. There is no
// way to widen — the new root is a descendant and the new rights are a subset.
// Denied if `sub_root` escapes the current authority.
export fn pathcap_attenuate(t: *mut Tree, cap: *PathCap, sub_root: usize, rights_keep: u32) -> Result<PathCap, FsToolError> {
    if !within_cap(t, sub_root, cap.root) {
        return err(.Denied);
    }
    return ok(.{ .agent_pid = cap.agent_pid, .root = sub_root, .rights = cap.rights & rights_keep });
}

// ----- audit -----

fn audit(sink: *mut IpcTrace, cap: *PathCap, op: u32, verdict: u32, node: u32) -> void {
    // from = the agent (attribution), to = verdict, tag = op, size = target node.
    ipc_trace_record(sink, cap.agent_pid, verdict, op, node);
}

fn has_right(cap: *PathCap, want: u32) -> bool {
    return (cap.rights & want) == want;
}

// ----- mediated operations: authorize, audit, then act -----

// Create a directory at `path`. Authorized against the PARENT directory (must be
// in-scope and writable) BEFORE any node is created, so an out-of-scope mkdir is
// denied with no side effect.
export fn fs_tool_mkdir(t: *mut Tree, sink: *mut IpcTrace, cap: *PathCap, path: usize, path_len: usize) -> Result<usize, FsToolError> {
    var parent: usize = 0;
    switch tree_lookup_parent(t, path, path_len) {
        ok(p) => { parent = p; }
        err(e) => { return err(map_tree_err(e)); }
    }
    if !within_cap(t, parent, cap.root) {
        audit(sink, cap, OP_MKDIR, V_DENY, parent as u32);
        return err(.Denied);
    }
    if !has_right(cap, FS_WRITE) {
        audit(sink, cap, OP_MKDIR, V_DENY, parent as u32);
        return err(.NoRight);
    }
    switch tree_mkdir(t, path, path_len) {
        ok(idx) => {
            audit(sink, cap, OP_MKDIR, V_ALLOW, idx as u32);
            return ok(idx);
        }
        err(e) => { return err(map_tree_err(e)); }
    }
}

// Resolve `path` to an existing file under `cap`, or create it (capacity bytes)
// if absent — authorizing the parent for write first. The deny path (parent
// out of scope, e.g. `/etc`) is taken before the tree is touched.
fn open_or_create_for_write(t: *mut Tree, sink: *mut IpcTrace, cap: *PathCap, path: usize, path_len: usize, capacity: usize) -> Result<usize, FsToolError> {
    var parent: usize = 0;
    switch tree_lookup_parent(t, path, path_len) {
        ok(p) => { parent = p; }
        err(e) => { return err(map_tree_err(e)); }
    }
    if !within_cap(t, parent, cap.root) {
        audit(sink, cap, OP_WRITE, V_DENY, parent as u32);
        return err(.Denied);
    }
    if !has_right(cap, FS_WRITE) {
        audit(sink, cap, OP_WRITE, V_DENY, parent as u32);
        return err(.NoRight);
    }
    switch tree_create(t, path, path_len, capacity) {
        ok(i) => { return ok(i); }
        err(e) => {
            if e == .Exists {
                // Already there — reuse the existing node (still in-scope: its
                // parent was authorized above).
                switch tree_resolve(t, path, path_len) {
                    ok(i2) => { return ok(i2); }
                    err(e2) => { return err(map_tree_err(e2)); }
                }
            }
            return err(map_tree_err(e));
        }
    }
}

// Write `n` bytes from `src` to `path` at `offset`, creating the file (reserving
// `capacity`) if absent. Authorized for write against the parent directory.
export fn fs_tool_write(t: *mut Tree, sink: *mut IpcTrace, cap: *PathCap, path: usize, path_len: usize, offset: usize, src: usize, n: usize, capacity: usize) -> Result<usize, FsToolError> {
    let idx: usize = open_or_create_for_write(t, sink, cap, path, path_len, capacity)?;
    switch tree_write_at(t, idx, offset, src, n) {
        ok(wrote) => {
            audit(sink, cap, OP_WRITE, V_ALLOW, idx as u32);
            return ok(wrote);
        }
        err(e) => { return err(map_tree_err(e)); }
    }
}

// Read up to `n` bytes of `path` from `offset` into `dst`. Authorized for read
// against the resolved file node (must be in-scope). Returns the byte count.
export fn fs_tool_read(t: *mut Tree, sink: *mut IpcTrace, cap: *PathCap, path: usize, path_len: usize, offset: usize, dst: usize, n: usize) -> Result<usize, FsToolError> {
    var idx: usize = 0;
    switch tree_resolve(t, path, path_len) {
        ok(i) => { idx = i; }
        err(e) => { return err(map_tree_err(e)); }
    }
    if !within_cap(t, idx, cap.root) {
        audit(sink, cap, OP_READ, V_DENY, idx as u32);
        return err(.Denied);
    }
    if !has_right(cap, FS_READ) {
        audit(sink, cap, OP_READ, V_DENY, idx as u32);
        return err(.NoRight);
    }
    let got: usize = tree_read_at(t, idx, offset, dst, n);
    audit(sink, cap, OP_READ, V_ALLOW, idx as u32);
    return ok(got);
}

// Count the entries of directory `path`. Authorized for read against the
// resolved directory (must be in-scope).
export fn fs_tool_list_count(t: *mut Tree, sink: *mut IpcTrace, cap: *PathCap, path: usize, path_len: usize) -> Result<usize, FsToolError> {
    var idx: usize = 0;
    switch tree_resolve(t, path, path_len) {
        ok(i) => { idx = i; }
        err(e) => { return err(map_tree_err(e)); }
    }
    if !within_cap(t, idx, cap.root) {
        audit(sink, cap, OP_LIST, V_DENY, idx as u32);
        return err(.Denied);
    }
    if !has_right(cap, FS_READ) {
        audit(sink, cap, OP_LIST, V_DENY, idx as u32);
        return err(.NoRight);
    }
    if !tree_is_dir(t, idx) {
        return err(.NotDir);
    }
    audit(sink, cap, OP_LIST, V_ALLOW, idx as u32);
    return ok(tree_child_count(t, idx));
}
