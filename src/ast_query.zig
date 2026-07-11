// Pure AST-shape queries shared across the checker, MIR builder, and C backend.
//
// These recognize syntactic forms over the AST — an identifier by name, an `mmio.map<T>(...)`
// intrinsic call and its payload, a fully-narrowed `Result` local, a layout/arithmetic type
// generic — returning a bool, a name, or an `ast` node. They were previously copied into
// `sema.zig`, `mir.zig`, and `lower_c.zig`; some copies had drifted (only the MIR copy of
// `isIdentNamed` looked through grouping parens), so a parenthesized form was recognized in one
// pass but not another. One definition keeps the passes agreeing on what a given form *is*.
//
// Only forms that are byte-identical across the passes live here; deliberately per-pass queries
// (e.g. sema's `structTypeName`, whose copy alone sees through a pointer) stay in their file. The
// non-pointer-aware struct-name lookup used by the MIR builder and C backend is just `typeName`.

const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

/// True when `expr` is (transparently through grouping parens) the identifier `name`.
/// Grouping is semantically invisible — `(x)` is `x` — so `(mmio).map(...)` must read the
/// same as `mmio.map(...)`.
pub fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| isIdentNamed(inner.*, name),
        else => false,
    };
}

/// True when `callee` names the `mmio.map` intrinsic (`mmio.map<T>(...)`), through grouping.
pub fn isMmioMapCallName(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "map") and isIdentNamed(member.base.*, "mmio"),
        .grouped => |inner| isMmioMapCallName(inner.*),
        else => false,
    };
}

/// For an `mmio.map<T>(...)` call, the payload type `MmioPtr<T>`; null for any other call. Takes
/// `call: anytype` so it accepts every pass's call node shape (all expose `callee` and
/// `type_args`).
pub fn mmioMapCallPayloadType(call: anytype) ?ast.TypeExpr {
    if (!isMmioMapCallName(call.callee.*) or call.type_args.len != 1) return null;
    return .{
        .span = call.type_args[0].span,
        .kind = .{ .generic = .{
            .base = .{ .text = "MmioPtr", .span = call.type_args[0].span },
            .args = call.type_args[0..1],
        } },
    };
}

// ── Expression / pattern queries ──────────────────────────────────────────────────────────

/// True when `expr` is the identifier `name`, through grouping parens. (A second spelling of
/// `isIdentNamed`, kept distinct only because callers reference both names.)
pub fn exprIsIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| exprIsIdentNamed(inner.*, name),
        else => false,
    };
}

/// The `bool` value of a boolean-literal expression (through grouping), or null.
pub fn boolLiteralValue(expr: ast.Expr) ?bool {
    return switch (expr.kind) {
        .bool_literal => |value| value,
        .grouped => |inner| boolLiteralValue(inner.*),
        else => null,
    };
}

/// True when `expr` is the `---` uninitialized literal, through grouping.
pub fn isUninitLiteral(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .uninit_literal => true,
        .grouped => |inner| isUninitLiteral(inner.*),
        else => false,
    };
}

/// True when an expression tree contains a `?` result/nullable propagation expression.
pub fn exprHandlesAnyResult(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .try_expr => true,
        .grouped, .address_of, .deref => |inner| exprHandlesAnyResult(inner.*),
        .block => |block| blockHandlesAnyResult(block),
        .array_literal => |items| {
            for (items) |item| {
                if (exprHandlesAnyResult(item)) return true;
            }
            return false;
        },
        .struct_literal => |fields| {
            for (fields) |field| {
                if (exprHandlesAnyResult(field.value)) return true;
            }
            return false;
        },
        .unary => |node| exprHandlesAnyResult(node.expr.*),
        .binary => |node| exprHandlesAnyResult(node.left.*) or exprHandlesAnyResult(node.right.*),
        .cast => |node| exprHandlesAnyResult(node.value.*),
        .call => |node| callHandlesAnyResult(node),
        .index => |node| exprHandlesAnyResult(node.base.*) or exprHandlesAnyResult(node.index.*),
        .slice => |node| exprHandlesAnyResult(node.base.*) or exprHandlesAnyResult(node.start.*) or exprHandlesAnyResult(node.end.*),
        .member => |node| exprHandlesAnyResult(node.base.*),
        else => false,
    };
}

