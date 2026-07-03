//! G8: `?` error coercion via an explicit `#[error_from]` conversion function.
//!
//! When `expr?` propagates a `Result<_, E1>` out of a function returning
//! `Result<_, E2>` and `E1 != E2`, the `?` must invoke a user-written conversion
//! from `E1` to `E2`. The conversion is a plain free function annotated
//! `#[error_from]` with exactly one parameter of type `E1` and return type `E2`:
//!
//!     #[error_from]
//!     fn high_from_low(e: LowErr) -> HighErr { ... }
//!
//! The user writes the conversion (EXPLICIT); the compiler only inserts its
//! INVOCATION on the `?` error path. If no matching conversion exists, sema
//! rejects the `?` with `E_NO_ERROR_CONVERSION`. When `E1 == E2` nothing changes:
//! the error is propagated as-is, byte-identical to before this feature.
//!
//! The trait machinery cannot express `impl From<E1> for E2` (impl trait names are
//! plain idents with no generic type argument, and each impl is keyed by
//! (trait, target-type) — so a single target type cannot carry two `From` impls
//! distinguished by source type). A `#[error_from]` free-function convention keeps
//! the conversion fully explicit, needs no parser/monomorphizer changes, and is
//! resolvable at a `?` site from (source-error-name, target-error-name).

const std = @import("std");
const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");

pub const ATTR_NAME = "error_from";

/// True when a declaration's attribute list carries `#[error_from]`.
pub fn hasAttr(attrs: []const ast.Attr) bool {
    for (attrs) |attr| switch (attr.kind) {
        .named => |named| if (std.mem.eql(u8, named.text, ATTR_NAME)) return true,
        else => {},
    };
    return false;
}

fn infoReturnType(info: anytype) ?ast.TypeExpr {
    const Info = @TypeOf(info);
    if (@hasField(Info, "return_ty")) return info.return_ty; // sema FunctionInfo
    if (@hasField(Info, "return_type")) return info.return_type; // C FnInfo
    return info.ret; // LLVM FnSig (non-optional)
}

/// Resolve the `#[error_from]` conversion from error type name `from` to `to` by
/// scanning a function registry (any map whose value carries `.error_from`,
/// `.params`, and a return type). Returns the conversion function's symbol name,
/// or null if none is declared. `from`/`to` are compared as nominal type names.
pub fn resolve(functions: anytype, from: []const u8, to: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, from, to)) return null; // same error type: no conversion
    var it = functions.iterator();
    while (it.next()) |entry| {
        const info = entry.value_ptr.*;
        if (!info.error_from) continue;
        if (info.params.len != 1) continue;
        const p = ast_query.typeName(info.params[0].ty) orelse continue;
        const ret = infoReturnType(info) orelse continue;
        const rn = ast_query.typeName(ret) orelse continue;
        if (std.mem.eql(u8, p, from) and std.mem.eql(u8, rn, to)) return entry.key_ptr.*;
    }
    return null;
}

/// Convenience: resolve using the operand-error and function-error TypeExprs
/// directly. Returns null when either type is unnamed or the two names match.
pub fn resolveTypes(functions: anytype, from_ty: ast.TypeExpr, to_ty: ast.TypeExpr) ?[]const u8 {
    const from = ast_query.typeName(from_ty) orelse return null;
    const to = ast_query.typeName(to_ty) orelse return null;
    return resolve(functions, from, to);
}
