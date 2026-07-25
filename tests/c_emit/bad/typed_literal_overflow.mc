// EXPECT: E_COMPTIME_TRAP
const BAD_TYPED_SUM: u8 = 255_u8 + 1_u8;

export fn typed_literal_overflow() -> u8 {
    return BAD_TYPED_SUM;
}
