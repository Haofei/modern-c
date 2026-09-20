//! C backend atomic helpers.
//!
//! Maps already-verified atomic orderings to C `__ATOMIC_*` constants.
//!
//! Function-body atomic rendering lives in `mir_executable_c.zig`.  This file
//! remains only for shared ordering mechanics; it must not reopen AST call
//! syntax to select an atomic operation, and no longer can: it names no
//! syntax type. The three helpers that read ordering arguments and asm
//! clobbers out of the AST moved to `c_inspection.zig`, their only caller,
//! which is an inspection surface rather than a lowering path.

const std = @import("std");

pub fn atomicOrderCConstant(ordering: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, ordering, "relaxed")) return "__ATOMIC_RELAXED";
    if (std.mem.eql(u8, ordering, "acquire")) return "__ATOMIC_ACQUIRE";
    if (std.mem.eql(u8, ordering, "release")) return "__ATOMIC_RELEASE";
    if (std.mem.eql(u8, ordering, "acq_rel")) return "__ATOMIC_ACQ_REL";
    if (std.mem.eql(u8, ordering, "seq_cst")) return "__ATOMIC_SEQ_CST";
    return null;
}

pub fn atomicOrderSynchronizes(ordering: []const u8) bool {
    return !std.mem.eql(u8, ordering, "relaxed") and atomicOrderCConstant(ordering) != null;
}

pub fn isAtomicLoadOrdering(ordering: []const u8) bool {
    return std.mem.eql(u8, ordering, "relaxed") or
        std.mem.eql(u8, ordering, "acquire") or
        std.mem.eql(u8, ordering, "seq_cst");
}

pub fn isAtomicStoreOrdering(ordering: []const u8) bool {
    return std.mem.eql(u8, ordering, "relaxed") or
        std.mem.eql(u8, ordering, "release") or
        std.mem.eql(u8, ordering, "seq_cst");
}

/// Inspection and legacy-target validation share this representation predicate.
/// It is not a call-syntax classifier; executable MIR owns atomic operation
/// selection and payload typing before C rendering.
pub fn isAtomicIntegerPayload(name: []const u8) bool {
    return std.mem.eql(u8, name, "u8") or
        std.mem.eql(u8, name, "u16") or
        std.mem.eql(u8, name, "u32") or
        std.mem.eql(u8, name, "u64") or
        std.mem.eql(u8, name, "usize") or
        std.mem.eql(u8, name, "i8") or
        std.mem.eql(u8, name, "i16") or
        std.mem.eql(u8, name, "i32") or
        std.mem.eql(u8, name, "i64") or
        std.mem.eql(u8, name, "isize");
}
