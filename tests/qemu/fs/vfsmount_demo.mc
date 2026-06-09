import "kernel/fs/vfsmount.mc";
global g_mt: MountTable;
export fn vfsmount_run() -> u32 {
    var pass: u32 = 1;
    mount_init(&g_mt);
    if !mount(&g_mt, 0x2F, FS_RAMFS) { pass = 0; }   // '/' -> ramfs
    if !mount(&g_mt, 0x64, FS_DISKFS) { pass = 0; }  // 'd' -> diskfs
    if mount_resolve(&g_mt, 0x2F) != FS_RAMFS { pass = 0; }
    if mount_resolve(&g_mt, 0x64) != FS_DISKFS { pass = 0; }
    if mount_resolve(&g_mt, 0x78) != FS_NONE { pass = 0; } // 'x' unmounted
    umount(&g_mt, 0x64);
    if mount_resolve(&g_mt, 0x64) != FS_NONE { pass = 0; } // diskfs unmounted
    return pass;
}
