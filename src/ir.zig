const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");

pub const TrapKind = enum {
    IntegerOverflow,
    DivideByZero,
    InvalidShift,
    Bounds,
    Assert,
    Unreachable,
    Unknown,
};

pub const TrapSource = enum {
    checked_arithmetic,
    checked_shift,
    index,
    assert_stmt,
    trap_call,
    unreachable_expr,
    unwrap,
};

pub const TrapEdge = struct {
    function_name: []const u8,
    kind: TrapKind,
    source: TrapSource,
    no_lang_trap: bool,
    line: usize,
    column: usize,
};

pub const SafeNoTrapOp = struct {
    function_name: []const u8,
    kind: []const u8,
    line: usize,
    column: usize,
};

pub const ContractRegion = struct {
    function_name: []const u8,
    id: usize,
    contract: []const u8,
    begin_line: usize,
    end_line: usize,
    unchecked_calls: usize,
    metadata_attached_after_region: bool,
};

pub const UncheckedCall = struct {
    function_name: []const u8,
    callee: []const u8,
    contract: ?[]const u8,
    contract_region_id: ?usize,
    line: usize,
    column: usize,
};

pub const FunctionIr = struct {
    name: []const u8,
    no_lang_trap: bool,
    trap_edges: []TrapEdge,
    safe_no_trap_ops: []SafeNoTrapOp,
    contract_regions: []ContractRegion,
    unchecked_calls: []UncheckedCall,
};

pub const ModuleIr = struct {
    allocator: std.mem.Allocator,
    functions: []FunctionIr,

    pub fn deinit(self: *ModuleIr) void {
        for (self.functions) |function| {
            self.allocator.free(function.trap_edges);
            self.allocator.free(function.safe_no_trap_ops);
            self.allocator.free(function.contract_regions);
            self.allocator.free(function.unchecked_calls);
        }
        self.allocator.free(self.functions);
    }
};

pub fn buildModuleIr(allocator: std.mem.Allocator, module: ast.Module) !ModuleIr {
    var functions: std.ArrayList(FunctionIr) = .empty;
    errdefer {
        for (functions.items) |function| {
            allocator.free(function.trap_edges);
            allocator.free(function.safe_no_trap_ops);
            allocator.free(function.contract_regions);
            allocator.free(function.unchecked_calls);
        }
        functions.deinit(allocator);
    }

    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| {
                if (fn_decl.body) |body| {
                    var builder = FunctionIrBuilder.init(allocator, fn_decl, hasNoLangTrap(decl.attrs));
                    errdefer builder.deinit();
                    try builder.collectBlock(body);
                    try functions.append(allocator, try builder.finish());
                }
            },
            .type_alias, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
        }
    }

    return .{ .allocator = allocator, .functions = try functions.toOwnedSlice(allocator) };
}

pub fn appendLowerIr(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    var module_ir = try buildModuleIr(allocator, module);
    defer module_ir.deinit();
    for (module_ir.functions) |function| {
        try out.print(
            allocator,
            "ir function name={s} no_lang_trap={} trap_edges={} safe_no_trap_ops={} contract_regions={} unchecked_calls={}\n",
            .{ function.name, function.no_lang_trap, function.trap_edges.len, function.safe_no_trap_ops.len, function.contract_regions.len, function.unchecked_calls.len },
        );
        for (function.contract_regions) |region| {
            try out.print(
                allocator,
                "ir contract_region fn={s} id={} contract={s} begin_line={} end_line={} unchecked_calls={} metadata_attached_after_region={}\n",
                .{ region.function_name, region.id, region.contract, region.begin_line, region.end_line, region.unchecked_calls, region.metadata_attached_after_region },
            );
        }
        for (function.unchecked_calls) |call| {
            if (call.contract_region_id) |region_id| {
                try out.print(
                    allocator,
                    "ir unchecked_call fn={s} callee={s} contract={s} contract_region_id={} line={} column={}\n",
                    .{ call.function_name, call.callee, call.contract orelse "none", region_id, call.line, call.column },
                );
            } else {
                try out.print(
                    allocator,
                    "ir unchecked_call fn={s} callee={s} contract={s} contract_region_id=none line={} column={}\n",
                    .{ call.function_name, call.callee, call.contract orelse "none", call.line, call.column },
                );
            }
        }
        for (function.trap_edges) |edge| {
            try out.print(
                allocator,
                "ir trap_edge fn={s} kind={s} source={s} no_lang_trap={} line={} column={}\n",
                .{ edge.function_name, @tagName(edge.kind), @tagName(edge.source), edge.no_lang_trap, edge.line, edge.column },
            );
        }
        for (function.contract_regions) |region| {
            for (function.trap_edges) |edge| {
                if (!std.mem.eql(u8, region.contract, "no_overflow")) continue;
                if (edge.kind != .IntegerOverflow or edge.line <= region.end_line) continue;
                try out.print(
                    allocator,
                    "ir post_contract_trap_edge fn={s} contract={s} region_id={} trap={s} source={s} line={} metadata_attached=false\n",
                    .{ function.name, region.contract, region.id, @tagName(edge.kind), @tagName(edge.source), edge.line },
                );
            }
        }
        for (function.safe_no_trap_ops) |op| {
            try out.print(
                allocator,
                "ir safe_no_trap fn={s} kind={s} line={} column={}\n",
                .{ op.function_name, op.kind, op.line, op.column },
            );
        }
    }
}

