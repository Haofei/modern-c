const std = @import("std");

const ast = @import("ast.zig");

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

pub fn runTrapExpectation(
    allocator: std.mem.Allocator,
    module: ast.Module,
    function_name: []const u8,
    args: []const i128,
) EvalError!?Trap {
    for (module.decls) |decl| {
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
            .unary => |node| try self.evalUnary(node, expected_ty),
            .binary => |node| try self.evalBinary(node, expected_ty),
            else => error.UnsupportedRunTrapFixture,
        };
    }

    fn evalUnary(self: *Evaluator, node: anytype, expected_ty: IntInfo) EvalError!EvalResult {
        if (node.op != .neg) return error.UnsupportedRunTrapFixture;
        if (node.expr.kind == .int_literal) {
            const magnitude = try parseInt(node.expr.kind.int_literal);
            const value = -magnitude;
            if (!expected_ty.contains(value)) return .{ .trap = .IntegerOverflow };
            return .{ .value = .{ .value = value, .ty = expected_ty } };
        }
        const inner = switch (try self.evalExpr(node.expr.*, expected_ty)) {
            .trap => |trap| return .{ .trap = trap },
            .value => |binding| binding,
        };
        const ty = inner.ty;
        if (!ty.signed or inner.value == ty.min()) return .{ .trap = .IntegerOverflow };
        return .{ .value = .{ .value = -inner.value, .ty = ty } };
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
            .add => left.value + right.value,
            .sub => left.value - right.value,
            .mul => left.value * right.value,
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
                break :blk left.value * (@as(i128, 1) << @intCast(right.value));
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

pub const ComptimeValue = union(enum) {
    int: i128,
    boolean: bool,
    tag: []const u8,
    // A fixed comptime array value (section 22). Element storage is owned by the
    // evaluation scope's allocator and lives for the duration of the fold.
    array: []const ComptimeValue,
    // A comptime struct value: field name → value, scope-allocated like arrays.
    @"struct": []const ComptimeStructField,
};

pub fn cloneComptimeValue(allocator: std.mem.Allocator, value: ComptimeValue) !ComptimeValue {
    return switch (value) {
        .int, .boolean, .tag => value,
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
        .int, .boolean, .tag => {},
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
    trap, // a provable trap during const eval (divide-by-zero, invalid shift)
    unknown, // not a compile-time constant; sema must not diagnose it
};

// Fuel limit on nested const-fn evaluation, so a recursive `const fn` cannot
// hang the compiler — it simply folds to `.unknown` past the limit.
const comptime_call_fuel: u32 = 256;

// Resolves a comptime reflection call (`sizeof`/`alignof`/…) to an integer, or
// null if it is not a reflection call this resolver can fold.
pub const ReflectFn = *const fn (ctx: ?*anyopaque, call: ast.Expr) ?i128;

pub const ComptimeScope = struct {
    bindings: std.StringHashMap(ComptimeValue),
    // Registry of `const fn` declarations callable at comptime (section 22).
    funcs: ?*const std.StringHashMap(ast.FnDecl) = null,
    // Named compile-time constants (`const NAME: T = …` globals), resolved when
    // an identifier is not a local binding.
    globals: ?*const std.StringHashMap(ComptimeValue) = null,
    // Optional reflection resolver (section 22): folds `sizeof(T)`/`alignof(T)`/
    // `field_offset(T, .f)` calls to an integer using the front end's layout
    // model. Returns null for non-reflection calls or types it cannot lay out.
    reflect: ?ReflectFn = null,
    reflect_ctx: ?*anyopaque = null,
    // Nested const-fn call depth, bounded by comptime_call_fuel.
    call_depth: u32 = 0,
    // Declared integer bit-width of bound names (params, comptime locals), so a
    // width-dependent fold like `~x` can mask to the operand's type. The comptime
    // model otherwise works in untyped i128, where `~0` is -1 rather than the
    // width-bounded `0xFFFFFFFF` a u32 would produce at runtime.
    widths: std.StringHashMap(u16),

    pub fn init(allocator: std.mem.Allocator) ComptimeScope {
        return .{
            .bindings = std.StringHashMap(ComptimeValue).init(allocator),
            .widths = std.StringHashMap(u16).init(allocator),
        };
    }

    pub fn deinit(self: *ComptimeScope) void {
        self.bindings.deinit();
        self.widths.deinit();
    }

    pub fn bind(self: *ComptimeScope, name: []const u8, value: ComptimeValue) !void {
        try self.bindings.put(name, value);
    }

    pub fn bindWidth(self: *ComptimeScope, name: []const u8, bits: u16) void {
        self.widths.put(name, bits) catch {};
    }
};

// The declared bit-width of an integer type expression, or null for non-integer
// (or width-unknown) types. usize/isize follow the 64-bit C ABI this backend targets.
pub fn comptimeTypeBitWidth(ty: ast.TypeExpr) ?u16 {
    const name = switch (ty.kind) {
        .name => |n| n.text,
        else => return null,
    };
    if (name.len < 2) return null;
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return 64;
    if (name[0] != 'u' and name[0] != 'i') return null;
    const bits = std.fmt.parseInt(u16, name[1..], 10) catch return null;
    return switch (bits) {
        8, 16, 32, 64 => bits,
        else => null,
    };
}

// Apply an `as T` integer conversion to a comptime value, mirroring C cast
// semantics: mask to T's width, sign-extending for signed targets. Returns null
// for non-integer values or non-integer (width-unknown) targets, so those casts
// simply stay unfolded rather than producing a wrong constant.
fn comptimeCastValue(value: ComptimeValue, ty: ast.TypeExpr) ?ComptimeValue {
    const v = switch (value) {
        .int => |n| n,
        else => return null,
    };
    const bits = comptimeTypeBitWidth(ty) orelse return null;
    if (bits >= 128) return .{ .int = v };
    const mask: u128 = (@as(u128, 1) << @intCast(bits)) - 1;
    const raw: u128 = @as(u128, @bitCast(v)) & mask;
    const signed = switch (ty.kind) {
        .name => |n| n.text.len > 0 and (n.text[0] == 'i'),
        else => false,
    };
    if (signed and (raw >> @intCast(bits - 1)) & 1 == 1) {
        return .{ .int = @bitCast(raw | ~mask) };
    }
    return .{ .int = @intCast(raw) };
}

// The declared integer width of a comptime expression, resolved through bound
// names and width-preserving operators (so `~(a - 1)` masks to `a`'s width). The
// checker forbids mixed-width operands, so taking the left operand's width (then
// the right's) is sufficient.
fn comptimeExprWidth(scope: *const ComptimeScope, expr: ast.Expr) ?u16 {
    return switch (expr.kind) {
        .ident => |id| scope.widths.get(id.text),
        .grouped => |inner| comptimeExprWidth(scope, inner.*),
        .unary => |node| comptimeExprWidth(scope, node.expr.*),
        .binary => |node| comptimeExprWidth(scope, node.left.*) orelse comptimeExprWidth(scope, node.right.*),
        .cast => |node| comptimeTypeBitWidth(node.ty.*),
        else => null,
    };
}

// Fold every `const NAME: T = …` global to a comptime value, populating `out`
// (keyed by name). Earlier const globals are visible to later ones. Globals
// whose initializer is not a foldable comptime constant are simply omitted.
pub fn collectConstGlobals(
    allocator: std.mem.Allocator,
    module: ast.Module,
    funcs: *const std.StringHashMap(ast.FnDecl),
    out: *std.StringHashMap(ComptimeValue),
) !void {
    // Fold scratch (e.g. array temporaries) lives in an arena that is freed
    // here; values retained in `out` must therefore be deep-cloned.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var scope = ComptimeScope.init(arena.allocator());
    defer scope.deinit();
    scope.funcs = funcs;
    scope.globals = out;
    for (module.decls) |decl| {
        const global = switch (decl.kind) {
            .global_decl => |g| g,
            else => continue,
        };
        if (!global.is_const) continue;
        const init_expr = global.init orelse continue;
        switch (foldComptimeExpr(&scope, init_expr)) {
            .value => |v| {
                const cloned = try cloneComptimeValue(allocator, v);
                errdefer freeComptimeValue(allocator, cloned);
                try out.put(global.name.text, cloned);
            },
            else => {},
        }
    }
}

fn comptimeIdentValue(scope: *const ComptimeScope, name: []const u8) ?ComptimeValue {
    if (scope.bindings.get(name)) |value| return value;
    if (scope.globals) |g| return g.get(name);
    return null;
}

pub fn foldComptimeExpr(scope: *const ComptimeScope, expr: ast.Expr) ComptimeFold {
    return switch (expr.kind) {
        .int_literal => |literal| .{ .value = .{ .int = parseInt(literal) catch return .unknown } },
        .bool_literal => |value| .{ .value = .{ .boolean = value } },
        .enum_literal => |literal| .{ .value = .{ .tag = literal.text } },
        .ident => |ident| if (comptimeIdentValue(scope, ident.text)) |value| .{ .value = value } else .unknown,
        .grouped => |inner| foldComptimeExpr(scope, inner.*),
        .unary => |node| foldComptimeUnary(scope, node.op, node.expr.*),
        .binary => |node| foldComptimeBinary(scope, node.op, node.left.*, node.right.*),
        .call => |call| switch (foldComptimeCall(scope, call)) {
            .unknown => if (scope.reflect) |r|
                (if (r(scope.reflect_ctx, expr)) |v| ComptimeFold{ .value = .{ .int = v } } else .unknown)
            else
                .unknown,
            else => |f| f,
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
    const out = scope.bindings.allocator.alloc(ComptimeStructField, fields.len) catch return .unknown;
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

// Fold `base.field` over a comptime struct (section 22).
fn foldComptimeMember(scope: *const ComptimeScope, base_expr: ast.Expr, field_name: []const u8) ComptimeFold {
    const base = switch (foldComptimeExpr(scope, base_expr)) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
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
    const elems = scope.bindings.allocator.alloc(ComptimeValue, items.len) catch return .unknown;
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
    const base = switch (foldComptimeExpr(scope, base_expr)) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    const arr = switch (base) {
        .array => |a| a,
        else => return .unknown,
    };
    const index = switch (foldComptimeExpr(scope, index_expr)) {
        .value => |v| switch (v) {
            .int => |n| n,
            else => return .unknown,
        },
        .trap => return .trap,
        .unknown => return .unknown,
    };
    if (index < 0 or index >= arr.len) return .trap;
    return .{ .value = arr[@intCast(index)] };
}

// Evaluate a call to a `const fn` with constant arguments (section 22). Returns
// `.unknown` for non-const callees, unbound arguments, fuel exhaustion, or any
// body construct outside the supported subset — none of which is a provable
// trap. A divide-by-zero / invalid shift inside the body propagates as `.trap`.
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
    callee_scope.globals = scope.globals;
    callee_scope.reflect = scope.reflect;
    callee_scope.reflect_ctx = scope.reflect_ctx;
    callee_scope.call_depth = scope.call_depth + 1;
    for (fn_decl.params, call.args) |param, arg| {
        const value = switch (foldComptimeExpr(scope, arg)) {
            .value => |v| v,
            .trap => return .trap,
            .unknown => return .unknown,
        };
        callee_scope.bind(param.name.text, value) catch return .unknown;
        if (comptimeTypeBitWidth(param.ty)) |bits| callee_scope.bindWidth(param.name.text, bits);
    }
    return foldComptimeFnBody(&callee_scope, body);
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
    trap, // a const-eval trap (divide-by-zero, invalid shift)
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
                switch (foldComptimeExpr(scope, init_expr)) {
                    .value => |value| {
                        scope.bind(local.names[0].text, value) catch return .unknown;
                        if (local.ty) |lty| if (comptimeTypeBitWidth(lty)) |bits| scope.bindWidth(local.names[0].text, bits);
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
                const expr = maybe_expr orelse return .unknown;
                return .{ .returned = foldComptimeExpr(scope, expr) };
            },
            .assert => |expr| {
                switch (foldComptimeExpr(scope, expr)) {
                    .value => |value| switch (value) {
                        .boolean => |ok| if (!ok) return .trap,
                        .int, .tag, .array, .@"struct" => return .unknown,
                    },
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
            else => return .unknown,
        }
    }
    return .fallthrough;
}

// Evaluate a comptime `switch` statement (section 22): fold the subject, take
// the first arm whose literal/tag/wildcard/binding pattern matches, and run
// that arm's body. Payload tag-bind patterns are not modeled at comptime.
fn foldComptimeSwitch(scope: *ComptimeScope, sw: ast.Switch) BodyFlow {
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
                    break :blk true;
                },
                .literal => |lit| switch (foldComptimeExpr(scope, lit)) {
                    .value => |lv| comptimeValueEql(lv, subject),
                    .trap => return .trap,
                    .unknown => return .unknown,
                },
                .tag => |tag| switch (subject) {
                    .tag => |subject_tag| std.mem.eql(u8, subject_tag, tag.text),
                    else => return .unknown,
                },
                .tag_bind => return .unknown,
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
        .int => |av| switch (b) {
            .int => |bv| av == bv,
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

const AssignResult = enum { ok, trap, unknown };

// Comptime assignment (section 22): `name = v`, plus mutable-aggregate element
// (`arr[i] = v`, out-of-bounds → trap) and field (`s.field = v`) stores, which
// rebind the whole aggregate with an updated copy (copy-on-write). This is the
// comptime "memory" model — values, no aliasing.
fn foldComptimeAssign(scope: *ComptimeScope, target: ast.Expr, value_expr: ast.Expr) AssignResult {
    switch (target.kind) {
        .grouped => |inner| return foldComptimeAssign(scope, inner.*, value_expr),
        .ident => |ident| {
            const v = switch (foldComptimeExpr(scope, value_expr)) {
                .value => |x| x,
                .trap => return .trap,
                .unknown => return .unknown,
            };
            scope.bind(ident.text, v) catch return .unknown;
            return .ok;
        },
        .index => |node| {
            const base_name = switch (node.base.*.kind) {
                .ident => |i| i.text,
                else => return .unknown,
            };
            const arr = switch (scope.bindings.get(base_name) orelse return .unknown) {
                .array => |a| a,
                else => return .unknown,
            };
            const idx = switch (foldComptimeExpr(scope, node.index.*)) {
                .value => |x| switch (x) {
                    .int => |n| n,
                    else => return .unknown,
                },
                .trap => return .trap,
                .unknown => return .unknown,
            };
            if (idx < 0 or idx >= arr.len) return .trap;
            const v = switch (foldComptimeExpr(scope, value_expr)) {
                .value => |x| x,
                .trap => return .trap,
                .unknown => return .unknown,
            };
            const copy = scope.bindings.allocator.dupe(ComptimeValue, arr) catch return .unknown;
            copy[@intCast(idx)] = v;
            scope.bind(base_name, .{ .array = copy }) catch return .unknown;
            return .ok;
        },
        .member => |node| {
            const base_name = switch (node.base.*.kind) {
                .ident => |i| i.text,
                else => return .unknown,
            };
            const fields = switch (scope.bindings.get(base_name) orelse return .unknown) {
                .@"struct" => |f| f,
                else => return .unknown,
            };
            const v = switch (foldComptimeExpr(scope, value_expr)) {
                .value => |x| x,
                .trap => return .trap,
                .unknown => return .unknown,
            };
            const copy = scope.bindings.allocator.dupe(ComptimeStructField, fields) catch return .unknown;
            var found = false;
            for (copy) |*f| {
                if (std.mem.eql(u8, f.name, node.name.text)) {
                    f.value = v;
                    found = true;
                    break;
                }
            }
            if (!found) return .unknown;
            scope.bind(base_name, .{ .@"struct" = copy }) catch return .unknown;
            return .ok;
        },
        else => return .unknown,
    }
}

fn foldComptimeWhile(scope: *ComptimeScope, loop: ast.Loop) BodyFlow {
    const cond = loop.iterable orelse return .unknown;
    var fuel: u64 = comptime_loop_fuel;
    while (fuel > 0) : (fuel -= 1) {
        const keep_going = switch (foldComptimeExpr(scope, cond)) {
            .value => |v| switch (v) {
                .boolean => |b| b,
                .int, .tag, .array, .@"struct" => return .unknown,
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
            .int => |v| .{ .value = .{ .int = std.math.negate(v) catch return .unknown } },
            .boolean, .tag, .array, .@"struct" => .unknown,
        },
        .bit_not => switch (operand) {
            // Mask the complement to the operand's declared width. Without a known
            // width we cannot pick the right mask, so fold to .unknown rather than
            // the unmasked (negative) i128 value — that previously made identities
            // like `~zero == 0xFFFFFFFF` (u32) wrongly fail as a comptime trap.
            .int => |v| if (comptimeExprWidth(scope, operand_expr)) |bits| blk: {
                const mask: u128 = if (bits >= 128) ~@as(u128, 0) else (@as(u128, 1) << @intCast(bits)) - 1;
                const masked: u128 = (~@as(u128, @bitCast(v))) & mask;
                break :blk .{ .value = .{ .int = @intCast(masked) } };
            } else .unknown,
            .boolean, .tag, .array, .@"struct" => .unknown,
        },
        .logical_not => switch (operand) {
            .boolean => |v| .{ .value = .{ .boolean = !v } },
            .int, .tag, .array, .@"struct" => .unknown,
        },
    };
}

fn foldComptimeBinary(scope: *const ComptimeScope, op: ast.BinaryOp, left_expr: ast.Expr, right_expr: ast.Expr) ComptimeFold {
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
                .int, .tag, .array, .@"struct" => return .unknown,
            },
            .unknown => return .unknown,
        }
        return switch (foldComptimeExpr(scope, right_expr)) {
            .value => |v| switch (v) {
                .boolean => |b| .{ .value = .{ .boolean = b } },
                .int, .tag, .array, .@"struct" => .unknown,
            },
            .trap => .trap,
            .unknown => .unknown,
        };
    }

    const left = switch (foldComptimeExpr(scope, left_expr)) {
        .value => |v| v,
        .trap => return .trap,
        .unknown => return .unknown,
    };
    const right = switch (foldComptimeExpr(scope, right_expr)) {
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
                .boolean, .tag, .array, .@"struct" => return .unknown,
            },
            .boolean => |l| switch (right) {
                .boolean => |r| l == r,
                .int, .tag, .array, .@"struct" => return .unknown,
            },
            .tag => |l| switch (right) {
                .tag => |r| std.mem.eql(u8, l, r),
                .int, .boolean, .array, .@"struct" => return .unknown,
            },
            .array => switch (right) {
                .array => comptimeValueEql(left, right),
                .int, .boolean, .tag, .@"struct" => return .unknown,
            },
            .@"struct" => switch (right) {
                .@"struct" => comptimeValueEql(left, right),
                .int, .boolean, .tag, .array => return .unknown,
            },
        };
        return .{ .value = .{ .boolean = if (op == .eq) equal else !equal } };
    }

    const l = switch (left) {
        .int => |v| v,
        .boolean, .tag, .array, .@"struct" => return .unknown,
    };
    const r = switch (right) {
        .int => |v| v,
        .boolean, .tag, .array, .@"struct" => return .unknown,
    };

    return switch (op) {
        .lt => .{ .value = .{ .boolean = l < r } },
        .le => .{ .value = .{ .boolean = l <= r } },
        .gt => .{ .value = .{ .boolean = l > r } },
        .ge => .{ .value = .{ .boolean = l >= r } },
        // i128 is only the evaluation domain — overflowing it (as opposed to a
        // declared target type) is outside the scalar model, so fold to unknown
        // rather than risk a false trap or a compiler panic.
        .add => .{ .value = .{ .int = std.math.add(i128, l, r) catch return .unknown } },
        .sub => .{ .value = .{ .int = std.math.sub(i128, l, r) catch return .unknown } },
        .mul => .{ .value = .{ .int = std.math.mul(i128, l, r) catch return .unknown } },
        .div => if (r == 0) .trap else .{ .value = .{ .int = std.math.divTrunc(i128, l, r) catch return .unknown } },
        .mod => if (r == 0) .trap else .{ .value = .{ .int = @rem(l, r) } },
        .bit_and => .{ .value = .{ .int = l & r } },
        .bit_or => .{ .value = .{ .int = l | r } },
        .bit_xor => .{ .value = .{ .int = l ^ r } },
        .shl => if (r < 0 or r >= 128) .trap else blk: {
            const shifted = @shlWithOverflow(l, @as(u7, @intCast(r)));
            break :blk if (shifted[1] != 0) .unknown else .{ .value = .{ .int = shifted[0] } };
        },
        .shr => if (r < 0 or r >= 128) .trap else .{ .value = .{ .int = l >> @as(u7, @intCast(r)) } },
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
    var cleaned: [128]u8 = undefined;
    if (raw.len > cleaned.len) return error.InvalidIntegerLiteral;
    var len: usize = 0;
    for (raw) |ch| {
        if (ch == '_') continue;
        cleaned[len] = ch;
        len += 1;
    }
    return std.fmt.parseInt(i128, cleaned[0..len], 0) catch error.InvalidIntegerLiteral;
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

const zero_span = ast.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

fn testInt(a: std.mem.Allocator, text: []const u8) !*ast.Expr {
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .int_literal = text } });
}

fn testBool(a: std.mem.Allocator, value: bool) !*ast.Expr {
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .bool_literal = value } });
}