pub fn blockHandlesAnyResult(block: ast.Block) bool {
    for (block.items) |stmt| {
        if (stmtHandlesAnyResult(stmt)) return true;
    }
    return false;
}

pub fn stmtHandlesAnyResult(stmt: ast.Stmt) bool {
    return switch (stmt.kind) {
        .let_decl, .var_decl => |local| if (local.init) |expr| exprHandlesAnyResult(expr) else false,
        .loop => |node| (if (node.iterable) |iterable| exprHandlesAnyResult(iterable) else false) or blockHandlesAnyResult(node.body),
        .if_let => |node| exprHandlesAnyResult(node.value) or blockHandlesAnyResult(node.then_block) or (if (node.else_block) |else_block| blockHandlesAnyResult(else_block) else false),
        .@"switch" => |node| switchHandlesAnyResult(node),
        .unsafe_block, .comptime_block, .block => |block| blockHandlesAnyResult(block),
        .contract_block => |contract| blockHandlesAnyResult(contract.block),
        .@"return" => |maybe| if (maybe) |expr| exprHandlesAnyResult(expr) else false,
        .@"break", .@"continue", .asm_stmt => false,
        .@"defer", .expr, .assert => |expr| exprHandlesAnyResult(expr),
        .assignment => |node| exprHandlesAnyResult(node.target) or exprHandlesAnyResult(node.value),
    };
}

pub fn switchHandlesAnyResult(node: ast.Switch) bool {
    if (exprHandlesAnyResult(node.subject)) return true;
    for (node.arms) |arm| {
        const handles = switch (arm.body) {
            .block => |block| blockHandlesAnyResult(block),
            .expr => |expr| exprHandlesAnyResult(expr),
        };
        if (handles) return true;
    }
    return false;
}

pub fn callHandlesAnyResult(call: anytype) bool {
    if (exprHandlesAnyResult(call.callee.*)) return true;
    for (call.args) |arg| {
        if (exprHandlesAnyResult(arg)) return true;
    }
    return false;
}

/// True when `name` is a `Result` narrowing tag (`ok` / `err`).
pub fn isResultNarrowingTag(name: []const u8) bool {
    return std.mem.eql(u8, name, "ok") or std.mem.eql(u8, name, "err");
}

/// True when the local declaration binds `name` (one of its `names`).
pub fn localDeclaresName(local: ast.LocalDecl, name: []const u8) bool {
    for (local.names) |ident| {
        if (std.mem.eql(u8, ident.text, name)) return true;
    }
    return false;
}

/// True when `if let ok(x) = name { … } else { … }` fully narrows the `Result` local `name`
/// (a tag-binding `ok`/`err` pattern over `name`, with an `else`).
pub fn resultIfLetHandlesLocal(name: []const u8, node: ast.IfLet) bool {
    if (node.else_block == null or !exprIsIdentNamed(node.value, name)) return false;
    return switch (node.pattern.kind) {
        .tag_bind => |tag_bind| isResultNarrowingTag(tag_bind.tag.text),
        else => false,
    };
}

/// True when a `switch` over `name` exhaustively handles the `Result` local — either a
/// wildcard arm, or both an `ok` and an `err` arm.
pub fn resultSwitchHandlesLocal(name: []const u8, node: ast.Switch) bool {
    if (!exprIsIdentNamed(node.subject, name)) return false;
    var has_wildcard = false;
    var has_ok = false;
    var has_err = false;
    for (node.arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .wildcard => has_wildcard = true,
                .tag => |tag| {
                    if (std.mem.eql(u8, tag.text, "ok")) has_ok = true;
                    if (std.mem.eql(u8, tag.text, "err")) has_err = true;
                },
                .tag_bind => |tag_bind| {
                    if (std.mem.eql(u8, tag_bind.tag.text, "ok")) has_ok = true;
                    if (std.mem.eql(u8, tag_bind.tag.text, "err")) has_err = true;
                },
                .literal, .bind => {},
            }
        }
    }
    return has_wildcard or (has_ok and has_err);
}