const FunctionIrBuilder = struct {
    allocator: std.mem.Allocator,
    function_name: []const u8,
    no_lang_trap: bool,
    trap_edges: std.ArrayList(TrapEdge),
    safe_no_trap_ops: std.ArrayList(SafeNoTrapOp),
    contract_regions: std.ArrayList(ContractRegion),
    unchecked_calls: std.ArrayList(UncheckedCall),
    wrap_values: std.StringHashMap(void),
    sat_values: std.StringHashMap(void),
    active_contract: ?[]const u8 = null,
    active_contract_region_id: ?usize = null,
    next_contract_region_id: usize = 1,

    fn init(allocator: std.mem.Allocator, fn_decl: ast.FnDecl, no_lang_trap: bool) FunctionIrBuilder {
        var builder = FunctionIrBuilder{
            .allocator = allocator,
            .function_name = fn_decl.name.text,
            .no_lang_trap = no_lang_trap,
            .trap_edges = .empty,
            .safe_no_trap_ops = .empty,
            .contract_regions = .empty,
            .unchecked_calls = .empty,
            .wrap_values = std.StringHashMap(void).init(allocator),
            .sat_values = std.StringHashMap(void).init(allocator),
        };
        for (fn_decl.params) |param| {
            if (isWrapType(param.ty)) builder.wrap_values.put(param.name.text, {}) catch {};
            if (isSatType(param.ty)) builder.sat_values.put(param.name.text, {}) catch {};
        }
        return builder;
    }

    fn deinit(self: *FunctionIrBuilder) void {
        self.trap_edges.deinit(self.allocator);
        self.safe_no_trap_ops.deinit(self.allocator);
        self.contract_regions.deinit(self.allocator);
        self.unchecked_calls.deinit(self.allocator);
        self.wrap_values.deinit();
        self.wrap_values = std.StringHashMap(void).init(self.allocator);
        self.sat_values.deinit();
        self.sat_values = std.StringHashMap(void).init(self.allocator);
    }

    fn finish(self: *FunctionIrBuilder) !FunctionIr {
        const trap_edges = try self.trap_edges.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(trap_edges);
        const safe_no_trap_ops = try self.safe_no_trap_ops.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(safe_no_trap_ops);
        const contract_regions = try self.contract_regions.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(contract_regions);
        const unchecked_calls = try self.unchecked_calls.toOwnedSlice(self.allocator);
        self.wrap_values.deinit();
        self.sat_values.deinit();
        return .{
            .name = self.function_name,
            .no_lang_trap = self.no_lang_trap,
            .trap_edges = trap_edges,
            .safe_no_trap_ops = safe_no_trap_ops,
            .contract_regions = contract_regions,
            .unchecked_calls = unchecked_calls,
        };
    }

    fn collectBlock(self: *FunctionIrBuilder, block: ast.Block) anyerror!void {
        for (block.items) |stmt| try self.collectStmt(stmt);
    }

    fn collectStmt(self: *FunctionIrBuilder, stmt: ast.Stmt) anyerror!void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                if (local.ty) |ty| {
                    if (isWrapType(ty)) {
                        for (local.names) |name| self.wrap_values.put(name.text, {}) catch {};
                    }
                    if (isSatType(ty)) {
                        for (local.names) |name| self.sat_values.put(name.text, {}) catch {};
                    }
                }
                if (local.init) |expr| try self.collectExpr(expr);
            },
            .loop => |node| {
                if (node.iterable) |iterable| try self.collectExpr(iterable);
                try self.collectBlock(node.body);
            },
            .if_let => |node| {
                try self.collectExpr(node.value);
                try self.collectBlock(node.then_block);
                if (node.else_block) |else_block| try self.collectBlock(else_block);
            },
            .@"switch" => |node| {
                try self.collectExpr(node.subject);
                for (node.arms) |arm| switch (arm.body) {
                    .block => |body| try self.collectBlock(body),
                    .expr => |expr| try self.collectExpr(expr),
                };
            },
            .unsafe_block, .comptime_block, .block => |body| try self.collectBlock(body),
            .contract_block => |contract| try self.collectContractBlock(contract),
            .asm_stmt => if (self.no_lang_trap) try self.addSafeOp("opaque_volatile_asm", stmt.span),
            .@"return" => |maybe| if (maybe) |expr| try self.collectExpr(expr),
            .@"break", .@"continue" => {},
            .@"defer", .expr => |expr| try self.collectExpr(expr),
            .assert => |expr| {
                try self.addTrap(.Assert, .assert_stmt, stmt.span);
                try self.collectExpr(expr);
            },
            .assignment => |node| {
                try self.collectExpr(node.target);
                try self.collectExpr(node.value);
            },
        }
    }

    fn collectExpr(self: *FunctionIrBuilder, expr: ast.Expr) anyerror!void {
        switch (expr.kind) {
            .ident,
            .int_literal,
            .float_literal,
            .string_literal,
            .char_literal,
            .bool_literal,
            .null_literal,
            .uninit_literal,
            .void_literal,
            .enum_literal,
            => {},
            .array_literal => |items| for (items) |item| try self.collectExpr(item),
            .struct_literal => |fields| for (fields) |field| try self.collectExpr(field.value),
            .unreachable_expr => try self.addTrap(.Unreachable, .unreachable_expr, expr.span),
            .grouped, .address_of, .deref => |inner| try self.collectExpr(inner.*),
            .try_expr => |inner| {
                try self.addTrap(.Unknown, .unwrap, expr.span);
                try self.collectExpr(inner.operand.*);
            },
            .block => |body| try self.collectBlock(body),
            .unary => |node| {
                if (node.op == .neg) {
                    if (self.exprIsWrap(node.expr.*)) {
                        if (self.no_lang_trap) try self.addSafeOp("wrapping.neg", expr.span);
                    } else {
                        try self.addTrap(.IntegerOverflow, .checked_arithmetic, expr.span);
                    }
                }
                try self.collectExpr(node.expr.*);
            },
            .binary => |node| {
                if (self.binaryIsSafeNoTrapArithmeticDomain(node)) {
                    if (self.no_lang_trap) try self.addSafeOp(safeArithmeticDomainOpName(node.op, if (self.exprIsSat(node.left.*)) "sat" else "wrap"), expr.span);
                } else if (isCheckedTrapOp(node.op)) {
                    try self.addTrap(irTrapKindForBinary(node), .checked_arithmetic, expr.span);
                }
                if (isShiftOp(node.op) and !self.binaryIsSafeNoTrapArithmeticDomain(node)) {
                    try self.addTrap(.InvalidShift, .checked_shift, expr.span);
                }
                try self.collectExpr(node.left.*);
                try self.collectExpr(node.right.*);
            },
            .cast => |node| try self.collectExpr(node.value.*),
            .call => |node| {
                if (isTrapCall(node.callee.*)) {
                    try self.addTrap(irTrapKindFromArgs(node.args), .trap_call, expr.span);
                } else if (unwrapCalleeName(node.callee.*) != null) {
                    try self.addTrap(.Unknown, .unwrap, expr.span);
                } else if (safeNoLangTrapCalleeName(node.callee.*)) |callee_name| {
                    if (self.no_lang_trap) try self.addSafeOp(callee_name, expr.span);
                }
                if (isUncheckedCall(node.callee.*)) {
                    try self.addUncheckedCall(node.callee.*, expr.span);
                }
                try self.collectExpr(node.callee.*);
                for (node.args) |arg| try self.collectExpr(arg);
            },
            .index => |node| {
                try self.addTrap(.Bounds, .index, expr.span);
                try self.collectExpr(node.base.*);
                try self.collectExpr(node.index.*);
            },
            .slice => |node| {
                try self.addTrap(.Bounds, .index, expr.span);
                try self.collectExpr(node.base.*);
                try self.collectExpr(node.start.*);
                try self.collectExpr(node.end.*);
            },
            .member => |node| try self.collectExpr(node.base.*),
        }
    }

    fn collectContractBlock(self: *FunctionIrBuilder, contract: ast.ContractBlock) !void {
        const id = self.next_contract_region_id;
        self.next_contract_region_id += 1;
        const name = contractName(contract.attr);
        const region_index = self.contract_regions.items.len;
        try self.contract_regions.append(self.allocator, .{
            .function_name = self.function_name,
            .id = id,
            .contract = name,
            .begin_line = contract.attr.span.line,
            .end_line = contractBlockEndLine(contract.block),
            .unchecked_calls = 0,
            .metadata_attached_after_region = false,
        });
        const previous_contract = self.active_contract;
        const previous_region_id = self.active_contract_region_id;
        self.active_contract = name;
        self.active_contract_region_id = id;
        try self.collectBlock(contract.block);
        self.active_contract = previous_contract;
        self.active_contract_region_id = previous_region_id;
        self.contract_regions.items[region_index].end_line = contractBlockEndLine(contract.block);
    }

    fn addTrap(self: *FunctionIrBuilder, kind: TrapKind, source: TrapSource, span: ast.Span) !void {
        try self.trap_edges.append(self.allocator, .{
            .function_name = self.function_name,
            .kind = kind,
            .source = source,
            .no_lang_trap = self.no_lang_trap,
            .line = span.line,
            .column = span.column,
        });
    }

    fn addSafeOp(self: *FunctionIrBuilder, kind: []const u8, span: ast.Span) !void {
        try self.safe_no_trap_ops.append(self.allocator, .{
            .function_name = self.function_name,
            .kind = kind,
            .line = span.line,
            .column = span.column,
        });
    }

    fn addUncheckedCall(self: *FunctionIrBuilder, callee: ast.Expr, span: ast.Span) !void {
        const callee_name = uncheckedCalleeName(callee) orelse "unknown";
        try self.unchecked_calls.append(self.allocator, .{
            .function_name = self.function_name,
            .callee = callee_name,
            .contract = self.active_contract,
            .contract_region_id = self.active_contract_region_id,
            .line = span.line,
            .column = span.column,
        });
        if (self.active_contract_region_id) |region_id| {
            for (self.contract_regions.items) |*region| {
                if (region.id == region_id) {
                    region.unchecked_calls += 1;
                    break;
                }
            }
        }
    }

    fn exprIsWrap(self: *FunctionIrBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| self.wrap_values.contains(ident.text),
            .grouped => |inner| self.exprIsWrap(inner.*),
            .binary => |node| isWrapPreservingBinary(node.op) and self.exprIsWrap(node.left.*) and self.exprIsWrap(node.right.*),
            else => false,
        };
    }

    fn exprIsSat(self: *FunctionIrBuilder, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| self.sat_values.contains(ident.text),
            .grouped => |inner| self.exprIsSat(inner.*),
            .binary => |node| isSatPreservingBinary(node.op) and self.exprIsSat(node.left.*) and self.exprIsSat(node.right.*),
            else => false,
        };
    }

    fn binaryIsSafeNoTrapArithmeticDomain(self: *FunctionIrBuilder, node: anytype) bool {
        if (isWrapPreservingBinary(node.op) and self.exprIsWrap(node.left.*) and self.exprIsWrap(node.right.*)) return true;
        if (isSatPreservingBinary(node.op) and self.exprIsSat(node.left.*) and self.exprIsSat(node.right.*)) return true;
        return false;
    }
};

