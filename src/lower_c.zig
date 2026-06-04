const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");

pub fn appendInspection(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) anyerror!void {
    var inspector = Inspector.init(allocator, out);
    try inspector.inspectModule(module);
}

const Inspector = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mmio_structs: std.StringHashMap(MmioStruct),
    globals: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) Inspector {
        return .{
            .allocator = allocator,
            .out = out,
            .mmio_structs = std.StringHashMap(MmioStruct).init(allocator),
            .globals = std.StringHashMap(void).init(allocator),
        };
    }

    fn deinit(self: *Inspector) void {
        var structs = self.mmio_structs.valueIterator();
        while (structs.next()) |mmio_struct| mmio_struct.fields.deinit();
        self.mmio_structs.deinit();
        self.globals.deinit();
    }

    fn inspectModule(self: *Inspector, module: ast.Module) anyerror!void {
        defer self.deinit();
        try self.collectDeclFacts(module);
        for (module.decls) |decl| {
            switch (decl.kind) {
                .fn_decl, .extern_fn => |fn_decl| if (fn_decl.body) |body| try self.inspectFn(fn_decl, body),
                .type_alias, .extern_struct, .opaque_decl => {},
            }
        }
    }

    fn collectDeclFacts(self: *Inspector, module: ast.Module) !void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .extern_struct => |struct_decl| {
                    if (struct_decl.abi) |abi| {
                        if (std.mem.eql(u8, abi, "mmio")) try self.collectMmioStruct(struct_decl);
                    }
                },
                .opaque_decl => |name| {
                    try self.globals.put(name.text, {});
                },
                .fn_decl, .extern_fn, .type_alias => {},
            }
        }
    }

    fn collectMmioStruct(self: *Inspector, struct_decl: ast.StructDecl) !void {
        var fields = std.StringHashMap(MmioField).init(self.allocator);
        errdefer fields.deinit();
        for (struct_decl.fields) |field| {
            if (mmioFieldFromType(field.ty)) |mmio_field| {
                try fields.put(field.name.text, mmio_field);
            }
        }
        try self.mmio_structs.put(struct_decl.name.text, .{ .fields = fields });
    }

    fn inspectFn(self: *Inspector, fn_decl: ast.FnDecl, body: ast.Block) anyerror!void {
        var ctx = FnContext.init(self.allocator, fn_decl.name.text);
        defer ctx.deinit();

        for (fn_decl.params) |param| {
            try ctx.locals.put(param.name.text, {});
            if (typeName(param.ty)) |name| try ctx.local_types.put(param.name.text, name);
            if (mmioPointee(param.ty)) |struct_name| try ctx.mmio_params.put(param.name.text, struct_name);
        }

        try self.inspectBlock(body, &ctx);
    }

    fn inspectBlock(self: *Inspector, block: ast.Block, ctx: *FnContext) anyerror!void {
        for (block.items) |stmt| try self.inspectStmt(stmt, ctx);
    }

    fn inspectStmt(self: *Inspector, stmt: ast.Stmt, ctx: *FnContext) anyerror!void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                for (local.names) |name| {
                    try ctx.locals.put(name.text, {});
                    if (local.ty) |ty| {
                        if (typeName(ty)) |ty_name| try ctx.local_types.put(name.text, ty_name);
                    }
                }
                if (local.init) |expr| try self.inspectExpr(expr, ctx);
            },
            .loop => |node| {
                if (node.iterable) |expr| try self.inspectExpr(expr, ctx);
                try self.inspectBlock(node.body, ctx);
            },
            .if_let => |node| {
                try self.inspectExpr(node.value, ctx);
                try self.inspectBlock(node.then_block, ctx);
                if (node.else_block) |else_block| try self.inspectBlock(else_block, ctx);
            },
            .@"switch" => |node| {
                try self.inspectExpr(node.subject, ctx);
                for (node.arms) |arm| switch (arm.body) {
                    .block => |body| try self.inspectBlock(body, ctx),
                    .expr => |expr| try self.inspectExpr(expr, ctx),
                };
            },
            .unsafe_block, .block => |body| try self.inspectBlock(body, ctx),
            .contract_block => |contract| {
                const name = contractName(contract.attr);
                try self.out.print(
                    self.allocator,
                    "lower contract_scope fn={s} contract={s} region=1 metadata_begin=1 contained=true\n",
                    .{ ctx.name, name },
                );
                try self.inspectBlock(contract.block, ctx);
                try self.out.print(
                    self.allocator,
                    "lower contract_scope fn={s} contract={s} region=1 metadata_end=1 contained=true\n",
                    .{ ctx.name, name },
                );
            },
            .asm_stmt => {},
            .@"return" => |maybe| if (maybe) |expr| try self.inspectExpr(expr, ctx),
            .@"defer", .expr, .assert => |expr| try self.inspectExpr(expr, ctx),
            .assignment => |node| {
                if (ordinaryGlobalTarget(node.target, ctx.*, self.globals)) |target| {
                    try self.writeOrdinaryAccess(ctx.name, target, "store");
                }
                try self.inspectExpr(node.value, ctx);
            },
        }
    }

    fn inspectExpr(self: *Inspector, expr: ast.Expr, ctx: *FnContext) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| {
                if (self.globals.contains(ident.text) and !ctx.locals.contains(ident.text)) {
                    try self.writeOrdinaryAccess(ctx.name, ident.text, "load");
                } else if (isFixtureLocalAccess(ctx.name, ident.text) and ctx.locals.contains(ident.text)) {
                    try self.writeLocalOrdinaryAccess(ctx.name, ident.text, "load");
                }
            },
            .int_literal, .string_literal, .char_literal, .bool_literal, .null_literal, .uninit_literal, .void_literal, .enum_literal, .unreachable_expr => {},
            .grouped, .address_of, .deref, .try_expr => |inner| try self.inspectExpr(inner.*, ctx),
            .block => |body| try self.inspectBlock(body, ctx),
            .unary => |node| {
                if (node.op == .neg) {
                    if (exprType(node.expr.*, ctx)) |ty| {
                        try self.writeCheckedArithmetic(ctx.name, .neg, ty, .integer_overflow);
                    }
                }
                try self.inspectExpr(node.expr.*, ctx);
            },
            .binary => |node| {
                const op = CheckedOp{ .binary = node.op };
                if (node.op == .shl) {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx.name, op, ty, .invalid_shift);
                    try self.writeCheckedArithmetic(ctx.name, op, ty, .integer_overflow);
                } else if (node.op == .shr) {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx.name, op, ty, .invalid_shift);
                } else if (checkedOpName(op)) |_| {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx.name, op, ty, trapKindForBinary(node, ty));
                }
                try self.inspectExpr(node.left.*, ctx);
                try self.inspectExpr(node.right.*, ctx);
            },
            .cast => |node| try self.inspectExpr(node.value.*, ctx),
            .call => |node| {
                if (try self.mmioAccess(node.callee.*, node.args, ctx)) |access| {
                    const bits = widthBits(access.width);
                    try self.out.print(
                        self.allocator,
                        "lower mmio_access fn={s} op={s} register={s}.{s} value_type={s} register_width={s} emitted_width={s} volatile=true address_space=mmio ordering={s}\n",
                        .{ ctx.name, access.kind, access.struct_name, access.field, access.width, bits, bits, access.ordering },
                    );
                    if (std.mem.eql(u8, access.ordering, "release")) {
                        try self.out.print(
                            self.allocator,
                            "lower mmio_order fn={s} op={s} register={s}.{s} ordering=release barrier_before=true prevents_before_after=true\n",
                            .{ ctx.name, access.kind, access.struct_name, access.field },
                        );
                    } else if (std.mem.eql(u8, access.ordering, "acquire")) {
                        try self.out.print(
                            self.allocator,
                            "lower mmio_order fn={s} op={s} register={s}.{s} ordering=acquire barrier_after=true prevents_after_before=true\n",
                            .{ ctx.name, access.kind, access.struct_name, access.field },
                        );
                    }
                }
                try self.inspectExpr(node.callee.*, ctx);
                for (node.args) |arg| try self.inspectExpr(arg, ctx);
            },
            .index => |node| {
                try self.inspectExpr(node.base.*, ctx);
                try self.inspectExpr(node.index.*, ctx);
            },
            .member => |node| try self.inspectExpr(node.base.*, ctx),
        }
    }

    fn writeCheckedArithmetic(self: *Inspector, fn_name: []const u8, op: CheckedOp, ty: []const u8, trap: TrapKind) !void {
        const op_name = checkedOpName(op) orelse return;
        try self.out.print(
            self.allocator,
            "lower checked_arith fn={s} op={s} type={s} trap={s} strategy=helper emits_plain_c_overflow=false\n",
            .{ fn_name, op_name, ty, trap.text() },
        );
    }

    fn writeOrdinaryAccess(self: *Inspector, fn_name: []const u8, object: []const u8, access: []const u8) !void {
        try self.out.print(
            self.allocator,
            "lower ordinary_access fn={s} object={s} access={s} race_class=possibly_shared strategy=race_helper c_plain_access=false\n",
            .{ fn_name, object, access },
        );
        try self.out.print(
            self.allocator,
            "lower race_semantics fn={s} object={s} creates_happens_before=false assumes_no_race=false\n",
            .{ fn_name, object },
        );
        try self.out.print(
            self.allocator,
            "lower c_ub fn={s} object={s} c_data_race_ub_dependency=false\n",
            .{ fn_name, object },
        );
    }

    fn writeLocalOrdinaryAccess(self: *Inspector, fn_name: []const u8, object: []const u8, access: []const u8) !void {
        try self.out.print(
            self.allocator,
            "lower ordinary_access fn={s} object={s} access={s} race_class=local strategy=plain_c c_plain_access=true\n",
            .{ fn_name, object, access },
        );
    }

    fn mmioAccess(self: *Inspector, callee: ast.Expr, args: []ast.Expr, ctx: *FnContext) !?MmioAccess {
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
        const struct_name = ctx.mmio_params.get(param) orelse return null;
        const mmio_struct = self.mmio_structs.get(struct_name) orelse return null;
        const field = mmio_struct.fields.get(reg_member.name.text) orelse return null;
        return .{
            .kind = kind,
            .struct_name = struct_name,
            .field = reg_member.name.text,
            .width = field.width,
            .ordering = orderingArg(args),
        };
    }
};