/// The single `asm` statement of a `#[naked]` function body, or `null` if the body
/// is not the well-formed shape (exactly one `asm` block, optionally wrapped in one
/// `unsafe { }` block). A naked body has no frame for anything else; sema reports
/// `E_NAKED_BODY` when this returns `null`, and both backends emit from it.
pub fn nakedAsmStmt(body: ast.Block) ?ast.AsmStmt {
    if (body.items.len != 1) return null;
    return switch (body.items[0].kind) {
        .asm_stmt => |stmt| stmt,
        .unsafe_block => |inner| if (inner.items.len == 1) switch (inner.items[0].kind) {
            .asm_stmt => |stmt| stmt,
            else => null,
        } else null,
        else => null,
    };
}

/// The contract name of an attribute (`#[unsafe_contract(name)]`), or `"unknown"`.
pub fn contractName(attr: ast.Attr) []const u8 {
    return switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .naked, .@"noinline", .weak, .named, .backend_name, .origin, .section, .@"align" => "unknown",
    };
}

// ── Type-shape queries ────────────────────────────────────────────────────────────────────

/// A synthetic plain named type (`.name`) carrying `name` at `span`.
pub fn simpleNameType(name: []const u8, span: diagnostics.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .text = name, .span = span } } };
}

/// The leading type name of a (possibly `qualified`) named type, or null.
pub fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

/// True for a raw many-pointer type `[*]T` (through a qualifier).
pub fn isRawManyPointerType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .raw_many_pointer => true,
        .qualified => |node| isRawManyPointerType(node.child.*),
        else => false,
    };
}

/// True for the pointer-like layout generics (`MmioPtr`, `UserPtr`).
pub fn isPointerLikeGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "MmioPtr") or std.mem.eql(u8, name, "UserPtr");
}

/// True for the arithmetic-layout generics that wrap a scalar (`wrap`, `sat`, `serial`,
/// `counter`, `Duration`).
pub fn isArithmeticLayoutGeneric(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter") or
        std.mem.eql(u8, name, "Duration");
}

/// True for a saturating-arithmetic type `sat<T>` (through a qualifier).
pub fn isSatType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatType(node.child.*),
        else => false,
    };
}

/// True for a wrapping-arithmetic type `wrap<T>` (through a qualifier).
pub fn isWrapType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapType(node.child.*),
        else => false,
    };
}

/// The pointee type name of an `MmioPtr<T>`, or null for any other type.
pub fn mmioPointee(ty: ast.TypeExpr) ?[]const u8 {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "MmioPtr") or generic.args.len != 1) return null;
    return typeName(generic.args[0]);
}

/// True for the binary operators whose result a saturating type preserves (`+`, `-`, `*`).
pub fn isSatPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul => true,
        else => false,
    };
}

/// True for the binary operators whose result a wrapping type preserves.
pub fn isWrapPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

/// True when any declaration attribute is `#[no_lang_trap]`.
pub fn hasNoLangTrap(attrs: []const ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .no_lang_trap) return true;
    }
    return false;
}

// ── Intrinsic-call recognition with their result shapes ───────────────────────────────────

const builtin_zero_span = diagnostics.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };
const builtin_u8_type = ast.TypeExpr{ .span = builtin_zero_span, .kind = .{ .name = .{ .text = "u8", .span = builtin_zero_span } } };

/// The `[]const u8` slice type, synthesized at `span` (the result of `mem.as_bytes`).
pub fn constU8SliceType(span: diagnostics.Span) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .slice = .{ .mutability = .@"const", .child = @constCast(&builtin_u8_type) } } };
}

/// The `mem.*` byte-view intrinsics.
pub const ByteViewCallKind = enum {
    as_bytes,
    bytes_equal,
};

/// Classify a `mem.as_bytes` / `mem.bytes_equal` call (through grouping), or null.
pub fn byteViewCallKind(callee: ast.Expr) ?ByteViewCallKind {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return byteViewCallKind(inner.*),
        else => return null,
    };
    if (!isIdentNamed(member.base.*, "mem")) return null;
    if (std.mem.eql(u8, member.name.text, "as_bytes")) return .as_bytes;
    if (std.mem.eql(u8, member.name.text, "bytes_equal")) return .bytes_equal;
    return null;
}

/// The payload type and mode tag of a `DmaBuf<T, .mode>` type, or null.
pub const DmaBufInfo = struct {
    payload: ast.TypeExpr,
    mode: []const u8,
};