fn irTrapKindForBinary(node: anytype) TrapKind {
    return switch (node.op) {
        .div, .mod => if (isNegativeOne(node.right.*)) .IntegerOverflow else .DivideByZero,
        .add, .sub, .mul, .shl => .IntegerOverflow,
        else => .Unknown,
    };
}

fn irTrapKindFromArgs(args: []ast.Expr) TrapKind {
    if (args.len == 0) return .Unknown;
    return switch (args[0].kind) {
        .enum_literal => |literal| if (std.mem.eql(u8, literal.text, "Bounds"))
            .Bounds
        else if (std.mem.eql(u8, literal.text, "Assert"))
            .Assert
        else if (std.mem.eql(u8, literal.text, "Unreachable"))
            .Unreachable
        else if (std.mem.eql(u8, literal.text, "IntegerOverflow"))
            .IntegerOverflow
        else if (std.mem.eql(u8, literal.text, "DivideByZero"))
            .DivideByZero
        else if (std.mem.eql(u8, literal.text, "InvalidShift"))
            .InvalidShift
        else
            .Unknown,
        else => .Unknown,
    };
}

pub const FactKind = enum {
    checked_arithmetic_trap,
    no_lang_trap_index,
    unsafe_contract_begin,
    unsafe_contract_end,
    unchecked_call,
    mmio_read_call,
    mmio_write_call,
    direct_mmio_assignment,
    assignment,
    store,
};

pub const Collector = struct {
    pub fn appendFacts(
        allocator: std.mem.Allocator,
        module: ast.Module,
        out: *std.ArrayList(u8),
    ) anyerror!void {
        var collector = ModuleFactCollector.init(allocator);
        try collector.appendFacts(module, out);
    }

    pub fn writeFacts(module: ast.Module, writer: anytype) !void {
        var collector = ModuleFactCollector.init(std.heap.page_allocator);
        try collector.writeFacts(module, writer);
    }
};

pub fn appendFacts(
    allocator: std.mem.Allocator,
    module: ast.Module,
    out: *std.ArrayList(u8),
) anyerror!void {
    try Collector.appendFacts(allocator, module, out);
}

pub fn writeFacts(module: ast.Module, writer: anytype) !void {
    try Collector.writeFacts(module, writer);
}

const Context = struct {
    function_name: []const u8 = "",
    no_lang_trap: bool = false,
    unsafe_contract_depth: usize = 0,
    mmio_params: ?*const std.StringHashMap([]const u8) = null,
    locals: ?*std.StringHashMap(void) = null,
    wrap_values: ?*std.StringHashMap(void) = null,
    sat_values: ?*std.StringHashMap(void) = null,
    mmio_sequence: ?*MmioSequenceState = null,
};

const MmioSequenceState = struct {
    ordinary_store_seen: bool = false,
    pending_acquire: ?MmioAccess = null,
};

const OrdinaryGlobalAccess = struct {
    name: []const u8,
    owned: bool = false,
};

const ListFactWriter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),

    pub fn print(self: *ListFactWriter, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        try self.out.print(self.allocator, fmt, args);
    }
};

