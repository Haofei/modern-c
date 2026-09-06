const mir_model = @import("mir_model.zig");

pub const FnSig = struct {
    /// Canonical callable result identity. LLVM declaration and thunk
    /// rendering consume this through the module-owned signature table.
    return_ty: mir_model.ValueType,
    return_type_id: mir_model.SignatureTypeId,
    params: []const FnParam,
    c_abi: bool = false,
    is_variadic: bool = false,
    debug_id: ?usize = null,
    // G8: `#[error_from]` conversion `fn(E1) -> E2`, invoked by `?` on the error
    // path when the propagated error type differs from the function's error type.
    error_from: bool = false,
};

/// Backend-local callable parameter mechanics. Its type is a stable
/// module-owned signature identity; body lowering must not materialize an
/// AST type merely to render a declaration or closure thunk.
pub const FnParam = struct {
    name: []const u8,
    value_ty: mir_model.ValueType,
    type_id: mir_model.SignatureTypeId,
    is_comptime: bool = false,
};

// A generated env-widening thunk for a scalar-env `bind`. `fname` is the real
// target; the thunk takes the env as `ptr`, narrows it back to the scalar env
// type via `ptrtoint`, and forwards the remaining arguments.
pub const BindThunk = struct {
    fname: []const u8,
    sig: FnSig,
};

pub const StringLiteralGlobal = struct {
    name: []const u8,
    escaped_bytes: []const u8,
    len: usize,
    /// Null for expression-local strings. Planned global strings carry the
    /// frontend-owned backing identity so copies reuse one allocation.
    backing_id: ?mir_model.StringBackingId = null,
};

pub const DebugFunction = struct {
    id: usize,
    name: []const u8,
    source_path: []const u8,
    line: usize,
    column: usize,
};

pub const DebugLocation = struct {
    id: usize,
    scope: usize,
    line: usize,
    column: usize,
};
