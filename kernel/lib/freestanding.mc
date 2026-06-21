// Shared freestanding libc for the bare-metal kernel images — in PURE MC.
// The all-MC replacement for kernel/arch/riscv64/freestanding.c. Every QEMU kernel image links
// this single object (kernel_boot_compile_rt). It supplies the mem*/str* symbols the freestanding
// link needs: the backends emit calls to memset/memcpy/memmove for aggregate init/copy, and the
// BearSSL TLS runtimes additionally reference memcmp/strlen.
//
// CRITICAL: the harness lowers this via emit-c and compiles it with -fno-builtin, so the compiler
// will NOT rewrite these explicit byte loops back into calls to themselves (memset->memset). That
// is the same guarantee the C version relied on. Each body is scalar raw.load/raw.store only (no
// aggregate ops), so emit-c never itself emits a mem* call here. Signatures match the C ABI by
// name + pointer-size: usize == void*/size_t, i32 == int.

export fn memset(d: usize, c: i32, n: usize) -> usize {
    let byte: u8 = ((c as u32) & 0xFF) as u8;
    var i: usize = 0;
    while i < n {
        unsafe { raw.store<u8>(phys(d + i), byte); }
        i = i + 1;
    }
    return d;
}

export fn memcpy(d: usize, s: usize, n: usize) -> usize {
    var i: usize = 0;
    while i < n {
        var b: u8 = 0;
        unsafe {
            b = raw.load<u8>(phys(s + i));
            raw.store<u8>(phys(d + i), b);
        }
        i = i + 1;
    }
    return d;
}

export fn memmove(d: usize, s: usize, n: usize) -> usize {
    if d == s || n == 0 {
        return d;
    }
    if d < s {
        var i: usize = 0;
        while i < n {
            var b: u8 = 0;
            unsafe {
                b = raw.load<u8>(phys(s + i));
                raw.store<u8>(phys(d + i), b);
            }
            i = i + 1;
        }
    } else {
        var i: usize = n;
        while i != 0 {
            i = i - 1;
            var b: u8 = 0;
            unsafe {
                b = raw.load<u8>(phys(s + i));
                raw.store<u8>(phys(d + i), b);
            }
        }
    }
    return d;
}

export fn memcmp(a: usize, b: usize, n: usize) -> i32 {
    var i: usize = 0;
    while i < n {
        var pa: u8 = 0;
        var pb: u8 = 0;
        unsafe {
            pa = raw.load<u8>(phys(a + i));
            pb = raw.load<u8>(phys(b + i));
        }
        if pa != pb {
            return (pa as i32) - (pb as i32);
        }
        i = i + 1;
    }
    return 0;
}

export fn strlen(s: usize) -> usize {
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(s + i)); }
        if b == 0 {
            break;
        }
        i = i + 1;
    }
    return i;
}
