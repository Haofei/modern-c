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

/// The ordinal range reserved for body-local declarations — parameters,
/// `let`/`var` bindings, pattern and loop bindings.
///
/// A local is a declaration and deserves an identity, but it is not one of the
/// file's top-level declarations, whose ordinals are dense from zero and are
/// the codegen declaration join key. Splitting the range keeps one `DefId`
/// space for both kinds without letting the two numberings collide.
pub const local_ordinal_base: u32 = 1 << 31;

pub fn isLocalOrdinal(ordinal: u32) bool {
    return ordinal >= local_ordinal_base and ordinal != DefId.invalid.ordinal;
}
