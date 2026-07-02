// Gate source for `opaque struct` support in mcc2 (selfhost/parser.mc + sema.mc + emit_c.mc).
//
// `opaque struct` is an address-/access-class qualifier in the real MC grammar (field privacy,
// §31). The subset compiler does NOT enforce opacity — a cross-module access-control concern that
// is not needed to COMPILE the code — so an `opaque struct` is parsed, type-checked and emitted
// EXACTLY as a regular struct. This mirrors the std memory layer's usage (`opaque struct PAddr`
// in std/addr.mc), the concrete next blocker for a literal self-compile.
//
// The mcc2 CLI compiles THIS file to C; the gate driver then clang-compiles that C and calls
// mk(2, 3), asserting == 5 (construction into a typed local, member write, member read, returned
// field — all over an `opaque struct`).
opaque struct P { v: u32 }

export fn mk(a: u32, b: u32) -> u32 {
    var p: P = .{ .v = a };
    p.v = p.v + b;
    return p.v;
}
