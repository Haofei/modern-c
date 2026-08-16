const std = @import("std");

const ast = @import("ast.zig");
const numeric = @import("numeric.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const declaration_artifact_fallbacks = declaration_artifacts;
const FunctionBodyFallbackArtifact = declaration_artifact_fallbacks.FunctionBodyFallbackArtifact;
const string_literal = @import("string_literal.zig");
const target_layout = @import("target_layout.zig");

pub const Trap = enum {
    IntegerOverflow,
    DivideByZero,
    InvalidShift,
};

pub const RunTrapExpectation = struct {
    function_name: []const u8,
    args: []i128,
    trap: Trap,
    line: usize,
};

pub const EvalError = error{
    FunctionNotFound,
    MissingFunctionBody,
    ArgumentCountMismatch,
    UnsupportedRunTrapFixture,
    UnknownIdentifier,
    MissingReturn,
    InvalidIntegerLiteral,
    InvalidRunTrapExpectation,
} || std.mem.Allocator.Error;

pub fn parseRunTrapExpectations(allocator: std.mem.Allocator, source: []const u8) EvalError!std.ArrayList(RunTrapExpectation) {
    var out: std.ArrayList(RunTrapExpectation) = .empty;
    errdefer freeRunTrapExpectations(allocator, &out);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trim(u8, raw_line, "\r");
        const comment_start = std.mem.indexOf(u8, line, "//") orelse continue;
        const comment = std.mem.trim(u8, line[comment_start + 2 ..], " \t");
        const prefix = "EXPECT: run ";
        if (!std.mem.startsWith(u8, comment, prefix)) continue;

        const payload = comment[prefix.len..];
        const open = std.mem.indexOfScalar(u8, payload, '(') orelse return error.InvalidRunTrapExpectation;
        const close = std.mem.indexOfScalar(u8, payload[open + 1 ..], ')') orelse return error.InvalidRunTrapExpectation;
        const close_index = open + 1 + close;
        const function_name = std.mem.trim(u8, payload[0..open], " \t");
        if (function_name.len == 0) return error.InvalidRunTrapExpectation;

        const trap_prefix = " traps .";
        const after_call = payload[close_index + 1 ..];
        const trap_start = std.mem.indexOf(u8, after_call, trap_prefix) orelse return error.InvalidRunTrapExpectation;
        const trap_text = readIdentLike(after_call[trap_start + trap_prefix.len ..]);
        const trap = std.meta.stringToEnum(Trap, trap_text) orelse return error.InvalidRunTrapExpectation;

        const args = try parseRunTrapArgs(allocator, payload[open + 1 .. close_index]);
        try out.append(allocator, .{
            .function_name = function_name,
            .args = args,
            .trap = trap,
            .line = line_no,
        });
    }

    return out;
}

pub fn freeRunTrapExpectations(allocator: std.mem.Allocator, expectations: *std.ArrayList(RunTrapExpectation)) void {
    for (expectations.items) |expectation| allocator.free(expectation.args);
    expectations.deinit(allocator);
}

pub fn runTrapExpectationFromDecls(
    allocator: std.mem.Allocator,
    decls: []const ast.Decl,
    function_name: []const u8,
    args: []const i128,
) EvalError!?Trap {
    for (decls) |decl| {
        const fn_decl = switch (decl.kind) {
            .fn_decl => |node| node,
            else => continue,
        };
        if (!std.mem.eql(u8, fn_decl.name.text, function_name)) continue;
        const body = fn_decl.body orelse return error.MissingFunctionBody;
        if (fn_decl.params.len != args.len) return error.ArgumentCountMismatch;

        var evaluator = Evaluator.init(allocator);
        defer evaluator.deinit();

        for (fn_decl.params, args) |param, arg| {
            const info = try intInfo(param.ty);
            try evaluator.bind(param.name.text, .{ .value = arg, .ty = info });
        }

        const return_ty = if (fn_decl.return_type) |ty| try intInfo(ty) else null;
        return try evaluator.evalBlock(body, return_ty);
    }
    return error.FunctionNotFound;
}

const IntInfo = struct {
    signed: bool,
    bits: u8,

    fn min(self: IntInfo) i128 {
        if (!self.signed) return 0;
        return -(@as(i128, 1) << @intCast(self.bits - 1));
    }

    fn max(self: IntInfo) i128 {
        if (self.signed) return (@as(i128, 1) << @intCast(self.bits - 1)) - 1;
        return (@as(i128, 1) << @intCast(self.bits)) - 1;
    }

    fn contains(self: IntInfo, value: i128) bool {
        return value >= self.min() and value <= self.max();
    }
};

const Binding = struct {
    value: i128,
    ty: IntInfo,
};

const EvalResult = union(enum) {
    value: Binding,
    trap: Trap,
};

const Evaluator = struct {
    allocator: std.mem.Allocator,
    bindings: std.StringHashMap(Binding),

    fn init(allocator: std.mem.Allocator) Evaluator {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(Binding).init(allocator),
        };
    }

    fn deinit(self: *Evaluator) void {
        self.bindings.deinit();
    }

    fn bind(self: *Evaluator, name: []const u8, binding: Binding) !void {
        try self.bindings.put(name, binding);
    }

    fn evalBlock(self: *Evaluator, block: ast.Block, return_ty: ?IntInfo) EvalError!?Trap {
        for (block.items) |stmt| {
            switch (stmt.kind) {
                .let_decl, .var_decl => |local| {
                    if (local.names.len != 1) return error.UnsupportedRunTrapFixture;
                    const ty = if (local.ty) |node| try intInfo(node) else return error.UnsupportedRunTrapFixture;
                    const init_expr = local.init orelse return error.UnsupportedRunTrapFixture;
                    const value = switch (try self.evalExpr(init_expr, ty)) {
                        .trap => |trap| return trap,
                        .value => |binding| binding.value,
                    };
                    if (!ty.contains(value)) return .IntegerOverflow;
                    try self.bind(local.names[0].text, .{ .value = value, .ty = ty });
                },
                .@"return" => |maybe_expr| {
                    const expr = maybe_expr orelse return error.UnsupportedRunTrapFixture;
                    const ty = return_ty orelse return error.UnsupportedRunTrapFixture;
                    return switch (try self.evalExpr(expr, ty)) {
                        .trap => |trap| trap,
                        .value => |binding| if (ty.contains(binding.value)) null else .IntegerOverflow,
                    };
                },
                else => return error.UnsupportedRunTrapFixture,
            }
        }
        return error.MissingReturn;
    }

    fn evalExpr(self: *Evaluator, expr: ast.Expr, expected_ty: IntInfo) EvalError!EvalResult {
        return switch (expr.kind) {
            .ident => |ident| .{ .value = self.bindings.get(ident.text) orelse return error.UnknownIdentifier },
            .int_literal => |literal| .{ .value = .{ .value = try parseInt(literal), .ty = expected_ty } },
            .grouped => |inner| try self.evalExpr(inner.*, expected_ty),
            .unary => |node| try self.evalUnary(node, self.explicitExprType(expr) orelse expected_ty),
            .binary => |node| try self.evalBinary(node, self.explicitExprType(expr) orelse expected_ty),
            .cast => |node| try self.evalCast(node),
            else => error.UnsupportedRunTrapFixture,
        };
    }

    fn explicitExprType(self: *Evaluator, expr: ast.Expr) ?IntInfo {
        return switch (expr.kind) {
            .ident => |ident| (self.bindings.get(ident.text) orelse return null).ty,
            .int_literal => |literal| blk: {
                const parsed = numeric.parseIntegerLiteralParts(literal) orelse break :blk null;
                const suffix = parsed.suffix orelse break :blk null;
                const ty = ast.TypeExpr{
                    .span = expr.span,
                    .kind = .{ .name = .{ .text = suffix.typeName(), .span = expr.span } },
                };
                break :blk intInfo(ty) catch null;
            },
            .grouped => |inner| self.explicitExprType(inner.*),
            .unary => |node| self.explicitExprType(node.expr.*),
            .binary => |node| self.explicitExprType(node.left.*) orelse self.explicitExprType(node.right.*),
            .cast => |node| intInfo(node.ty.*) catch null,
            else => null,
        };
    }

    fn evalCast(self: *Evaluator, node: anytype) EvalError!EvalResult {
        const target_ty = try intInfo(node.ty.*);
        const source_ty = self.explicitExprType(node.value.*) orelse target_ty;
        return switch (try self.evalExpr(node.value.*, source_ty)) {
            .trap => |trap| .{ .trap = trap },
            .value => |binding| if (target_ty.contains(binding.value))
                .{ .value = .{ .value = binding.value, .ty = target_ty } }
            else
                .{ .trap = .IntegerOverflow },
        };
    }

    fn evalUnary(self: *Evaluator, node: anytype, expected_ty: IntInfo) EvalError!EvalResult {
        if (node.op != .neg) return error.UnsupportedRunTrapFixture;
        if (node.expr.kind == .int_literal) {
            const magnitude = try parseInt(node.expr.kind.int_literal);
            const value = std.math.negate(magnitude) catch return .{ .trap = .IntegerOverflow };
            if (!expected_ty.contains(value)) return .{ .trap = .IntegerOverflow };
            return .{ .value = .{ .value = value, .ty = expected_ty } };
        }
        const inner = switch (try self.evalExpr(node.expr.*, expected_ty)) {
            .trap => |trap| return .{ .trap = trap },
            .value => |binding| binding,
        };
        const ty = inner.ty;
        if (!ty.signed or inner.value == ty.min()) return .{ .trap = .IntegerOverflow };
        const value = std.math.negate(inner.value) catch return .{ .trap = .IntegerOverflow };
        return .{ .value = .{ .value = value, .ty = ty } };
    }

    fn evalBinary(self: *Evaluator, node: anytype, expected_ty: IntInfo) EvalError!EvalResult {
        const left = switch (try self.evalExpr(node.left.*, expected_ty)) {
            .trap => |trap| return .{ .trap = trap },
            .value => |binding| binding,
        };
        const right = switch (try self.evalExpr(node.right.*, left.ty)) {
            .trap => |trap| return .{ .trap = trap },
            .value => |binding| binding,
        };
        const ty = left.ty;

        const value = switch (node.op) {
            .add => std.math.add(i128, left.value, right.value) catch return .{ .trap = .IntegerOverflow },
            .sub => std.math.sub(i128, left.value, right.value) catch return .{ .trap = .IntegerOverflow },
            .mul => std.math.mul(i128, left.value, right.value) catch return .{ .trap = .IntegerOverflow },
            .div => blk: {
                if (right.value == 0) return .{ .trap = .DivideByZero };
                if (ty.signed and left.value == ty.min() and right.value == -1) return .{ .trap = .IntegerOverflow };
                break :blk @divTrunc(left.value, right.value);
            },
            .mod => blk: {
                if (right.value == 0) return .{ .trap = .DivideByZero };
                if (ty.signed and left.value == ty.min() and right.value == -1) return .{ .trap = .IntegerOverflow };
                break :blk @rem(left.value, right.value);
            },
            .shl => blk: {
                if (right.value < 0 or right.value >= ty.bits) return .{ .trap = .InvalidShift };
                if (right.value >= @bitSizeOf(i128)) {
                    break :blk if (left.value == 0) 0 else return .{ .trap = .IntegerOverflow };
                }
                const factor = std.math.shl(i128, 1, @as(u7, @intCast(right.value)));
                break :blk std.math.mul(i128, left.value, factor) catch return .{ .trap = .IntegerOverflow };
            },
            .shr => blk: {
                if (right.value < 0 or right.value >= ty.bits) return .{ .trap = .InvalidShift };
                break :blk left.value >> @intCast(right.value);
            },
            else => return error.UnsupportedRunTrapFixture,
        };

        if (!ty.contains(value)) return .{ .trap = .IntegerOverflow };
        return .{ .value = .{ .value = value, .ty = ty } };
    }
};

// --- Comptime constant-expression evaluator (section 22) -------------------
//
// A narrow tree-walking evaluator over the compile-time subset used by sema:
// integer/bool/enum-tag literals, comptime-bound `let`/`var` constants,
// arithmetic, comparisons, logical operators, arrays/structs, and simple
// control flow. Anything outside the supported subset folds to `.unknown`,
// which sema treats as "not provably wrong" — no diagnostic.

pub const ComptimeStructField = struct {
    name: []const u8,
    value: ComptimeValue,
};

pub const ComptimeFloat = struct {
    bits: u64,
    width: u8,

    pub fn fromF32(value: f32) ComptimeFloat {
        return .{ .bits = @as(u32, @bitCast(value)), .width = 32 };
    }

    pub fn fromF64(value: f64) ComptimeFloat {
        return .{ .bits = @bitCast(value), .width = 64 };
    }

    pub fn asF32(self: ComptimeFloat) f32 {
        return if (self.width == 32)
            @bitCast(@as(u32, @truncate(self.bits)))
        else
            @floatCast(@as(f64, @bitCast(self.bits)));
    }

    pub fn asF64(self: ComptimeFloat) f64 {
        return if (self.width == 32)
            @floatCast(@as(f32, @bitCast(@as(u32, @truncate(self.bits)))))
        else
            @bitCast(self.bits);
    }
};

pub const ComptimeValue = union(enum) {
    void,
    int: i128,
    // Values above i128.max remain first-class comptime integers instead of
    // degrading to `.unknown`. Together the two arms cover every MC i128/u128
    // scalar value; the declared type/domain continues to live in semantic
    // facts and the comptime scope's width/domain maps.
    uint: u128,
    // Width and raw bits are part of the value. This forces f32 rounding after
    // every f32 operation and preserves signed zero and NaN sign/payload.
    float: ComptimeFloat,
    boolean: bool,
    tag: []const u8,
    // A comptime byte string — the decoded bytes of a string literal. Backed by the
    // fold scope's allocator (escape decoding allocates), so it is cloned/freed.
    bytes: []const u8,
    // A fixed comptime array value (section 22). Element storage is owned by the
    // evaluation scope's allocator and lives for the duration of the fold.
    array: []const ComptimeValue,
    // A comptime struct value: field name → value, scope-allocated like arrays.
    @"struct": []const ComptimeStructField,
};

fn comptimeIntegerLiteral(raw: []const u8) ?ComptimeValue {
    const magnitude = numeric.parseIntegerLiteral(raw) orelse return null;
    if (magnitude <= std.math.maxInt(i128)) return .{ .int = @intCast(magnitude) };
    return .{ .uint = magnitude };
}

fn comptimeUnsignedValue(value: u128) ComptimeValue {
    if (value <= std.math.maxInt(i128)) return .{ .int = @intCast(value) };
    return .{ .uint = value };
}