fn testIdent(a: std.mem.Allocator, name: []const u8) !*ast.Expr {
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .ident = .{ .text = name, .span = zero_span } } });
}

fn testBinary(a: std.mem.Allocator, op: ast.BinaryOp, left: *ast.Expr, right: *ast.Expr) !*ast.Expr {
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .binary = .{ .op = op, .left = left, .right = right } } });
}

test "foldComptimeExpr folds the comptime scalar subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    try scope.bind("n", .{ .int = 4 });

    // n == 4  -> true
    const eq = try testBinary(a, .eq, try testIdent(a, "n"), try testInt(a, "4"));
    try std.testing.expect(foldComptimeExpr(&scope, eq.*).value.boolean);

    // (2 + 3) * 2 == 10  -> true
    const sum = try testBinary(a, .add, try testInt(a, "2"), try testInt(a, "3"));
    const product = try testBinary(a, .mul, sum, try testInt(a, "2"));
    const cmp = try testBinary(a, .eq, product, try testInt(a, "10"));
    try std.testing.expect(foldComptimeExpr(&scope, cmp.*).value.boolean);

    // 2 < 1  -> false
    const lt = try testBinary(a, .lt, try testInt(a, "2"), try testInt(a, "1"));
    try std.testing.expect(!foldComptimeExpr(&scope, lt.*).value.boolean);

    // 1 / 0  -> trap
    const div = try testBinary(a, .div, try testInt(a, "1"), try testInt(a, "0"));
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, div.*)) == .trap);

    // unknown identifier -> unknown (no diagnostic)
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, (try testIdent(a, "runtime")).*)) == .unknown);

    // short-circuit: false && <unknown> -> false
    const sc_and = try testBinary(a, .logical_and, try testBool(a, false), try testIdent(a, "runtime"));
    try std.testing.expect(!foldComptimeExpr(&scope, sc_and.*).value.boolean);

    // short-circuit: true || <unknown> -> true
    const sc_or = try testBinary(a, .logical_or, try testBool(a, true), try testIdent(a, "runtime"));
    try std.testing.expect(foldComptimeExpr(&scope, sc_or.*).value.boolean);
}

