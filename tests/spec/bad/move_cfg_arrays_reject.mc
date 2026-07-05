// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_MOVE_ARRAY_UNSUPPORTED

// Arrays of linear `move` resources are not yet trackable (element moves need the
// indexed-place model), so the checker fails closed on them in EVERY position:
// struct fields, type aliases (nested or not), return types, parameters, globals,
// and explicit locals (section 18.1). Split out of tests/spec/move_cfg.mc: several
// of these are top-level declarations with trailing EXPECT_ERROR markers that the
// sweeps' chunk-level strip cannot isolate (the marker comment falls after the
// chunk-ending `;`), so they live in this pure-reject fixture the sweeps skip.

move struct Handle { v: u32 }
fn acquire() -> Handle {
    return .{ .v = 1 };
}

// --- rejected: an array of a `move` resource as a struct field (not yet trackable — element
//     moves need the indexed-place model), so it is rejected in any struct, move or not ---
struct BadArrayContainer {
    // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    hs: [4]Handle,
}

// --- rejected: aliases to arrays of `move` resources are also fail-closed ---
type BadArrayAlias = [4]Handle; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED

// --- rejected: nested arrays still require element-place tracking ---
type BadNestedArrayAlias = [2][1]Handle; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED

// --- rejected: a function cannot return an array of `move` resources by value ---
fn reject_move_array_return() -> [1]Handle { // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return .{ acquire() };
}

// --- rejected: a function cannot accept an array of `move` resources by value ---
extern fn reject_move_array_param(hs: [1]Handle) -> void; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED

// --- rejected: global storage cannot hold an array of `move` resources by value ---
global bad_move_array_global: [1]Handle; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED

// --- rejected: explicit local bindings to arrays of `move` resources are not trackable ---
fn reject_move_array_local() -> void {
    let hs: [1]Handle = .{ acquire() }; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
}