fn comptimeNonnegative(value: ComptimeValue) ?u128 {
    return switch (value) {
        .int => |n| if (n >= 0) @intCast(n) else null,
        .uint => |n| n,
        else => null,
    };
}

pub fn cloneComptimeValue(allocator: std.mem.Allocator, value: ComptimeValue) !ComptimeValue {
    return switch (value) {
        .void, .int, .uint, .float, .boolean, .tag => value,
        .bytes => |b| .{ .bytes = try allocator.dupe(u8, b) },
        .array => |items| blk: {
            const copy = try allocator.alloc(ComptimeValue, items.len);
            var initialized: usize = 0;
            errdefer {
                for (copy[0..initialized]) |item| freeComptimeValue(allocator, item);
                allocator.free(copy);
            }
            for (items, 0..) |item, index| {
                copy[index] = try cloneComptimeValue(allocator, item);
                initialized += 1;
            }
            break :blk .{ .array = copy };
        },
        .@"struct" => |fields| blk: {
            const copy = try allocator.alloc(ComptimeStructField, fields.len);
            var initialized: usize = 0;
            errdefer {
                for (copy[0..initialized]) |field| freeComptimeValue(allocator, field.value);
                allocator.free(copy);
            }
            for (fields, 0..) |field, index| {
                copy[index] = .{
                    .name = field.name,
                    .value = try cloneComptimeValue(allocator, field.value),
                };
                initialized += 1;
            }
            break :blk .{ .@"struct" = copy };
        },
    };
}

pub fn freeComptimeValue(allocator: std.mem.Allocator, value: ComptimeValue) void {
    switch (value) {
        .void, .int, .uint, .float, .boolean, .tag => {},
        .bytes => |b| allocator.free(b),
        .array => |items| {
            for (items) |item| freeComptimeValue(allocator, item);
            allocator.free(items);
        },
        .@"struct" => |fields| {
            for (fields) |field| freeComptimeValue(allocator, field.value);
            allocator.free(fields);
        },
    }
}

pub fn deinitConstGlobals(allocator: std.mem.Allocator, globals: *std.StringHashMap(ComptimeValue)) void {
    var it = globals.valueIterator();
    while (it.next()) |value| freeComptimeValue(allocator, value.*);
    globals.deinit();
}

pub const ComptimeFold = union(enum) {
    value: ComptimeValue,
    trap, // a provable trap during const eval (integer divide-by-zero, invalid shift)
    unknown, // not a compile-time constant; sema must not diagnose it
};

// Fuel limit on nested const-fn evaluation, so a recursive `const fn` cannot
// hang the compiler — it simply folds to `.unknown` past the limit.
const comptime_call_fuel: u32 = 256;

// Resolves a comptime reflection call (`sizeof`/`alignof`/…) to an integer, or
// null if it is not a reflection call this resolver can fold.
pub const ReflectFn = *const fn (ctx: ?*anyopaque, call: ast.Expr) ?i128;

// Shared scratch buffer for the const-fold evaluator's scopes. A comptime fold
// produces only short-lived scalar values (or the caller deep-copies aggregates
// out via cloneComptimeValue), so a single reusable buffer replaces the fresh
// 64 KiB stack buffer that hot fold sites used to `= undefined`-poison on every
// call (a 64 KiB memset per call in Debug/ReleaseSafe builds).
//
// Reentrancy: reflection folds can recurse back into the evaluator (e.g.
// sizeof of an array type re-folds the array length). A busy flag makes reuse
// safe — a nested fold sees the buffer in use and the caller falls back to its
// own allocator instead of resetting/clobbering the outer scope's allocations.
// `threadlocal` keeps it correct if the compiler ever folds on multiple threads.
threadlocal var fold_scratch_buf: [64 * 1024]u8 = undefined;
threadlocal var fold_scratch_fba: std.heap.FixedBufferAllocator = undefined;
threadlocal var fold_scratch_busy: bool = false;

/// Acquire the shared fold-scratch allocator, resetting it for a fresh fold.
/// Returns null when it is already in use on this thread (a reentrant fold); the
/// caller must then supply its own allocator. On success the caller MUST pair
/// this with `releaseFoldScratch()` (typically via `defer`) once the fold — and
/// any use of its results that alias the buffer — is complete.
pub fn tryFoldScratch() ?std.mem.Allocator {
    if (fold_scratch_busy) return null;
    fold_scratch_busy = true;
    fold_scratch_fba = std.heap.FixedBufferAllocator.init(&fold_scratch_buf);
    return fold_scratch_fba.allocator();
}

pub fn releaseFoldScratch() void {
    fold_scratch_busy = false;
}

pub const ComptimeScope = struct {
    bindings: std.StringHashMap(ComptimeValue),
    // Complete declared or inferred types for value bindings. Width/domain
    // maps remain fast-path caches, but correctness for projections, generic
    // substitution, and call results comes from these typed bindings.
    binding_types: std.StringHashMap(ast.TypeExpr),
    // Concrete type arguments for `comptime T: type` parameters. These are
    // AST slices/pointers owned by the parsed module's arena; the map only
    // borrows them for the duration of the fold.
    type_bindings: std.StringHashMap(ast.TypeExpr),
    // Registry of `const fn` declarations callable at comptime (section 22).
    funcs: ?*const std.StringHashMap(ComptimeFunction) = null,
    // Narrow declaration view used to resolve global types, aliases, and
    // aggregate field types while folding. AST storage is owned by the caller,
    // but callers do not need to expose a generic top-level declaration slice.
    declarations: ?ComptimeDeclarations = null,
    // Named compile-time constants (`const NAME: T = …` globals), resolved when
    // an identifier is not a local binding.
    globals: ?*const std.StringHashMap(ComptimeValue) = null,
    // Complete arithmetic-domain metadata for named globals. Values alone cannot
    // distinguish checked<T>, wrap<T>, and sat<T>.
    global_domains: ?*const std.StringHashMap(DomainWidth) = null,
    // Optional reflection resolver (section 22): folds `sizeof(T)`/`alignof(T)`/
    // `field_offset(T, .f)` calls to an integer using the front end's layout
    // model. Returns null for non-reflection calls or types it cannot lay out.
    reflect: ?ReflectFn = null,
    reflect_ctx: ?*anyopaque = null,
    // Nested const-fn call depth, bounded by comptime_call_fuel.
    call_depth: u32 = 0,
    // Substituted return type of the const function currently being evaluated.
    return_type: ?ast.TypeExpr = null,
    // Declared integer bit-width of bound names (params, comptime locals), so a
    // width-dependent fold like `~x` can mask to the operand's type. The comptime
    // model otherwise works in untyped i128, where `~0` is -1 rather than the
    // width-bounded `0xFFFFFFFF` a u32 would produce at runtime.
    widths: std.StringHashMap(u16),
    // Arithmetic domain + width per binding (section 5), so the folder can wrap/saturate/
    // trap a `wrap<uN>`/`sat<uN>`/checked `uN` operation as the runtime would.
    domains: std.StringHashMap(DomainWidth),
    oom: bool = false,

    pub fn init(allocator: std.mem.Allocator) ComptimeScope {
        return .{
            .bindings = std.StringHashMap(ComptimeValue).init(allocator),
            .binding_types = std.StringHashMap(ast.TypeExpr).init(allocator),
            .type_bindings = std.StringHashMap(ast.TypeExpr).init(allocator),
            .widths = std.StringHashMap(u16).init(allocator),
            .domains = std.StringHashMap(DomainWidth).init(allocator),
        };
    }

    pub fn deinit(self: *ComptimeScope) void {
        self.bindings.deinit();
        self.binding_types.deinit();
        self.type_bindings.deinit();
        self.widths.deinit();
        self.domains.deinit();
    }

    pub fn hasOom(self: *const ComptimeScope) bool {
        return self.oom;
    }

    pub fn recordOom(self: *const ComptimeScope) void {
        @constCast(self).oom = true;
    }

    fn alloc(self: *const ComptimeScope, comptime T: type, len: usize) std.mem.Allocator.Error![]T {
        return self.bindings.allocator.alloc(T, len) catch |err| {
            self.recordOom();
            return err;
        };
    }

    fn dupe(self: *const ComptimeScope, comptime T: type, slice: []const T) std.mem.Allocator.Error![]T {
        return self.bindings.allocator.dupe(T, slice) catch |err| {
            self.recordOom();
            return err;
        };
    }

    pub fn bind(self: *ComptimeScope, name: []const u8, value: ComptimeValue) !void {
        self.bindings.put(name, value) catch |err| {
            self.oom = true;
            return err;
        };
    }

    pub fn bindType(self: *ComptimeScope, name: []const u8, ty: ast.TypeExpr) !void {
        self.type_bindings.put(name, ty) catch |err| {
            self.oom = true;
            return err;
        };
    }

    pub fn bindWidth(self: *ComptimeScope, name: []const u8, bits: u16) std.mem.Allocator.Error!void {
        self.widths.put(name, bits) catch {
            self.oom = true;
            return error.OutOfMemory;
        };
    }

    // Bind a name's full domain+width from its declared type (covers `wrap`/`sat`/checked);
    // also records the bit width so width-sensitive bitwise ops keep working.
    pub fn bindTypeInfo(self: *ComptimeScope, name: []const u8, ty: ast.TypeExpr) std.mem.Allocator.Error!void {
        const resolved = resolveComptimeType(self, ty);
        self.binding_types.put(name, resolved) catch {
            self.oom = true;
            return error.OutOfMemory;
        };
        if (comptimeTypeBitWidth(resolved)) |bits| try self.bindWidth(name, bits);
        if (comptimeTypeDomainWidth(resolved)) |dw| {
            self.domains.put(name, dw) catch {
                self.oom = true;
                return error.OutOfMemory;
            };
            try self.bindWidth(name, dw.bits);
        }
    }
};

pub const ComptimeFunction = struct {
    name: ast.Ident,
    params: []const ast.Param,
    return_type: ?ast.TypeExpr,
    body: ?ast.Block,

    pub fn fromFnDecl(fn_decl: ast.FnDecl) ComptimeFunction {
        return .{
            .name = fn_decl.name,
            .params = fn_decl.params,
            .return_type = fn_decl.return_type,
            .body = fn_decl.body,
        };
    }

    pub fn fromDeclarationArtifact(function: declaration_artifacts.FunctionArtifact, body: ?ast.Block) ComptimeFunction {
        return .{
            .name = function.signature.name,
            .params = function.signature.params,
            .return_type = function.signature.return_type,
            .body = body,
        };
    }
};

pub const ComptimeDeclarations = struct {
    globals: []const ast.GlobalDecl = &.{},
    type_aliases: []const ast.TypeAlias = &.{},
    structs: []const ast.StructDecl = &.{},
    legacy_decls: ?[]const ast.Decl = null,
    decl_artifacts: ?[]const declaration_artifacts.DeclArtifact = null,
    function_body_fallbacks: []const FunctionBodyFallbackArtifact = &.{},

    pub fn fromDecls(decls: []const ast.Decl) ComptimeDeclarations {
        // Compatibility adapter for older frontend call sites. It keeps the
        // generic declaration scan inside eval instead of leaking it into
        // backend lowering state.
        return .{ .legacy_decls = decls };
    }

    pub fn fromDeclarationArtifacts(artifacts: declaration_artifacts.CodegenDeclarationArtifacts) ComptimeDeclarations {
        return .{
            .decl_artifacts = artifacts.decl_artifacts,
            .function_body_fallbacks = artifacts.function_body_fallbacks,
        };
    }
};

pub fn collectConstFunctionsFromDeclarations(
    declarations: ComptimeDeclarations,
    out: *std.StringHashMap(ComptimeFunction),
) !void {
    if (declarations.legacy_decls) |decls| {
        for (decls) |decl| switch (decl.kind) {
            .fn_decl => |function| if (function.is_const and !out.contains(function.name.text)) try out.put(function.name.text, ComptimeFunction.fromFnDecl(function)),
            else => {},
        };
        return;
    }
    if (declarations.decl_artifacts) |decl_artifacts| {
        for (decl_artifacts) |artifact| switch (artifact) {
            .function => |function| {
                if (!function.signature.is_const or out.contains(function.signature.name.text)) continue;
                const body = declaration_artifact_fallbacks.findLegacyFunctionBody(declarations.function_body_fallbacks, function.signature.name.text);
                try out.put(function.signature.name.text, ComptimeFunction.fromDeclarationArtifact(function, body));
            },
            else => {},
        };
    }
}

// The declared bit-width of an integer type expression, or null for non-integer
// (or width-unknown) types. usize/isize follow the explicit v0 target-data contract.
// The arithmetic domain + width of a comptime integer binding (section 5): a plain `uN`/`iN`
// is `checked`, `wrap<uN>`/`sat<uN>` carry their domain. Drives overflow handling in the
// const folder (checked → trap, wrap → mask mod 2^N, sat → clamp).
pub const ComptimeDomain = enum { checked, wrap, sat };
pub const DomainWidth = struct { domain: ComptimeDomain, bits: u16, signed: bool };
const ComptimeIntType = struct { bits: u16, signed: bool };

fn comptimeIntType(ty: ast.TypeExpr) ?ComptimeIntType {
    const scalar_ty = switch (ty.kind) {
        .generic => |g| if ((std.mem.eql(u8, g.base.text, "wrap") or std.mem.eql(u8, g.base.text, "sat")) and g.args.len == 1) g.args[0] else return null,
        .qualified => |q| q.child.*,
        else => ty,
    };
    const name = switch (scalar_ty.kind) {
        .name => |n| n.text,
        else => return null,
    };
    if (target_layout.pointerSizedIntegerBits(name)) |bits| {
        return .{ .bits = bits, .signed = std.mem.eql(u8, name, "isize") };
    }
    if (name.len < 2) return null;
    const signed = switch (name[0]) {
        'i' => true,
        'u' => false,
        else => return null,
    };
    const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
    return switch (bits) {
        8, 16, 32, 64, 128 => .{ .bits = bits, .signed = signed },
        else => null,
    };
}

fn comptimeIntFromBits(raw: u128, info: ComptimeIntType) ?i128 {
    if (info.bits == 0 or info.bits > 128) return null;
    const mask: u128 = if (info.bits == 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(info.bits)) - 1;
    const value = raw & mask;
    if (info.signed and ((value >> @intCast(info.bits - 1)) & 1) == 1) {
        if (info.bits == 128) return @bitCast(value);
        return @bitCast(value | ~mask);
    }
    return std.math.cast(i128, value);
}

