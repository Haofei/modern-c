// kernel/core/perm — POSIX-style permission checks: a credential (uid/gid) against a
// file's owner/group and 9-bit rwx mode (owner<<6 | group<<3 | other). uid 0 (root)
// bypasses. This is the access-control the VFS/PM consult on open.

struct Cred {
    uid: u32,
    gid: u32,
}

const PERM_R: u32 = 4;
const PERM_W: u32 = 2;
const PERM_X: u32 = 1;

// May `c` perform `want` (bitwise R|W|X) on a file owned by file_uid/file_gid with `mode`?
export fn perm_check(c: *Cred, file_uid: u32, file_gid: u32, mode: u32, want: u32) -> bool {
    if c.uid == 0 {
        return true; // root
    }
    var bits: u32 = 0;
    if c.uid == file_uid {
        bits = (mode >> 6) & 7;
    } else {
        if c.gid == file_gid {
            bits = (mode >> 3) & 7;
        } else {
            bits = mode & 7;
        }
    }
    return (bits & want) == want;
}