const ModuleFactCollector = struct {
    allocator: std.mem.Allocator,
    mmio_structs: std.StringHashMap(MmioStruct),
    structs: std.StringHashMap(ast.StructDecl),
    globals: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator) ModuleFactCollector {
        return .{
            .allocator = allocator,
            .mmio_structs = std.StringHashMap(MmioStruct).init(allocator),
            .structs = std.StringHashMap(ast.StructDecl).init(allocator),
            .globals = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit(self: *ModuleFactCollector) void {
        var structs = self.mmio_structs.valueIterator();
        while (structs.next()) |mmio_struct| mmio_struct.fields.deinit();
        self.mmio_structs.deinit();
        self.structs.deinit();
        self.globals.deinit();
    }

    fn appendFacts(self: *ModuleFactCollector, module: ast.Module, out: *std.ArrayList(u8)) anyerror!void {
        var writer: ListFactWriter = .{ .allocator = self.allocator, .out = out };
        try self.writeFacts(module, &writer);
    }

    fn writeFacts(self: *ModuleFactCollector, module: ast.Module, writer: anytype) anyerror!void {
        defer self.deinit();
        try self.collectDeclFacts(module);
        for (module.decls) |decl| try self.writeDeclFacts(decl, writer);
    }

    fn collectDeclFacts(self: *ModuleFactCollector, module: ast.Module) !void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .struct_decl => |struct_decl| {
                    if (struct_decl.abi) |abi| {
                        if (std.mem.eql(u8, abi, "mmio")) try self.collectMmioStruct(struct_decl);
                    } else {
                        try self.structs.put(struct_decl.name.text, struct_decl);
                    }
                },
                .global_decl => |global| if (global.ty) |ty| {
                    try self.globals.put(global.name.text, typeName(ty) orelse "unknown");
                },
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .trait_decl, .impl_trait => {},
            }
        }
    }

    fn collectMmioStruct(self: *ModuleFactCollector, struct_decl: ast.StructDecl) !void {
        var fields = std.StringHashMap(MmioField).init(self.allocator);
        errdefer fields.deinit();
        for (struct_decl.fields) |field| {
            if (mmioFieldFromType(field.ty)) |mmio_field| {
                if (!fields.contains(field.name.text)) try fields.put(field.name.text, mmio_field);
            }
        }
        try self.mmio_structs.put(struct_decl.name.text, .{ .fields = fields });
    }

    fn writeDeclFacts(self: *ModuleFactCollector, decl: ast.Decl, writer: anytype) anyerror!void {
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| {
                if (fn_decl.body) |body| {
                    var mmio_params = std.StringHashMap([]const u8).init(self.allocator);
                    defer mmio_params.deinit();
                    var locals = std.StringHashMap(void).init(self.allocator);
                    defer locals.deinit();
                    var wrap_values = std.StringHashMap(void).init(self.allocator);
                    defer wrap_values.deinit();
                    var sat_values = std.StringHashMap(void).init(self.allocator);
                    defer sat_values.deinit();
                    var mmio_sequence = MmioSequenceState{};
                    for (fn_decl.params) |param| {
                        try locals.put(param.name.text, {});
                        if (isWrapType(param.ty)) try wrap_values.put(param.name.text, {});
                        if (isSatType(param.ty)) try sat_values.put(param.name.text, {});
                        if (mmioPointee(param.ty)) |struct_name| try mmio_params.put(param.name.text, struct_name);
                    }
                    try writeBlockFacts(self, body, writer, .{
                        .function_name = fn_decl.name.text,
                        .no_lang_trap = hasNoLangTrap(decl.attrs),
                        .mmio_params = &mmio_params,
                        .locals = &locals,
                        .wrap_values = &wrap_values,
                        .sat_values = &sat_values,
                        .mmio_sequence = &mmio_sequence,
                    });
                }
            },
            .type_alias, .struct_decl, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl, .trait_decl, .impl_trait => {},
        }
    }

    fn mmioAccess(self: *ModuleFactCollector, callee: ast.Expr, args: []ast.Expr, ctx: Context) ?MmioAccess {
        const member = switch (callee.kind) {
            .member => |node| node,
            else => return null,
        };
        const kind: []const u8 = if (std.mem.eql(u8, member.name.text, "read"))
            "read"
        else if (std.mem.eql(u8, member.name.text, "write"))
            "write"
        else
            return null;

        const reg_member = switch (member.base.kind) {
            .member => |node| node,
            else => return null,
        };
        const param = switch (reg_member.base.kind) {
            .ident => |ident| ident.text,
            else => return null,
        };
        const mmio_params = ctx.mmio_params orelse return null;
        const struct_name = mmio_params.get(param) orelse return null;
        const mmio_struct = self.mmio_structs.get(struct_name) orelse return null;
        const field = mmio_struct.fields.get(reg_member.name.text) orelse return null;
        return .{
            .kind = kind,
            .struct_name = struct_name,
            .field = reg_member.name.text,
            .value_type = field.value_type,
            .width = field.width,
            .ordering = orderingArg(args),
        };
    }

    fn ordinaryGlobalTarget(self: *ModuleFactCollector, target: ast.Expr, ctx: Context) ?OrdinaryGlobalAccess {
        return switch (target.kind) {
            .ident => |ident| if (self.isOrdinaryGlobalLoad(ident.text, ctx)) .{ .name = ident.text } else null,
            .index => |index| self.ordinaryGlobalArrayTarget(index, ctx),
            .member => |member| self.ordinaryGlobalMemberTarget(member, ctx),
            .grouped => |inner| self.ordinaryGlobalTarget(inner.*, ctx),
            else => null,
        };
    }

    fn ordinaryGlobalArrayTarget(self: *ModuleFactCollector, index: anytype, ctx: Context) ?OrdinaryGlobalAccess {
        const base_ident = switch (index.base.kind) {
            .ident => |ident| ident,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident,
                else => return null,
            },
            else => return null,
        };
        if (!self.isOrdinaryGlobalLoad(base_ident.text, ctx)) return null;
        return .{
            .name = std.fmt.allocPrint(self.allocator, "{s}[]", .{base_ident.text}) catch return null,
            .owned = true,
        };
    }

    fn ordinaryGlobalMemberTarget(self: *ModuleFactCollector, member: anytype, ctx: Context) ?OrdinaryGlobalAccess {
        const base_ident = switch (member.base.kind) {
            .ident => |ident| ident,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident,
                else => return null,
            },
            else => return null,
        };
        if (!self.isOrdinaryGlobalLoad(base_ident.text, ctx)) return null;
        const struct_name = self.globals.get(base_ident.text) orelse return null;
        const struct_decl = self.structs.get(struct_name) orelse return null;
        for (struct_decl.fields) |field| {
            if (!std.mem.eql(u8, field.name.text, member.name.text)) continue;
            return .{
                .name = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ base_ident.text, member.name.text }) catch return null,
                .owned = true,
            };
        }
        return null;
    }

    fn mmioRegisterTarget(self: *ModuleFactCollector, target: ast.Expr, ctx: Context) bool {
        const member = switch (target.kind) {
            .member => |node| node,
            .grouped => |inner| return self.mmioRegisterTarget(inner.*, ctx),
            else => return false,
        };
        const base_name = switch (member.base.kind) {
            .ident => |ident| ident.text,
            else => return false,
        };
        const mmio_params = ctx.mmio_params orelse return false;
        const struct_name = mmio_params.get(base_name) orelse return false;
        const mmio_struct = self.mmio_structs.get(struct_name) orelse return false;
        return mmio_struct.fields.contains(member.name.text);
    }

    fn isOrdinaryGlobalLoad(self: *ModuleFactCollector, name: []const u8, ctx: Context) bool {
        if (!self.globals.contains(name)) return false;
        if (ctx.locals) |locals| {
            if (locals.contains(name)) return false;
        }
        return true;
    }
};

const MmioStruct = struct {
    fields: std.StringHashMap(MmioField),
};

const MmioField = struct {
    value_type: []const u8,
    width: []const u8,
};

const MmioAccess = struct {
    kind: []const u8,
    struct_name: []const u8,
    field: []const u8,
    value_type: []const u8,
    width: []const u8,
    ordering: []const u8,
};

fn mmioFieldFromType(ty: ast.TypeExpr) ?MmioField {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (std.mem.eql(u8, generic.base.text, "Reg")) {
        if (generic.args.len == 0) return null;
        const width = typeName(generic.args[0]) orelse "unknown";
        return .{ .value_type = width, .width = width };
    }
    if (std.mem.eql(u8, generic.base.text, "RegBits")) {
        if (generic.args.len == 0) return null;
        const width = typeName(generic.args[0]) orelse "unknown";
        const value_type = if (generic.args.len > 1) typeName(generic.args[1]) orelse width else width;
        return .{ .value_type = value_type, .width = width };
    }
    return null;
}

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