pub fn comptimeTypeDomainWidth(ty: ast.TypeExpr) ?DomainWidth {
    switch (ty.kind) {
        .name => |n| {
            const w = comptimeTypeBitWidth(ty) orelse return null;
            return .{ .domain = .checked, .bits = w, .signed = n.text.len > 0 and n.text[0] == 'i' };
        },
        .generic => |g| {
            const domain: ComptimeDomain = if (std.mem.eql(u8, g.base.text, "wrap"))
                .wrap
            else if (std.mem.eql(u8, g.base.text, "sat"))
                .sat
            else
                return null;
            if (g.args.len != 1) return null;
            const w = comptimeTypeBitWidth(g.args[0]) orelse return null;
            const signed = switch (g.args[0].kind) {
                .name => |nn| nn.text.len > 0 and nn.text[0] == 'i',
                else => false,
            };
            return .{ .domain = domain, .bits = w, .signed = signed };
        },
        .qualified => |q| return comptimeTypeDomainWidth(q.child.*),
        else => return null,
    }
}

// Apply a domain's overflow rule to a raw i128 arithmetic result.
fn applyDomain(dw: DomainWidth, raw: i128) ComptimeFold {
    const bits = dw.bits;
    if (bits >= 128) return .{ .value = .{ .int = raw } };
    const max: i128 = if (dw.signed) (@as(i128, 1) << @intCast(bits - 1)) - 1 else (@as(i128, 1) << @intCast(bits)) - 1;
    const min: i128 = if (dw.signed) -(@as(i128, 1) << @intCast(bits - 1)) else 0;
    switch (dw.domain) {
        .checked => return if (raw < min or raw > max) .trap else .{ .value = .{ .int = raw } },
        .sat => return .{ .value = .{ .int = if (raw < min) min else if (raw > max) max else raw } },
        .wrap => {
            const mask: u128 = (@as(u128, 1) << @intCast(bits)) - 1;
            const m: u128 = @as(u128, @bitCast(raw)) & mask;
            if (dw.signed and (m >> @intCast(bits - 1)) & 1 == 1) return .{ .value = .{ .int = @bitCast(m | ~mask) } };
            return .{ .value = .{ .int = @intCast(m) } };
        },
    }
}

pub fn comptimeTypeBitWidth(ty: ast.TypeExpr) ?u16 {
    return if (comptimeIntType(ty)) |info| info.bits else null;
}

pub fn parseCharLiteral(literal: []const u8) ?u128 {
    return numeric.parseCharLiteral(literal);
}

// Apply an `as T` integer conversion to a comptime value, mirroring C cast
// semantics: mask to T's width, sign-extending for signed targets. Returns null
// for non-integer values or non-integer (width-unknown) targets, so those casts
// simply stay unfolded rather than producing a wrong constant.
fn comptimeCastValue(value: ComptimeValue, ty: ast.TypeExpr) ?ComptimeValue {
    const scalar_ty = switch (ty.kind) {
        .generic => |g| if ((std.mem.eql(u8, g.base.text, "wrap") or std.mem.eql(u8, g.base.text, "sat")) and g.args.len == 1) g.args[0] else return null,
        .qualified => |q| q.child.*,
        else => ty,
    };
    const tname = switch (scalar_ty.kind) {
        .name => |n| n.text,
        else => return null,
    };
    // Float targets: int→float widening, float→f32 narrowing, float→f64 identity.
    if (std.mem.eql(u8, tname, "f64") or std.mem.eql(u8, tname, "f32")) {
        if (std.mem.eql(u8, tname, "f32")) {
            const f: f32 = switch (value) {
                .int => |n| @floatFromInt(n),
                .uint => |n| @floatFromInt(n),
                .float => |x| x.asF32(),
                else => return null,
            };
            return .{ .float = ComptimeFloat.fromF32(f) };
        }
        const f: f64 = switch (value) {
            .int => |n| @floatFromInt(n),
            .uint => |n| @floatFromInt(n),
            .float => |x| x.asF64(),
            else => return null,
        };
        return .{ .float = ComptimeFloat.fromF64(f) };
    }
    // Integer target: a float source truncates toward zero (C `(int)f` semantics).
    const int_info = comptimeIntType(ty) orelse return null;
    const raw_bits: u128 = switch (value) {
        .int => |n| @bitCast(n),
        .uint => |n| n,
        .float => |x| blk: {
            const t = @trunc(x.asF64());
            if (!std.math.isFinite(t)) return null;
            if (int_info.signed) {
                const lower: f64 = -0x1p127;
                const upper: f64 = 0x1p127;
                if (t < lower or t >= upper) return null;
                break :blk @bitCast(@as(i128, @intFromFloat(t)));
            }
            const upper: f64 = 0x1p128;
            if (t < 0 or t >= upper) return null;
            break :blk @as(u128, @intFromFloat(t));
        },
        else => return null,
    };
    if (!int_info.signed and int_info.bits == 128) return comptimeUnsignedValue(raw_bits);
    return if (comptimeIntFromBits(raw_bits, int_info)) |n| .{ .int = n } else null;
}

// The declared integer width of a comptime expression, resolved through bound
// names and width-preserving operators (so `~(a - 1)` masks to `a`'s width). The
// checker forbids mixed-width operands, so taking the left operand's width (then
// the right's) is sufficient.
fn comptimeExprWidth(scope: *const ComptimeScope, expr: ast.Expr) ?u16 {
    if (comptimeExprType(scope, expr)) |ty| {
        if (comptimeTypeBitWidth(resolveComptimeType(scope, ty))) |bits| return bits;
    }
    return switch (expr.kind) {
        .ident => |id| scope.widths.get(id.text),
        .grouped => |inner| comptimeExprWidth(scope, inner.*),
        .unary => |node| comptimeExprWidth(scope, node.expr.*),
        .binary => |node| comptimeExprWidth(scope, node.left.*) orelse comptimeExprWidth(scope, node.right.*),
        .cast => |node| comptimeTypeBitWidth(node.ty.*),
        else => null,
    };
}

// The arithmetic domain+width an expression evaluates in, resolved through bound names and
// width/domain-preserving operators (mirrors comptimeExprWidth). Drives wrap/sat/checked
// overflow folding.
fn comptimeExprDomainWidth(scope: *const ComptimeScope, expr: ast.Expr) ?DomainWidth {
    if (comptimeExprType(scope, expr)) |ty| {
        if (comptimeTypeDomainWidth(resolveComptimeType(scope, ty))) |dw| return dw;
    }
    return switch (expr.kind) {
        .ident => |id| scope.domains.get(id.text) orelse if (scope.global_domains) |domains| domains.get(id.text) else null,
        .grouped => |inner| comptimeExprDomainWidth(scope, inner.*),
        .unary => |node| comptimeExprDomainWidth(scope, node.expr.*),
        .binary => |node| comptimeExprDomainWidth(scope, node.left.*) orelse comptimeExprDomainWidth(scope, node.right.*),
        .cast => |node| comptimeTypeDomainWidth(node.ty.*),
        else => null,
    };
}

// Apply the domain rule to an arithmetic result, or pass it through untyped when no domain
// is known (preserving the prior untyped-i128 behavior for plain literals).
fn domainArith(dw: ?DomainWidth, raw: i128) ComptimeFold {
    if (dw) |d| return applyDomain(d, raw);
    return .{ .value = .{ .int = raw } };
}

// Fold every `const NAME: T = …` global to a comptime value, populating `out`
// (keyed by name). Earlier const globals are visible to later ones. Globals
// whose initializer is not a foldable comptime constant are simply omitted.
pub const CollectConstGlobalsOptions = struct {
    reflect: ?ReflectFn = null,
    reflect_ctx: ?*anyopaque = null,
    domains: ?*std.StringHashMap(DomainWidth) = null,
};

pub fn collectConstGlobalsFromDeclsWithOptions(
    allocator: std.mem.Allocator,
    decls: []const ast.Decl,
    funcs: *const std.StringHashMap(ComptimeFunction),
    out: *std.StringHashMap(ComptimeValue),
    options: CollectConstGlobalsOptions,
) !void {
    return collectConstGlobalsFromDeclarationsWithOptions(allocator, ComptimeDeclarations.fromDecls(decls), funcs, out, options);
}

pub fn collectConstGlobalsFromDeclItemsWithOptions(
    allocator: std.mem.Allocator,
    decl_items: anytype,
    funcs: *const std.StringHashMap(ComptimeFunction),
    out: *std.StringHashMap(ComptimeValue),
    options: CollectConstGlobalsOptions,
) !void {
    return collectConstGlobalsFromDeclItemsWithScope(allocator, ComptimeDeclarations{}, decl_items, funcs, out, options);
}

pub fn collectConstGlobalsFromDeclarationsWithOptions(
    allocator: std.mem.Allocator,
    declarations: ComptimeDeclarations,
    funcs: *const std.StringHashMap(ComptimeFunction),
    out: *std.StringHashMap(ComptimeValue),
    options: CollectConstGlobalsOptions,
) !void {
    return collectConstGlobalsFromDeclItemsWithScope(allocator, declarations, null, funcs, out, options);
}

fn collectConstGlobalsFromDeclItemsWithScope(
    allocator: std.mem.Allocator,
    declarations: ComptimeDeclarations,
    decl_items: anytype,
    funcs: *const std.StringHashMap(ComptimeFunction),
    out: *std.StringHashMap(ComptimeValue),
    options: CollectConstGlobalsOptions,
) !void {
    // Fold scratch (e.g. array temporaries) lives in an arena that is freed
    // here; values retained in `out` must therefore be deep-cloned.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scope = ComptimeScope.init(arena.allocator());
    defer scope.deinit();
    scope.declarations = declarations;
    scope.funcs = funcs;
    scope.globals = out;
    scope.reflect = options.reflect;
    scope.reflect_ctx = options.reflect_ctx;
    if (declarations.legacy_decls) |decls| {
        for (decls) |decl| {
            const global = switch (decl.kind) {
                .global_decl => |g| g,
                else => continue,
            };
            try collectConstGlobal(allocator, &scope, global, out, options);
        }
        return;
    }
    if (@TypeOf(decl_items) != @TypeOf(null)) {
        for (decl_items) |item| {
            const decl = if (@hasField(@TypeOf(item), "decl")) item.decl else item;
            const global = switch (decl.kind) {
                .global_decl => |g| g,
                else => continue,
            };
            try collectConstGlobal(allocator, &scope, global, out, options);
        }
        return;
    }
    if (declarations.decl_artifacts) |decl_artifacts| {
        for (decl_artifacts) |artifact| switch (artifact) {
            .global => |global| try collectConstGlobalArtifact(allocator, &scope, global, out, options),
            else => {},
        };
        return;
    }
    for (declarations.globals) |global| try collectConstGlobal(allocator, &scope, global, out, options);
}

fn collectConstGlobal(
    allocator: std.mem.Allocator,
    scope: *ComptimeScope,
    global: ast.GlobalDecl,
    out: *std.StringHashMap(ComptimeValue),
    options: CollectConstGlobalsOptions,
) !void {
    if (!global.is_const) return;
    const init_expr = global.init orelse return;
    const folded = if (global.ty) |ty|
        foldComptimeExprExpected(scope, init_expr, ty)
    else
        foldComptimeExpr(scope, init_expr);
    switch (folded) {
        .value => |folded_value| {
            const cloned = try cloneComptimeValue(allocator, folded_value);
            errdefer freeComptimeValue(allocator, cloned);
            try out.put(global.name.text, cloned);
            if (global.ty) |ty| {
                try scope.bindTypeInfo(global.name.text, ty);
                if (options.domains) |domains| {
                    if (comptimeTypeDomainWidth(ty)) |dw| try domains.put(global.name.text, dw);
                }
            }
        },
        else => {},
    }
    if (scope.hasOom()) return error.OutOfMemory;
}

fn collectConstGlobalArtifact(
    allocator: std.mem.Allocator,
    scope: *ComptimeScope,
    global: declaration_artifacts.GlobalArtifact,
    out: *std.StringHashMap(ComptimeValue),
    options: CollectConstGlobalsOptions,
) !void {
    const sig = global.signature;
    const init_facts = global.initializer;
    return collectConstGlobal(allocator, scope, .{
        .name = sig.name,
        .ty = sig.ty,
        .init = init_facts.init,
        .is_const = sig.is_const,
        .exported = sig.exported,
        .is_extern = sig.is_extern,
    }, out, options);
}

fn comptimeIdentValue(scope: *const ComptimeScope, name: []const u8) ?ComptimeValue {
    if (scope.bindings.get(name)) |value| return value;
    if (scope.globals) |g| return g.get(name);
    return null;
}

fn isComptimeTypeParam(param: ast.Param) bool {
    if (!param.is_comptime) return false;
    return switch (param.ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, "type"),
        .qualified => |node| switch (node.child.*.kind) {
            .name => |name| std.mem.eql(u8, name.text, "type"),
            else => false,
        },
        else => false,
    };
}

// Convert the expression syntax accepted for `comptime T: type` arguments into
// a type expression. A bare identifier that names an already-bound type
// parameter resolves to that concrete type, so nested const-fn calls can pass
// type parameters through (`inner(T)`).
pub fn comptimeTypeArg(scope: *const ComptimeScope, arg: ast.Expr) ?ast.TypeExpr {
    return switch (arg.kind) {
        .ident => |ident| scope.type_bindings.get(ident.text) orelse .{ .span = ident.span, .kind = .{ .name = ident } },
        .grouped => |inner| comptimeTypeArg(scope, inner.*),
        else => null,
    };
}

fn substituteComptimeType(scope: *const ComptimeScope, ty: ast.TypeExpr) ?ast.TypeExpr {
    return switch (ty.kind) {
        .name => |name| scope.type_bindings.get(name.text) orelse ty,
        .enum_literal => ty,
        .member => |node| blk: {
            const base = trySubstituteTypePtr(scope, node.base.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .member = .{ .base = base, .field = node.field } } };
        },
        .nullable => |child| blk: {
            const next = trySubstituteTypePtr(scope, child.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .nullable = next } };
        },
        .qualified => |node| blk: {
            const child = trySubstituteTypePtr(scope, node.child.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .qualified = .{ .mutability = node.mutability, .child = child } } };
        },
        .pointer => |node| blk: {
            const child = trySubstituteTypePtr(scope, node.child.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .pointer = .{ .mutability = node.mutability, .child = child } } };
        },
        .raw_many_pointer => |node| blk: {
            const child = trySubstituteTypePtr(scope, node.child.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .raw_many_pointer = .{ .mutability = node.mutability, .child = child } } };
        },
        .slice => |node| blk: {
            const child = trySubstituteTypePtr(scope, node.child.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .slice = .{ .mutability = node.mutability, .child = child } } };
        },
        .array => |node| blk: {
            const child = trySubstituteTypePtr(scope, node.child.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .array = .{ .len = node.len, .child = child } } };
        },
        .generic => |node| blk: {
            const args = scope.alloc(ast.TypeExpr, node.args.len) catch return null;
            for (node.args, 0..) |arg, i| args[i] = substituteComptimeType(scope, arg) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .generic = .{ .base = node.base, .args = args } } };
        },
        .fn_pointer => |node| blk: {
            const params = scope.alloc(ast.TypeExpr, node.params.len) catch return null;
            for (node.params, 0..) |param, i| params[i] = substituteComptimeType(scope, param) orelse return null;
            const ret = trySubstituteTypePtr(scope, node.ret.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .fn_pointer = .{ .params = params, .ret = ret } } };
        },
        .closure_type => |node| blk: {
            const params = scope.alloc(ast.TypeExpr, node.params.len) catch return null;
            for (node.params, 0..) |param, i| params[i] = substituteComptimeType(scope, param) orelse return null;
            const ret = trySubstituteTypePtr(scope, node.ret.*) orelse return null;
            break :blk .{ .span = ty.span, .kind = .{ .closure_type = .{ .params = params, .ret = ret } } };
        },
        // A `*dyn Trait` names a concrete trait, not a comptime type parameter — no
        // substitution applies.
        .dyn_trait => ty,
    };
}

