// Qualified C and LLVM backends deliberately reject Tier-2 `*dyn Trait`
// representation until it has a syntax-free dispatch table.
// EXPECT: E_EXPERIMENTAL_DYN_CODEGEN

trait Shape {
    fn area(self: *Self) -> u32;
}

fn rejected(value: *dyn Shape) -> u32 {
    return value.area();
}