fn mmioPointee(ty: ast.TypeExpr) ?[]const u8 {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "MmioPtr") or generic.args.len != 1) return null;
    return typeName(generic.args[0]);
}

fn writeBlockFacts(collector: *ModuleFactCollector, block: ast.Block, writer: anytype, ctx: Context) anyerror!void {
    for (block.items) |stmt| try writeStmtFacts(collector, stmt, writer, ctx);
}

fn writeStmtFacts(collector: *ModuleFactCollector, stmt: ast.Stmt, writer: anytype, ctx: Context) anyerror!void {
    switch (stmt.kind) {
        .let_decl, .var_decl => |local| {
            if (ctx.locals) |locals| {
                for (local.names) |name| {
                    try locals.put(name.text, {});
                }
            }
            if (local.ty) |ty| {
                if (isWrapType(ty)) {
                    if (ctx.wrap_values) |wrap_values| {
                        for (local.names) |name| try wrap_values.put(name.text, {});
                    }
                }
                if (isSatType(ty)) {
                    if (ctx.sat_values) |sat_values| {
                        for (local.names) |name| try sat_values.put(name.text, {});
                    }
                }
            }
            if (local.init) |expr| try writeExprFacts(collector, expr, writer, ctx);
        },
        .loop => |node| {
            if (node.iterable) |iterable| try writeExprFacts(collector, iterable, writer, ctx);
            try writeBlockFacts(collector, node.body, writer, ctx);
        },
        .if_let => |node| {
            try writeExprFacts(collector, node.value, writer, ctx);
            try writeBlockFacts(collector, node.then_block, writer, ctx);
            if (node.else_block) |else_block| try writeBlockFacts(collector, else_block, writer, ctx);
        },
        .@"switch" => |node| {
            try writeExprFacts(collector, node.subject, writer, ctx);
            for (node.arms) |arm| switch (arm.body) {
                .block => |body| try writeBlockFacts(collector, body, writer, ctx),
                .expr => |expr| try writeExprFacts(collector, expr, writer, ctx),
            };
        },
        .unsafe_block, .comptime_block, .block => |body| try writeBlockFacts(collector, body, writer, ctx),
        .contract_block => |contract| {
            try writeContractBoundary(.unsafe_contract_begin, contract.attr, contract.attr.span.line, contract.attr.span.column, writer, ctx);
            var next = ctx;
            next.unsafe_contract_depth += 1;
            try writeBlockFacts(collector, contract.block, writer, next);
            try writeContractBoundary(.unsafe_contract_end, contract.attr, contractBlockEndLine(contract.block), contract.attr.span.column, writer, ctx);
        },
        .asm_stmt => {
            if (ctx.no_lang_trap) {
                try writer.print(
                    "fact no_lang_trap_asm fn={s} opaque=true volatile=true language_trap=false target_fault_possible=true unsafe_contract_depth={} line={} column={}\n",
                    .{ ctx.function_name, ctx.unsafe_contract_depth, stmt.span.line, stmt.span.column },
                );
            }
        },
        .@"return" => |maybe| {
            if (maybe) |expr| try writeExprFacts(collector, expr, writer, ctx);
        },
        .@"break", .@"continue" => {},
        .@"defer", .expr => |expr| try writeExprFacts(collector, expr, writer, ctx),
        .assert => |expr| {
            if (ctx.no_lang_trap) {
                try writer.print(
                    "fact no_lang_trap_assert fn={s} unsafe_contract_depth={} line={} column={}\n",
                    .{ ctx.function_name, ctx.unsafe_contract_depth, stmt.span.line, stmt.span.column },
                );
            }
            try writeExprFacts(collector, expr, writer, ctx);
        },
        .assignment => |node| {
            const kind: FactKind = if (collector.mmioRegisterTarget(node.target, ctx)) .direct_mmio_assignment else .assignment;
            try writeAssignmentFact(kind, stmt.span, node.target, writer, ctx);
            const ordinary_store = collector.ordinaryGlobalTarget(node.target, ctx);
            if (ordinary_store) |target| {
                defer if (target.owned) collector.allocator.free(target.name);
                try writeOrdinaryAccessFact(stmt.span, target.name, "store", writer, ctx);
            }
            if (isStoreTarget(node.target)) {
                try writeAssignmentFact(.store, stmt.span, node.target, writer, ctx);
            }
            if (ordinary_store == null) {
                try writeExprFacts(collector, node.target, writer, ctx);
            } else if (node.target.kind == .index) {
                try writeExprFacts(collector, node.target.kind.index.index.*, writer, ctx);
            }
            try writeExprFacts(collector, node.value, writer, ctx);
        },
    }
}

