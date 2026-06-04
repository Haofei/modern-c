// SPEC: section=17,25
// SPEC: milestone=declaration-binding
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_DUPLICATE_STRUCT_FIELD,E_DUPLICATE_DECLARATION

fn reject_duplicate_declaration() -> void;
// EXPECT_ERROR: E_DUPLICATE_DECLARATION
extern fn reject_duplicate_declaration() -> void;

global reject_duplicate_global: u32 = 0;
// EXPECT_ERROR: E_DUPLICATE_DECLARATION
global reject_duplicate_global: u32 = 1;

type RejectDuplicateAlias = u32;
// EXPECT_ERROR: E_DUPLICATE_DECLARATION
type RejectDuplicateAlias = bool;

packed bits RejectDuplicateOpaque: u8 {}
// EXPECT_ERROR: E_DUPLICATE_DECLARATION
packed bits RejectDuplicateOpaque: u8 {}

extern struct RejectDuplicateStruct {
    first: u8,
}

// EXPECT_ERROR: E_DUPLICATE_DECLARATION
extern struct RejectDuplicateStruct {
    second: u8,
}

extern struct RejectDuplicateField {
    value: u32,
    // EXPECT_ERROR: E_DUPLICATE_STRUCT_FIELD
    value: bool,
}

extern mmio struct RejectDuplicateMmioField {
    status: Reg<u8, .read>,
    // EXPECT_ERROR: E_DUPLICATE_STRUCT_FIELD
    status: Reg<u16, .read>,
}