fn trySubstituteTypePtr(scope: *const ComptimeScope, ty: ast.TypeExpr) ?*ast.TypeExpr {
    const substituted = substituteComptimeType(scope, ty) orelse return null;
    return ast.makePtr(scope.bindings.allocator, substituted) catch {
        scope.recordOom();
        return null;
    };
}

fn moduleAliasType(scope: *const ComptimeScope, name: []const u8) ?ast.TypeExpr {
    const declarations = scope.declarations orelse return null;
    if (declarations.legacy_decls) |decls| {
        for (decls) |decl| {
            const alias = switch (decl.kind) {
                .type_alias => |node| node,
                else => continue,
            };
            if (std.mem.eql(u8, alias.name.text, name)) return alias.ty;
        }
        return null;
    }
    if (declarations.decl_artifacts) |decl_artifacts| {
        for (decl_artifacts) |artifact| switch (artifact) {
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .type_alias => |alias| if (std.mem.eql(u8, alias.name.text, name)) return alias.ty,
                else => {},
            },
            else => {},
        };
        return null;
    }
    for (declarations.type_aliases) |alias| {
        if (std.mem.eql(u8, alias.name.text, name)) return alias.ty;
    }
    return null;
}

fn moduleGlobalType(scope: *const ComptimeScope, name: []const u8) ?ast.TypeExpr {
    const declarations = scope.declarations orelse return null;
    if (declarations.legacy_decls) |decls| {
        for (decls) |decl| {
            const global = switch (decl.kind) {
                .global_decl => |node| node,
                else => continue,
            };
            if (std.mem.eql(u8, global.name.text, name)) return global.ty;
        }
        return null;
    }
    if (declarations.decl_artifacts) |decl_artifacts| {
        for (decl_artifacts) |artifact| switch (artifact) {
            .global => |global| if (std.mem.eql(u8, global.signature.name.text, name)) return global.signature.ty,
            else => {},
        };
        return null;
    }
    for (declarations.globals) |global| {
        if (std.mem.eql(u8, global.name.text, name)) return global.ty;
    }
    return null;
}

fn moduleStructDecl(scope: *const ComptimeScope, name: []const u8) ?ast.StructDecl {
    const declarations = scope.declarations orelse return null;
    if (declarations.legacy_decls) |decls| {
        for (decls) |decl| {
            const struct_decl = switch (decl.kind) {
                .struct_decl => |node| node,
                else => continue,
            };
            if (std.mem.eql(u8, struct_decl.name.text, name)) return struct_decl;
        }
        return null;
    }
    if (declarations.decl_artifacts) |decl_artifacts| {
        for (decl_artifacts) |artifact| switch (artifact) {
            .transitional_type_decl => |type_decl| switch (type_decl) {
                .struct_decl => |struct_decl| if (std.mem.eql(u8, struct_decl.name.text, name)) return struct_decl,
                else => {},
            },
            else => {},
        };
        return null;
    }
    for (declarations.structs) |struct_decl| {
        if (std.mem.eql(u8, struct_decl.name.text, name)) return struct_decl;
    }
    return null;
}

fn moduleStructFieldType(scope: *const ComptimeScope, ty: ast.TypeExpr, field_name: []const u8) ?ast.TypeExpr {
    const resolved = resolveComptimeType(scope, ty);
    const struct_name = switch (resolved.kind) {
        .name => |name| name.text,
        else => return null,
    };
    const struct_decl = moduleStructDecl(scope, struct_name) orelse return null;
    for (struct_decl.fields) |field| {
        if (std.mem.eql(u8, field.name.text, field_name)) return resolveComptimeType(scope, field.ty);
    }
    return null;
}

fn resolveComptimeType(scope: *const ComptimeScope, ty: ast.TypeExpr) ast.TypeExpr {
    var current = substituteComptimeType(scope, ty) orelse ty;
    var depth: usize = 0;
    while (depth < 32) : (depth += 1) {
        const name = switch (current.kind) {
            .name => |ident| ident.text,
            .qualified => |node| {
                current = node.child.*;
                continue;
            },
            else => return current,
        };
        const aliased = moduleAliasType(scope, name) orelse return current;
        current = substituteComptimeType(scope, aliased) orelse aliased;
    }
    return current;
}

fn comptimeCallReturnType(scope: *const ComptimeScope, call: anytype) ?ast.TypeExpr {
    const funcs = scope.funcs orelse return null;
    const name = switch (call.callee.*.kind) {
        .ident => |ident| ident.text,
        else => return null,
    };
    const fn_decl = funcs.get(name) orelse return null;
    const return_type = fn_decl.return_type orelse return null;

    var call_scope = ComptimeScope.init(scope.bindings.allocator);
    defer call_scope.deinit();
    call_scope.declarations = scope.declarations;
    call_scope.funcs = scope.funcs;
    for (fn_decl.params, call.args) |param, arg| {
        if (!isComptimeTypeParam(param)) continue;
        const ty = comptimeTypeArg(scope, arg) orelse return null;
        call_scope.bindType(param.name.text, resolveComptimeType(scope, ty)) catch {
            scope.recordOom();
            return null;
        };
    }
    return resolveComptimeType(&call_scope, return_type);
}

fn comptimeIntegerLiteralType(expr: ast.Expr, literal: []const u8) ?ast.TypeExpr {
    const parsed = numeric.parseIntegerLiteralParts(literal) orelse return null;
    const suffix = parsed.suffix orelse return null;
    return .{
        .span = expr.span,
        .kind = .{ .name = .{ .text = suffix.typeName(), .span = expr.span } },
    };
}

fn comptimeExprType(scope: *const ComptimeScope, expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .int_literal => |literal| comptimeIntegerLiteralType(expr, literal),
        .ident => |ident| scope.binding_types.get(ident.text) orelse
            (if (moduleGlobalType(scope, ident.text)) |ty| resolveComptimeType(scope, ty) else null),
        .grouped => |inner| comptimeExprType(scope, inner.*),
        .unary => |node| comptimeExprType(scope, node.expr.*),
        .binary => |node| comptimeExprType(scope, node.left.*) orelse comptimeExprType(scope, node.right.*),
        .cast => |node| resolveComptimeType(scope, node.ty.*),
        .index => |node| blk: {
            const base_ty = resolveComptimeType(scope, comptimeExprType(scope, node.base.*) orelse break :blk null);
            break :blk switch (base_ty.kind) {
                .array => |array| resolveComptimeType(scope, array.child.*),
                else => null,
            };
        },
        .member => |node| blk: {
            const base_ty = comptimeExprType(scope, node.base.*) orelse break :blk null;
            break :blk moduleStructFieldType(scope, base_ty, node.name.text);
        },
        .call => |call| comptimeCallReturnType(scope, call),
        else => null,
    };
}

pub fn bindComptimeExprType(scope: *ComptimeScope, name: []const u8, expr: ast.Expr) std.mem.Allocator.Error!void {
    const ty = comptimeExprType(scope, expr) orelse return;
    try scope.bindTypeInfo(name, ty);
}

fn foldComptimeReflection(scope: *const ComptimeScope, expr: ast.Expr) ComptimeFold {
    const reflect = scope.reflect orelse return .unknown;
    const rewritten = rewriteReflectionExpr(scope, expr) orelse return .unknown;
    return if (reflect(scope.reflect_ctx, rewritten)) |v| .{ .value = .{ .int = v } } else .unknown;
}

fn rewriteReflectionExpr(scope: *const ComptimeScope, expr: ast.Expr) ?ast.Expr {
    const call = switch (expr.kind) {
        .call => |node| node,
        else => return expr,
    };
    if (call.type_args.len > 0) {
        const type_args = scope.alloc(ast.TypeExpr, call.type_args.len) catch return null;
        for (call.type_args, 0..) |ty, i| type_args[i] = substituteComptimeType(scope, ty) orelse return null;
        return .{ .span = expr.span, .kind = .{ .call = .{ .callee = call.callee, .type_args = type_args, .args = call.args } } };
    }
    if (call.args.len > 0) {
        const ty = comptimeTypeArg(scope, call.args[0]) orelse return expr;
        const type_args = scope.alloc(ast.TypeExpr, 1) catch return null;
        type_args[0] = substituteComptimeType(scope, ty) orelse return null;
        return .{ .span = expr.span, .kind = .{ .call = .{ .callee = call.callee, .type_args = type_args, .args = call.args[1..] } } };
    }
    return expr;
}

fn contextualComptimeValue(scope: *const ComptimeScope, value: ComptimeValue, ty: ast.TypeExpr) ComptimeFold {
    const resolved = resolveComptimeType(scope, ty);
    if (comptimeIntType(resolved)) |info| {
        const raw: u128 = switch (value) {
            .int => |n| blk: {
                if (info.signed) {
                    if (info.bits < 128) {
                        const min = -(@as(i128, 1) << @intCast(info.bits - 1));
                        const max = (@as(i128, 1) << @intCast(info.bits - 1)) - 1;
                        if (n < min or n > max) return .trap;
                    }
                } else {
                    if (n < 0) return .trap;
                    if (info.bits < 128 and @as(u128, @intCast(n)) > ((@as(u128, 1) << @intCast(info.bits)) - 1)) return .trap;
                }
                break :blk @bitCast(n);
            },
            .uint => |n| blk: {
                if (info.signed) {
                    const max: u128 = if (info.bits == 128)
                        @intCast(std.math.maxInt(i128))
                    else
                        (@as(u128, 1) << @intCast(info.bits - 1)) - 1;
                    if (n > max) return .trap;
                } else if (info.bits < 128 and n > ((@as(u128, 1) << @intCast(info.bits)) - 1)) {
                    return .trap;
                }
                break :blk n;
            },
            else => return if (comptimeCastValue(value, resolved)) |converted|
                .{ .value = converted }
            else
                .unknown,
        };
        if (!info.signed and info.bits == 128) return .{ .value = comptimeUnsignedValue(raw) };
        const converted = comptimeIntFromBits(raw, info) orelse return .trap;
        return .{ .value = .{ .int = converted } };
    }
    const type_name = switch (resolved.kind) {
        .name => |name| name.text,
        else => return .{ .value = value },
    };
    if (std.mem.eql(u8, type_name, "f32") or std.mem.eql(u8, type_name, "f64")) {
        return if (comptimeCastValue(value, resolved)) |converted|
            .{ .value = converted }
        else
            .unknown;
    }
    return .{ .value = value };
}