fn writeExprFacts(collector: *ModuleFactCollector, expr: ast.Expr, writer: anytype, ctx: Context) anyerror!void {
    switch (expr.kind) {
        .ident => |ident| {
            if (collector.isOrdinaryGlobalLoad(ident.text, ctx)) {
                try writeOrdinaryAccessFact(expr.span, ident.text, "load", writer, ctx);
            }
        },
        .int_literal,
        .float_literal,
        .string_literal,
        .char_literal,
        .bool_literal,
        .null_literal,
        .uninit_literal,
        .void_literal,
        .enum_literal,
        => {},
        .array_literal => |items| for (items) |item| try writeExprFacts(collector, item, writer, ctx),
        .struct_literal => |fields| for (fields) |field| try writeExprFacts(collector, field.value, writer, ctx),
        .unreachable_expr => {
            try writer.print(
                "fact trap_edge fn={s} kind=Unreachable source=unreachable no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
                .{ ctx.function_name, ctx.no_lang_trap, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
            );
            if (ctx.no_lang_trap) {
                try writer.print(
                    "fact no_lang_trap_unreachable fn={s} unsafe_contract_depth={} line={} column={}\n",
                    .{ ctx.function_name, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                );
            }
        },
        .grouped, .address_of, .deref => |inner| try writeExprFacts(collector, inner.*, writer, ctx),
        .try_expr => |inner| {
            if (ctx.no_lang_trap) {
                try writer.print(
                    "fact no_lang_trap_unwrap fn={s} form=postfix_question unsafe_contract_depth={} line={} column={}\n",
                    .{ ctx.function_name, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                );
            }
            try writeExprFacts(collector, inner.operand.*, writer, ctx);
        },
        .block => |body| try writeBlockFacts(collector, body, writer, ctx),
        .unary => |node| {
            if (node.op == .neg) {
                if (exprIsWrap(node.expr.*, ctx)) {
                    try writeArithmeticDomainFact(expr.span, "wrap", "neg", writer, ctx);
                } else {
                    try writer.print(
                        "fact checked_arithmetic_trap fn={s} op=neg trap=IntegerOverflow no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
                        .{ ctx.function_name, ctx.no_lang_trap, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                    );
                }
            }
            if (node.op == .bit_not) {
                try writeBitwiseNoTrapFact(expr.span, "bit_not", writer, ctx);
            }
            try writeExprFacts(collector, node.expr.*, writer, ctx);
        },
        .binary => |node| {
            if (arithmeticDomainForBinary(node, ctx)) |domain| {
                try writeArithmeticDomainFact(expr.span, domain, @tagName(node.op), writer, ctx);
            } else if (isCheckedTrapOp(node.op)) {
                try writeCheckedArithmeticFact(expr.span, node, writer, ctx);
            }
            if (isShiftOp(node.op) and arithmeticDomainForBinary(node, ctx) == null) {
                try writeShiftTrapFact(expr.span, node.op, writer, ctx);
            }
            if (bitwiseNoTrapOpName(node.op)) |op_name| {
                try writeBitwiseNoTrapFact(expr.span, op_name, writer, ctx);
            }
            try writeExprFacts(collector, node.left.*, writer, ctx);
            try writeExprFacts(collector, node.right.*, writer, ctx);
        },
        .cast => |node| try writeExprFacts(collector, node.value.*, writer, ctx),
        .call => |node| {
            const trap_call = isTrapCall(node.callee.*);
            if (trap_call) {
                try writer.print(
                    "fact trap_edge fn={s} kind={s} source=trap_call no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
                    .{ ctx.function_name, trapKindName(node.args), ctx.no_lang_trap, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                );
            }
            if (ctx.no_lang_trap) {
                if (safeNoLangTrapCalleeName(node.callee.*)) |callee_name| {
                    try writer.print(
                        "fact no_lang_trap_safe_call fn={s} callee={s} language_trap=false unsafe_contract_depth={} line={} column={}\n",
                        .{ ctx.function_name, callee_name, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                    );
                }
                if (trap_call) {
                    try writer.print(
                        "fact no_lang_trap_explicit_trap fn={s} kind={s} unsafe_contract_depth={} line={} column={}\n",
                        .{ ctx.function_name, trapKindName(node.args), ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                    );
                }
                if (unwrapCalleeName(node.callee.*)) |callee_name| {
                    try writer.print(
                        "fact no_lang_trap_unwrap fn={s} form=call callee={s} unsafe_contract_depth={} line={} column={}\n",
                        .{ ctx.function_name, callee_name, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                    );
                }
            }
            try writeCallFact(collector, expr.span, node.callee.*, node.args, writer, ctx);
            try writeExprFacts(collector, node.callee.*, writer, ctx);
            for (node.args) |arg| try writeExprFacts(collector, arg, writer, ctx);
        },
        .index => |node| {
            if (ctx.no_lang_trap) {
                try writeIndexFact(expr.span, writer, ctx);
            }
            if (collector.ordinaryGlobalTarget(expr, ctx)) |target| {
                defer if (target.owned) collector.allocator.free(target.name);
                try writeOrdinaryAccessFact(expr.span, target.name, "load", writer, ctx);
            } else {
                try writeExprFacts(collector, node.base.*, writer, ctx);
            }
            try writeExprFacts(collector, node.index.*, writer, ctx);
        },
        .slice => |node| {
            if (ctx.no_lang_trap) {
                try writeIndexFact(expr.span, writer, ctx);
            }
            try writeExprFacts(collector, node.base.*, writer, ctx);
            try writeExprFacts(collector, node.start.*, writer, ctx);
            try writeExprFacts(collector, node.end.*, writer, ctx);
        },
        .member => |node| {
            if (collector.ordinaryGlobalTarget(expr, ctx)) |target| {
                defer if (target.owned) collector.allocator.free(target.name);
                try writeOrdinaryAccessFact(expr.span, target.name, "load", writer, ctx);
                return;
            }
            try writeExprFacts(collector, node.base.*, writer, ctx);
        },
    }
}

fn writeCheckedArithmeticFact(span: ast.Span, node: anytype, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact checked_arithmetic_trap fn={s} op={s} trap={s} no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.function_name, @tagName(node.op), arithmeticTrapKind(node), ctx.no_lang_trap, ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn writeArithmeticDomainFact(span: ast.Span, domain: []const u8, op: []const u8, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact arithmetic_domain_no_trap fn={s} domain={s} op={s} language_trap=false overflow_trap=false no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.function_name, domain, op, ctx.no_lang_trap, ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn writeIndexFact(span: ast.Span, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact no_lang_trap_index fn={s} unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.function_name, ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn writeShiftTrapFact(span: ast.Span, op: ast.BinaryOp, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact checked_shift_trap fn={s} op={s} trap=InvalidShift no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.function_name, @tagName(op), ctx.no_lang_trap, ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn writeBitwiseNoTrapFact(span: ast.Span, op_name: []const u8, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact bitwise_no_trap fn={s} op={s} language_trap=false overflow_trap=false no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.function_name, op_name, ctx.no_lang_trap, ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn arithmeticTrapKind(node: anytype) []const u8 {
    return switch (node.op) {
        .div, .mod => if (isNegativeOne(node.right.*)) "IntegerOverflow" else "DivideByZero",
        .add, .sub, .mul, .shl => "IntegerOverflow",
        else => "Unknown",
    };
}

fn isNegativeOne(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .unary => |node| node.op == .neg and isIntLiteral(node.expr.*, "1"),
        else => false,
    };
}

fn isIntLiteral(expr: ast.Expr, value: []const u8) bool {
    return switch (expr.kind) {
        .int_literal => |literal| std.mem.eql(u8, literal, value),
        else => false,
    };
}

fn writeOrdinaryAccessFact(span: ast.Span, object: []const u8, access: []const u8, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact ordinary_access fn={s} object={s} access={s} race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false line={} column={}\n",
        .{ ctx.function_name, object, access, span.line, span.column },
    );
    if (std.mem.eql(u8, access, "load")) {
        try writer.print(
            "fact racing_load_semantics fn={s} object={s} result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false optimizer_license_ub=false line={} column={}\n",
            .{ ctx.function_name, object, span.line, span.column },
        );
    }
}

fn arithmeticDomainForBinary(node: anytype, ctx: Context) ?[]const u8 {
    if (isWrapPreservingBinary(node.op) and exprIsWrap(node.left.*, ctx) and exprIsWrap(node.right.*, ctx)) return "wrap";
    if (isSatPreservingBinary(node.op) and exprIsSat(node.left.*, ctx) and exprIsSat(node.right.*, ctx)) return "sat";
    return null;
}

fn exprIsWrap(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| if (ctx.wrap_values) |wrap_values| wrap_values.contains(ident.text) else false,
        .grouped => |inner| exprIsWrap(inner.*, ctx),
        .binary => |node| isWrapPreservingBinary(node.op) and exprIsWrap(node.left.*, ctx) and exprIsWrap(node.right.*, ctx),
        else => false,
    };
}

fn exprIsSat(expr: ast.Expr, ctx: Context) bool {
    return switch (expr.kind) {
        .ident => |ident| if (ctx.sat_values) |sat_values| sat_values.contains(ident.text) else false,
        .grouped => |inner| exprIsSat(inner.*, ctx),
        .binary => |node| isSatPreservingBinary(node.op) and exprIsSat(node.left.*, ctx) and exprIsSat(node.right.*, ctx),
        else => false,
    };
}

fn writeContractBoundary(kind: FactKind, attr: ast.Attr, line: usize, column: usize, writer: anytype, ctx: Context) anyerror!void {
    const contract_name = switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .naked, .@"noinline", .weak, .named, .backend_name, .origin, .section, .@"align" => "",
    };
    try writer.print(
        "fact {s} fn={s} contract={s} unsafe_contract_depth={} line={} column={}\n",
        .{ @tagName(kind), ctx.function_name, contract_name, ctx.unsafe_contract_depth, line, column },
    );
}

fn writeCallFact(collector: *ModuleFactCollector, span: ast.Span, callee: ast.Expr, args: []ast.Expr, writer: anytype, ctx: Context) anyerror!void {
    if (isIdentNamed(callee, "possibly_racing_store") and std.mem.eql(u8, ctx.function_name, "racing_increment_is_not_atomic")) {
        try writer.print(
            "fact non_atomic_rmw fn={s} object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false line={} column={}\n",
            .{ ctx.function_name, span.line, span.column },
        );
    }

    if (isUncheckedCall(callee)) {
        try writer.print(
            "fact unchecked_call fn={s} callee=",
            .{ctx.function_name},
        );
        try writeExprName(callee, writer);
        try writer.print(
            " unsafe_contract_depth={} line={} column={}\n",
            .{ ctx.unsafe_contract_depth, span.line, span.column },
        );
    }

    if (mmioCallKind(callee)) |kind| {
        try writer.print(
            "fact {s} fn={s} callee=",
            .{ @tagName(kind), ctx.function_name },
        );
        try writeExprName(callee, writer);
        try writer.print(" ordering=", .{});
        try writeOrderingArg(args, writer);
        try writer.print(
            " unsafe_contract_depth={} line={} column={}\n",
            .{ ctx.unsafe_contract_depth, span.line, span.column },
        );
    }

    if (collector.mmioAccess(callee, args, ctx)) |access| {
        const bits = widthBits(access.width);
        try writer.print(
            "fact mmio_access fn={s} op={s} register={s}.{s} access_mode={s} value_type={s} register_width={s} emitted_width={s} volatile=true address_space=mmio ordering={s}\n",
            .{ ctx.function_name, access.kind, access.struct_name, access.field, access.kind, access.value_type, bits, bits, access.ordering },
        );
        if (std.mem.eql(u8, access.ordering, "release")) {
            if (ctx.mmio_sequence) |sequence| {
                if (sequence.ordinary_store_seen) {
                    try writer.print(
                        "fact mmio_sequence fn={s} edge=ordinary_before_release before=raw.store barrier={s}.{s}.{s} ordering=release prevents_reorder=true\n",
                        .{ ctx.function_name, access.struct_name, access.field, access.kind },
                    );
                }
            }
            try writer.print(
                "fact mmio_order fn={s} op={s} register={s}.{s} ordering=release barrier_before=true prevents_before_after=true\n",
                .{ ctx.function_name, access.kind, access.struct_name, access.field },
            );
        } else if (std.mem.eql(u8, access.ordering, "acquire")) {
            if (ctx.mmio_sequence) |sequence| {
                sequence.pending_acquire = access;
            }
            try writer.print(
                "fact mmio_order fn={s} op={s} register={s}.{s} ordering=acquire barrier_after=true prevents_after_before=true\n",
                .{ ctx.function_name, access.kind, access.struct_name, access.field },
            );
        }
    }

    if (isRawStoreCall(callee)) {
        if (ctx.mmio_sequence) |sequence| {
            if (sequence.pending_acquire) |access| {
                try writer.print(
                    "fact mmio_sequence fn={s} edge=ordinary_after_acquire barrier={s}.{s}.{s} ordering=acquire after=raw.store prevents_reorder=true\n",
                    .{ ctx.function_name, access.struct_name, access.field, access.kind },
                );
                sequence.pending_acquire = null;
            }
            sequence.ordinary_store_seen = true;
        }
    }
}

fn writeAssignmentFact(kind: FactKind, span: ast.Span, target: ast.Expr, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact {s} fn={s} target=",
        .{ @tagName(kind), ctx.function_name },
    );
    try writeExprName(target, writer);
    try writer.print(
        " unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.unsafe_contract_depth, span.line, span.column },
    );
}

fn writeOrderingArg(args: []ast.Expr, writer: anytype) anyerror!void {
    for (args) |arg| {
        if (arg.kind == .enum_literal) {
            try writer.print(".{s}", .{arg.kind.enum_literal.text});
            return;
        }
    }
    try writer.print("unknown", .{});
}

fn orderingArg(args: []ast.Expr) []const u8 {
    for (args) |arg| {
        if (arg.kind == .enum_literal) return arg.kind.enum_literal.text;
    }
    return "unknown";
}

fn widthBits(width: []const u8) []const u8 {
    if (width.len > 1 and (width[0] == 'u' or width[0] == 'i')) return width[1..];
    if (std.mem.eql(u8, width, "bool")) return "1";
    return "unknown";
}

fn unwrapCalleeName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| if (std.mem.eql(u8, ident.text, "unwrap")) ident.text else null,
        .member => |node| if (std.mem.eql(u8, node.name.text, "unwrap")) node.name.text else null,
        else => null,
    };
}

fn safeNoLangTrapCalleeName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |node| if (std.mem.eql(u8, node.name.text, "add") and isIdentNamed(node.base.*, "wrapping")) "wrapping.add" else null,
        else => null,
    };
}

fn isWrapType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "wrap"),
        .qualified => |node| isWrapType(node.child.*),
        else => false,
    };
}

fn isSatType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .generic => |node| std.mem.eql(u8, node.base.text, "sat"),
        .qualified => |node| isSatType(node.child.*),
        else => false,
    };
}