pub fn dmaBufInfo(ty: ast.TypeExpr) ?DmaBufInfo {
    return switch (ty.kind) {
        .generic => |node| {
            if (!std.mem.eql(u8, node.base.text, "DmaBuf") or node.args.len != 2) return null;
            const mode = switch (node.args[1].kind) {
                .enum_literal => |literal| literal.text,
                else => return null,
            };
            return .{ .payload = node.args[0], .mode = mode };
        },
        .qualified => |node| dmaBufInfo(node.child.*),
        else => null,
    };
}

// ── Backend-shared queries (C and LLVM lowering) ──────────────────────────────────────────

/// The address operand of `&x` (through grouping), or null — the target of a byte-view.
pub fn byteViewAddressTarget(expr: ast.Expr) ?ast.Expr {
    return switch (expr.kind) {
        .address_of => |target| target.*,
        .grouped => |inner| byteViewAddressTarget(inner.*),
        else => null,
    };
}

/// The identifier text of a callee expression (through grouping), or null.
pub fn calleeIdentName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| calleeIdentName(inner.*),
        else => null,
    };
}

/// A call expression, through grouping.
pub const CallExpr = struct {
    callee: *ast.Expr,
    type_args: []ast.TypeExpr,
    args: []ast.Expr,
};

pub fn callExpr(expr: ast.Expr) ?CallExpr {
    return switch (expr.kind) {
        .call => |node| .{ .callee = node.callee, .type_args = node.type_args, .args = node.args },
        .grouped => |inner| callExpr(inner.*),
        else => null,
    };
}

/// A member expression (`base.name`), through grouping.
pub const MemberExpr = struct { base: *ast.Expr, name: ast.Ident };

pub fn memberExpr(expr: ast.Expr) ?MemberExpr {
    return switch (expr.kind) {
        .member => |node| .{ .base = node.base, .name = node.name },
        .grouped => |inner| memberExpr(inner.*),
        else => null,
    };
}

/// An index expression (`base[index]`), through grouping.
pub const IndexExpr = struct { base: *ast.Expr, index: *ast.Expr };

pub fn indexExpr(expr: ast.Expr) ?IndexExpr {
    return switch (expr.kind) {
        .index => |node| .{ .base = node.base, .index = node.index },
        .grouped => |inner| indexExpr(inner.*),
        else => null,
    };
}

/// A member callee expression (`base.name(...)`), through grouping.
pub const MemberCallee = struct { base: *ast.Expr, name: ast.Ident };

pub fn memberCallee(expr: ast.Expr) ?MemberCallee {
    return switch (expr.kind) {
        .member => |node| .{ .base = node.base, .name = node.name },
        .grouped => |inner| memberCallee(inner.*),
        else => null,
    };
}

/// A `Type.member(...)` callee, decomposed into its owner name and member ident.
/// This is the syntactic shape of a qualified tagged-union constructor
/// (`Token.number(11)`) — the caller decides whether `owner` is actually a union.
/// It is purely syntactic; an inherent/associated `impl` call (`Guarded.lock`) and
/// an intrinsic namespace (`atomic.load`) share the same shape and are told apart by
/// the caller's type tables.
pub const QualifiedCallee = struct { owner: []const u8, member: ast.Ident };

pub fn qualifiedMemberCallee(expr: ast.Expr) ?QualifiedCallee {
    return switch (expr.kind) {
        .member => |node| switch (node.base.*.kind) {
            .ident => |base_ident| QualifiedCallee{ .owner = base_ident.text, .member = node.name },
            else => null,
        },
        .grouped => |inner| qualifiedMemberCallee(inner.*),
        else => null,
    };
}

/// True when `callee` names the `cpu.pause` intrinsic (through grouping).
pub fn isCpuPauseCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "pause") and isIdentNamed(member.base.*, "cpu"),
        .grouped => |inner| isCpuPauseCall(inner.*),
        else => false,
    };
}

/// True when `callee` names the `raw.load` intrinsic (through grouping).
pub fn isRawLoadCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "load") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawLoadCall(inner.*),
        else => false,
    };
}