test "foldComptimeExpr evaluates const fn calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn is_power_of_two(x: u32) -> bool { return x != 0 && (x & (x - 1)) == 0; }
    const x_param = ast.Param{ .name = .{ .text = "x", .span = zero_span }, .ty = .{ .span = zero_span, .kind = .{ .name = .{ .text = "u32", .span = zero_span } } } };
    const x_ne_0 = try testBinary(a, .ne, try testIdent(a, "x"), try testInt(a, "0"));
    const x_minus_1 = try testBinary(a, .sub, try testIdent(a, "x"), try testInt(a, "1"));
    const x_and = try testBinary(a, .bit_and, try testIdent(a, "x"), x_minus_1);
    const and_eq_0 = try testBinary(a, .eq, x_and, try testInt(a, "0"));
    const body_expr = try testBinary(a, .logical_and, x_ne_0, and_eq_0);
    const ret_stmt = ast.Stmt{ .span = zero_span, .kind = .{ .@"return" = body_expr.* } };
    const items = try a.dupe(ast.Stmt, &.{ret_stmt});
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "is_power_of_two", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{x_param}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = items },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("is_power_of_two", fn_decl);

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    scope.funcs = &funcs;

    // is_power_of_two(16) -> true
    const call16 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "is_power_of_two"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "16")).*}),
    } } });
    try std.testing.expect(foldComptimeExpr(&scope, call16.*).value.boolean);

    // is_power_of_two(17) -> false
    const call17 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "is_power_of_two"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "17")).*}),
    } } });
    try std.testing.expect(!foldComptimeExpr(&scope, call17.*).value.boolean);

    // unknown function -> unknown (no diagnostic)
    const call_unknown = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "mystery"),
        .type_args = &.{},
        .args = &.{},
    } } });
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, call_unknown.*)) == .unknown);
}