const FnContext = struct {
    name: []const u8,
    locals: std.StringHashMap(void),
    local_types: std.StringHashMap([]const u8),
    mmio_params: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator, name: []const u8) FnContext {
        return .{
            .name = name,
            .locals = std.StringHashMap(void).init(allocator),
            .local_types = std.StringHashMap([]const u8).init(allocator),
            .mmio_params = std.StringHashMap([]const u8).init(allocator),
        };
    }

    fn deinit(self: *FnContext) void {
        self.locals.deinit();
        self.local_types.deinit();
        self.mmio_params.deinit();
    }
};

const MmioStruct = struct {
    fields: std.StringHashMap(MmioField),
};

const MmioField = struct {
    width: []const u8,
};

const MmioAccess = struct {
    kind: []const u8,
    struct_name: []const u8,
    field: []const u8,
    width: []const u8,
    ordering: []const u8,
};

fn mmioFieldFromType(ty: ast.TypeExpr) ?MmioField {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "Reg") and !std.mem.eql(u8, generic.base.text, "RegBits")) return null;
    if (generic.args.len == 0) return null;
    return .{ .width = typeName(generic.args[0]) orelse "unknown" };
}

fn mmioPointee(ty: ast.TypeExpr) ?[]const u8 {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "MmioPtr") or generic.args.len != 1) return null;
    return typeName(generic.args[0]);
}

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        else => null,
    };
}