/// The result type of `raw.load<T>(addr)`, or null when the call shape is not exact.
pub fn rawLoadCallReturnType(call: anytype) ?ast.TypeExpr {
    if (!isRawLoadCall(call.callee.*) or call.type_args.len != 1 or call.args.len != 1) return null;
    return call.type_args[0];
}

/// If `callee` is a `va.<name>` intrinsic (through grouping), return `<name>`; else null.
pub fn vaCallMember(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |member| if (isIdentNamed(member.base.*, "va")) member.name.text else null,
        .grouped => |inner| vaCallMember(inner.*),
        else => null,
    };
}

/// True when `callee` names `va.start` (the only `va.*` valid as a let initializer).
pub fn isVaStartCall(callee: ast.Expr) bool {
    return if (vaCallMember(callee)) |name| std.mem.eql(u8, name, "start") else false;
}

/// True when `callee` names the `raw.ptr` intrinsic (through grouping).
pub fn isRawPtrCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "ptr") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawPtrCall(inner.*),
        else => false,
    };
}

/// The result type of `raw.ptr<T>(addr)`, or null when the call shape is not exact.
pub fn rawPtrCallReturnType(call: anytype) ?ast.TypeExpr {
    if (!isRawPtrCall(call.callee.*) or call.type_args.len != 1 or call.args.len != 1) return null;
    return .{
        .span = call.callee.*.span,
        .kind = .{ .pointer = .{ .mutability = .mut, .child = @constCast(&call.type_args[0]) } },
    };
}

/// True when `callee` names the `raw.store` intrinsic (through grouping).
pub fn isRawStoreCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "store") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawStoreCall(inner.*),
        else => false,
    };
}

/// True for the opaque address type names (`PAddr`, `VAddr`, `DmaAddr`).
pub fn isOpaqueAddressTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "PAddr") or
        std.mem.eql(u8, name, "VAddr") or
        std.mem.eql(u8, name, "DmaAddr");
}

/// True for a pointer (or raw many-pointer) to `u8` — the string-literal target shape.
pub fn isStringLiteralTarget(ty: ast.TypeExpr) bool {
    if (typeName(ty)) |name| {
        if (std.mem.eql(u8, name, "cstr")) return true;
    }
    const child = switch (ty.kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        else => return false,
    };
    const name = typeName(child) orelse return false;
    return std.mem.eql(u8, name, "u8");
}

/// If `ty` is a `[]const u8` / `[]u8` slice (a byte-slice), return its element mutability;
/// null otherwise. This is the slice-shaped string-literal target: a string literal can lower
/// to a fat-pointer slice value `{ptr, len}` over a static C string literal.
pub fn u8SliceMutability(ty: ast.TypeExpr) ?ast.Mutability {
    const node = switch (ty.kind) {
        .slice => |node| node,
        else => return null,
    };
    const name = typeName(node.child.*) orelse return null;
    if (!std.mem.eql(u8, name, "u8")) return null;
    return node.mutability;
}

/// The decoded byte length of a `"…"` string literal lexeme (escapes counted as one byte
/// each), or null if the lexeme is malformed / has an unsupported escape. Matches the escape
/// set of both backends' string-literal emitters (no trailing NUL is counted).
pub fn stringLiteralByteLen(literal: []const u8) ?usize {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    const body = literal[1 .. literal.len - 1];
    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\') {
            n += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) return null;
        switch (body[i]) {
            '\\', '\'', '"', '0', 'n', 'r', 't' => {},
            else => return null,
        }
        n += 1;
    }
    return n;
}

/// True for a struct declared with `abi("mmio")`.
pub fn isMmioStructAbi(struct_decl: ast.StructDecl) bool {
    return if (struct_decl.abi) |abi| std.mem.eql(u8, abi, "mmio") else false;
}

/// The field name an `.enum_literal` reflection argument names (through grouping), or null.
pub fn reflectionFieldName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| reflectionFieldName(inner.*),
        else => null,
    };
}

/// The element type of a `[N]u8` byte-array overlay (through a qualifier), or null.
pub fn overlayByteArrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| {
            const child_name = typeName(node.child.*) orelse return null;
            if (!std.mem.eql(u8, child_name, "u8")) return null;
            return node.child.*;
        },
        .qualified => |node| overlayByteArrayElementType(node.child.*),
        else => null,
    };
}

