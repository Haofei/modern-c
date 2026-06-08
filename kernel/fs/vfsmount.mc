// kernel/fs/vfsmount — the VFS mount switch: a table mapping a mount key (a path's
// leading byte, standing in for a prefix) to a filesystem-type id, so path resolution
// dispatches to the backing FS (ramfs, diskfs, ...). mount/umount/resolve.

const MNT_MAX: usize = 4;
const FS_NONE: u32 = 0;
const FS_RAMFS: u32 = 1;
const FS_DISKFS: u32 = 2;

struct MountTable {
    key: [MNT_MAX]u8,
    fstype: [MNT_MAX]u32,
    used: [MNT_MAX]bool,
}

export fn mount_init(m: *mut MountTable) -> void {
    var i: usize = 0;
    while i < MNT_MAX {
        m.used[i] = false;
        i = i + 1;
    }
}

export fn mount(m: *mut MountTable, key: u8, fstype: u32) -> bool {
    var i: usize = 0;
    while i < MNT_MAX {
        if !m.used[i] {
            m.key[i] = key;
            m.fstype[i] = fstype;
            m.used[i] = true;
            return true;
        }
        i = i + 1;
    }
    return false; // table full
}

// Which filesystem backs `key`? FS_NONE if nothing is mounted there.
export fn mount_resolve(m: *mut MountTable, key: u8) -> u32 {
    var i: usize = 0;
    while i < MNT_MAX {
        if m.used[i] {
            if m.key[i] == key {
                return m.fstype[i];
            }
        }
        i = i + 1;
    }
    return FS_NONE;
}

export fn umount(m: *mut MountTable, key: u8) -> void {
    var i: usize = 0;
    while i < MNT_MAX {
        if m.used[i] {
            if m.key[i] == key {
                m.used[i] = false;
            }
        }
        i = i + 1;
    }
}
