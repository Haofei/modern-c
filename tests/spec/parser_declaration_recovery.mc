// SPEC: section=0
// SPEC: milestone=parser-recovery
// SPEC: phase=parse
// SPEC: expect=compile_error
// SPEC: check=E_PARSE,E_PARSE_EXPECTED_PARAMETER_NAME,E_PARSE_EXPECTED_EXPRESSION

module RecoveryModule {
    fn bad_member( -> void; // EXPECT_ERROR: E_PARSE_EXPECTED_PARAMETER_NAME
    fn good_member() -> void {
        return;
    }
    fn later_bad_member() -> void {
        let x: u32 = ; // EXPECT_ERROR: E_PARSE_EXPECTED_EXPRESSION
    }
}

struct RecoveryStruct {
    x: u32,
}

impl RecoveryStruct {
    fn bad_impl_member( -> void; // EXPECT_ERROR: E_PARSE_EXPECTED_PARAMETER_NAME
    fn good_impl_member(self: *RecoveryStruct) -> u32 {
        return self.x;
    }
    fn later_bad_impl_member(self: *RecoveryStruct) -> void {
        let x: u32 = ; // EXPECT_ERROR: E_PARSE_EXPECTED_EXPRESSION
    }
}

trait RecoveryTrait {
    fn bad_trait_member( -> u32; // EXPECT_ERROR: E_PARSE
    fn good_trait_member(self: *Self) -> u32;
    fn later_bad_trait_member(self: *Self) -> ; // EXPECT_ERROR: E_PARSE
}

struct FieldRecovery {
    a: , // EXPECT_ERROR: E_PARSE
    b: , // EXPECT_ERROR: E_PARSE
    c: u32,
}

fn later_top_level_bad() -> void {
    let y: u32 = ; // EXPECT_ERROR: E_PARSE_EXPECTED_EXPRESSION
}
