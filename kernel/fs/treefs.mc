// kernel/fs/treefs — a hierarchical, in-memory tree filesystem.
//
// Where `ramfs` is a FLAT namespace (one table of named byte streams, no
// directories), `treefs` adds the structure the agent sandbox needs: real
// directories, absolute path resolution (`/a/b/c`), `.`/`..` traversal, and
// `getdents`-style directory listing. It is the M2 unblocker — the FS tool
// server resolves an agent's workspace-rooted paths through this tree, and a
// capability check on the resolved node is what denies a `/etc` escape.
//
// Storage follows ramfs's discipline: a fixed node table plus two flat pools
// (one for names, one for file data), so there is no nested
// array-of-struct-of-array and no hidden allocation. The tree itself is built
// from parent / first-child / next-sibling indices into the node table — a
// classic n-ary tree with O(1) link edits and no per-directory child arrays.
//
// Every operation is bounds-checked and returns a typed error (no silent
// truncation, no wild copy); path bytes are read through the bounds-checked
// std/bytes reader, so a malformed path can never over-read.

import "std/bytes.mc";
import "std/addr.mc";

const MAX_NODES: usize = 32;   // total directories + files
const NAME_POOL: usize = 256;  // bytes for all component names
const DATA_POOL: usize = 4096; // bytes for all file contents

const NONE: usize = 0xFFFF_FFFF_FFFF_FFFF; // sentinel: no node
const ROOT: usize = 0;                     // node 0 is always the root directory

const KIND_UNUSED: u32 = 0;
const KIND_DIR: u32 = 1;
const KIND_FILE: u32 = 2;

const SLASH: u8 = 0x2F; // '/'
const DOT: u8 = 0x2E;   // '.'

// A node is either a directory or a regular file. Names live in the shared name
// pool ([name_off, name_off+name_len)); file bytes live in the shared data pool
// ([data_off, data_off+capacity)). Directories ignore the data fields.
struct Node {
    name_off: usize,
    name_len: usize,
    kind: u32,          // KIND_UNUSED / KIND_DIR / KIND_FILE
    parent: usize,      // index of containing directory (ROOT's parent is ROOT)
    first_child: usize, // head of the child sibling list, or NONE
    next_sibling: usize,// next entry in the parent's child list, or NONE
    data_off: usize,    // file: slice base in the data pool
    capacity: usize,    // file: reserved bytes
    size: usize,        // file: bytes written
}

struct Tree {
    nodes: [MAX_NODES]Node,
    names: [NAME_POOL]u8,
    name_used: usize,
    data: [DATA_POOL]u8,
    data_used: usize,
}

enum TreeError {
    NoSpace,     // node table full
    NameTooLong, // name pool exhausted
    NotFound,    // a path component does not exist
    NotDir,      // a path component exists but is a file, not a directory
    TooLarge,    // write would exceed the file's data capacity
    BadIndex,    // node index out of range, or refers to an unused slot
    Exists,      // target already exists
    InvalidName, // empty path, or a final component of "." / ".."
    IsDir,       // file operation attempted on a directory
}

// ----- a single path component, returned by value (no out-params) -----

struct Comp {
    found: bool,
    start: usize, // offset of the component's first byte in the reader
    len: usize,   // component length (never includes a '/')
    next: usize,  // reader offset to resume scanning from
}

// Scan the next '/'-delimited component of the path starting at `pos`. Leading
// and repeated separators are skipped (so `//a` and `/a` parse alike); a
// trailing slash yields no further component. The component bytes are NOT
// copied — `start`/`len` index back into the reader.
fn next_component(r: *ByteReader, pos: usize) -> Comp {
    let n: usize = br_len(r);
    var p: usize = pos;
    while p < n {
        if br_u8(r, p) != SLASH {
            break;
        }
        p = p + 1;
    }
    if p >= n {
        return .{ .found = false, .start = p, .len = 0, .next = p };
    }
    let start: usize = p;
    while p < n {
        if br_u8(r, p) == SLASH {
            break;
        }
        p = p + 1;
    }
    return .{ .found = true, .start = start, .len = p - start, .next = p };
}

fn comp_is_dot(r: *ByteReader, c: *Comp) -> bool {
    if c.len != 1 {
        return false;
    }
    return br_u8(r, c.start) == DOT;
}