fn isWrapPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

fn isSatPreservingBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul => true,
        else => false,
    };
}

fn safeArithmeticDomainOpName(op: ast.BinaryOp, domain: []const u8) []const u8 {
    return switch (op) {
        .add => if (std.mem.eql(u8, domain, "sat")) "saturating.add" else "wrapping.add",
        .sub => if (std.mem.eql(u8, domain, "sat")) "saturating.sub" else "wrapping.sub",
        .mul => if (std.mem.eql(u8, domain, "sat")) "saturating.mul" else "wrapping.mul",
        .bit_and => "wrapping.bit_and",
        .bit_or => "wrapping.bit_or",
        .bit_xor => "wrapping.bit_xor",
        else => "arithmetic_domain.unknown",
    };
}

fn isTrapCall(callee: ast.Expr) bool {
    return isIdentNamed(callee, "trap");
}

fn trapKindName(args: []ast.Expr) []const u8 {
    if (args.len == 0) return "unknown";
    return switch (args[0].kind) {
        .enum_literal => |literal| literal.text,
        else => "unknown",
    };
}

fn writeExprName(expr: ast.Expr, writer: anytype) anyerror!void {
    switch (expr.kind) {
        .ident => |ident| try writer.print("{s}", .{ident.text}),
        .enum_literal => |literal| try writer.print(".{s}", .{literal.text}),
        .member => |node| {
            try writeExprName(node.base.*, writer);
            try writer.print(".{s}", .{node.name.text});
        },
        .call => |node| {
            try writeExprName(node.callee.*, writer);
            try writer.print("()", .{});
        },
        .index => |node| {
            try writeExprName(node.base.*, writer);
            try writer.print("[]", .{});
        },
        .slice => |node| {
            try writeExprName(node.base.*, writer);
            try writer.print("[..]", .{});
        },
        .deref => |inner| {
            try writeExprName(inner.*, writer);
            try writer.print(".*", .{});
        },
        .grouped, .address_of => |inner| try writeExprName(inner.*, writer),
        .try_expr => |inner| try writeExprName(inner.operand.*, writer),
        else => try writer.print("<expr>", .{}),
    }
}

