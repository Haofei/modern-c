// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_MOVE_ARRAY_UNSUPPORTED

// Arrays of linear `move` resources are still rejected in storage/signature
// positions whose ownership cannot be tracked by the local indexed-place model:
// non-move struct fields, extern/export return types, extern/export parameters,
// and globals (section 18.1).
// Type aliases are allowed as names for locally tracked array places, but using
// those aliases in unsupported storage/signature positions still fails closed.
// Split out of tests/spec/move_cfg.mc: several
// of these are top-level declarations with trailing EXPECT_ERROR markers that the
// sweeps' chunk-level strip cannot isolate (the marker comment falls after the
// chunk-ending `;`), so they live in this pure-reject fixture the sweeps skip.

move struct Handle { v: u32 }
fn acquire() -> Handle {
    return .{ .v = 1 };
}

// --- rejected: an array of a `move` resource as a non-move struct field would make
//     a copyable aggregate own linear resources by value ---
struct BadArrayContainer {
    // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    hs: [4]Handle,
}

type HandleArray = [4]Handle;
type NestedHandleArray = [2][1]Handle;

// --- rejected: an exported function cannot return an array of `move` resources
//     by value, including through an alias ---
export fn reject_move_array_return() -> HandleArray { // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    return .{ acquire(), acquire(), acquire(), acquire() };
}

// --- rejected: an extern function cannot accept an array of `move` resources by
//     value, including through a nested alias ---
extern fn reject_move_array_param(hs: NestedHandleArray) -> void; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED

// --- rejected: global storage cannot hold an array of `move` resources by value,
//     including through an alias ---
global bad_move_array_global: HandleArray; // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
