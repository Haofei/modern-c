type Words = [3]u32;
fn other() -> u32 { return 0; }
fn get_word(values: Words) -> u32 { return values.const_get<2>(); }
