const std = @import("std");

pub const LowerError = std.mem.Allocator.Error || error{
    UnsupportedCEmission,
    UnsupportedLlvmEmission,
    InvalidMirTargetTypeFacts,
    InvalidMirCallTargetFacts,
    InvalidMirConstGetFacts,
    InvalidMirIntegerFacts,
    InvalidMirFloatFacts,
    InvalidMirRepresentationFacts,
    StaleMirTargetTypeFacts,
    GeneratedTypeNameCollision,
    LayoutStructNotFound,
    LayoutUnresolved,
    InternalLoweringFailure,
};

pub fn lowerErrorFromAny(err: anyerror) LowerError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedCEmission => error.UnsupportedCEmission,
        error.UnsupportedLlvmEmission => error.UnsupportedLlvmEmission,
        error.InvalidMirTargetTypeFacts => error.InvalidMirTargetTypeFacts,
        error.InvalidMirCallTargetFacts => error.InvalidMirCallTargetFacts,
        error.InvalidMirConstGetFacts => error.InvalidMirConstGetFacts,
        error.InvalidMirIntegerFacts => error.InvalidMirIntegerFacts,
        error.InvalidMirFloatFacts => error.InvalidMirFloatFacts,
        error.InvalidMirRepresentationFacts => error.InvalidMirRepresentationFacts,
        error.StaleMirTargetTypeFacts => error.StaleMirTargetTypeFacts,
        error.GeneratedTypeNameCollision => error.GeneratedTypeNameCollision,
        error.LayoutStructNotFound => error.LayoutStructNotFound,
        error.LayoutUnresolved => error.LayoutUnresolved,
        else => error.InternalLoweringFailure,
    };
}

test "lowering errors are mapped to the domain error set" {
    try std.testing.expectEqual(LowerError.UnsupportedCEmission, lowerErrorFromAny(error.UnsupportedCEmission));
    try std.testing.expectEqual(LowerError.InvalidMirTargetTypeFacts, lowerErrorFromAny(error.InvalidMirTargetTypeFacts));
    try std.testing.expectEqual(LowerError.OutOfMemory, lowerErrorFromAny(error.OutOfMemory));
    try std.testing.expectEqual(LowerError.InternalLoweringFailure, lowerErrorFromAny(error.UnexpectedBackendBug));
}