fn comp_is_dotdot(r: *ByteReader, c: *Comp) -> bool {
    if c.len != 2 {
        return false;
    }
    if br_u8(r, c.start) != DOT {
        return false;
    }
    return br_u8(r, c.start + 1) == DOT;
}

// A node index is valid only if in range and naming a live slot.
fn tree_valid(t: *mut Tree, idx: usize) -> bool {
    if idx >= MAX_NODES {
        return false;
    }
    return t.nodes[idx].kind != KIND_UNUSED;
}

export fn tree_is_dir(t: *mut Tree, idx: usize) -> bool {
    if !tree_valid(t, idx) {
        return false;
    }
    return t.nodes[idx].kind == KIND_DIR;
}

export fn tree_is_file(t: *mut Tree, idx: usize) -> bool {
    if !tree_valid(t, idx) {
        return false;
    }
    return t.nodes[idx].kind == KIND_FILE;
}

export fn tree_init(t: *mut Tree) -> void {
    var i: usize = 0;
    while i < MAX_NODES {
        t.nodes[i].kind = KIND_UNUSED;
        i = i + 1;
    }
    t.name_used = 0;
    t.data_used = 0;
    // Node 0 is the root directory: empty name, its own parent, no children.
    t.nodes[ROOT].name_off = 0;
    t.nodes[ROOT].name_len = 0;
    t.nodes[ROOT].kind = KIND_DIR;
    t.nodes[ROOT].parent = ROOT;
    t.nodes[ROOT].first_child = NONE;
    t.nodes[ROOT].next_sibling = NONE;
    t.nodes[ROOT].size = 0;
}

// Does node `idx` carry the name held in the reader at [cstart, cstart+clen)?
fn name_eq(t: *mut Tree, idx: usize, r: *ByteReader, cstart: usize, clen: usize) -> bool {
    if t.nodes[idx].name_len != clen {
        return false;
    }
    let noff: usize = t.nodes[idx].name_off;
    var j: usize = 0;
    while j < clen {
        if t.names[noff + j] != br_u8(r, cstart + j) {
            return false;
        }
        j = j + 1;
    }
    return true;
}

// Find a directly-contained child of `dir` by name, or NONE.
fn find_child(t: *mut Tree, dir: usize, r: *ByteReader, cstart: usize, clen: usize) -> usize {
    var c: usize = t.nodes[dir].first_child;
    while c != NONE {
        if name_eq(t, c, r, cstart, clen) {
            return c;
        }
        c = t.nodes[c].next_sibling;
    }
    return NONE;
}

// Intern a component's bytes into the name pool, returning its offset.
fn intern_name(t: *mut Tree, r: *ByteReader, cstart: usize, clen: usize) -> Result<usize, TreeError> {
    if (t.name_used + clen) > NAME_POOL {
        return err(.NameTooLong);
    }
    let noff: usize = t.name_used;
    var j: usize = 0;
    while j < clen {
        t.names[noff + j] = br_u8(r, cstart + j);
        j = j + 1;
    }
    t.name_used = noff + clen;
    return ok(noff);
}

fn alloc_node(t: *mut Tree) -> Result<usize, TreeError> {
    var i: usize = 0;
    while i < MAX_NODES {
        if t.nodes[i].kind == KIND_UNUSED {
            return ok(i);
        }
        i = i + 1;
    }
    return err(.NoSpace);
}

// Descend one intermediate component from `cur`: handle `.`/`..`, else look up
// an existing child directory. A missing or non-directory component fails.
fn descend(t: *mut Tree, cur: usize, r: *ByteReader, c: *Comp) -> Result<usize, TreeError> {
    if comp_is_dot(r, c) {
        return ok(cur);
    }
    if comp_is_dotdot(r, c) {
        return ok(t.nodes[cur].parent); // ROOT's parent is ROOT: `..` can't escape
    }
    if t.nodes[cur].kind != KIND_DIR {
        return err(.NotDir);
    }
    let child: usize = find_child(t, cur, r, c.start, c.len);
    if child == NONE {
        return err(.NotFound);
    }
    if t.nodes[child].kind != KIND_DIR {
        return err(.NotDir); // a file appeared mid-path
    }
    return ok(child);
}