test "foldComptimeExpr evaluates assert statements in const fn calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn require_four(x: u32) -> u32 { assert(x == 4); return x; }
    const x_param = ast.Param{ .name = .{ .text = "x", .span = zero_span }, .ty = .{ .span = zero_span, .kind = .{ .name = .{ .text = "u32", .span = zero_span } } } };
    const assert_expr = try testBinary(a, .eq, try testIdent(a, "x"), try testInt(a, "4"));
    const assert_stmt = ast.Stmt{ .span = zero_span, .kind = .{ .assert = assert_expr.* } };
    const ret_stmt = ast.Stmt{ .span = zero_span, .kind = .{ .@"return" = (try testIdent(a, "x")).* } };
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "require_four", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{x_param}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{ assert_stmt, ret_stmt }) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("require_four", fn_decl);

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    scope.funcs = &funcs;

    const call_ok = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "require_four"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "4")).*}),
    } } });
    try std.testing.expectEqual(@as(i128, 4), foldComptimeExpr(&scope, call_ok.*).value.int);

    const call_trap = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "require_four"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "5")).*}),
    } } });
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, call_trap.*)) == .trap);
}

fn testU32(name: []const u8) ast.Param {
    return ast.Param{ .name = .{ .text = name, .span = zero_span }, .ty = .{ .span = zero_span, .kind = .{ .name = .{ .text = "u32", .span = zero_span } } } };
}