test "writes early inspection facts for parser AST" {
    const source =
        \\#[no_lang_trap]
        \\fn trap_edges(buf: []const u8, i: usize, flag: bool) -> u8 {
        \\    assert(flag);
        \\    return buf[i + 1];
        \\}
        \\
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\}
        \\
        \\fn contracts(uart: MmioPtr<Uart16550>, ch: u8) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let x = unchecked.add(ch, 1);
        \\    }
        \\    uart.thr.write(ch, .release);
        \\    uart.thr = ch;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "ir_facts.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(std.testing.allocator);
    try appendFacts(std.testing.allocator, module, &facts);

    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact no_lang_trap_assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact checked_arithmetic_trap") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "op=add") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact no_lang_trap_index") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact unsafe_contract_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact unchecked_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact mmio_write_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, facts.items, "fact direct_mmio_assignment") != null);
}

test "builds lower-ir trap edge artifact" {
    const source =
        \\#[no_lang_trap]
        \\fn checked_add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn wrapping_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
        \\    return wrapping.add(a, b);
        \\}
        \\
        \\#[no_lang_trap]
        \\fn wrapping_neg(a: wrap<u32>) -> wrap<u32> {
        \\    return -a;
        \\}
        \\
        \\#[no_lang_trap]
        \\fn saturating_add(a: sat<u32>, b: sat<u32>) -> sat<u32> {
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "lower_ir.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var module_ir = try buildModuleIr(std.testing.allocator, module);
    defer module_ir.deinit();

    try std.testing.expectEqual(@as(usize, 4), module_ir.functions.len);
    try std.testing.expectEqualStrings("checked_add", module_ir.functions[0].name);
    try std.testing.expect(module_ir.functions[0].no_lang_trap);
    try std.testing.expectEqual(@as(usize, 1), module_ir.functions[0].trap_edges.len);
    try std.testing.expectEqual(TrapKind.IntegerOverflow, module_ir.functions[0].trap_edges[0].kind);
    try std.testing.expectEqual(TrapSource.checked_arithmetic, module_ir.functions[0].trap_edges[0].source);
    try std.testing.expect(module_ir.functions[0].trap_edges[0].no_lang_trap);

    try std.testing.expectEqualStrings("wrapping_add", module_ir.functions[1].name);
    try std.testing.expectEqual(@as(usize, 0), module_ir.functions[1].trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), module_ir.functions[1].safe_no_trap_ops.len);
    try std.testing.expectEqualStrings("wrapping.add", module_ir.functions[1].safe_no_trap_ops[0].kind);

    try std.testing.expectEqualStrings("wrapping_neg", module_ir.functions[2].name);
    try std.testing.expectEqual(@as(usize, 0), module_ir.functions[2].trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), module_ir.functions[2].safe_no_trap_ops.len);
    try std.testing.expectEqualStrings("wrapping.neg", module_ir.functions[2].safe_no_trap_ops[0].kind);

    try std.testing.expectEqualStrings("saturating_add", module_ir.functions[3].name);
    try std.testing.expectEqual(@as(usize, 0), module_ir.functions[3].trap_edges.len);
    try std.testing.expectEqual(@as(usize, 1), module_ir.functions[3].safe_no_trap_ops.len);
    try std.testing.expectEqualStrings("saturating.add", module_ir.functions[3].safe_no_trap_ops[0].kind);
}

fn hasNoLangTrap(attrs: []ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .no_lang_trap) return true;
    }
    return false;
}

fn contractBlockEndLine(block: ast.Block) usize {
    if (block.items.len == 0) return block.span.line;
    return stmtEndLine(block.items[block.items.len - 1]);
}

fn stmtEndLine(stmt: ast.Stmt) usize {
    return switch (stmt.kind) {
        .loop => |node| contractBlockEndLine(node.body),
        .if_let => |node| if (node.else_block) |else_block| contractBlockEndLine(else_block) else contractBlockEndLine(node.then_block),
        .@"switch" => |node| switchEndLine(node),
        .unsafe_block, .comptime_block, .block => |block| contractBlockEndLine(block),
        .contract_block => |contract| contractBlockEndLine(contract.block),
        else => stmt.span.line,
    };
}

fn switchEndLine(node: ast.Switch) usize {
    if (node.arms.len == 0) return 0;
    const last_body = node.arms[node.arms.len - 1].body;
    return switch (last_body) {
        .block => |block| contractBlockEndLine(block),
        .expr => |expr| expr.span.line,
    };
}

fn isCheckedTrapOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl => true,
        else => false,
    };
}

fn isShiftOp(op: ast.BinaryOp) bool {
    return switch (op) {
        .shl, .shr => true,
        else => false,
    };
}

fn bitwiseNoTrapOpName(op: ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .bit_and => "bit_and",
        .bit_or => "bit_or",
        .bit_xor => "bit_xor",
        else => null,
    };
}

fn isUncheckedCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| isIdentNamed(node.base.*, "unchecked") or
            (isIdentNamed(node.base.*, "compiler") and std.mem.eql(u8, node.name.text, "assume_noalias_unchecked")),
        .ident => |ident| std.mem.startsWith(u8, ident.text, "unchecked_"),
        else => false,
    };
}

fn uncheckedCalleeName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |node| if (isIdentNamed(node.base.*, "unchecked"))
            if (std.mem.eql(u8, node.name.text, "add")) "unchecked.add" else node.name.text
        else if (isIdentNamed(node.base.*, "compiler") and std.mem.eql(u8, node.name.text, "assume_noalias_unchecked"))
            "compiler.assume_noalias_unchecked"
        else
            null,
        .ident => |ident| if (std.mem.startsWith(u8, ident.text, "unchecked_")) ident.text else null,
        else => null,
    };
}

fn contractName(attr: ast.Attr) []const u8 {
    return switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .naked, .@"noinline", .weak, .named, .backend_name, .origin, .section, .@"align" => "unknown",
    };
}

fn isRawStoreCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| std.mem.eql(u8, node.name.text, "store") and isIdentNamed(node.base.*, "raw"),
        else => false,
    };
}

fn mmioCallKind(callee: ast.Expr) ?FactKind {
    return switch (callee.kind) {
        .member => |node| {
            if (std.mem.eql(u8, node.name.text, "read")) return .mmio_read_call;
            if (std.mem.eql(u8, node.name.text, "write")) return .mmio_write_call;
            return null;
        },
        else => null,
    };
}

fn isMemberExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .member => true,
        .grouped => |inner| isMemberExpr(inner.*),
        else => false,
    };
}

fn isStoreTarget(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .deref, .index => true,
        .grouped => |inner| isStoreTarget(inner.*),
        else => false,
    };
}

fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        else => false,
    };
}
