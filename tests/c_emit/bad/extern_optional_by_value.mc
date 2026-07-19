// EXPECT: E_EXTERN_STRUCT_BY_VALUE
extern "C" fn consume_optional(value: ?u32) -> void;

fn main() -> void {
    return;
}