fn testStmt(kind: ast.Stmt.Kind) ast.Stmt {
    return ast.Stmt{ .span = zero_span, .kind = kind };
}

test "foldComptimeExpr evaluates a const fn with a while loop and fuel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn count_down(n: u32) -> u32 {
    //     var i: u32 = n;
    //     while i != 0 { i = i - 1; }
    //     return i;
    // }
    const var_i = testStmt(.{ .var_decl = .{
        .names = try a.dupe(ast.Ident, &.{.{ .text = "i", .span = zero_span }}),
        .ty = null,
        .init = (try testIdent(a, "n")).*,
    } });
    const dec = testStmt(.{ .assignment = .{
        .target = (try testIdent(a, "i")).*,
        .value = (try testBinary(a, .sub, try testIdent(a, "i"), try testInt(a, "1"))).*,
    } });
    const while_loop = testStmt(.{ .loop = .{
        .kind = .@"while",
        .label = null,
        .iterable = (try testBinary(a, .ne, try testIdent(a, "i"), try testInt(a, "0"))).*,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{dec}) },
    } });
    const ret = testStmt(.{ .@"return" = (try testIdent(a, "i")).* });
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "count_down", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{testU32("n")}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{ var_i, while_loop, ret }) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("count_down", fn_decl);

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    scope.funcs = &funcs;

    // count_down(5) -> 0
    const call = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "count_down"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testInt(a, "5")).*}),
    } } });
    try std.testing.expectEqual(@as(i128, 0), foldComptimeExpr(&scope, call.*).value.int);
}

