// Fixture for `mcmap-test`: validates the source map's stable typed-AST/MIR IDs and its
// object-symbol correlation against the *real* symbols the C and LLVM backends emit.
//
// The interesting case is `renamed_export`: its emitted linker symbol is overridden by
// `#[backend_name]`, so the map's `object_symbol` must be the *renamed* symbol — not the
// source name — and that renamed symbol must actually be defined in both objects while the
// source name is absent. That can only hold if the map reports the genuine emitted symbol.

export fn exported_add(a: u32, b: u32) -> u32 {
    let sum: u32 = a + b;
    return sum;
}

#[backend_name("mc_renamed_export")]
export fn renamed_export() -> u32 {
    return 42;
}

export fn calls_helper() -> u32 {
    return exported_add(1, 2);
}
