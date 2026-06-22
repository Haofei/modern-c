// kernel/core/userland — minimal userland utilities built on the args vector + libc.
// `util_echo` joins the arguments with spaces (the classic `echo`), writing to a buffer
// and returning the byte count — a real utility program over the same primitives a shell
// would exec.

import "kernel/lib/args.mc";
import "std/addr.mc";

export fn util_echo(a: *mut Args, out: PAddr, max: usize) -> usize {
    var w: usize = 0;
    var i: usize = 0;
    while i < args_count(a) {
        if i > 0 {
            if w < max {
                unsafe {
                    raw.store<u8>(pa_offset(out, w), 0x20); // space separator
                }
                w = w + 1;
            }
        }
        let alen: usize = args_len(a, i);
        var j: usize = 0;
        while j < alen {
            if w < max {
                unsafe {
                    raw.store<u8>(pa_offset(out, w), args_byte(a, i, j));
                }
                w = w + 1;
            }
            j = j + 1;
        }
        i = i + 1;
    }
    return w;
}
