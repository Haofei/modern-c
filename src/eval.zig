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