fn testArrayLit(a: std.mem.Allocator, vals: []const i128) !*ast.Expr {
    var items = try a.alloc(ast.Expr, vals.len);
    for (vals, 0..) |v, i| {
        const text = try std.fmt.allocPrint(a, "{d}", .{v});
        items[i] = (try testInt(a, text)).*;
    }
    return ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .array_literal = items } });
}

test "foldComptimeExpr folds comptime array literals and indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Arena-backed scope so folded array temporaries are freed with the arena.
    var scope = ComptimeScope.init(a);
    defer scope.deinit();

    const arr = try testArrayLit(a, &.{ 10, 20, 30, 40 });
    // array literal -> array value of length 4
    try std.testing.expectEqual(@as(usize, 4), foldComptimeExpr(&scope, arr.*).value.array.len);

    // arr[2] -> 30
    const idx2 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .index = .{ .base = arr, .index = try testInt(a, "2") } } });
    try std.testing.expectEqual(@as(i128, 30), foldComptimeExpr(&scope, idx2.*).value.int);

    // arr[4] -> out-of-bounds trap
    const idx4 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .index = .{ .base = arr, .index = try testInt(a, "4") } } });
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, idx4.*)) == .trap);
}

test "foldComptimeExpr folds comptime aggregate equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scope = ComptimeScope.init(a);
    defer scope.deinit();

    const arr_eq = try testBinary(a, .eq, try testArrayLit(a, &.{ 1, 2, 3 }), try testArrayLit(a, &.{ 1, 2, 3 }));
    try std.testing.expect(foldComptimeExpr(&scope, arr_eq.*).value.boolean);

    const arr_ne = try testBinary(a, .ne, try testArrayLit(a, &.{ 1, 2, 3 }), try testArrayLit(a, &.{ 1, 2, 4 }));
    try std.testing.expect(foldComptimeExpr(&scope, arr_ne.*).value.boolean);

    const left_fields = try a.dupe(ast.StructLiteralField, &.{
        .{ .name = .{ .text = "w", .span = zero_span }, .value = (try testInt(a, "3")).* },
        .{ .name = .{ .text = "h", .span = zero_span }, .value = (try testInt(a, "4")).* },
    });
    const right_fields = try a.dupe(ast.StructLiteralField, &.{
        .{ .name = .{ .text = "h", .span = zero_span }, .value = (try testInt(a, "4")).* },
        .{ .name = .{ .text = "w", .span = zero_span }, .value = (try testInt(a, "3")).* },
    });
    const left = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .struct_literal = left_fields } });
    const right = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .struct_literal = right_fields } });
    const struct_eq = try testBinary(a, .eq, left, right);
    try std.testing.expect(foldComptimeExpr(&scope, struct_eq.*).value.boolean);
}

