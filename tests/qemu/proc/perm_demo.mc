import "kernel/lib/perm.mc";
export fn perm_run() -> u32 {
    var pass: u32 = 1;
    // file owned by uid=1000/gid=1000, mode 0640 (owner rw, group r, other none)
    let owner: Cred = .{ .uid = 1000, .gid = 1000 };
    let group: Cred = .{ .uid = 2000, .gid = 1000 };
    let other: Cred = .{ .uid = 3000, .gid = 3000 };
    let root: Cred = .{ .uid = 0, .gid = 0 };
    let mode: u32 = 0x1A0; // 0640 octal = 0b110_100_000

    if !perm_check(&owner, 1000, 1000, mode, PERM_R) { pass = 0; } // owner read: yes
    if !perm_check(&owner, 1000, 1000, mode, PERM_W) { pass = 0; } // owner write: yes
    if perm_check(&owner, 1000, 1000, mode, PERM_X) { pass = 0; }  // owner exec: no
    if !perm_check(&group, 1000, 1000, mode, PERM_R) { pass = 0; } // group read: yes
    if perm_check(&group, 1000, 1000, mode, PERM_W) { pass = 0; }  // group write: no
    if perm_check(&other, 1000, 1000, mode, PERM_R) { pass = 0; }  // other read: no
    if !perm_check(&root, 1000, 1000, mode, PERM_W) { pass = 0; }  // root: always
    return pass;
}