fn foldComptimeUnaryExpected(scope: *const ComptimeScope, op: ast.UnaryOp, operand_expr: ast.Expr, expected_ty: ast.TypeExpr) ComptimeFold {
    const resolved = resolveComptimeType(scope, expected_ty);
    const operand = switch (foldComptimeExpr(scope, operand_expr)) {
        .value => |value| value,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    const folded: ComptimeFold = switch (op) {
        .neg => switch (operand) {
            .int => |value| foldComptimeIntegerNeg(comptimeTypeDomainWidth(resolved), value),
            .uint => |value| foldComptimeUnsignedNeg(comptimeTypeDomainWidth(resolved), value),
            .float => blk: {
                const converted = switch (contextualComptimeValue(scope, operand, resolved)) {
                    .value => |value| value,
                    .trap => break :blk .trap,
                    .unknown => break :blk .unknown,
                };
                const float_value = switch (converted) {
                    .float => |value| value,
                    else => break :blk .unknown,
                };
                break :blk .{ .value = .{ .float = .{
                    .bits = float_value.bits ^ if (float_value.width == 32) @as(u64, 1) << 31 else @as(u64, 1) << 63,
                    .width = float_value.width,
                } } };
            },
            else => .unknown,
        },
        .bit_not => blk: {
            const bits = comptimeTypeBitWidth(resolved) orelse break :blk .unknown;
            const mask: u128 = if (bits == 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(bits)) - 1;
            const raw = switch (operand) {
                .int => |value| @as(u128, @bitCast(value)),
                .uint => |value| value,
                else => break :blk .unknown,
            };
            break :blk contextualComptimeValue(scope, comptimeUnsignedValue((~raw) & mask), resolved);
        },
        .logical_not => return foldComptimeUnary(scope, op, operand_expr),
    };
    return switch (folded) {
        .value => |value| contextualComptimeValue(scope, value, resolved),
        .trap => .trap,
        .unknown => .unknown,
    };
}

pub fn foldComptimeExprExpected(scope: *const ComptimeScope, expr: ast.Expr, expected_ty: ast.TypeExpr) ComptimeFold {
    const resolved = resolveComptimeType(scope, expected_ty);
    return switch (expr.kind) {
        .grouped => |inner| foldComptimeExprExpected(scope, inner.*, resolved),
        .binary => |node| foldComptimeBinaryWithExpected(scope, node.op, node.left.*, node.right.*, resolved),
        .unary => |node| foldComptimeUnaryExpected(scope, node.op, node.expr.*, resolved),
        .array_literal => |items| foldComptimeArrayLiteralExpected(scope, items, resolved),
        .struct_literal => |fields| foldComptimeStructLiteralExpected(scope, fields, resolved),
        else => switch (foldComptimeExpr(scope, expr)) {
            .value => |value| contextualComptimeValue(scope, value, resolved),
            .trap => .trap,
            .unknown => .unknown,
        },
    };
}

fn foldComptimeArrayLiteralExpected(scope: *const ComptimeScope, items: []const ast.Expr, expected_ty: ast.TypeExpr) ComptimeFold {
    const array = switch (resolveComptimeType(scope, expected_ty).kind) {
        .array => |node| node,
        else => return foldComptimeArrayLiteral(scope, items),
    };
    const elems = scope.alloc(ComptimeValue, items.len) catch return .unknown;
    for (items, 0..) |item, i| {
        elems[i] = switch (foldComptimeExprExpected(scope, item, array.child.*)) {
            .value => |value| value,
            .trap => return .trap,
            .unknown => return .unknown,
        };
    }
    return .{ .value = .{ .array = elems } };
}

fn foldComptimeStructLiteralExpected(scope: *const ComptimeScope, fields: []const ast.StructLiteralField, expected_ty: ast.TypeExpr) ComptimeFold {
    const resolved = resolveComptimeType(scope, expected_ty);
    const struct_name = switch (resolved.kind) {
        .name => |name| name.text,
        else => return foldComptimeStructLiteral(scope, fields),
    };
    const declaration = moduleStructDecl(scope, struct_name) orelse return foldComptimeStructLiteral(scope, fields);
    const out = scope.alloc(ComptimeStructField, fields.len) catch return .unknown;
    for (fields, 0..) |field, i| {
        var field_ty: ?ast.TypeExpr = null;
        for (declaration.fields) |decl_field| {
            if (std.mem.eql(u8, decl_field.name.text, field.name.text)) {
                field_ty = decl_field.ty;
                break;
            }
        }
        const folded = if (field_ty) |ty|
            foldComptimeExprExpected(scope, field.value, ty)
        else
            foldComptimeExpr(scope, field.value);
        const value = switch (folded) {
            .value => |next| next,
            .trap => return .trap,
            .unknown => return .unknown,
        };
        out[i] = .{ .name = field.name.text, .value = value };
    }
    return .{ .value = .{ .@"struct" = out } };
}

pub fn foldComptimeExpr(scope: *const ComptimeScope, expr: ast.Expr) ComptimeFold {
    return switch (expr.kind) {
        .void_literal => .{ .value = .void },
        // `null` is intentionally NOT folded: MC optionals are pointer-only (`?*T`), which
        // have no comptime value, and folding `null` to a sentinel would mis-bake a
        // `const p: ?*T = null` global. A comptime `?T` is therefore out of scope (§22).
        .int_literal => |literal| .{ .value = comptimeIntegerLiteral(literal) orelse return .unknown },
        .float_literal => |literal| .{ .value = .{ .float = ComptimeFloat.fromF64(parseFloat(literal) catch return .unknown) } },
        .char_literal => |literal| .{ .value = .{ .int = @intCast(parseCharLiteral(literal) orelse return .unknown) } },
        // A bare string literal is NOT folded to a value: it is a `*const u8`/`[]const u8`
        // pointer that must bake as a pointer (not a byte value) in a global initializer.
        // `.len` / indexing on a string literal are handled where they are consumed (below).
        .bool_literal => |value| .{ .value = .{ .boolean = value } },
        .enum_literal => |literal| .{ .value = .{ .tag = literal.text } },
        .ident => |ident| if (comptimeIdentValue(scope, ident.text)) |value| .{ .value = value } else .unknown,
        .grouped => |inner| foldComptimeExpr(scope, inner.*),
        .unary => |node| foldComptimeUnary(scope, node.op, node.expr.*),
        .binary => |node| foldComptimeBinary(scope, node.op, node.left.*, node.right.*),
        .call => |call| blk: {
            // `comptime_error("msg")` (section 22): a reached comptime diagnostic is a trap.
            // The custom message is surfaced by sema for a top-level block statement; a
            // conditionally-reached one still fires here as a generic const-eval trap.
            if (isComptimeErrorName(call.callee.*)) break :blk .trap;
            if (isComptimeBitcastName(call.callee.*)) break :blk foldComptimeBitcast(scope, call);
            // `ok(v)` / `err(e)` construct a comptime Result value.
            if ((isOkErrName(call.callee.*, "ok") or isOkErrName(call.callee.*, "err")) and call.args.len == 1) {
                const payload = switch (foldComptimeExpr(scope, call.args[0])) {
                    .value => |v| v,
                    .trap => break :blk .trap,
                    .unknown => break :blk .unknown,
                };
                const is_ok = isOkErrName(call.callee.*, "ok");
                break :blk if (comptimeResult(scope, is_ok, payload)) |v| .{ .value = v } else .unknown;
            }
            break :blk switch (foldComptimeCall(scope, call)) {
                .unknown => foldComptimeReflection(scope, expr),
                else => |f| f,
            };
        },
        // An explicit integer conversion (`v as T`): fold the operand, then apply T's
        // width as C would (truncate, sign-extend for signed). Non-integer targets
        // (floats, pointers) are not folded. This makes a cast usable in a const
        // global / array-length context instead of being rejected as non-static.
        .cast => |node| switch (foldComptimeExpr(scope, node.value.*)) {
            .value => |v| if (comptimeCastValue(v, node.ty.*)) |cv| .{ .value = cv } else .unknown,
            .trap => .trap,
            .unknown => .unknown,
        },
        .array_literal => |items| foldComptimeArrayLiteral(scope, items),
        .index => |node| foldComptimeIndex(scope, node.base.*, node.index.*),
        .struct_literal => |fields| foldComptimeStructLiteral(scope, fields),
        .member => |node| foldComptimeMember(scope, node.base.*, node.name.text),
        else => .unknown,
    };
}

// Fold a struct literal `.{ .field = value, … }` (section 22). Field storage is
// allocated in the scope's allocator, which lives for the whole fold.
fn foldComptimeStructLiteral(scope: *const ComptimeScope, fields: []const ast.StructLiteralField) ComptimeFold {
    const out = scope.alloc(ComptimeStructField, fields.len) catch return .unknown;
    for (fields, 0..) |field, i| {
        const value = switch (foldComptimeExpr(scope, field.value)) {
            .value => |v| v,
            .trap => return .trap,
            .unknown => return .unknown,
        };
        out[i] = .{ .name = field.name.text, .value = value };
    }
    return .{ .value = .{ .@"struct" = out } };
}

fn isComptimeBitcastName(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "bitcast"),
        .grouped => |inner| isComptimeBitcastName(inner.*),
        else => false,
    };
}

// Optionals and Results at comptime (section 22) are represented as sentinel structs over
// the existing `.@"struct"` value, so no new ComptimeValue arm (and no churn to every
// consumer) is needed. `?T` none is a `{ __null }` struct; `ok(v)`/`err(e)` is a
// `{ __result_tag: "ok"|"err", __result_payload: v }` struct. The double-underscore field
// names are reserved like the desugar temporaries.
fn comptimeResult(scope: *const ComptimeScope, is_ok: bool, payload: ComptimeValue) ?ComptimeValue {
    const fields = scope.alloc(ComptimeStructField, 2) catch return null;
    fields[0] = .{ .name = "__result_tag", .value = .{ .tag = if (is_ok) "ok" else "err" } };
    fields[1] = .{ .name = "__result_payload", .value = payload };
    return .{ .@"struct" = fields };
}

fn comptimeStructFieldVal(v: ComptimeValue, name: []const u8) ?ComptimeValue {
    const fields = switch (v) {
        .@"struct" => |f| f,
        else => return null,
    };
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

fn isComptimeNull(v: ComptimeValue) bool {
    return comptimeStructFieldVal(v, "__null") != null;
}

// The tag ("ok"/"err") of a comptime Result value, or null if `v` is not one.
fn comptimeResultTag(v: ComptimeValue) ?[]const u8 {
    const t = comptimeStructFieldVal(v, "__result_tag") orelse return null;
    return switch (t) {
        .tag => |s| s,
        else => null,
    };
}

fn isOkErrName(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| isOkErrName(inner.*, name),
        else => false,
    };
}

fn isComptimeErrorName(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "comptime_error"),
        .grouped => |inner| isComptimeErrorName(inner.*),
        else => false,
    };
}

// Fold `bitcast<T>(v)` (section 22): a pure bit-reinterpretation between same-width scalar
// types. The target width fixes how the operand is read — f32↔i32/u32 and f64↔i64/u64,
// plus integer↔integer truncation/widening of the low bits. Conservative (`.unknown`) when
// the widths/types are not a known scalar pair.
fn foldComptimeBitcast(scope: *const ComptimeScope, call: anytype) ComptimeFold {
    if (call.type_args.len != 1 or call.args.len != 1) return .unknown;
    const target = call.type_args[0];
    const tname = switch (target.kind) {
        .name => |n| n.text,
        else => return .unknown,
    };
    const operand = switch (foldComptimeExpr(scope, call.args[0])) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    if (std.mem.eql(u8, tname, "f64")) {
        const bits: u64 = switch (operand) {
            .int => |n| @truncate(@as(u128, @bitCast(n))),
            .uint => |n| @truncate(n),
            .float => |f| return .{ .value = .{ .float = ComptimeFloat.fromF64(f.asF64()) } },
            else => return .unknown,
        };
        return .{ .value = .{ .float = .{ .bits = bits, .width = 64 } } };
    }
    if (std.mem.eql(u8, tname, "f32")) {
        switch (operand) {
            .int => |n| {
                const bits: u32 = @truncate(@as(u128, @bitCast(n)));
                return .{ .value = .{ .float = .{ .bits = bits, .width = 32 } } };
            },
            .uint => |n| {
                const bits: u32 = @truncate(n);
                return .{ .value = .{ .float = .{ .bits = bits, .width = 32 } } };
            },
            .float => |f| return .{ .value = .{ .float = ComptimeFloat.fromF32(f.asF32()) } },
            else => return .unknown,
        }
    }
    const int_info = comptimeIntType(target) orelse return .unknown;
    switch (operand) {
        .int => |n| {
            const raw: u128 = @bitCast(n);
            if (!int_info.signed and int_info.bits == 128) return .{ .value = comptimeUnsignedValue(raw) };
            return if (comptimeIntFromBits(raw, int_info)) |v| .{ .value = .{ .int = v } } else .unknown;
        },
        .uint => |n| {
            if (!int_info.signed and int_info.bits == 128) return .{ .value = comptimeUnsignedValue(n) };
            return if (comptimeIntFromBits(n, int_info)) |v| .{ .value = .{ .int = v } } else .unknown;
        },
        .float => |f| {
            if (int_info.bits == 64) {
                const raw: u128 = if (f.width == 64) f.bits else @as(u64, @bitCast(f.asF64()));
                return if (comptimeIntFromBits(raw, int_info)) |v| .{ .value = .{ .int = v } } else .unknown;
            }
            if (int_info.bits == 32) {
                const raw: u128 = if (f.width == 32)
                    @as(u32, @truncate(f.bits))
                else
                    @as(u32, @bitCast(f.asF32()));
                return if (comptimeIntFromBits(raw, int_info)) |v| .{ .value = .{ .int = v } } else .unknown;
            }
            return .unknown;
        },
        else => return .unknown,
    }
}

// Fold `base.field` over a comptime struct (section 22).
fn foldComptimeMember(scope: *const ComptimeScope, base_expr: ast.Expr, field_name: []const u8) ComptimeFold {
    // `"abc".len` — a string literal's length is a comptime constant (the literal is decoded
    // here, where it is consumed as a value rather than a pointer).
    if (std.mem.eql(u8, field_name, "len")) {
        if (base_expr.kind == .string_literal) {
            if (decodeStringLiteral(scope, base_expr.kind.string_literal)) |b| {
                return .{ .value = .{ .int = @intCast(b.len) } };
            }
        }
    }
    const base = switch (foldComptimeExpr(scope, base_expr)) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    // `.len` of a fixed array or a byte string is a comptime constant.
    if (std.mem.eql(u8, field_name, "len")) {
        switch (base) {
            .array => |a| return .{ .value = .{ .int = @intCast(a.len) } },
            .bytes => |b| return .{ .value = .{ .int = @intCast(b.len) } },
            else => {},
        }
    }
    const fields = switch (base) {
        .@"struct" => |f| f,
        else => return .unknown,
    };
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) return .{ .value = field.value };
    }
    return .unknown;
}

// Fold an array literal `.{a, b, …}` (section 22). Element storage is allocated
// in the scope's allocator, which lives for the whole fold.
fn foldComptimeArrayLiteral(scope: *const ComptimeScope, items: []const ast.Expr) ComptimeFold {
    const elems = scope.alloc(ComptimeValue, items.len) catch return .unknown;
    for (items, 0..) |item, i| {
        elems[i] = switch (foldComptimeExpr(scope, item)) {
            .value => |v| v,
            .trap => return .trap,
            .unknown => return .unknown,
        };
    }
    return .{ .value = .{ .array = elems } };
}

// Fold `base[index]` over a comptime array (section 22). An out-of-bounds index
// is a const-eval trap.
fn foldComptimeIndex(scope: *const ComptimeScope, base_expr: ast.Expr, index_expr: ast.Expr) ComptimeFold {
    // `"abc"[i]` — index a string literal's bytes (decoded here, as a value).
    const literal_bytes: ?[]const u8 = if (base_expr.kind == .string_literal)
        decodeStringLiteral(scope, base_expr.kind.string_literal)
    else
        null;
    const base: ?ComptimeValue = if (literal_bytes == null) switch (foldComptimeExpr(scope, base_expr)) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    } else null;
    const index = switch (foldComptimeExpr(scope, index_expr)) {
        .value => |v| switch (v) {
            .int => |n| n,
            .uint => |n| if (n <= std.math.maxInt(i128)) @as(i128, @intCast(n)) else return .trap,
            else => return .unknown,
        },
        .trap => return .trap,
        .unknown => return .unknown,
    };
    if (literal_bytes) |b| {
        if (index < 0 or index >= b.len) return .trap;
        return .{ .value = .{ .int = b[@intCast(index)] } };
    }
    switch (base.?) {
        .array => |arr| {
            if (index < 0 or index >= arr.len) return .trap;
            return .{ .value = arr[@intCast(index)] };
        },
        // Indexing a byte string yields the byte as a comptime integer.
        .bytes => |b| {
            if (index < 0 or index >= b.len) return .trap;
            return .{ .value = .{ .int = b[@intCast(index)] } };
        },
        else => return .unknown,
    }
}