// Resolve an absolute path to an existing node. The path is taken as rooted at
// ROOT regardless of a leading '/'. `.`/`..` are honoured; `..` from the root
// stays at the root (no traversal escape). NotFound if any component is absent.
export fn tree_resolve(t: *mut Tree, path: usize, path_len: usize) -> Result<usize, TreeError> {
    var r: ByteReader = byte_reader(pa(path), path_len);
    var cur: usize = ROOT;
    var c: Comp = next_component(&r, 0);
    while c.found {
        if comp_is_dot(&r, &c) {
            // stay
        } else if comp_is_dotdot(&r, &c) {
            cur = t.nodes[cur].parent;
        } else {
            if t.nodes[cur].kind != KIND_DIR {
                return err(.NotDir);
            }
            let child: usize = find_child(t, cur, &r, c.start, c.len);
            if child == NONE {
                return err(.NotFound);
            }
            cur = child;
        }
        c = next_component(&r, c.next);
    }
    return ok(cur);
}

// Shared creation core: resolve every component but the last as an existing
// directory chain, then create the final component as `kind` under it.
fn make_path(t: *mut Tree, path: usize, path_len: usize, kind: u32, capacity: usize) -> Result<usize, TreeError> {
    var r: ByteReader = byte_reader(pa(path), path_len);
    var cur: usize = ROOT;
    var c: Comp = next_component(&r, 0);
    if !c.found {
        return err(.InvalidName); // empty path / "/" — can't create the root
    }
    while true {
        let after: Comp = next_component(&r, c.next);
        if !after.found {
            break; // `c` is the final component — fall through to creation
        }
        cur = descend(t, cur, &r, &c)?;
        c = after;
    }
    // `c` is the final component; `cur` is its parent directory.
    if comp_is_dot(&r, &c) {
        return err(.InvalidName);
    }
    if comp_is_dotdot(&r, &c) {
        return err(.InvalidName);
    }
    if t.nodes[cur].kind != KIND_DIR {
        return err(.NotDir);
    }
    if find_child(t, cur, &r, c.start, c.len) != NONE {
        return err(.Exists);
    }
    let slot: usize = alloc_node(t)?;
    if kind == KIND_FILE {
        if (t.data_used + capacity) > DATA_POOL {
            return err(.TooLarge);
        }
    }
    let noff: usize = intern_name(t, &r, c.start, c.len)?;
    t.nodes[slot].name_off = noff;
    t.nodes[slot].name_len = c.len;
    t.nodes[slot].kind = kind;
    t.nodes[slot].parent = cur;
    t.nodes[slot].first_child = NONE;
    t.nodes[slot].size = 0;
    if kind == KIND_FILE {
        t.nodes[slot].data_off = t.data_used;
        t.nodes[slot].capacity = capacity;
        t.data_used = t.data_used + capacity;
    } else {
        t.nodes[slot].capacity = 0;
    }
    // Link as the new head of the parent's child list (O(1)).
    t.nodes[slot].next_sibling = t.nodes[cur].first_child;
    t.nodes[cur].first_child = slot;
    return ok(slot);
}

// Resolve every component of `path` EXCEPT the last, returning the directory
// that would contain the final component — without creating anything. This is
// the hook a capability layer uses to authorize a create/mkdir against the
// parent directory (and so deny it) before any side effect occurs. A missing or
// non-directory intermediate is NotFound/NotDir; a path with no final component
// (empty / "/") is InvalidName.
export fn tree_lookup_parent(t: *mut Tree, path: usize, path_len: usize) -> Result<usize, TreeError> {
    var r: ByteReader = byte_reader(pa(path), path_len);
    var cur: usize = ROOT;
    var c: Comp = next_component(&r, 0);
    if !c.found {
        return err(.InvalidName);
    }
    while true {
        let after: Comp = next_component(&r, c.next);
        if !after.found {
            break; // `c` is the final component; `cur` is its parent
        }
        cur = descend(t, cur, &r, &c)?;
        c = after;
    }
    return ok(cur);
}

// Create a directory at `path`; its parent chain must already exist.
export fn tree_mkdir(t: *mut Tree, path: usize, path_len: usize) -> Result<usize, TreeError> {
    return make_path(t, path, path_len, KIND_DIR, 0);
}

