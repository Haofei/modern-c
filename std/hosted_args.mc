// MC standard library — `hosted_args`: read the command-line argument vector in
// the HOSTED profile.
//
// A hosted MC program has no ambient `argc`/`argv`: the freestanding entry MC
// emits is nullary, and a bare-metal kernel has no process arguments at all.
// This module is the OPT-IN bridge that lets a hosted program (e.g. a
// self-hosting `mcc2 in.mc -o out.c`) see its arguments — and, like `hosted_io`,
// it is strictly opt-in: a program enters the hosted profile by importing this
// file (the language-level opt-in) and linking against the tiny C runtime shim
// `tools/toolchain/hosted_args_rt.c` (the toolchain-level opt-in).
//
// PROGRAM CONTRACT: the shim provides `main(argc, argv)`, stashes the vector, and
// then calls the MC entry point `mc_main`. So a hosted program using this module
// does NOT define `fn main` — it exports `fn mc_main() -> i32` instead, and the
// process exit code is that return value.
//
// PRINCIPLES (spec §0): the machine contract is made explicit. Raw `argv` is an
// untyped `char**` with a NUL-terminated string behind each slot — an invisible
// contract. Here each argument is handed back as a `ByteReader` (base + length):
// a bounds-checked view whose reads can never run off the string, with the length
// computed once (by the shim's `strlen`) rather than rediscovered at every use.

import "std/addr.mc";
import "std/bytes.mc";

// ----- raw C runtime bindings (explicit machine contract) -----
//
// The shim (`tools/toolchain/hosted_args_rt.c`) saves the process `argc`/`argv`
// and exposes them through these three accessors. `mc_argv` returns the raw
// address of argument `i` as a `usize` (0 if `i` is out of range); `mc_arg_len`
// returns that argument's `strlen` (0 if out of range) — so length never has to
// be rediscovered in MC.

extern "C" fn mc_argc() -> i32;
extern "C" fn mc_argv(i: i32) -> usize;
extern "C" fn mc_arg_len(i: i32) -> usize;

// ----- the MC surface -----

// The number of command-line arguments, INCLUDING argv[0] (the program name),
// exactly like C's `argc`.
export fn args_count() -> i32 {
    return mc_argc();
}

// The length in bytes of argument `i` (excluding the NUL terminator); 0 if `i`
// is out of range.
export fn arg_len(i: i32) -> usize {
    return mc_arg_len(i);
}

// A bounds-checked view of argument `i`: a `ByteReader` over its bytes (the
// trailing NUL is NOT included). Out-of-range `i` yields an empty reader (base 0,
// length 0), so every read is still bounds-safe. Use `br_len`/`br_u8`/`br_try_u8`
// from `std/bytes` to inspect it — a read past the argument can never over-run.
export fn arg(i: i32) -> ByteReader {
    return byte_reader(pa(mc_argv(i)), mc_arg_len(i));
}

// Byte `j` of argument `i`, bounds-checked against the argument length (traps via
// the `ByteReader` on an out-of-range `j`). A convenience for callers that want a
// single byte without holding the reader.
export fn arg_byte(i: i32, j: usize) -> u8 {
    var r: ByteReader = arg(i);
    return br_u8(&r, j);
}

// True if argument `i` equals the NUL-terminated C string at `expected`
// (byte-for-byte, same length). Handy for flag matching (e.g. `arg_eq(1, "-o")`).
export fn arg_eq(i: i32, expected: *const u8) -> bool {
    let n: usize = mc_arg_len(i);
    var r: ByteReader = arg(i);
    var k: usize = 0;
    while k < n {
        var e: u8 = 0;
        unsafe {
            e = raw.load<u8>(pa_offset(pa(expected as usize), k));
        }
        if e == 0 {
            return false; // `expected` is shorter than argument `i`
        }
        if br_u8(&r, k) != e {
            return false;
        }
        k = k + 1;
    }
    // Argument fully matched; require `expected` to end exactly here too.
    var tail: u8 = 0;
    unsafe {
        tail = raw.load<u8>(pa_offset(pa(expected as usize), n));
    }
    return tail == 0;
}