// Evaluate a call to a `const fn` with constant arguments (section 22). Returns
// `.unknown` for non-const callees, unbound arguments, fuel exhaustion, or any
// body construct outside the supported subset — none of which is a provable
// trap. An integer divide-by-zero / invalid shift inside the body propagates as `.trap`.
fn foldComptimeCall(scope: *const ComptimeScope, call: anytype) ComptimeFold {
    const funcs = scope.funcs orelse return .unknown;
    if (scope.call_depth >= comptime_call_fuel) return .unknown;
    const name = switch (call.callee.*.kind) {
        .ident => |ident| ident.text,
        else => return .unknown,
    };
    const fn_decl = funcs.get(name) orelse return .unknown;
    const body = fn_decl.body orelse return .unknown;
    if (call.args.len != fn_decl.params.len) return .unknown;

    // A fresh callee scope shares the const-fn registry and bumps the fuel
    // counter; parameters bind to the folded argument values.
    var callee_scope = ComptimeScope.init(scope.bindings.allocator);
    defer callee_scope.deinit();
    callee_scope.funcs = scope.funcs;
    callee_scope.declarations = scope.declarations;
    callee_scope.globals = scope.globals;
    callee_scope.global_domains = scope.global_domains;
    callee_scope.reflect = scope.reflect;
    callee_scope.reflect_ctx = scope.reflect_ctx;
    callee_scope.call_depth = scope.call_depth + 1;
    for (fn_decl.params, call.args) |param, arg| {
        if (isComptimeTypeParam(param)) {
            const ty = comptimeTypeArg(scope, arg) orelse return .unknown;
            callee_scope.bindType(param.name.text, ty) catch {
                scope.recordOom();
                return .unknown;
            };
            continue;
        }
        const param_ty = resolveComptimeType(&callee_scope, param.ty);
        const value = switch (foldComptimeExprExpected(scope, arg, param_ty)) {
            .value => |v| v,
            .trap => return .trap,
            .unknown => return .unknown,
        };
        callee_scope.bind(param.name.text, value) catch {
            scope.recordOom();
            return .unknown;
        };
        callee_scope.bindTypeInfo(param.name.text, param_ty) catch {
            scope.recordOom();
            return .unknown;
        };
    }
    if (fn_decl.return_type) |return_type| {
        callee_scope.return_type = resolveComptimeType(&callee_scope, return_type);
    }
    const folded = foldComptimeFnBody(&callee_scope, body);
    if (callee_scope.hasOom()) scope.recordOom();
    return folded;
}

// Iteration fuel for a comptime `while` loop (section 22: "loops with a
// compiler fuel limit"). On exhaustion the fold yields `.unknown`.
const comptime_loop_fuel: u64 = 1_000_000;

// Control-flow outcome of evaluating a statement sequence in a const-fn body.
const BodyFlow = union(enum) {
    fallthrough, // reached the end of the sequence normally
    returned: ComptimeFold, // hit a `return` (a value or a const-eval trap)
    broke, // hit `break`
    continued, // hit `continue`
    trap, // a const-eval trap (integer divide-by-zero, invalid shift)
    unknown, // a construct outside the supported subset — bail without diagnosing
};

pub const ComptimeBlockFold = enum { ok, trap, unknown };

pub fn foldComptimeBlock(scope: *ComptimeScope, block: ast.Block) ComptimeBlockFold {
    return switch (foldComptimeStmtSeq(scope, block.items)) {
        .fallthrough => .ok,
        .trap => .trap,
        else => .unknown,
    };
}

// Evaluate a const-fn body: a `return` produces the call's value; falling off
// the end (no return) or any unsupported construct yields `.unknown`.
fn foldComptimeFnBody(scope: *ComptimeScope, block: ast.Block) ComptimeFold {
    return switch (foldComptimeStmtSeq(scope, block.items)) {
        .returned => |fold| fold,
        .trap => .trap,
        else => .unknown,
    };
}

fn foldComptimeStmtSeq(scope: *ComptimeScope, items: []const ast.Stmt) BodyFlow {
    for (items) |stmt| {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                if (local.names.len != 1) return .unknown;
                const init_expr = local.init orelse return .unknown;
                // `var x: T = uninit;` — e.g. the temporary an expression-`switch` desugars to
                // (`var __sw: T = uninit; switch … { __sw = v; } let r = __sw;`). Bind a void
                // placeholder so the following assignment fills it; a read before assignment
                // folds to .unknown, which is conservative.
                if (init_expr.kind == .uninit_literal) {
                    scope.bind(local.names[0].text, .void) catch return .unknown;
                    if (local.ty) |lty| scope.bindTypeInfo(local.names[0].text, lty) catch return .unknown;
                    continue;
                }
                const folded = if (local.ty) |lty|
                    foldComptimeExprExpected(scope, init_expr, lty)
                else
                    foldComptimeExpr(scope, init_expr);
                switch (folded) {
                    .value => |folded_value| {
                        scope.bind(local.names[0].text, folded_value) catch return .unknown;
                        if (local.ty) |lty| scope.bindTypeInfo(local.names[0].text, lty) catch return .unknown;
                        if (local.ty == null) bindComptimeExprType(scope, local.names[0].text, init_expr) catch return .unknown;
                    },
                    .trap => return .trap,
                    .unknown => return .unknown,
                }
            },
            .assignment => |node| {
                switch (foldComptimeAssign(scope, node.target, node.value)) {
                    .ok => {},
                    .trap => return .trap,
                    .unknown => return .unknown,
                }
            },
            .@"return" => |maybe_expr| {
                const expr = maybe_expr orelse return .{ .returned = .{ .value = .void } };
                return .{ .returned = if (scope.return_type) |ty|
                    foldComptimeExprExpected(scope, expr, ty)
                else
                    foldComptimeExpr(scope, expr) };
            },
            .assert => |expr| {
                switch (foldComptimeExpr(scope, expr)) {
                    .value => |value| switch (value) {
                        .boolean => |ok| if (!ok) return .trap,
                        .void, .int, .uint, .float, .tag, .bytes, .array, .@"struct" => return .unknown,
                    },
                    .trap => return .trap,
                    .unknown => return .unknown,
                }
            },
            .expr => |expr| {
                switch (foldComptimeExpr(scope, expr)) {
                    .value => {},
                    .trap => return .trap,
                    .unknown => return .unknown,
                }
            },
            .@"break" => return .broke,
            .@"continue" => return .continued,
            .loop => |loop| {
                const flow = switch (loop.kind) {
                    .@"while" => foldComptimeWhile(scope, loop),
                    .@"for" => foldComptimeForLoop(scope, loop),
                };
                switch (flow) {
                    .fallthrough => {},
                    else => return flow,
                }
            },
            .block, .unsafe_block => |inner| {
                const flow = foldComptimeStmtSeq(scope, inner.items);
                switch (flow) {
                    .fallthrough => {},
                    else => return flow,
                }
            },
            .@"switch" => |sw| {
                const flow = foldComptimeSwitch(scope, sw);
                switch (flow) {
                    .fallthrough => {},
                    else => return flow,
                }
            },
            .if_let => |node| {
                const flow = foldComptimeIfLet(scope, node);
                switch (flow) {
                    .fallthrough => {},
                    else => return flow,
                }
            },
            else => return .unknown,
        }
    }
    return .fallthrough;
}

// Fold an `if let` over a comptime optional (`if let x = opt`) or Result
// (`if let ok(v) = r` / `if let err(e) = r`), section 22 narrowing.
fn foldComptimeIfLet(scope: *ComptimeScope, node: ast.IfLet) BodyFlow {
    const source_ty = if (comptimeExprType(scope, node.value)) |ty| resolveComptimeType(scope, ty) else null;
    const value = switch (foldComptimeExpr(scope, node.value)) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    const take_then = switch (node.pattern.kind) {
        // `if let x = opt`: a non-null optional binds x to its value; `null` takes else.
        .bind => |name| blk: {
            if (isComptimeNull(value)) break :blk false;
            scope.bind(name.text, value) catch return .unknown;
            if (source_ty) |ty| {
                const payload_ty = switch (ty.kind) {
                    .nullable => |child| resolveComptimeType(scope, child.*),
                    else => ty,
                };
                scope.bindTypeInfo(name.text, payload_ty) catch return .unknown;
            }
            break :blk true;
        },
        // `if let ok(v) = r` / `if let err(e) = r`: bind the payload on a tag match.
        .tag_bind => |tb| blk: {
            const tag = comptimeResultTag(value) orelse return .unknown;
            if (!std.mem.eql(u8, tag, tb.tag.text)) break :blk false;
            const payload = comptimeStructFieldVal(value, "__result_payload") orelse return .unknown;
            scope.bind(tb.binding.text, payload) catch return .unknown;
            break :blk true;
        },
        .tag => |t| std.mem.eql(u8, comptimeResultTag(value) orelse return .unknown, t.text),
        else => return .unknown,
    };
    if (take_then) return foldComptimeStmtSeq(scope, node.then_block.items);
    if (node.else_block) |eb| return foldComptimeStmtSeq(scope, eb.items);
    return .fallthrough;
}

// Evaluate a comptime `switch` statement (section 22): fold the subject, take
// the first arm whose literal/tag/wildcard/binding pattern matches, and run
// that arm's body. Payload tag-bind patterns are not modeled at comptime.
fn foldComptimeSwitch(scope: *ComptimeScope, sw: ast.Switch) BodyFlow {
    const subject_ty = comptimeExprType(scope, sw.subject);
    const subject = switch (foldComptimeExpr(scope, sw.subject)) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    for (sw.arms) |arm| {
        for (arm.patterns) |pat| {
            const matched = switch (pat.kind) {
                .wildcard => true,
                .bind => |name| blk: {
                    scope.bind(name.text, subject) catch return .unknown;
                    if (subject_ty) |ty| scope.bindTypeInfo(name.text, ty) catch return .unknown;
                    break :blk true;
                },
                .literal => |lit| switch (foldComptimeExpr(scope, lit)) {
                    .value => |lv| comptimeValueEql(lv, subject),
                    .trap => return .trap,
                    .unknown => return .unknown,
                },
                .tag => |tag| switch (subject) {
                    .tag => |subject_tag| std.mem.eql(u8, subject_tag, tag.text),
                    // A Result subject matched against a bare `.ok`/`.err` tag.
                    else => if (comptimeResultTag(subject)) |rt| std.mem.eql(u8, rt, tag.text) else return .unknown,
                },
                // `.ok(v)` / `.err(e)`: match a comptime Result's tag and bind its payload.
                .tag_bind => |tb| blk: {
                    const rt = comptimeResultTag(subject) orelse return .unknown;
                    if (!std.mem.eql(u8, rt, tb.tag.text)) break :blk false;
                    const payload = comptimeStructFieldVal(subject, "__result_payload") orelse return .unknown;
                    scope.bind(tb.binding.text, payload) catch return .unknown;
                    break :blk true;
                },
            };
            if (matched) {
                return switch (arm.body) {
                    .block => |b| foldComptimeStmtSeq(scope, b.items),
                    // An expression arm as a statement: fold for trap detection,
                    // then fall through.
                    .expr => |e| switch (foldComptimeExpr(scope, e)) {
                        .trap => .trap,
                        else => .fallthrough,
                    },
                };
            }
        }
    }
    return .unknown; // no arm matched (or non-exhaustive at comptime)
}

fn comptimeValueEql(a: ComptimeValue, b: ComptimeValue) bool {
    return switch (a) {
        .void => switch (b) {
            .void => true,
            else => false,
        },
        .int => |av| switch (b) {
            .int => |bv| av == bv,
            .uint => |bv| av >= 0 and @as(u128, @intCast(av)) == bv,
            else => false,
        },
        .uint => |av| switch (b) {
            .int => |bv| bv >= 0 and av == @as(u128, @intCast(bv)),
            .uint => |bv| av == bv,
            else => false,
        },
        .float => |av| switch (b) {
            .float => |bv| av.asF64() == bv.asF64(),
            else => false,
        },
        .bytes => |av| switch (b) {
            .bytes => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .boolean => |av| switch (b) {
            .boolean => |bv| av == bv,
            else => false,
        },
        .tag => |av| switch (b) {
            .tag => |bv| std.mem.eql(u8, av, bv),
            else => false,
        },
        .array => |av| switch (b) {
            .array => |bv| comptimeArrayEql(av, bv),
            else => false,
        },
        .@"struct" => |av| switch (b) {
            .@"struct" => |bv| comptimeStructEql(av, bv),
            else => false,
        },
    };
}

fn comptimeArrayEql(a: []const ComptimeValue, b: []const ComptimeValue) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!comptimeValueEql(av, bv)) return false;
    }
    return true;
}

fn comptimeStructEql(a: []const ComptimeStructField, b: []const ComptimeStructField) bool {
    if (a.len != b.len) return false;
    for (a) |af| {
        var found = false;
        for (b) |bf| {
            if (!std.mem.eql(u8, af.name, bf.name)) continue;
            if (!comptimeValueEql(af.value, bf.value)) return false;
            found = true;
            break;
        }
        if (!found) return false;
    }
    return true;
}

pub const AssignResult = enum { ok, trap, unknown };

