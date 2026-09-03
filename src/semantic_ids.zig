//! Compile-local semantic identities shared by frontend and MIR layers.

const std = @import("std");

/// Declaration identity within one compilation request.
///
/// `file_id` is the stable per-file source identity and `ordinal` is assigned
/// after declaration-producing frontend transforms. This intentionally makes
/// no cross-revision, cache, or separate-compilation promise.
pub const DefId = struct {
    file_id: u32,
    ordinal: u32,

    pub const invalid: DefId = .{
        .file_id = std.math.maxInt(u32),
        .ordinal = std.math.maxInt(u32),
    };

    pub fn isValid(self: DefId) bool {
        return self.file_id != invalid.file_id and self.ordinal != invalid.ordinal;
    }

    pub fn eql(self: DefId, other: DefId) bool {
        return self.file_id == other.file_id and self.ordinal == other.ordinal;
    }
};
