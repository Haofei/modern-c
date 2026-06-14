// SPEC: section=30,30.1,30.2,30.3,30.4
// SPEC: milestone=modules-and-associated-functions
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_RESERVED_QUALIFIED_NAME

// §30 modules/associated functions desugar `Owner.member` to a mangled top-level symbol, so an
// owner name is reserved against local bindings — a local may not shadow it, or `Owner.member`
// would silently bind to the qualified symbol instead of the local.

module Config {
    const LIMIT: u32 = 10;
    fn doubled(x: u32) -> u32 { return x + x; }
}

fn shadows() -> u32 {
    // EXPECT_ERROR: E_RESERVED_QUALIFIED_NAME
    let Config: u32 = 9;   // reserved: shadows module `Config`
    return 0;
}