// Comptime assignment (section 22): `name = v`, plus mutable-aggregate element
// (`arr[i] = v`, out-of-bounds → trap) and field (`s.field = v`) stores, which
// rebind the whole aggregate with an updated copy (copy-on-write). This is the
// comptime "memory" model — values, no aliasing.
pub fn foldComptimeAssign(scope: *ComptimeScope, target: ast.Expr, value_expr: ast.Expr) AssignResult {
    const folded = if (comptimeExprType(scope, target)) |ty|
        foldComptimeExprExpected(scope, value_expr, ty)
    else
        foldComptimeExpr(scope, value_expr);
    const v = switch (folded) {
        .value => |x| x,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    const root_name = comptimeAssignRootName(target) orelse return .unknown;
    const root = scope.bindings.get(root_name) orelse return .unknown;
    const updated = switch (foldComptimeUpdateTarget(scope, root, target, v)) {
        .value => |next| next,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    scope.bind(root_name, updated) catch return .unknown;
    return .ok;
}

fn comptimeAssignRootName(target: ast.Expr) ?[]const u8 {
    return switch (target.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| comptimeAssignRootName(inner.*),
        .index => |node| comptimeAssignRootName(node.base.*),
        .member => |node| comptimeAssignRootName(node.base.*),
        else => null,
    };
}

const AssignPathSegment = union(enum) {
    member: []const u8,
    index: ast.Expr,
};

fn foldComptimeUpdateTarget(scope: *ComptimeScope, current: ComptimeValue, target: ast.Expr, replacement: ComptimeValue) ComptimeFold {
    var path: std.ArrayList(AssignPathSegment) = .empty;
    defer path.deinit(scope.bindings.allocator);
    appendAssignPath(scope.bindings.allocator, &path, target) catch |err| {
        if (err == error.OutOfMemory) scope.recordOom();
        return .unknown;
    };
    return foldComptimeUpdatePath(scope, current, path.items, replacement);
}

fn appendAssignPath(allocator: std.mem.Allocator, path: *std.ArrayList(AssignPathSegment), target: ast.Expr) !void {
    switch (target.kind) {
        .ident => {},
        .grouped => |inner| try appendAssignPath(allocator, path, inner.*),
        .member => |node| {
            try appendAssignPath(allocator, path, node.base.*);
            try path.append(allocator, .{ .member = node.name.text });
        },
        .index => |node| {
            try appendAssignPath(allocator, path, node.base.*);
            try path.append(allocator, .{ .index = node.index.* });
        },
        else => return error.UnsupportedComptimeAssignmentTarget,
    }
}

fn foldComptimeUpdatePath(scope: *ComptimeScope, current: ComptimeValue, path: []const AssignPathSegment, replacement: ComptimeValue) ComptimeFold {
    if (path.len == 0) return .{ .value = replacement };
    return switch (path[0]) {
        .member => |name| {
            const fields = switch (current) {
                .@"struct" => |items| items,
                else => return .unknown,
            };
            const copy = scope.dupe(ComptimeStructField, fields) catch return .unknown;
            for (copy) |*field| {
                if (!std.mem.eql(u8, field.name, name)) continue;
                field.value = switch (foldComptimeUpdatePath(scope, field.value, path[1..], replacement)) {
                    .value => |value| value,
                    .trap => return .trap,
                    .unknown => return .unknown,
                };
                return .{ .value = .{ .@"struct" = copy } };
            }
            return .unknown;
        },
        .index => |index_expr| {
            const arr = switch (current) {
                .array => |items| items,
                else => return .unknown,
            };
            const idx = switch (foldComptimeExpr(scope, index_expr)) {
                .value => |x| switch (x) {
                    .int => |n| n,
                    .uint => |n| if (n <= std.math.maxInt(i128)) @as(i128, @intCast(n)) else return .trap,
                    else => return .unknown,
                },
                .trap => return .trap,
                .unknown => return .unknown,
            };
            if (idx < 0 or idx >= arr.len) return .trap;
            const copy = scope.dupe(ComptimeValue, arr) catch return .unknown;
            copy[@intCast(idx)] = switch (foldComptimeUpdatePath(scope, arr[@intCast(idx)], path[1..], replacement)) {
                .value => |value| value,
                .trap => return .trap,
                .unknown => return .unknown,
            };
            return .{ .value = .{ .array = copy } };
        },
    };
}

fn foldComptimeWhile(scope: *ComptimeScope, loop: ast.Loop) BodyFlow {
    const cond = loop.iterable orelse return .unknown;
    var fuel: u64 = comptime_loop_fuel;
    while (fuel > 0) : (fuel -= 1) {
        const keep_going = switch (foldComptimeExpr(scope, cond)) {
            .value => |v| switch (v) {
                .boolean => |b| b,
                .void, .int, .uint, .float, .tag, .bytes, .array, .@"struct" => return .unknown,
            },
            .trap => return .trap,
            .unknown => return .unknown,
        };
        if (!keep_going) return .fallthrough;
        switch (foldComptimeStmtSeq(scope, loop.body.items)) {
            .fallthrough, .continued => {},
            .broke => return .fallthrough,
            .returned => |fold| return .{ .returned = fold },
            .trap => return .trap,
            .unknown => return .unknown,
        }
    }
    return .unknown; // fuel exhausted: not provably anything
}

// Evaluate a comptime `for x in <array> { … }` (section 22). The iterable must
// fold to a comptime array; the loop binding takes each element in turn.
fn foldComptimeForLoop(scope: *ComptimeScope, loop: ast.Loop) BodyFlow {
    const iterable_expr = loop.iterable orelse return .unknown;
    const binding = loop.label orelse return .unknown;
    const element_ty: ?ast.TypeExpr = if (comptimeExprType(scope, iterable_expr)) |iterable_ty|
        switch (resolveComptimeType(scope, iterable_ty).kind) {
            .array => |array| resolveComptimeType(scope, array.child.*),
            else => null,
        }
    else
        null;
    const arr = switch (foldComptimeExpr(scope, iterable_expr)) {
        .value => |v| switch (v) {
            .array => |a| a,
            else => return .unknown,
        },
        .trap => return .trap,
        .unknown => return .unknown,
    };
    for (arr) |element| {
        scope.bind(binding.text, element) catch return .unknown;
        if (element_ty) |ty| scope.bindTypeInfo(binding.text, ty) catch return .unknown;
        switch (foldComptimeStmtSeq(scope, loop.body.items)) {
            .fallthrough, .continued => {},
            .broke => return .fallthrough,
            .returned => |fold| return .{ .returned = fold },
            .trap => return .trap,
            .unknown => return .unknown,
        }
    }
    return .fallthrough;
}

fn foldComptimeUnary(scope: *const ComptimeScope, op: ast.UnaryOp, operand_expr: ast.Expr) ComptimeFold {
    const operand = switch (foldComptimeExpr(scope, operand_expr)) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    return switch (op) {
        .neg => switch (operand) {
            .int => |v| foldComptimeIntegerNeg(comptimeExprDomainWidth(scope, operand_expr), v),
            .uint => |v| foldComptimeUnsignedNeg(comptimeExprDomainWidth(scope, operand_expr), v),
            .float => |v| .{ .value = .{ .float = .{
                .bits = v.bits ^ if (v.width == 32) @as(u64, 1) << 31 else @as(u64, 1) << 63,
                .width = v.width,
            } } },
            .void, .boolean, .tag, .bytes, .array, .@"struct" => .unknown,
        },
        .bit_not => switch (operand) {
            // Mask the complement to the operand's declared width. Without a known
            // width we cannot pick the right mask, so fold to .unknown rather than
            // the unmasked (negative) i128 value — that previously made identities
            // like `~zero == 0xFFFFFFFF` (u32) wrongly fail as a comptime trap.
            .int => |v| if (comptimeExprWidth(scope, operand_expr)) |bits| blk: {
                const mask: u128 = if (bits >= 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(bits)) - 1;
                const masked: u128 = (~@as(u128, @bitCast(v))) & mask;
                break :blk .{ .value = comptimeUnsignedValue(masked) };
            } else .unknown,
            .uint => |v| if (comptimeExprWidth(scope, operand_expr)) |bits| blk: {
                const mask: u128 = if (bits >= 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(bits)) - 1;
                break :blk .{ .value = comptimeUnsignedValue((~v) & mask) };
            } else .unknown,
            .void, .float, .boolean, .tag, .bytes, .array, .@"struct" => .unknown,
        },
        .logical_not => switch (operand) {
            .boolean => |v| .{ .value = .{ .boolean = !v } },
            .void, .int, .uint, .float, .tag, .bytes, .array, .@"struct" => .unknown,
        },
    };
}

fn foldComptimeIntegerNeg(dw: ?DomainWidth, value: i128) ComptimeFold {
    const d = dw orelse return .{ .value = .{ .int = std.math.negate(value) catch return .unknown } };
    if (!d.signed) return foldComptimeUnsignedNeg(d, @bitCast(value));
    const min: i128 = if (d.bits == 128) std.math.minInt(i128) else -(@as(i128, 1) << @intCast(d.bits - 1));
    const max: i128 = if (d.bits == 128) std.math.maxInt(i128) else (@as(i128, 1) << @intCast(d.bits - 1)) - 1;
    if (value == min) return switch (d.domain) {
        .checked => .trap,
        .wrap => .{ .value = .{ .int = min } },
        .sat => .{ .value = .{ .int = max } },
    };
    return .{ .value = .{ .int = -value } };
}

fn foldComptimeUnsignedNeg(dw: ?DomainWidth, value: u128) ComptimeFold {
    const d = dw orelse {
        if (value == (@as(u128, 1) << 127)) return .{ .value = .{ .int = std.math.minInt(i128) } };
        if (value <= std.math.maxInt(i128)) return .{ .value = .{ .int = -@as(i128, @intCast(value)) } };
        return .unknown;
    };
    if (d.signed) {
        const limit: u128 = @as(u128, 1) << @intCast(d.bits - 1);
        if (value > limit) return switch (d.domain) {
            .checked => .trap,
            .wrap => blk: {
                const mask: u128 = if (d.bits == 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(d.bits)) - 1;
                const raw = (0 -% value) & mask;
                break :blk if (comptimeIntFromBits(raw, .{ .bits = d.bits, .signed = true })) |n|
                    .{ .value = .{ .int = n } }
                else
                    .unknown;
            },
            .sat => .{ .value = .{ .int = if (d.bits == 128) std.math.minInt(i128) else -(@as(i128, 1) << @intCast(d.bits - 1)) } },
        };
        if (value == limit) {
            const minimum = if (d.bits == 128) std.math.minInt(i128) else -(@as(i128, 1) << @intCast(d.bits - 1));
            return .{ .value = .{ .int = minimum } };
        }
        return .{ .value = .{ .int = -@as(i128, @intCast(value)) } };
    }
    if (d.domain == .checked) return if (value == 0) .{ .value = .{ .int = 0 } } else .trap;
    if (d.domain == .sat) return .{ .value = .{ .int = 0 } };
    const mask: u128 = if (d.bits == 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(d.bits)) - 1;
    return .{ .value = comptimeUnsignedValue((0 -% value) & mask) };
}

fn foldWideUnsignedBinary(op: ast.BinaryOp, left: ComptimeValue, right: ComptimeValue, dw: ?DomainWidth) ComptimeFold {
    const l = comptimeNonnegative(left) orelse return .unknown;
    const r = comptimeNonnegative(right) orelse return .unknown;
    const domain = if (dw) |d| d.domain else ComptimeDomain.checked;
    const bits: u16 = if (dw) |d| d.bits else 128;
    const mask: u128 = if (bits == 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(bits)) - 1;
    return switch (op) {
        .lt => .{ .value = .{ .boolean = l < r } },
        .le => .{ .value = .{ .boolean = l <= r } },
        .gt => .{ .value = .{ .boolean = l > r } },
        .ge => .{ .value = .{ .boolean = l >= r } },
        .add => blk: {
            const result = @addWithOverflow(l, r);
            const overflow = result[1] != 0 or result[0] > mask;
            break :blk if (!overflow)
                .{ .value = comptimeUnsignedValue(result[0] & mask) }
            else switch (domain) {
                .checked => .trap,
                .wrap => .{ .value = comptimeUnsignedValue(result[0] & mask) },
                .sat => .{ .value = comptimeUnsignedValue(mask) },
            };
        },
        .sub => if (l >= r)
            .{ .value = comptimeUnsignedValue((l - r) & mask) }
        else switch (domain) {
            .checked => .trap,
            .wrap => .{ .value = comptimeUnsignedValue((l -% r) & mask) },
            .sat => .{ .value = .{ .int = 0 } },
        },
        .mul => blk: {
            const result = @mulWithOverflow(l, r);
            const overflow = result[1] != 0 or result[0] > mask;
            break :blk if (!overflow)
                .{ .value = comptimeUnsignedValue(result[0] & mask) }
            else switch (domain) {
                .checked => .trap,
                .wrap => .{ .value = comptimeUnsignedValue(result[0] & mask) },
                .sat => .{ .value = comptimeUnsignedValue(mask) },
            };
        },
        .div => if (r == 0) .trap else .{ .value = comptimeUnsignedValue(l / r) },
        .mod => if (r == 0) .trap else .{ .value = comptimeUnsignedValue(l % r) },
        .bit_and => .{ .value = comptimeUnsignedValue(l & r) },
        .bit_or => .{ .value = comptimeUnsignedValue(l | r) },
        .bit_xor => .{ .value = comptimeUnsignedValue(l ^ r) },
        .shl => if (r >= bits) .trap else blk: {
            const shifted = @shlWithOverflow(l, @as(u7, @intCast(r)));
            const overflow = shifted[1] != 0 or (shifted[0] & ~mask) != 0;
            break :blk if (!overflow)
                .{ .value = comptimeUnsignedValue(shifted[0] & mask) }
            else switch (domain) {
                .checked => .trap,
                .wrap => .{ .value = comptimeUnsignedValue(shifted[0] & mask) },
                .sat => .{ .value = comptimeUnsignedValue(mask) },
            };
        },
        .shr => if (r >= bits) .trap else .{ .value = comptimeUnsignedValue(l >> @as(u7, @intCast(r))) },
        .eq => .{ .value = .{ .boolean = l == r } },
        .ne => .{ .value = .{ .boolean = l != r } },
        .logical_and, .logical_or => unreachable,
    };
}

fn signedOverflowResult(dw: ?DomainWidth, wrapped: i128, overflowed: bool, saturate_to_max: bool) ComptimeFold {
    if (!overflowed) return domainArith(dw, wrapped);
    const d = dw orelse return .unknown;
    return switch (d.domain) {
        .checked => .trap,
        .wrap => .{ .value = .{ .int = wrapped } },
        .sat => .{ .value = .{ .int = if (saturate_to_max) std.math.maxInt(i128) else std.math.minInt(i128) } },
    };
}

fn foldSignedShift(op: ast.BinaryOp, value: i128, count: i128, dw: ?DomainWidth) ComptimeFold {
    const bits: u16 = if (dw) |d| d.bits else 128;
    if (count < 0 or count >= bits) return .trap;
    const amount: u7 = @intCast(count);
    if (op == .shr) {
        const shifted = value >> amount;
        return domainArith(dw, shifted);
    }
    const d = dw orelse {
        if (value >= 0) {
            const shifted = @shlWithOverflow(@as(u128, @intCast(value)), amount);
            return if (shifted[1] != 0) .unknown else .{ .value = comptimeUnsignedValue(shifted[0]) };
        }
        const shifted = @shlWithOverflow(value, amount);
        return if (shifted[1] != 0) .unknown else .{ .value = .{ .int = shifted[0] } };
    };
    if (d.domain == .wrap) {
        const mask: u128 = if (bits == 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(bits)) - 1;
        const raw = (@as(u128, @bitCast(value)) << amount) & mask;
        if (d.signed) return if (comptimeIntFromBits(raw, .{ .bits = bits, .signed = true })) |n|
            .{ .value = .{ .int = n } }
        else
            .unknown;
        return .{ .value = comptimeUnsignedValue(raw) };
    }
    if (value < 0) return if (d.domain == .sat)
        .{ .value = .{ .int = if (d.signed) -(@as(i128, 1) << @intCast(bits - 1)) else 0 } }
    else
        .trap;
    const shifted = @shlWithOverflow(@as(u128, @intCast(value)), amount);
    const max: u128 = if (d.signed)
        (@as(u128, 1) << @intCast(bits - 1)) - 1
    else if (bits == 128)
        ~@as(u128, 0)
    else
        (@as(u128, 1) << @intCast(bits)) - 1;
    if (shifted[1] != 0 or shifted[0] > max) return switch (d.domain) {
        .checked => .trap,
        .sat => .{ .value = comptimeUnsignedValue(max) },
        .wrap => unreachable,
    };
    return .{ .value = comptimeUnsignedValue(shifted[0]) };
}

fn foldComptimeBinary(scope: *const ComptimeScope, op: ast.BinaryOp, left_expr: ast.Expr, right_expr: ast.Expr) ComptimeFold {
    return foldComptimeBinaryWithExpected(scope, op, left_expr, right_expr, null);
}

fn foldComptimeBinaryWithExpected(scope: *const ComptimeScope, op: ast.BinaryOp, left_expr: ast.Expr, right_expr: ast.Expr, expected_ty: ?ast.TypeExpr) ComptimeFold {
    // Logical operators short-circuit so a known-determining operand folds even
    // when the other side is not a constant.
    if (op == .logical_and or op == .logical_or) {
        const left = foldComptimeExpr(scope, left_expr);
        switch (left) {
            .trap => return .trap,
            .value => |v| switch (v) {
                .boolean => |b| {
                    if (op == .logical_and and !b) return .{ .value = .{ .boolean = false } };
                    if (op == .logical_or and b) return .{ .value = .{ .boolean = true } };
                },
                .void, .int, .uint, .float, .tag, .bytes, .array, .@"struct" => return .unknown,
            },
            .unknown => return .unknown,
        }
        return switch (foldComptimeExpr(scope, right_expr)) {
            .value => |v| switch (v) {
                .boolean => |b| .{ .value = .{ .boolean = b } },
                .void, .int, .uint, .float, .tag, .bytes, .array, .@"struct" => .unknown,
            },
            .trap => .trap,
            .unknown => .unknown,
        };
    }

    const context_applies = switch (op) {
        .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .shl, .shr => expected_ty != null,
        else => false,
    };
    const left_fold = if (context_applies)
        foldComptimeExprExpected(scope, left_expr, expected_ty.?)
    else
        foldComptimeExpr(scope, left_expr);
    const right_fold = if (context_applies)
        foldComptimeExprExpected(scope, right_expr, expected_ty.?)
    else
        foldComptimeExpr(scope, right_expr);
    const left = switch (left_fold) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    const right = switch (right_fold) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };

    // Equality is defined for comptime values, including aggregate values from
    // section 22. Ordering and arithmetic remain integer-only.
    if (op == .eq or op == .ne) {
        const equal = switch (left) {
            .int => |l| switch (right) {
                .int => |r| l == r,
                .uint => |r| l >= 0 and @as(u128, @intCast(l)) == r,
                else => return .unknown,
            },
            .uint => |l| switch (right) {
                .int => |r| r >= 0 and l == @as(u128, @intCast(r)),
                .uint => |r| l == r,
                else => return .unknown,
            },
            .float => |l| switch (right) {
                .float => |r| l.asF64() == r.asF64(),
                else => return .unknown,
            },
            .boolean => |l| switch (right) {
                .boolean => |r| l == r,
                else => return .unknown,
            },
            .void => switch (right) {
                .void => true,
                else => return .unknown,
            },
            .tag => |l| switch (right) {
                .tag => |r| std.mem.eql(u8, l, r),
                else => return .unknown,
            },
            .bytes => |l| switch (right) {
                .bytes => |r| std.mem.eql(u8, l, r),
                else => return .unknown,
            },
            .array => switch (right) {
                .array => comptimeValueEql(left, right),
                else => return .unknown,
            },
            .@"struct" => switch (right) {
                .@"struct" => comptimeValueEql(left, right),
                else => return .unknown,
            },
        };
        return .{ .value = .{ .boolean = if (op == .eq) equal else !equal } };
    }

    // Floating-point ordering/arithmetic. f32 rounds after every operation;
    // division by zero follows IEEE and produces infinity/NaN rather than a
    // language trap, matching runtime lowering.
    if (left == .float or right == .float) {
        const lf = switch (left) {
            .float => |v| v,
            else => return .unknown,
        };
        const rf = switch (right) {
            .float => |v| v,
            else => return .unknown,
        };
        const as_f32 = lf.width == 32 or rf.width == 32;
        return switch (op) {
            .lt => .{ .value = .{ .boolean = lf.asF64() < rf.asF64() } },
            .le => .{ .value = .{ .boolean = lf.asF64() <= rf.asF64() } },
            .gt => .{ .value = .{ .boolean = lf.asF64() > rf.asF64() } },
            .ge => .{ .value = .{ .boolean = lf.asF64() >= rf.asF64() } },
            .add => .{ .value = .{ .float = if (as_f32)
                ComptimeFloat.fromF32(lf.asF32() + rf.asF32())
            else
                ComptimeFloat.fromF64(lf.asF64() + rf.asF64()) } },
            .sub => .{ .value = .{ .float = if (as_f32)
                ComptimeFloat.fromF32(lf.asF32() - rf.asF32())
            else
                ComptimeFloat.fromF64(lf.asF64() - rf.asF64()) } },
            .mul => .{ .value = .{ .float = if (as_f32)
                ComptimeFloat.fromF32(lf.asF32() * rf.asF32())
            else
                ComptimeFloat.fromF64(lf.asF64() * rf.asF64()) } },
            .div => .{ .value = .{ .float = if (as_f32)
                ComptimeFloat.fromF32(lf.asF32() / rf.asF32())
            else
                ComptimeFloat.fromF64(lf.asF64() / rf.asF64()) } },
            else => .unknown, // mod/bitwise/shift not defined on floats
        };
    }

    const dw = if (expected_ty) |ty|
        comptimeTypeDomainWidth(resolveComptimeType(scope, ty)) orelse
            comptimeExprDomainWidth(scope, left_expr) orelse
            comptimeExprDomainWidth(scope, right_expr)
    else
        comptimeExprDomainWidth(scope, left_expr) orelse comptimeExprDomainWidth(scope, right_expr);
    if (left == .uint or right == .uint or (dw != null and !dw.?.signed))
        return foldWideUnsignedBinary(op, left, right, dw);

    const l = switch (left) {
        .int => |v| v,
        else => return .unknown,
    };
    const r = switch (right) {
        .int => |v| v,
        else => return .unknown,
    };

    // The arithmetic domain (checked/wrap/sat) + width the operation evaluates in, when the
    // operands' declared types make it known. `add`/`sub`/`mul`/`div`/`mod` then trap on a
    // checked overflow, mask for `wrap<uN>`, or clamp for `sat<uN>` — as the runtime would.
    // Plain literals (no domain) keep the prior untyped-i128 behavior.
    return switch (op) {
        .lt => .{ .value = .{ .boolean = l < r } },
        .le => .{ .value = .{ .boolean = l <= r } },
        .gt => .{ .value = .{ .boolean = l > r } },
        .ge => .{ .value = .{ .boolean = l >= r } },
        // i128 is only the evaluation domain — overflowing it (as opposed to a
        // declared target type) is outside the scalar model, so fold to unknown
        // rather than risk a false trap or a compiler panic.
        .add => if (dw != null and dw.?.bits == 128) blk: {
            const result = @addWithOverflow(l, r);
            break :blk signedOverflowResult(dw, result[0], result[1] != 0, l >= 0 and r >= 0);
        } else domainArith(dw, std.math.add(i128, l, r) catch return .unknown),
        .sub => if (dw != null and dw.?.bits == 128) blk: {
            const result = @subWithOverflow(l, r);
            break :blk signedOverflowResult(dw, result[0], result[1] != 0, l >= 0 and r < 0);
        } else domainArith(dw, std.math.sub(i128, l, r) catch return .unknown),
        .mul => if (dw != null and dw.?.bits == 128) blk: {
            const result = @mulWithOverflow(l, r);
            break :blk signedOverflowResult(dw, result[0], result[1] != 0, (l < 0) == (r < 0));
        } else domainArith(dw, std.math.mul(i128, l, r) catch return .unknown),
        .div => if (r == 0) .trap else if (dw != null and dw.?.bits == 128 and l == std.math.minInt(i128) and r == -1)
            switch (dw.?.domain) {
                .checked => .trap,
                .wrap => .{ .value = .{ .int = std.math.minInt(i128) } },
                .sat => .{ .value = .{ .int = std.math.maxInt(i128) } },
            }
        else
            domainArith(dw, std.math.divTrunc(i128, l, r) catch return .unknown),
        .mod => if (r == 0)
            .trap
        else if (l == std.math.minInt(i128) and r == -1)
            if (dw) |d| switch (d.domain) {
                .checked => .trap,
                .wrap, .sat => .{ .value = .{ .int = 0 } },
            } else .unknown
        else
            domainArith(dw, @rem(l, r)),
        .bit_and => .{ .value = .{ .int = l & r } },
        .bit_or => .{ .value = .{ .int = l | r } },
        .bit_xor => .{ .value = .{ .int = l ^ r } },
        .shl, .shr => foldSignedShift(op, l, r, dw),
        .eq, .ne, .logical_and, .logical_or => unreachable,
    };
}

fn intInfo(ty: ast.TypeExpr) EvalError!IntInfo {
    const name = switch (ty.kind) {
        .name => |ident| ident.text,
        else => return error.UnsupportedRunTrapFixture,
    };
    if (name.len < 2) return error.UnsupportedRunTrapFixture;
    const signed = switch (name[0]) {
        'i' => true,
        'u' => false,
        else => return error.UnsupportedRunTrapFixture,
    };
    const bits = std.fmt.parseInt(u8, name[1..], 10) catch return error.UnsupportedRunTrapFixture;
    // Only the four supported checked-integer widths have well-defined i128 bounds.
    // A wider (u128/i128) or zero width would overflow/underflow IntInfo.min/max
    // (`1 << bits`), panicking the interpreter; report it as an unsupported fixture.
    switch (bits) {
        8, 16, 32, 64 => {},
        else => return error.UnsupportedRunTrapFixture,
    }
    return .{ .signed = signed, .bits = bits };
}

fn parseInt(raw: []const u8) EvalError!i128 {
    const magnitude = numeric.parseIntegerLiteral(raw) orelse return error.InvalidIntegerLiteral;
    return std.math.cast(i128, magnitude) orelse error.InvalidIntegerLiteral;
}

fn parseFloat(raw: []const u8) EvalError!f64 {
    // IEEE special-constant lexemes (`inf`/`nan`) are float literals; parse them directly
    // so the generic `f`-suffix stripping below does not mangle "inf" into "in".
    if (std.mem.eql(u8, raw, "inf")) return std.math.inf(f64);
    if (std.mem.eql(u8, raw, "nan")) return std.math.nan(f64);
    var cleaned: [128]u8 = undefined;
    if (raw.len > cleaned.len) return error.InvalidIntegerLiteral;
    var len: usize = 0;
    for (raw) |ch| {
        // `_` digit separators and a trailing `f` float suffix are not part of the value.
        if (ch == '_' or ch == 'f' or ch == 'F') continue;
        cleaned[len] = ch;
        len += 1;
    }
    return std.fmt.parseFloat(f64, cleaned[0..len]) catch error.InvalidIntegerLiteral;
}

// Decode a string-literal lexeme (with surrounding quotes and escape sequences) into its
// raw bytes, allocated in `scope`. Returns null on a malformed/unsupported escape.
fn decodeStringLiteral(scope: *const ComptimeScope, literal: []const u8) ?[]const u8 {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return null;
    const out = scope.alloc(u8, literal.len - 2) catch return null;
    return string_literal.decodeInto(out, literal) catch null;
}

fn parseRunTrapArgs(allocator: std.mem.Allocator, raw_args: []const u8) EvalError![]i128 {
    var args: std.ArrayList(i128) = .empty;
    errdefer args.deinit(allocator);

    const trimmed = std.mem.trim(u8, raw_args, " \t");
    if (trimmed.len == 0) return args.toOwnedSlice(allocator);

    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t");
        if (part.len == 0) return error.InvalidRunTrapExpectation;
        try args.append(allocator, try parseRunTrapInt(part));
    }

    return args.toOwnedSlice(allocator);
}