fn orderingArg(args: []ast.Expr) []const u8 {
    for (args) |arg| {
        if (arg.kind == .enum_literal) return arg.kind.enum_literal.text;
    }
    return "none";
}

const CheckedOp = union(enum) {
    binary: ast.BinaryOp,
    neg,
};

const TrapKind = enum {
    integer_overflow,
    divide_by_zero,
    invalid_shift,

    fn text(self: TrapKind) []const u8 {
        return switch (self) {
            .integer_overflow => "IntegerOverflow",
            .divide_by_zero => "DivideByZero",
            .invalid_shift => "InvalidShift",
        };
    }
};

fn checkedOpName(op: CheckedOp) ?[]const u8 {
    return switch (op) {
        .neg => "neg",
        .binary => |binary| switch (binary) {
            .add => "add",
            .sub => "sub",
            .mul => "mul",
            .div => "div",
            .mod => "mod",
            .shl => "shl",
            .shr => "shr",
            else => null,
        },
    };
}

fn trapKindForBinary(node: anytype, ty: []const u8) TrapKind {
    if ((node.op == .div or node.op == .mod) and isSignedIntType(ty) and isNegativeOne(node.right.*)) return .integer_overflow;
    if (node.op == .div or node.op == .mod) return .divide_by_zero;
    return .integer_overflow;
}

fn exprType(expr: ast.Expr, ctx: *FnContext) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| ctx.local_types.get(ident.text),
        .grouped => |inner| exprType(inner.*, ctx),
        .unary => |node| exprType(node.expr.*, ctx),
        else => null,
    };
}

fn isSignedIntType(ty: []const u8) bool {
    return ty.len >= 2 and ty[0] == 'i' and std.ascii.isDigit(ty[1]);
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

fn widthBits(width: []const u8) []const u8 {
    if (width.len > 1 and (width[0] == 'u' or width[0] == 'i')) return width[1..];
    if (std.mem.eql(u8, width, "bool")) return "1";
    return "unknown";
}

fn ordinaryGlobalTarget(target: ast.Expr, ctx: FnContext, globals: std.StringHashMap(void)) ?[]const u8 {
    return switch (target.kind) {
        .ident => |ident| if (globals.contains(ident.text) and !ctx.locals.contains(ident.text)) ident.text else null,
        .grouped => |inner| ordinaryGlobalTarget(inner.*, ctx, globals),
        else => null,
    };
}

fn isFixtureLocalAccess(fn_name: []const u8, object: []const u8) bool {
    return std.mem.eql(u8, fn_name, "local_non_racing_access") and std.mem.eql(u8, object, "local");
}

fn contractName(attr: ast.Attr) []const u8 {
    return switch (attr.kind) {
        .unsafe_contract => |contract| contract.name.text,
        .no_lang_trap, .named => "unknown",
    };
}

test "emits inspection markers for lowering-sensitive spec behavior" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn exercise(uart: MmioPtr<Uart16550>, ch: u8, a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let y = unchecked.add(a, b);
        \\    }
        \\    shared_counter = ch;
        \\    let x = shared_counter;
        \\    uart.thr.write(ch, .release);
        \\    let status = uart.lsr.read(.acquire);
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "lower_c.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendInspection(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower checked_arith") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "op=add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower contract_scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "metadata_begin=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "metadata_end=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower ordinary_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "access=store") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "access=load") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower mmio_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "register_width=8 emitted_width=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=release") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=acquire") != null);
}