// Create an empty file at `path`, reserving `capacity` bytes of data pool.
export fn tree_create(t: *mut Tree, path: usize, path_len: usize, capacity: usize) -> Result<usize, TreeError> {
    return make_path(t, path, path_len, KIND_FILE, capacity);
}

// ----- file data: same slice discipline as ramfs -----

// Write `len` bytes from `src` into file `idx` at `offset`, never past capacity.
export fn tree_write_at(t: *mut Tree, idx: usize, offset: usize, src: usize, len: usize) -> Result<usize, TreeError> {
    if !tree_valid(t, idx) {
        return err(.BadIndex);
    }
    if t.nodes[idx].kind != KIND_FILE {
        return err(.IsDir);
    }
    let base: usize = t.nodes[idx].data_off;
    let capacity: usize = t.nodes[idx].capacity;
    if offset > capacity {
        return err(.TooLarge);
    }
    let room: usize = capacity - offset;
    if len > room {
        return err(.TooLarge);
    }
    var sr: ByteReader = byte_reader(pa(src), len);
    var j: usize = 0;
    while j < len {
        t.data[base + offset + j] = br_u8(&sr, j);
        j = j + 1;
    }
    let end: usize = offset + len;
    if end > t.nodes[idx].size {
        t.nodes[idx].size = end;
    }
    return ok(len);
}

// Read up to `len` bytes of file `idx` from `offset` into `dst`; returns count.
export fn tree_read_at(t: *mut Tree, idx: usize, offset: usize, dst: usize, len: usize) -> usize {
    if !tree_valid(t, idx) {
        return 0;
    }
    if t.nodes[idx].kind != KIND_FILE {
        return 0;
    }
    let base: usize = t.nodes[idx].data_off;
    let size: usize = t.nodes[idx].size;
    if offset >= size {
        return 0;
    }
    let avail: usize = size - offset;
    var n: usize = len;
    if avail < n {
        n = avail;
    }
    var j: usize = 0;
    while j < n {
        let b: u8 = t.data[base + offset + j];
        unsafe {
            raw.store<u8>(phys(dst + j), b);
        }
        j = j + 1;
    }
    return n;
}

export fn tree_size(t: *mut Tree, idx: usize) -> usize {
    if !tree_valid(t, idx) {
        return 0;
    }
    return t.nodes[idx].size;
}

// ----- directory listing (getdents-style) -----

// Number of direct children of directory `dir` (0 for a file or bad index).
export fn tree_child_count(t: *mut Tree, dir: usize) -> usize {
    if !tree_is_dir(t, dir) {
        return 0;
    }
    var n: usize = 0;
    var c: usize = t.nodes[dir].first_child;
    while c != NONE {
        n = n + 1;
        c = t.nodes[c].next_sibling;
    }
    return n;
}

// The node index of the `n`-th child of `dir` (list order), or NotFound.
export fn tree_child_at(t: *mut Tree, dir: usize, n: usize) -> Result<usize, TreeError> {
    if !tree_is_dir(t, dir) {
        return err(.NotDir);
    }
    var i: usize = 0;
    var c: usize = t.nodes[dir].first_child;
    while c != NONE {
        if i == n {
            return ok(c);
        }
        i = i + 1;
        c = t.nodes[c].next_sibling;
    }
    return err(.NotFound);
}

// The parent directory of `idx` (ROOT's parent is ROOT).
export fn tree_parent(t: *mut Tree, idx: usize) -> usize {
    if !tree_valid(t, idx) {
        return ROOT;
    }
    return t.nodes[idx].parent;
}

// ----- name accessors (for listing without exposing the pool) -----

export fn tree_name_len(t: *mut Tree, idx: usize) -> usize {
    if !tree_valid(t, idx) {
        return 0;
    }
    return t.nodes[idx].name_len;
}

// The `j`-th byte of node `idx`'s name (0 if out of range).
export fn tree_name_byte(t: *mut Tree, idx: usize, j: usize) -> u8 {
    if !tree_valid(t, idx) {
        return 0;
    }
    if j >= t.nodes[idx].name_len {
        return 0;
    }
    return t.names[t.nodes[idx].name_off + j];
}
