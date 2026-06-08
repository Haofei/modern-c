import "kernel/core/posix.mc";
export fn posix_run() -> u32 {
    var pass: u32 = 1;
    posix_setup(7);
    if posix_call(10, 0, 0, 0) != 7 { pass = 0; }       // getpid -> 7
    let fd: u64 = posix_call(11, 0, 0, 0);               // open -> 3
    if fd != 3 { pass = 0; }
    if posix_call(12, fd, 0x48, 0) != 1 { pass = 0; }    // write 'H'
    if posix_call(12, fd, 0x49, 0) != 1 { pass = 0; }    // write 'I'
    if posix_call(14, fd, 0, 0) != 0 { pass = 0; }       // close
    let fd2: u64 = posix_call(11, 0, 0, 0);              // reopen (pos=0)
    if posix_call(13, fd2, 0, 0) != 0x48 { pass = 0; }   // read 'H'
    if posix_call(13, fd2, 0, 0) != 0x49 { pass = 0; }   // read 'I'
    if posix_call(13, fd2, 0, 0) != 0x100 { pass = 0; }  // EOF
    if posix_call(99, 0, 0, 0) != 0xFFFFFFFFFFFFFFFF { pass = 0; } // ENOSYS
    return pass;
}
