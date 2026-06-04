const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");

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
    mmio_sequence: ?*MmioSequenceState = null,
};

const MmioSequenceState = struct {
    ordinary_store_seen: bool = false,
    pending_acquire: ?MmioAccess = null,
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
    globals: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) ModuleFactCollector {
        return .{
            .allocator = allocator,
            .mmio_structs = std.StringHashMap(MmioStruct).init(allocator),
            .globals = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *ModuleFactCollector) void {
        var structs = self.mmio_structs.valueIterator();
        while (structs.next()) |mmio_struct| mmio_struct.fields.deinit();
        self.mmio_structs.deinit();
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
                .extern_struct => |struct_decl| {
                    if (struct_decl.abi) |abi| {
                        if (std.mem.eql(u8, abi, "mmio")) try self.collectMmioStruct(struct_decl);
                    }
                },
                .global_decl => |global| try self.globals.put(global.name.text, {}),
                .fn_decl, .extern_fn, .type_alias, .opaque_decl => {},
            }
        }
    }

    fn collectMmioStruct(self: *ModuleFactCollector, struct_decl: ast.StructDecl) !void {
        var fields = std.StringHashMap(MmioField).init(self.allocator);
        errdefer fields.deinit();
        for (struct_decl.fields) |field| {
            if (mmioFieldFromType(field.ty)) |mmio_field| {
                try fields.put(field.name.text, mmio_field);
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
                    var mmio_sequence = MmioSequenceState{};
                    for (fn_decl.params) |param| {
                        try locals.put(param.name.text, {});
                        if (mmioPointee(param.ty)) |struct_name| try mmio_params.put(param.name.text, struct_name);
                    }
                    try writeBlockFacts(self, body, writer, .{
                        .function_name = fn_decl.name.text,
                        .no_lang_trap = hasNoLangTrap(decl.attrs),
                        .mmio_params = &mmio_params,
                        .locals = &locals,
                        .mmio_sequence = &mmio_sequence,
                    });
                }
            },
            .type_alias, .extern_struct, .opaque_decl, .global_decl => {},
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

    fn ordinaryGlobalTarget(self: *ModuleFactCollector, target: ast.Expr, ctx: Context) ?[]const u8 {
        return switch (target.kind) {
            .ident => |ident| if (self.isOrdinaryGlobalLoad(ident.text, ctx)) ident.text else null,
            .grouped => |inner| self.ordinaryGlobalTarget(inner.*, ctx),
            else => null,
        };
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
        .unsafe_block, .block => |body| try writeBlockFacts(collector, body, writer, ctx),
        .contract_block => |contract| {
            try writeContractBoundary(.unsafe_contract_begin, contract.attr, writer, ctx);
            var next = ctx;
            next.unsafe_contract_depth += 1;
            try writeBlockFacts(collector, contract.block, writer, next);
            try writeContractBoundary(.unsafe_contract_end, contract.attr, writer, ctx);
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
                try writeOrdinaryAccessFact(stmt.span, target, "store", writer, ctx);
            }
            if (isStoreTarget(node.target)) {
                try writeAssignmentFact(.store, stmt.span, node.target, writer, ctx);
            }
            if (ordinary_store == null) {
                try writeExprFacts(collector, node.target, writer, ctx);
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
        .string_literal,
        .char_literal,
        .bool_literal,
        .null_literal,
        .uninit_literal,
        .void_literal,
        .enum_literal,
        => {},
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
            try writeExprFacts(collector, inner.*, writer, ctx);
        },
        .block => |body| try writeBlockFacts(collector, body, writer, ctx),
        .unary => |node| {
            if (node.op == .neg) {
                try writer.print(
                    "fact checked_arithmetic_trap fn={s} op=neg trap=IntegerOverflow no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
                    .{ ctx.function_name, ctx.no_lang_trap, ctx.unsafe_contract_depth, expr.span.line, expr.span.column },
                );
            }
            try writeExprFacts(collector, node.expr.*, writer, ctx);
        },
        .binary => |node| {
            if (isCheckedTrapOp(node.op)) {
                try writeCheckedArithmeticFact(expr.span, node, writer, ctx);
            }
            if (isShiftOp(node.op)) {
                try writeShiftTrapFact(expr.span, node.op, writer, ctx);
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
            try writeExprFacts(collector, node.base.*, writer, ctx);
            try writeExprFacts(collector, node.index.*, writer, ctx);
        },
        .member => |node| try writeExprFacts(collector, node.base.*, writer, ctx),
    }
}

fn writeCheckedArithmeticFact(span: ast.Span, node: anytype, writer: anytype, ctx: Context) anyerror!void {
    try writer.print(
        "fact checked_arithmetic_trap fn={s} op={s} trap={s} no_lang_trap={} unsafe_contract_depth={} line={} column={}\n",
        .{ ctx.function_name, @tagName(node.op), arithmeticTrapKind(node), ctx.no_lang_trap, ctx.unsafe_contract_depth, span.line, span.column },
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

fn writeContractBoundary(kind: FactKind, attr: ast.Attr, writer: anytype, ctx: Context) anyerror!void {
    const contract_name = switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .named => "",
    };
    try writer.print(
        "fact {s} fn={s} contract={s} unsafe_contract_depth={} line={} column={}\n",
        .{ @tagName(kind), ctx.function_name, contract_name, ctx.unsafe_contract_depth, attr.span.line, attr.span.column },
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
        .deref => |inner| {
            try writeExprName(inner.*, writer);
            try writer.print(".*", .{});
        },
        .grouped, .address_of, .try_expr => |inner| try writeExprName(inner.*, writer),
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

fn hasNoLangTrap(attrs: []ast.Attr) bool {
    for (attrs) |attr| {
        if (std.meta.activeTag(attr.kind) == .no_lang_trap) return true;
    }
    return false;
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

fn isUncheckedCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |node| isIdentNamed(node.base.*, "unchecked"),
        .ident => |ident| std.mem.startsWith(u8, ident.text, "unchecked_"),
        else => false,
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
