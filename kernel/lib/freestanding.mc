// Shared freestanding libc for the bare-metal kernel images — in PURE MC.
// The all-MC replacement for kernel/arch/riscv64/freestanding.c. Every QEMU kernel image links
// this single object (kernel_boot_compile_rt). It supplies the mem*/str* symbols the freestanding
// link needs: the backends emit calls to memset/memcpy/memmove for aggregate init/copy, and the
// BearSSL TLS runtimes additionally reference memcmp/strlen.
//
// CRITICAL: the harness lowers this via emit-c and compiles it with -fno-builtin, so the compiler
// will NOT rewrite these explicit loops back into calls to themselves (memset->memset). That
// is the same guarantee the C version relied on. Each body is scalar raw.load/raw.store only
// (u8 AND u64 words — both scalar, no aggregate ops), so emit-c never itself emits a mem* call
// here. Signatures match the C ABI by name + pointer-size: usize == void*/size_t, i32 == int.
//
// PERF: mem*/memmove copy/fill 8 bytes (one u64 word) at a time for the aligned bulk (~6-8x on
// large copies — these are the ELF-load / DMA / aggregate-copy hot path). Shape is byte HEAD (to
// align dst to 8) + word BODY + byte TAIL. SAFETY: the word path for memcpy/memmove is taken ONLY
// when src and dst share the same alignment mod 8 (`(d ^ s) & 7 == 0`); otherwise a u64 access
// would be unaligned and fault on strict-align pre-MMU code, so we fall back to the byte loop.

export fn memset(d: usize, c: i32, n: usize) -> usize {
    let byte: u8 = ((c as u32) & 0xFF) as u8;
    var i: usize = 0;
    if n >= 8 {
        // Replicate the byte across a u64 word (shift/or, no mul → no overflow trap).
        var w: u64 = byte as u64;
        w = w | (w << 8);
        w = w | (w << 16);
        w = w | (w << 32);
        while ((d + i) & 7) != 0 { // HEAD: align dst to 8
            unsafe { raw.store<u8>(phys(d + i), byte); }
            i = i + 1;
        }
        while i <= n - 8 { // BODY: word fill (`i <= n - 8` avoids checked-add overflow)
            unsafe { raw.store<u64>(phys(d + i), w); }
            i = i + 8;
        }
    }
    while i < n { // TAIL (or whole fill when word path skipped)
        unsafe { raw.store<u8>(phys(d + i), byte); }
        i = i + 1;
    }
    return d;
}

export fn memcpy(d: usize, s: usize, n: usize) -> usize {
    var i: usize = 0;
    if n >= 8 {
        if ((d ^ s) & 7) == 0 { // word path only for same alignment mod 8
            while ((d + i) & 7) != 0 { // HEAD: align dst to 8 (src in lockstep)
                var hb: u8 = 0;
                unsafe {
                    hb = raw.load<u8>(phys(s + i));
                    raw.store<u8>(phys(d + i), hb);
                }
                i = i + 1;
            }
            while i <= n - 8 { // BODY: 8-byte words
                var w: u64 = 0;
                unsafe {
                    w = raw.load<u64>(phys(s + i));
                    raw.store<u64>(phys(d + i), w);
                }
                i = i + 8;
            }
        }
    }
    while i < n { // TAIL (or whole copy when word path skipped)
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
        // Forward copy (safe when dst precedes src): byte HEAD + word BODY + byte TAIL.
        var i: usize = 0;
        if n >= 8 {
            if ((d ^ s) & 7) == 0 {
                while ((d + i) & 7) != 0 {
                    var hb: u8 = 0;
                    unsafe {
                        hb = raw.load<u8>(phys(s + i));
                        raw.store<u8>(phys(d + i), hb);
                    }
                    i = i + 1;
                }
                while i <= n - 8 {
                    var w: u64 = 0;
                    unsafe {
                        w = raw.load<u64>(phys(s + i));
                        raw.store<u64>(phys(d + i), w);
                    }
                    i = i + 8;
                }
            }
        }
        while i < n {
            var b: u8 = 0;
            unsafe {
                b = raw.load<u8>(phys(s + i));
                raw.store<u8>(phys(d + i), b);
            }
            i = i + 1;
        }
    } else {
        // Backward copy (dst overlaps after src): walk high→low. Align the TAIL to 8,
        // copy words downward, then the low bytes. Word path only for same alignment.
        var i: usize = n;
        if n >= 8 {
            if ((d ^ s) & 7) == 0 {
                // TAIL: byte-copy the top bytes until (d+i) is 8-aligned.
                while i != 0 {
                    if ((d + i) & 7) == 0 {
                        break;
                    }
                    i = i - 1;
                    var tb: u8 = 0;
                    unsafe {
                        tb = raw.load<u8>(phys(s + i));
                        raw.store<u8>(phys(d + i), tb);
                    }
                }
                // BODY: 8-byte words downward while a full word remains below i.
                while i >= 8 {
                    i = i - 8;
                    var w: u64 = 0;
                    unsafe {
                        w = raw.load<u64>(phys(s + i));
                        raw.store<u64>(phys(d + i), w);
                    }
                }
            }
        }
        // HEAD: remaining low bytes (or whole backward copy when word path skipped).
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
