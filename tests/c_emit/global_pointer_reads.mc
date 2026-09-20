// Reading pointer-typed values out of globals.
//
// A thin pointer is a single machine word, so it reads through the same places
// a scalar does. The renderer's capability rules had drifted apart from that:
// `xs[1]` on a `[2]u32` global emitted, while `names[1]` on a `[2]*const u8`
// global did not, and a whole `*const u8` global could not be read at all
// even though the nullable-pointer form could.

global names: [2]*const u8 = .{ "alpha", "beta" };
global message: *const u8 = "ready";

global seed: u32 = 7;
global maybe_ptrs: [2]?*mut u32 = .{ null, &seed };

// An element of a global array of pointers.
fn read_name() -> *const u8 {
    return names[1];
}

// A whole pointer-typed global, no projection.
fn read_message() -> *const u8 {
    return message;
}

// The same, through the null niche: an element of a global array of nullable
// pointers.
fn read_maybe_ptr() -> ?*mut u32 {
    return maybe_ptrs[1];
}

export fn global_pointer_reads_run() -> u32 {
    let name: *const u8 = read_name();
    let msg: *const u8 = read_message();
    if name == msg { return 0; }

    if let slot = read_maybe_ptr() {
        return slot.*;
    }
    return 0;
}
