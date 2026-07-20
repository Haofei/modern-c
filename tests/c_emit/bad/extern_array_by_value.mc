// EXPECT: E_EXTERN_STRUCT_BY_VALUE
extern "C" fn consume_array(value: [2]u32) -> void;