fn parseRunTrapInt(raw: []const u8) EvalError!i128 {
    var cleaned: [128]u8 = undefined;
    if (raw.len > cleaned.len) return error.InvalidRunTrapExpectation;
    var len: usize = 0;
    for (raw) |ch| {
        if (ch == '_') continue;
        cleaned[len] = ch;
        len += 1;
    }
    return std.fmt.parseInt(i128, cleaned[0..len], 0) catch error.InvalidRunTrapExpectation;
}

fn readIdentLike(input: []const u8) []const u8 {
    var end: usize = 0;
    while (end < input.len) : (end += 1) {
        const ch = input[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) break;
    }
    return input[0..end];
}

const test_zero_span = ast.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

fn testIdentExpr(allocator: std.mem.Allocator, name: []const u8) !*ast.Expr {
    return ast.makePtr(allocator, ast.Expr{ .span = test_zero_span, .kind = .{ .ident = .{ .text = name, .span = test_zero_span } } });
}

fn testIntExpr(allocator: std.mem.Allocator, text: []const u8) !*ast.Expr {
    return ast.makePtr(allocator, ast.Expr{ .span = test_zero_span, .kind = .{ .int_literal = text } });
}

fn testNamedType(name: []const u8) ast.TypeExpr {
    return .{ .span = test_zero_span, .kind = .{ .name = .{ .text = name, .span = test_zero_span } } };
}

fn testBitcastExpr(allocator: std.mem.Allocator, target_name: []const u8, arg: ast.Expr) !ast.Expr {
    return .{ .span = test_zero_span, .kind = .{ .call = .{
        .callee = try testIdentExpr(allocator, "bitcast"),
        .type_args = try allocator.dupe(ast.TypeExpr, &.{testNamedType(target_name)}),
        .args = try allocator.dupe(ast.Expr, &.{arg}),
    } } };
}

test "foldComptimeBitcast handles 128-bit signed and unrepresentable unsigned values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var scope = ComptimeScope.init(allocator);
    defer scope.deinit();

    const minus_one = ast.Expr{ .span = test_zero_span, .kind = .{ .unary = .{
        .op = .neg,
        .expr = try testIntExpr(allocator, "1"),
    } } };

    const signed_128 = try testBitcastExpr(allocator, "i128", minus_one);
    try std.testing.expectEqual(@as(i128, -1), foldComptimeExpr(&scope, signed_128).value.int);

    const unsigned_128 = try testBitcastExpr(allocator, "u128", minus_one);
    try std.testing.expectEqual(
        std.math.maxInt(u128),
        foldComptimeExpr(&scope, unsigned_128).value.uint,
    );

    const min_i128_bits = ast.Expr{ .span = test_zero_span, .kind = .{ .int_literal = "-170141183460469231731687303715884105728" } };
    const high_unsigned = try testBitcastExpr(allocator, "u128", min_i128_bits);
    try std.testing.expectEqual(@as(std.meta.Tag(ComptimeFold), .unknown), std.meta.activeTag(foldComptimeExpr(&scope, high_unsigned)));
}