/// The element type of an overlay array view of ANY element type (e.g. `[N]u16`),
/// or null if `ty` is not an array. Unlike `overlayByteArrayElementType`, this is
/// not restricted to `u8` — it backs the non-byte array-view read/write lowering.
pub fn overlayArrayElementType(ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .array => |node| node.child.*,
        .qualified => |node| overlayArrayElementType(node.child.*),
        else => null,
    };
}

/// The member node of a `base.field` overlay index base (through grouping), or null.
pub fn overlayMemberFromIndexBase(expr: ast.Expr) ?@TypeOf(expr.kind.member) {
    return switch (expr.kind) {
        .member => |member| member,
        .grouped => |inner| overlayMemberFromIndexBase(inner.*),
        else => null,
    };
}

/// The union case named `name`, or null.
pub fn taggedUnionCase(union_decl: ast.UnionDecl, name: []const u8) ?ast.UnionCase {
    for (union_decl.cases) |case| {
        if (std.mem.eql(u8, case.name.text, name)) return case;
    }
    return null;
}

/// The result type of a qualified tagged-union constructor `Union.variant(...)`,
/// or null when the callee is not a known tagged-union case.
pub fn qualifiedTaggedUnionConstructorType(tagged_unions: *const std.StringHashMap(ast.UnionDecl), call: anytype) ?ast.TypeExpr {
    const q = qualifiedMemberCallee(call.callee.*) orelse return null;
    const union_decl = tagged_unions.get(q.owner) orelse return null;
    if (taggedUnionCase(union_decl, q.member.text) == null) return null;
    return simpleNameType(q.owner, call.callee.*.span);
}

/// The result type of a value-position enum variant path `Enum.variant`, or null
/// when the base is shadowed by a value binding or the member is not an enum case.
pub fn enumVariantPathType(enums: *const std.StringHashMap(ast.EnumDecl), member: anytype, base_is_value: bool) ?ast.TypeExpr {
    if (base_is_value) return null;
    const base_ident = switch (member.base.*.kind) {
        .ident => |id| id,
        else => return null,
    };
    const enum_decl = enums.get(base_ident.text) orelse return null;
    for (enum_decl.cases) |case| {
        if (std.mem.eql(u8, case.name.text, member.name.text)) {
            return simpleNameType(base_ident.text, base_ident.span);
        }
    }
    return null;
}

pub fn dynCalleeMethodName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |m| m.name.text,
        .grouped => |inner| dynCalleeMethodName(inner.*),
        else => null,
    };
}

/// The access mode of an MMIO register: which of read/write the hardware permits. The
/// checker and the MIR optimizer both reason about this identically.
pub const MmioRegisterAccess = enum {
    read,
    write,
    read_write,

    pub fn allowsRead(self: MmioRegisterAccess) bool {
        return self == .read or self == .read_write;
    }

    pub fn allowsWrite(self: MmioRegisterAccess) bool {
        return self == .write or self == .read_write;
    }
};

/// Maps an `.enum_literal` access-mode type (`read`/`write`/`read_write`) to its
/// `MmioRegisterAccess`, or null for any other type shape or unknown literal.
pub fn mmioRegisterAccessFromModeType(ty: ast.TypeExpr) ?MmioRegisterAccess {
    const name = switch (ty.kind) {
        .enum_literal => |literal| literal.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "write")) return .write;
    if (std.mem.eql(u8, name, "read_write")) return .read_write;
    return null;
}

/// The `reduce.*` sum intrinsics.
pub const ReduceCallKind = enum { sum_checked, sum_left, sum_fast };

/// Classify a `reduce.sum_checked` / `reduce.sum_left` / `reduce.sum_fast` call (through
/// grouping), or null.
pub fn reduceCallKind(callee: ast.Expr) ?ReduceCallKind {
    const member = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return reduceCallKind(inner.*),
        else => return null,
    };
    if (!isIdentNamed(member.base.*, "reduce")) return null;
    if (std.mem.eql(u8, member.name.text, "sum_checked")) return .sum_checked;
    if (std.mem.eql(u8, member.name.text, "sum_left")) return .sum_left;
    if (std.mem.eql(u8, member.name.text, "sum_fast")) return .sum_fast;
    return null;
}