test "foldComptimeExpr folds a const fn with a for loop over an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn sum(xs: [4]u32) -> u32 {
    //     var total: u32 = 0;
    //     for x in xs { total = total + x; }
    //     return total;
    // }
    const xs_param = ast.Param{ .name = .{ .text = "xs", .span = zero_span }, .ty = .{ .span = zero_span, .kind = .{ .array = .{ .len = (try testInt(a, "4")).*, .child = try ast.makePtr(a, ast.TypeExpr{ .span = zero_span, .kind = .{ .name = .{ .text = "u32", .span = zero_span } } }) } } } };
    const init_total = testStmt(.{ .var_decl = .{ .names = try a.dupe(ast.Ident, &.{.{ .text = "total", .span = zero_span }}), .ty = null, .init = (try testInt(a, "0")).* } });
    const add = testStmt(.{ .assignment = .{ .target = (try testIdent(a, "total")).*, .value = (try testBinary(a, .add, try testIdent(a, "total"), try testIdent(a, "x"))).* } });
    const for_loop = testStmt(.{ .loop = .{ .kind = .@"for", .label = .{ .text = "x", .span = zero_span }, .iterable = (try testIdent(a, "xs")).*, .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{add}) } } });
    const ret = testStmt(.{ .@"return" = (try testIdent(a, "total")).* });
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "sum", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{xs_param}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{ init_total, for_loop, ret }) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("sum", fn_decl);

    // Arena-backed scope so folded array temporaries are freed with the arena.
    var scope = ComptimeScope.init(a);
    defer scope.deinit();
    scope.funcs = &funcs;

    // sum(.{1, 2, 3, 4}) -> 10
    const call = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{
        .callee = try testIdent(a, "sum"),
        .type_args = &.{},
        .args = try a.dupe(ast.Expr, &.{(try testArrayLit(a, &.{ 1, 2, 3, 4 })).*}),
    } } });
    try std.testing.expectEqual(@as(i128, 10), foldComptimeExpr(&scope, call.*).value.int);
}

