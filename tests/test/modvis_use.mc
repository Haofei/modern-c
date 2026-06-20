// Consumer of modvis_lib's PUBLIC surface only. It uses the `pub` functions and the `pub`
// type; it never names the private `secret_double` / `internal_sum` (which would be
// E_PRIVATE_IMPORT — see tools/test/module-visibility-test.sh for the deny check).

import "modvis_lib.mc";

#[test]
export fn uses_public_functions() -> u32 {
    assert(scaled(10) == 21); // 10*2 + 1
    return 1;
}

#[test]
export fn uses_public_type() -> u32 {
    let p: Point = .{ .x = 3, .y = 4 }; // public type, public constructor path
    assert(point_sum(p) == 7);
    return 1;
}