test "foldComptimeExpr folds a const fn with a comptime switch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // const fn classify(x: u32) -> u32 {
    //     switch x { 0 => { return 100; }, _ => { return 999; }, }
    // }
    const arm0_body = ast.Block{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{testStmt(.{ .@"return" = (try testInt(a, "100")).* })}) };
    const armw_body = ast.Block{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{testStmt(.{ .@"return" = (try testInt(a, "999")).* })}) };
    const arms = try a.dupe(ast.SwitchArm, &.{
        .{ .patterns = try a.dupe(ast.Pattern, &.{.{ .span = zero_span, .kind = .{ .literal = (try testInt(a, "0")).* } }}), .body = .{ .block = arm0_body } },
        .{ .patterns = try a.dupe(ast.Pattern, &.{.{ .span = zero_span, .kind = .wildcard }}), .body = .{ .block = armw_body } },
    });
    const sw = testStmt(.{ .@"switch" = .{ .subject = (try testIdent(a, "x")).*, .arms = arms } });
    const fn_decl = ast.FnDecl{
        .name = .{ .text = "classify", .span = zero_span },
        .params = try a.dupe(ast.Param, &.{testU32("x")}),
        .return_type = null,
        .body = .{ .span = zero_span, .items = try a.dupe(ast.Stmt, &.{sw}) },
        .is_const = true,
        .abi = null,
        .exported = false,
    };

    var funcs = std.StringHashMap(ast.FnDecl).init(std.testing.allocator);
    defer funcs.deinit();
    try funcs.put("classify", fn_decl);

    var scope = ComptimeScope.init(a);
    defer scope.deinit();
    scope.funcs = &funcs;

    const call0 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{ .callee = try testIdent(a, "classify"), .type_args = &.{}, .args = try a.dupe(ast.Expr, &.{(try testInt(a, "0")).*}) } } });
    const call7 = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .call = .{ .callee = try testIdent(a, "classify"), .type_args = &.{}, .args = try a.dupe(ast.Expr, &.{(try testInt(a, "7")).*}) } } });
    try std.testing.expectEqual(@as(i128, 100), foldComptimeExpr(&scope, call0.*).value.int);
    try std.testing.expectEqual(@as(i128, 999), foldComptimeExpr(&scope, call7.*).value.int);
}

test "foldComptimeExpr folds comptime aggregate element assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scope = ComptimeScope.init(a);
    defer scope.deinit();
    try scope.bind("xs", .{ .array = try a.dupe(ComptimeValue, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 } }) });

    // xs[1] = 42
    const target = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .index = .{ .base = try testIdent(a, "xs"), .index = try testInt(a, "1") } } });
    try std.testing.expect(foldComptimeAssign(&scope, target.*, (try testInt(a, "42")).*) == .ok);
    try std.testing.expectEqual(@as(i128, 42), scope.bindings.get("xs").?.array[1].int);

    // xs[5] = 1 -> out-of-bounds trap
    const oob = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .index = .{ .base = try testIdent(a, "xs"), .index = try testInt(a, "5") } } });
    try std.testing.expect(foldComptimeAssign(&scope, oob.*, (try testInt(a, "1")).*) == .trap);
}

test "foldComptimeExpr folds comptime struct literals and field access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Arena-backed scope so folded struct temporaries are freed with the arena.
    var scope = ComptimeScope.init(a);
    defer scope.deinit();

    // .{ .w = 3, .h = 4 }
    const fields = try a.dupe(ast.StructLiteralField, &.{
        .{ .name = .{ .text = "w", .span = zero_span }, .value = (try testInt(a, "3")).* },
        .{ .name = .{ .text = "h", .span = zero_span }, .value = (try testInt(a, "4")).* },
    });
    const lit = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .struct_literal = fields } });

    // r.w -> 3, r.h -> 4
    const w = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .member = .{ .base = lit, .name = .{ .text = "w", .span = zero_span } } } });
    const h = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .member = .{ .base = lit, .name = .{ .text = "h", .span = zero_span } } } });
    try std.testing.expectEqual(@as(i128, 3), foldComptimeExpr(&scope, w.*).value.int);
    try std.testing.expectEqual(@as(i128, 4), foldComptimeExpr(&scope, h.*).value.int);

    // w * h -> 12
    const product = try testBinary(a, .mul, w, h);
    try std.testing.expectEqual(@as(i128, 12), foldComptimeExpr(&scope, product.*).value.int);

    // unknown field -> unknown
    const z = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .member = .{ .base = lit, .name = .{ .text = "z", .span = zero_span } } } });
    try std.testing.expect(std.meta.activeTag(foldComptimeExpr(&scope, z.*)) == .unknown);
}

test "foldComptimeExpr resolves named const globals via scope.globals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var globals = std.StringHashMap(ComptimeValue).init(std.testing.allocator);
    defer globals.deinit();
    try globals.put("MAX", .{ .int = 4 });

    var scope = ComptimeScope.init(std.testing.allocator);
    defer scope.deinit();
    scope.globals = &globals;

    // MAX * 2 -> 8
    const expr = try testBinary(a, .mul, try testIdent(a, "MAX"), try testInt(a, "2"));
    try std.testing.expectEqual(@as(i128, 8), foldComptimeExpr(&scope, expr.*).value.int);

    // a local binding shadows the global
    try scope.bind("MAX", .{ .int = 10 });
    try std.testing.expectEqual(@as(i128, 20), foldComptimeExpr(&scope, expr.*).value.int);
}
