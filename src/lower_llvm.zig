const std = @import("std");

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const mir = @import("mir.zig");

pub fn appendLlvm(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    try appendLlvmWithSourcePath(allocator, module, out, "input.mc");
}

pub fn appendLlvmWithSourcePath(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), source_path: []const u8) !void {
    var module_mir = try mir.build(allocator, module);
    defer module_mir.deinit();

    const escaped_source_path = try escapedLlvmString(allocator, source_path);
    defer allocator.free(escaped_source_path);
    try out.print(allocator, "source_filename = \"{s}\"\n", .{escaped_source_path});
    try out.appendSlice(allocator, "; MC LLVM IR backend v0\n");
    try out.appendSlice(allocator, "; semantic source: verified MC MIR\n\n");
    try emitTrapDecl(allocator, out);

    var ctx = LlvmEmitter{
        .allocator = allocator,
        .out = out,
        .mir_module = module_mir,
        .scratch = std.heap.ArenaAllocator.init(allocator),
        .need_uadd = std.StringHashMap(void).init(allocator),
        .need_usub = std.StringHashMap(void).init(allocator),
        .need_umul = std.StringHashMap(void).init(allocator),
        .need_sadd = std.StringHashMap(void).init(allocator),
        .need_ssub = std.StringHashMap(void).init(allocator),
        .need_smul = std.StringHashMap(void).init(allocator),
        .const_fns = std.StringHashMap(ast.FnDecl).init(allocator),
        .const_globals = std.StringHashMap(eval.ComptimeValue).init(allocator),
        .const_global_widths = std.StringHashMap(u16).init(allocator),
        .type_aliases = std.StringHashMap(ast.TypeExpr).init(allocator),
        .enum_types = std.StringHashMap(ast.EnumDecl).init(allocator),
        .packed_bits = std.StringHashMap(PackedBitsInfo).init(allocator),
        .struct_types = std.StringHashMap(ast.StructDecl).init(allocator),
        .fn_sigs = std.StringHashMap(FnSig).init(allocator),
        .global_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_slots = std.StringHashMap(LocalSlot).init(allocator),
        .loop_stack = std.ArrayList(LoopLabels).empty,
        .string_literals = std.ArrayList(StringLiteralGlobal).empty,
        .debug_functions = std.ArrayList(DebugFunction).empty,
        .debug_locations = std.ArrayList(DebugLocation).empty,
        .source_path = source_path,
    };
    defer ctx.deinit();
    for (module.decls) |decl| {
        if (decl.kind == .fn_decl) {
            const fn_decl = decl.kind.fn_decl;
            if (fn_decl.is_const and !ctx.const_fns.contains(fn_decl.name.text)) try ctx.const_fns.put(fn_decl.name.text, fn_decl);
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .packed_bits_decl => |packed_bits| try ctx.collectPackedBits(packed_bits),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .type_alias => |alias| try ctx.collectTypeAlias(alias),
            .enum_decl => |enum_decl| try ctx.collectEnum(enum_decl),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .struct_decl => |struct_decl| try ctx.collectStruct(struct_decl),
            else => {},
        }
    }
    try eval.collectConstGlobalsWithOptions(allocator, module, &ctx.const_fns, &ctx.const_globals, .{
        .reflect = llvmComptimeReflectThunk,
        .reflect_ctx = &ctx,
    });
    try ctx.collectConstGlobalWidths(module);
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| try ctx.collectFunction(fn_decl),
            .extern_fn => |fn_decl| try ctx.collectFunction(fn_decl),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .global_decl => |global| try ctx.collectGlobal(global),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .global_decl => |global| try ctx.emitGlobal(global),
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| if (fn_decl.body) |body| try ctx.emitFunction(fn_decl, body),
            .extern_fn => |fn_decl| try ctx.emitExternFunction(fn_decl),
            else => {},
        }
    }
    try ctx.emitStringLiteralGlobals();
    try ctx.emitIntrinsicDecls();
    try ctx.emitDebugMetadata();
}

fn emitTrapDecl(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "declare void @mc_trap_IntegerOverflow() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_DivideByZero() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_InvalidShift() noreturn\n\n");
    try out.appendSlice(allocator, "declare void @mc_trap_InvalidRepresentation() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_Bounds() noreturn\n\n");
    try out.appendSlice(allocator, "declare void @mc_trap_Assert() noreturn\n\n");
    try out.appendSlice(allocator, "declare void @mc_trap_NullUnwrap() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_Unreachable() noreturn\n\n");
}

const LlvmEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mir_module: mir.Module,
    scratch: std.heap.ArenaAllocator,
    temp_index: usize = 0,
    trap_index: usize = 0,
    need_uadd: std.StringHashMap(void) = undefined,
    need_usub: std.StringHashMap(void) = undefined,
    need_umul: std.StringHashMap(void) = undefined,
    need_sadd: std.StringHashMap(void) = undefined,
    need_ssub: std.StringHashMap(void) = undefined,
    need_smul: std.StringHashMap(void) = undefined,
    const_fns: std.StringHashMap(ast.FnDecl) = undefined,
    const_globals: std.StringHashMap(eval.ComptimeValue) = undefined,
    const_global_widths: std.StringHashMap(u16) = undefined,
    type_aliases: std.StringHashMap(ast.TypeExpr) = undefined,
    enum_types: std.StringHashMap(ast.EnumDecl) = undefined,
    packed_bits: std.StringHashMap(PackedBitsInfo) = undefined,
    struct_types: std.StringHashMap(ast.StructDecl) = undefined,
    fn_sigs: std.StringHashMap(FnSig) = undefined,
    global_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_slots: std.StringHashMap(LocalSlot) = undefined,
    loop_stack: std.ArrayList(LoopLabels) = undefined,
    string_literals: std.ArrayList(StringLiteralGlobal) = undefined,
    debug_functions: std.ArrayList(DebugFunction) = undefined,
    debug_locations: std.ArrayList(DebugLocation) = undefined,
    debug_next_id: usize = 6,
    current_debug_scope: ?usize = null,
    current_debug_span: ?ast.Span = null,
    source_path: []const u8,

    fn deinit(self: *LlvmEmitter) void {
        self.need_uadd.deinit();
        self.need_usub.deinit();
        self.need_umul.deinit();
        self.need_sadd.deinit();
        self.need_ssub.deinit();
        self.need_smul.deinit();
        self.const_fns.deinit();
        self.const_global_widths.deinit();
        eval.deinitConstGlobals(self.allocator, &self.const_globals);
        self.type_aliases.deinit();
        self.enum_types.deinit();
        self.packed_bits.deinit();
        self.struct_types.deinit();
        self.fn_sigs.deinit();
        self.global_types.deinit();
        self.local_types.deinit();
        self.local_slots.deinit();
        self.loop_stack.deinit(self.allocator);
        self.string_literals.deinit(self.allocator);
        self.debug_functions.deinit(self.allocator);
        self.debug_locations.deinit(self.allocator);
        self.scratch.deinit();
    }

    fn collectConstGlobalWidths(self: *LlvmEmitter, module: ast.Module) !void {
        for (module.decls) |decl| {
            const global = switch (decl.kind) {
                .global_decl => |g| g,
                else => continue,
            };
            if (!global.is_const) continue;
            const ty = global.ty orelse continue;
            const bits = eval.comptimeTypeBitWidth(ty) orelse continue;
            try self.const_global_widths.put(global.name.text, bits);
        }
    }

    fn collectStruct(self: *LlvmEmitter, struct_decl: ast.StructDecl) !void {
        if (struct_decl.type_params.len != 0 or struct_decl.is_move or struct_decl.abi != null) return error.UnsupportedLlvmEmission;
        for (struct_decl.fields) |field| _ = try self.llvmType(field.ty);
        try self.struct_types.put(struct_decl.name.text, struct_decl);
    }

    fn collectTypeAlias(self: *LlvmEmitter, alias: ast.TypeAlias) !void {
        _ = try self.llvmType(alias.ty);
        try self.type_aliases.put(alias.name.text, alias.ty);
    }

    fn collectEnum(self: *LlvmEmitter, enum_decl: ast.EnumDecl) !void {
        const repr = enumReprType(enum_decl);
        if (self.integerBitsOf(repr) == null) return error.UnsupportedLlvmEmission;
        for (enum_decl.cases) |case| _ = try self.enumCaseValue(enum_decl, case);
        try self.enum_types.put(enum_decl.name.text, enum_decl);
    }

    fn collectPackedBits(self: *LlvmEmitter, packed_bits: ast.PackedBitsDecl) !void {
        if (self.integerBitsOf(packed_bits.repr) == null) return error.UnsupportedLlvmEmission;
        try self.packed_bits.put(packed_bits.name.text, .{
            .repr = packed_bits.repr,
            .fields = packed_bits.fields,
        });
    }

    fn collectFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        _ = try self.llvmType(ret_ty);
        for (fn_decl.params) |param| _ = try self.llvmType(param.ty);
        const debug_id: ?usize = if (fn_decl.body != null) blk: {
            const id = self.debug_next_id;
            self.debug_next_id += 1;
            try self.debug_functions.append(self.allocator, .{
                .id = id,
                .name = fn_decl.name.text,
                .line = debugLine(fn_decl.name.span),
                .column = debugColumn(fn_decl.name.span),
            });
            break :blk id;
        } else null;
        try self.fn_sigs.put(fn_decl.name.text, .{ .ret = ret_ty, .params = fn_decl.params, .debug_id = debug_id });
    }

    fn collectGlobal(self: *LlvmEmitter, global: ast.GlobalDecl) !void {
        const ty = global.ty orelse return error.UnsupportedLlvmEmission;
        _ = try self.llvmType(ty);
        try self.global_types.put(global.name.text, ty);
    }

    fn emitGlobal(self: *LlvmEmitter, global: ast.GlobalDecl) !void {
        const ty = global.ty orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(ty);
        const linkage: []const u8 = if (global.is_const) "constant" else "global";
        const init = if (global.init) |expr| try self.emitGlobalInitializer(expr, ty) else try self.zeroInitializer(ty);
        try self.out.print(self.allocator, "@{s} = {s} {s} {s}\n", .{ global.name.text, linkage, llvm_ty, init });
    }

    fn emitGlobalInitializer(self: *LlvmEmitter, expr: ast.Expr, ty: ast.TypeExpr) ![]const u8 {
        const resolved_ty = self.resolveAliasType(ty);
        if (self.foldConstGlobalValue(expr)) |value| {
            return try self.comptimeValueInitializer(value, ty);
        }
        if (self.atomicPayloadType(resolved_ty)) |payload_ty| {
            if (isAtomicInitExpr(expr)) return try self.emitGlobalInitializer(atomicInitValue(expr).?, payload_ty);
            return try self.emitGlobalInitializer(expr, payload_ty);
        }
        if (self.enumDeclForType(ty)) |enum_decl| {
            return switch (expr.kind) {
                .enum_literal => |literal| try self.enumCaseValueByName(enum_decl, literal.text),
                .grouped => |inner| try self.emitGlobalInitializer(inner.*, ty),
                else => try self.emitGlobalInitializer(expr, enumReprType(enum_decl)),
            };
        }
        if (self.packedBitsInfoForType(ty)) |info| {
            return switch (expr.kind) {
                .struct_literal => |fields| try self.packedBitsLiteralValue(info, fields),
                .grouped => |inner| try self.emitGlobalInitializer(inner.*, ty),
                else => try self.emitGlobalInitializer(expr, info.repr),
            };
        }
        switch (resolved_ty.kind) {
            .array => |array| {
                const items = switch (expr.kind) {
                    .array_literal => |items| items,
                    .grouped => |inner| return self.emitGlobalInitializer(inner.*, ty),
                    else => return error.UnsupportedLlvmEmission,
                };
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                if (items.len != len) return error.UnsupportedLlvmEmission;
                var text: std.ArrayList(u8) = .empty;
                try text.append(self.scratch.allocator(), '[');
                for (items, 0..) |item, i| {
                    if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmType(array.child.*), try self.emitGlobalInitializer(item, array.child.*) });
                }
                try text.append(self.scratch.allocator(), ']');
                return text.toOwnedSlice(self.scratch.allocator());
            },
            .name => if (self.structDeclForType(resolved_ty)) |struct_decl| {
                const fields = switch (expr.kind) {
                    .struct_literal => |fields| fields,
                    .grouped => |inner| return self.emitGlobalInitializer(inner.*, resolved_ty),
                    else => return error.UnsupportedLlvmEmission,
                };
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(self.scratch.allocator(), "{ ");
                for (struct_decl.fields, 0..) |field, i| {
                    if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    const value_expr = structLiteralField(fields, field.name.text) orelse return error.UnsupportedLlvmEmission;
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmType(field.ty), try self.emitGlobalInitializer(value_expr, field.ty) });
                }
                try text.appendSlice(self.scratch.allocator(), " }");
                return text.toOwnedSlice(self.scratch.allocator());
            },
            else => {},
        }
        return switch (expr.kind) {
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .char_literal => |literal| try charLiteralValue(self.scratch.allocator(), literal),
            .float_literal => |literal| try normalizedFloatLiteral(self.scratch.allocator(), literal, self.isF32TypeOf(ty)),
            .unary => |node| blk: {
                if (node.op != .neg) break :blk error.UnsupportedLlvmEmission;
                if (self.isFloatTypeOf(ty)) {
                    const literal = switch ((node.expr.*).kind) {
                        .float_literal => |literal| literal,
                        .grouped => |inner| switch (inner.kind) {
                            .float_literal => |literal| literal,
                            else => break :blk error.UnsupportedLlvmEmission,
                        },
                        else => break :blk error.UnsupportedLlvmEmission,
                    };
                    break :blk try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedFloatLiteral(self.scratch.allocator(), literal, self.isF32TypeOf(ty))});
                }
                if (self.integerBitsOf(ty) != null) {
                    const literal = switch ((node.expr.*).kind) {
                        .int_literal => |literal| literal,
                        .grouped => |inner| switch (inner.kind) {
                            .int_literal => |literal| literal,
                            else => break :blk error.UnsupportedLlvmEmission,
                        },
                        else => break :blk error.UnsupportedLlvmEmission,
                    };
                    break :blk try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedIntLiteral(self.scratch.allocator(), literal)});
                }
                break :blk error.UnsupportedLlvmEmission;
            },
            .bool_literal => |value| if (value) "1" else "0",
            .null_literal => "null",
            .grouped => |inner| try self.emitGlobalInitializer(inner.*, ty),
            .ident => |ident| if (self.isFnPointerType(ty) and self.fn_sigs.contains(ident.text))
                try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text})
            else
                error.UnsupportedLlvmEmission,
            .address_of => |inner| switch (inner.kind) {
                .ident => |ident| if (self.global_types.contains(ident.text))
                    try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text})
                else
                    error.UnsupportedLlvmEmission,
                else => error.UnsupportedLlvmEmission,
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn foldConstGlobalValue(self: *LlvmEmitter, expr: ast.Expr) ?eval.ComptimeValue {
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var scope = eval.ComptimeScope.init(fba.allocator());
        defer scope.deinit();
        self.seedConstFoldScope(&scope);
        return switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => |v| eval.cloneComptimeValue(self.scratch.allocator(), v) catch null,
            else => null,
        };
    }

    fn seedConstFoldScope(self: *LlvmEmitter, scope: *eval.ComptimeScope) void {
        scope.funcs = &self.const_fns;
        scope.globals = &self.const_globals;
        scope.reflect = llvmComptimeReflectThunk;
        scope.reflect_ctx = self;
        var widths = self.const_global_widths.iterator();
        while (widths.next()) |entry| scope.bindWidth(entry.key_ptr.*, entry.value_ptr.*);
    }

    fn comptimeValueInitializer(self: *LlvmEmitter, value: eval.ComptimeValue, target_ty: ast.TypeExpr) anyerror![]const u8 {
        const resolved = self.resolveAliasType(target_ty);
        return switch (value) {
            .int => |n| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{n}),
            .boolean => |b| if (b) "1" else "0",
            .tag => |tag| blk: {
                const enum_decl = self.enumDeclForType(resolved) orelse return error.UnsupportedLlvmEmission;
                break :blk try self.enumCaseValueByName(enum_decl, tag);
            },
            .array => |items| blk: {
                const array = switch (resolved.kind) {
                    .array => |node| node,
                    else => return error.UnsupportedLlvmEmission,
                };
                var text: std.ArrayList(u8) = .empty;
                try text.append(self.scratch.allocator(), '[');
                for (items, 0..) |item, i| {
                    if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmType(array.child.*), try self.comptimeValueInitializer(item, array.child.*) });
                }
                try text.append(self.scratch.allocator(), ']');
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            .@"struct" => |fields| blk: {
                if (self.packedBitsInfoForType(resolved)) |info| break :blk try self.packedBitsComptimeValue(info, fields);
                const struct_decl = self.structDeclForType(resolved) orelse return error.UnsupportedLlvmEmission;
                var text: std.ArrayList(u8) = .empty;
                try text.appendSlice(self.scratch.allocator(), "{ ");
                for (struct_decl.fields, 0..) |field, i| {
                    if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
                    const field_value = comptimeStructFieldValue(fields, field.name.text) orelse return error.UnsupportedLlvmEmission;
                    try text.print(self.scratch.allocator(), "{s} {s}", .{ try self.llvmType(field.ty), try self.comptimeValueInitializer(field_value, field.ty) });
                }
                try text.appendSlice(self.scratch.allocator(), " }");
                break :blk try text.toOwnedSlice(self.scratch.allocator());
            },
            .void => error.UnsupportedLlvmEmission,
        };
    }

    fn zeroInitializer(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        const resolved_ty = self.resolveAliasType(ty);
        if (self.atomicPayloadType(resolved_ty)) |payload_ty| return self.zeroInitializer(payload_ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "bool"))
                "0"
            else if (self.isFloatTypeOf(resolved_ty))
                "0.0"
            else if (self.integerBitsOf(resolved_ty) != null or self.enumDeclForType(resolved_ty) != null)
                "0"
            else if (self.structDeclForType(resolved_ty) != null)
                "zeroinitializer"
            else
                error.UnsupportedLlvmEmission,
            .pointer, .raw_many_pointer, .nullable => "null",
            .array => "zeroinitializer",
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl, body: ast.Block) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        const ret_llvm = try self.llvmType(ret_ty);
        const old_scope = self.current_debug_scope;
        const old_span = self.current_debug_span;
        self.current_debug_scope = if (self.fn_sigs.get(fn_decl.name.text)) |sig| sig.debug_id else null;
        self.current_debug_span = fn_decl.name.span;
        defer {
            self.current_debug_scope = old_scope;
            self.current_debug_span = old_span;
        }
        try self.out.print(self.allocator, "define {s} @{s}(", .{ ret_llvm, fn_decl.name.text });
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} %{s}", .{ try self.llvmType(param.ty), param.name.text });
        }
        if (self.current_debug_scope) |scope| {
            try self.out.print(self.allocator, ") !dbg !{d} {{\nentry:\n", .{scope});
        } else {
            try self.out.appendSlice(self.allocator, ") {\nentry:\n");
        }
        self.temp_index = 0;
        self.trap_index = 0;
        self.local_types.clearRetainingCapacity();
        self.local_slots.clearRetainingCapacity();
        for (fn_decl.params) |param| {
            try self.local_types.put(param.name.text, param.ty);
            if (self.isAggregateType(param.ty)) {
                const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{param.name.text});
                try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, try self.llvmType(param.ty) });
                try self.out.print(self.allocator, "  store {s} %{s}, ptr {s}\n", .{ try self.llvmType(param.ty), param.name.text, ptr });
                try self.local_slots.put(param.name.text, .{ .ty = param.ty, .ptr = ptr });
            }
        }

        if (!try self.emitBlock(body, ret_ty)) {
            if (typeNameEql(ret_ty, "void")) {
                try self.emitReturnVoid(fn_decl.name.span);
            } else {
                return error.UnsupportedLlvmEmission;
            }
        }
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn emitExternFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        try self.out.print(self.allocator, "declare {s} @{s}(", .{ try self.llvmType(ret_ty), fn_decl.name.text });
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, try self.llvmType(param.ty));
        }
        try self.out.appendSlice(self.allocator, ")\n\n");
    }

    fn emitExpr(self: *LlvmEmitter, expr: ast.Expr, expected_ty: ast.TypeExpr) anyerror![]const u8 {
        const value = try switch (expr.kind) {
            .ident => |ident| try self.emitIdent(ident),
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .char_literal => |literal| try charLiteralValue(self.scratch.allocator(), literal),
            .string_literal => |literal| try self.emitStringLiteral(literal, expected_ty),
            .float_literal => |literal| try normalizedFloatLiteral(self.scratch.allocator(), literal, self.isF32TypeOf(expected_ty)),
            .bool_literal => |value| if (value) "1" else "0",
            .null_literal => "null",
            .enum_literal => |literal| if (self.enumDeclForType(expected_ty)) |enum_decl|
                try self.enumCaseValueByName(enum_decl, literal.text)
            else
                error.UnsupportedLlvmEmission,
            .grouped => |inner| self.emitExpr(inner.*, expected_ty),
            .call => |call| try self.emitCall(call, expected_ty),
            .array_literal => |items| try self.emitArrayLiteralValue(expected_ty, items),
            .struct_literal => |fields| if (self.packedBitsInfoForType(expected_ty)) |info|
                try self.packedBitsLiteralValue(info, fields)
            else
                try self.emitStructLiteralValue(expected_ty, fields),
            .binary => |node| try self.emitBinary(node, expected_ty),
            .unary => |node| try self.emitUnary(node, expected_ty),
            .cast => |node| try self.emitCast(node.value.*, node.ty.*),
            .address_of => |inner| try self.emitAddressOf(inner.*),
            .deref => |inner| try self.emitDeref(inner.*, expected_ty),
            .index => |node| try self.emitIndexLoad(node),
            .slice => |node| try self.emitSlice(node),
            .member => |node| try self.emitMemberLoad(node),
            .try_expr => |node| try self.emitTryExpr(node.operand.*, expected_ty),
            else => error.UnsupportedLlvmEmission,
        };
        return try self.coerceExprValue(value, expr, expected_ty);
    }

    fn coerceExprValue(self: *LlvmEmitter, value: []const u8, expr: ast.Expr, expected_ty: ast.TypeExpr) ![]const u8 {
        const source_ty = self.exprType(expr) orelse return value;
        if (std.mem.eql(u8, try self.llvmType(source_ty), try self.llvmType(expected_ty))) return value;
        if ((self.integerBitsOf(source_ty) != null or self.enumDeclForType(source_ty) != null) and
            (self.integerBitsOf(expected_ty) != null or self.enumDeclForType(expected_ty) != null))
        {
            return try self.castValue(value, source_ty, expected_ty);
        }
        return value;
    }

    fn emitIdent(self: *LlvmEmitter, ident: ast.Ident) ![]const u8 {
        if (self.local_slots.get(ident.text)) |slot| {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(slot.ty), slot.ptr });
            return result;
        }
        if (self.local_types.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
        if (self.global_types.get(ident.text)) |ty| {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr @{s}\n", .{ result, try self.llvmType(ty), ident.text });
            return result;
        }
        if (self.fn_sigs.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
        return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
    }

    fn emitBlock(self: *LlvmEmitter, block: ast.Block, ret_ty: ast.TypeExpr) anyerror!bool {
        for (block.items) |stmt| {
            switch (stmt.kind) {
                .let_decl => |local| try self.emitLocalDecl(local),
                .var_decl => |local| try self.emitLocalDecl(local),
                .assignment => |node| try self.emitAssignment(node.target, node.value),
                .loop => |node| {
                    if (try self.emitLoop(node, ret_ty)) return true;
                },
                .block => |node| {
                    if (try self.emitScopedBlock(node, ret_ty)) return true;
                },
                .comptime_block => {},
                .unsafe_block => |node| {
                    if (try self.emitScopedBlock(node, ret_ty)) return true;
                },
                .contract_block => |node| {
                    if (try self.emitScopedBlock(node.block, ret_ty)) return true;
                },
                .assert => |expr| try self.emitAssert(expr),
                .@"return" => |maybe_expr| {
                    if (maybe_expr) |expr| {
                        if (try self.emitNeverExpr(expr)) return true;
                    }
                    if (typeNameEql(ret_ty, "void")) {
                        if (maybe_expr) |expr| switch (expr.kind) {
                            .void_literal => {},
                            .grouped => |inner| if ((inner.*).kind != .void_literal) return error.UnsupportedLlvmEmission,
                            else => return error.UnsupportedLlvmEmission,
                        };
                        try self.emitReturnVoid(stmt.span);
                    } else if (typeNameEql(ret_ty, "never")) {
                        return error.UnsupportedLlvmEmission;
                    } else {
                        const expr = maybe_expr orelse return error.UnsupportedLlvmEmission;
                        const value = try self.emitExpr(expr, ret_ty);
                        try self.emitReturnValue(ret_ty, value, stmt.span);
                    }
                    return true;
                },
                .@"switch" => |node| {
                    if (try self.emitNullableSwitch(node, ret_ty)) return true;
                    if (try self.emitScalarSwitch(node, ret_ty)) return true;
                },
                .if_let => |node| {
                    if (try self.emitNullableIfLet(node, ret_ty)) return true;
                },
                .@"break" => {
                    const labels = self.loop_stack.getLastOrNull() orelse return error.UnsupportedLlvmEmission;
                    try self.out.print(self.allocator, "  br label %{s}\n", .{labels.break_label});
                    return true;
                },
                .@"continue" => {
                    const labels = self.loop_stack.getLastOrNull() orelse return error.UnsupportedLlvmEmission;
                    try self.out.print(self.allocator, "  br label %{s}\n", .{labels.continue_label});
                    return true;
                },
                .expr => |expr| try self.emitExprStatement(expr),
                else => return error.UnsupportedLlvmEmission,
            }
        }
        return false;
    }

    fn emitScopedBlock(self: *LlvmEmitter, block: ast.Block, ret_ty: ast.TypeExpr) !bool {
        var saved_types = std.StringHashMap(ast.TypeExpr).init(self.allocator);
        var restore_installed = false;
        errdefer if (!restore_installed) saved_types.deinit();
        var type_it = self.local_types.iterator();
        while (type_it.next()) |entry| try saved_types.put(entry.key_ptr.*, entry.value_ptr.*);

        var saved_slots = std.StringHashMap(LocalSlot).init(self.allocator);
        errdefer if (!restore_installed) saved_slots.deinit();
        var slot_it = self.local_slots.iterator();
        while (slot_it.next()) |entry| try saved_slots.put(entry.key_ptr.*, entry.value_ptr.*);

        restore_installed = true;
        defer {
            self.local_types.deinit();
            self.local_slots.deinit();
            self.local_types = saved_types;
            self.local_slots = saved_slots;
        }

        return try self.emitBlock(block, ret_ty);
    }

    fn emitExprStatement(self: *LlvmEmitter, expr: ast.Expr) !void {
        switch (expr.kind) {
            .call => |call| {
                if (try self.emitBuiltinVoidCall(call)) return;
                if (self.callReturnType(call)) |ret_ty| {
                    if (!typeNameEql(ret_ty, "void")) {
                        _ = try self.emitCall(call, ret_ty);
                        return;
                    }
                }
                const callee = switch (call.callee.kind) {
                    .ident => |ident| ident.text,
                    else => return error.UnsupportedLlvmEmission,
                };
                if (self.callReturnType(call)) |ret_ty| {
                    if (typeNameEql(ret_ty, "void")) {
                        try self.emitVoidCall(callee, call);
                        return;
                    }
                    _ = try self.emitCall(call, ret_ty);
                    return;
                }
                return error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| try self.emitExprStatement(inner.*),
            else => {
                const ty = self.exprType(expr) orelse return error.UnsupportedLlvmEmission;
                _ = try self.emitExpr(expr, ty);
            },
        }
    }

    fn emitAssert(self: *LlvmEmitter, expr: ast.Expr) !void {
        const ty = self.exprType(expr) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(ty, "bool")) return error.UnsupportedLlvmEmission;
        const condition = try self.emitExpr(expr, ty);
        const cont = try self.nextLabel("assert_ok");
        const trap = try self.nextLabel("trap_assert");
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_Assert(){s}\n  unreachable\n{s}:\n", .{ condition, cont, trap, trap, try self.debugCallSuffix(), cont });
    }

    fn emitTryExpr(self: *LlvmEmitter, operand: ast.Expr, expected_ty: ast.TypeExpr) ![]const u8 {
        const operand_ty = self.exprType(operand) orelse return error.UnsupportedLlvmEmission;
        const inner_ty = self.nullableInnerType(operand_ty) orelse return error.UnsupportedLlvmEmission;
        _ = try self.llvmType(expected_ty);
        const value = try self.emitExpr(operand, operand_ty);
        try self.emitNullUnwrapCheck(value);
        _ = inner_ty;
        return value;
    }

    fn emitNullUnwrapCheck(self: *LlvmEmitter, value: []const u8) !void {
        const is_null = try self.nextTemp();
        const trap = try self.nextLabel("trap_null");
        const cont = try self.nextLabel("nonnull");
        try self.out.print(self.allocator, "  {s} = icmp eq ptr {s}, null\n", .{ is_null, value });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_NullUnwrap(){s}\n  unreachable\n{s}:\n", .{ is_null, trap, cont, trap, try self.debugCallSuffix(), cont });
    }

    fn emitNullableIfLet(self: *LlvmEmitter, node: ast.IfLet, ret_ty: ast.TypeExpr) !bool {
        const binding = switch (node.pattern.kind) {
            .bind => |ident| ident,
            else => return false,
        };
        const subject_ty = self.exprType(node.value) orelse return false;
        const inner_ty = self.nullableInnerType(subject_ty) orelse return false;
        const subject = try self.emitExpr(node.value, subject_ty);
        const then_label = try self.nextLabel("nullable_some");
        const else_label = try self.nextLabel("nullable_none");
        const end_label = try self.nextLabel("nullable_end");
        const is_some = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = icmp ne ptr {s}, null\n", .{ is_some, subject });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ is_some, then_label, else_label, then_label });

        const old_type = self.local_types.fetchRemove(binding.text);
        const old_slot = self.local_slots.fetchRemove(binding.text);
        defer restoreLocal(&self.local_types, binding.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, binding.text, old_slot) catch {};

        const binding_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{binding.text});
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ binding_ptr, try self.llvmType(inner_ty) });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ try self.llvmType(inner_ty), subject, binding_ptr });
        try self.local_types.put(binding.text, inner_ty);
        try self.local_slots.put(binding.text, .{ .ty = inner_ty, .ptr = binding_ptr });

        const then_terminated = try self.emitBlock(node.then_block, ret_ty);
        if (!then_terminated) try self.out.print(self.allocator, "  br label %{s}\n", .{end_label});

        _ = self.local_types.remove(binding.text);
        _ = self.local_slots.remove(binding.text);

        try self.out.print(self.allocator, "{s}:\n", .{else_label});
        const else_terminated = if (node.else_block) |else_block| try self.emitBlock(else_block, ret_ty) else false;
        if (!else_terminated) try self.out.print(self.allocator, "  br label %{s}\n", .{end_label});
        if (then_terminated and else_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitNeverExpr(self: *LlvmEmitter, expr: ast.Expr) !bool {
        switch (expr.kind) {
            .unreachable_expr => {
                try self.out.print(self.allocator, "  call void @mc_trap_Unreachable(){s}\n  unreachable\n", .{try self.debugCallSuffix()});
                return true;
            },
            .call => |call| if (trapHelperForCall(call)) |helper| {
                try self.out.print(self.allocator, "  call void @{s}(){s}\n  unreachable\n", .{ helper, try self.debugCallSuffix() });
                return true;
            },
            .grouped => |inner| return try self.emitNeverExpr(inner.*),
            else => return false,
        }
        return false;
    }

    fn emitLocalDecl(self: *LlvmEmitter, local: ast.LocalDecl) !void {
        if (local.names.len != 1) return error.UnsupportedLlvmEmission;
        const init = local.init orelse return error.UnsupportedLlvmEmission;
        const ty = local.ty orelse self.exprType(init) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(ty);
        const resolved_ty = self.resolveAliasType(ty);
        const name = local.names[0].text;
        const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{name});
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, llvm_ty });
        try self.local_types.put(name, ty);
        try self.local_slots.put(name, .{ .ty = ty, .ptr = ptr });
        if (init.kind == .uninit_literal) return;
        if (resolved_ty.kind == .array) {
            if (init.kind == .array_literal) {
                try self.emitArrayLiteralStores(ptr, resolved_ty, init.kind.array_literal);
            } else {
                const value = try self.emitExpr(init, ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ llvm_ty, value, ptr });
            }
            return;
        }
        if (self.structDeclForType(resolved_ty)) |_| {
            if (init.kind == .struct_literal) {
                try self.emitStructLiteralStores(ptr, resolved_ty, init.kind.struct_literal);
            } else {
                const value = try self.emitExpr(init, ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ llvm_ty, value, ptr });
            }
            return;
        }
        const value = try self.emitExpr(init, ty);
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ llvm_ty, value, ptr });
    }

    fn emitAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr) !void {
        if (try self.emitIndexAssignment(target, value_expr)) return;
        if (try self.emitMemberAssignment(target, value_expr)) return;
        if (assignmentIdent(target)) |ident| {
            if (self.local_slots.get(ident.text)) |slot| {
                const llvm_ty = try self.llvmType(slot.ty);
                const value = try self.emitExpr(value_expr, slot.ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ llvm_ty, value, slot.ptr });
                return;
            }
            if (self.global_types.get(ident.text)) |ty| {
                const llvm_ty = try self.llvmType(ty);
                const value = try self.emitExpr(value_expr, ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr @{s}\n", .{ llvm_ty, value, ident.text });
                return;
            }
            return error.UnsupportedLlvmEmission;
        }
        if (derefTarget(target)) |ptr_expr| {
            const pointee_ty = self.derefPointeeType(ptr_expr) orelse return error.UnsupportedLlvmEmission;
            const llvm_ty = try self.llvmType(pointee_ty);
            const ptr = try self.emitExpr(ptr_expr, try self.pointerTypeFor(pointee_ty));
            const value = try self.emitExpr(value_expr, pointee_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ llvm_ty, value, ptr });
            return;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn emitIndexAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr) !bool {
        return switch (target.kind) {
            .index => |node| blk: {
                const element_ty = self.indexElementType(node.base.*) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.emitIndexAddress(node);
                const value = try self.emitExpr(value_expr, element_ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ try self.llvmType(element_ty), value, ptr });
                break :blk true;
            },
            .grouped => |inner| try self.emitIndexAssignment(inner.*, value_expr),
            else => false,
        };
    }

    fn emitBuiltinVoidCall(self: *LlvmEmitter, call: anytype) !bool {
        if (isRawStoreCall(call.callee.*)) {
            if (call.type_args.len != 1 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const value_ty = call.type_args[0];
            _ = rawScalarTypeName(value_ty) orelse return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const value = try self.emitExpr(call.args[1], value_ty);
            const ptr = try self.nextTemp();
            const llvm_ty = try self.llvmType(value_ty);
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
            try self.out.print(self.allocator, "  store volatile {s} {s}, ptr {s}\n", .{ llvm_ty, value, ptr });
            return true;
        }
        if (isCpuPauseCall(call.callee.*)) {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            try self.out.print(self.allocator, "  call void asm sideeffect \"pause\", \"~{{memory}}\"(){s}\n", .{try self.debugCallSuffix()});
            return true;
        }
        if (self.atomicCallInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "store")) return false;
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const ordering = atomicOrderingArg(call.args, 1) orelse return error.UnsupportedLlvmEmission;
            const llvm_order = atomicLlvmOrdering(ordering, .store) orelse return error.UnsupportedLlvmEmission;
            const ptr = try self.atomicBaseAddress(info.base);
            const value = try self.emitAtomicValueForStorage(call.args[0], info.payload_ty);
            try self.out.print(self.allocator, "  store atomic {s} {s}, ptr {s} {s}, align {d}\n", .{ try self.atomicStorageLlvmType(info.payload_ty), value, ptr, llvm_order, self.llvmAlignOf(info.payload_ty) });
            return true;
        }
        return false;
    }

    fn emitMemberAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr) !bool {
        return switch (target.kind) {
            .member => |node| blk: {
                const field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.emitMemberAddress(node);
                const value = try self.emitExpr(value_expr, field.ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ try self.llvmType(field.ty), value, ptr });
                break :blk true;
            },
            .grouped => |inner| try self.emitMemberAssignment(inner.*, value_expr),
            else => false,
        };
    }

    fn emitLoop(self: *LlvmEmitter, loop: ast.Loop, ret_ty: ast.TypeExpr) !bool {
        return switch (loop.kind) {
            .@"while" => try self.emitWhile(loop, ret_ty),
            .@"for" => try self.emitFor(loop, ret_ty),
        };
    }

    fn emitWhile(self: *LlvmEmitter, loop: ast.Loop, ret_ty: ast.TypeExpr) !bool {
        if (loop.kind != .@"while") return error.UnsupportedLlvmEmission;
        const condition_expr = loop.iterable orelse return error.UnsupportedLlvmEmission;
        const condition_ty = self.exprType(condition_expr) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(condition_ty, "bool")) return error.UnsupportedLlvmEmission;

        const cond_label = try self.nextLabel("while_cond");
        const body_label = try self.nextLabel("while_body");
        const end_label = try self.nextLabel("while_end");

        try self.out.print(self.allocator, "  br label %{s}\n{s}:\n", .{ cond_label, cond_label });
        const condition = try self.emitExpr(condition_expr, condition_ty);
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ condition, body_label, end_label, body_label });
        try self.loop_stack.append(self.allocator, .{ .break_label = end_label, .continue_label = cond_label });
        defer _ = self.loop_stack.pop();
        const body_terminated = try self.emitBlock(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}\n", .{cond_label});
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitFor(self: *LlvmEmitter, loop: ast.Loop, ret_ty: ast.TypeExpr) !bool {
        const binding = loop.label orelse return error.UnsupportedLlvmEmission;
        const iterable = loop.iterable orelse return error.UnsupportedLlvmEmission;
        const iterable_ty = self.exprType(iterable) orelse return error.UnsupportedLlvmEmission;
        const element_ty = self.indexElementType(iterable) orelse return error.UnsupportedLlvmEmission;
        const element_llvm = try self.llvmType(element_ty);

        const index_ptr = try self.nextTemp();
        const binding_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{binding.text});
        try self.out.print(self.allocator, "  {s} = alloca i64\n", .{index_ptr});
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ binding_ptr, element_llvm });
        try self.out.print(self.allocator, "  store i64 0, ptr {s}\n", .{index_ptr});

        var iterable_slot: ?LocalSlot = null;
        var iterable_ptr: ?[]const u8 = null;
        switch (iterable_ty.kind) {
            .slice => {
                const ptr = try self.nextTemp();
                const value = try self.emitExpr(iterable, iterable_ty);
                try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, try self.llvmType(iterable_ty) });
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ try self.llvmType(iterable_ty), value, ptr });
                iterable_slot = .{ .ty = iterable_ty, .ptr = ptr };
                iterable_ptr = ptr;
            },
            .array => if (!self.isStableAggregateAddress(iterable)) {
                iterable_ptr = try self.aggregateBasePointer(iterable);
            },
            else => {},
        }

        const old_type = self.local_types.fetchRemove(binding.text);
        const old_slot = self.local_slots.fetchRemove(binding.text);
        defer restoreLocal(&self.local_types, binding.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, binding.text, old_slot) catch {};
        try self.local_types.put(binding.text, element_ty);
        try self.local_slots.put(binding.text, .{ .ty = element_ty, .ptr = binding_ptr });

        const cond_label = try self.nextLabel("for_cond");
        const body_label = try self.nextLabel("for_body");
        const step_label = try self.nextLabel("for_step");
        const end_label = try self.nextLabel("for_end");

        try self.out.print(self.allocator, "  br label %{s}\n{s}:\n", .{ cond_label, cond_label });
        const index = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        const len = try self.emitIterableLen(iterable, iterable_ty, iterable_slot);
        const ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ ok, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n", .{ ok, body_label, end_label, body_label });

        const element_ptr = try self.emitForElementPtr(iterable, iterable_ty, iterable_ptr, index);
        const element_value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ element_value, element_llvm, element_ptr });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ element_llvm, element_value, binding_ptr });

        try self.loop_stack.append(self.allocator, .{ .break_label = end_label, .continue_label = step_label });
        defer _ = self.loop_stack.pop();
        const body_terminated = try self.emitBlock(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}\n", .{step_label});
        try self.out.print(self.allocator, "{s}:\n", .{step_label});
        const step_index = try self.nextTemp();
        const next_index = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ step_index, index_ptr });
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, step_index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}\n{s}:\n", .{ cond_label, end_label });
        return false;
    }

    fn emitIterableLen(self: *LlvmEmitter, iterable: ast.Expr, iterable_ty: ast.TypeExpr, iterable_slot: ?LocalSlot) ![]const u8 {
        return switch (iterable_ty.kind) {
            .array => |array| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission}),
            .slice => blk: {
                const slot = iterable_slot orelse return error.UnsupportedLlvmEmission;
                _ = iterable;
                const value = try self.nextTemp();
                const len = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(iterable_ty), slot.ptr });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, try self.llvmType(iterable_ty), value });
                break :blk len;
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitForElementPtr(self: *LlvmEmitter, iterable: ast.Expr, iterable_ty: ast.TypeExpr, iterable_ptr: ?[]const u8, index: []const u8) ![]const u8 {
        return switch (iterable_ty.kind) {
            .array => blk: {
                const base_ptr = iterable_ptr orelse try self.arrayBasePointer(iterable);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i64 {s}\n", .{ result, try self.llvmType(iterable_ty), base_ptr, index });
                break :blk result;
            },
            .slice => |slice| blk: {
                const ptr = iterable_ptr orelse return error.UnsupportedLlvmEmission;
                const value = try self.nextTemp();
                const data = try self.nextTemp();
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(iterable_ty), ptr });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ data, try self.llvmType(iterable_ty), value });
                try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(slice.child.*), data, index });
                break :blk result;
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitNullableSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !bool {
        const subject_ty = self.exprType(node.subject) orelse return false;
        const inner_ty = self.nullableInnerType(subject_ty) orelse return false;
        if (node.arms.len == 0) return error.UnsupportedLlvmEmission;

        var bind_index: ?usize = null;
        var binding: ?ast.Ident = null;
        var wildcard_index: ?usize = null;
        for (node.arms, 0..) |arm, i| {
            if (arm.patterns.len != 1) return false;
            switch (arm.patterns[0].kind) {
                .bind => |ident| {
                    if (bind_index != null) return false;
                    bind_index = i;
                    binding = ident;
                },
                .wildcard => {
                    if (wildcard_index != null) return false;
                    wildcard_index = i;
                },
                else => return false,
            }
        }
        const some_i = bind_index orelse return false;
        const none_i = wildcard_index orelse return false;
        const bind = binding orelse return false;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const some_label = try self.nextLabel("nullable_some");
        const none_label = try self.nextLabel("nullable_none");
        const end_label = try self.nextLabel("nullable_end");
        const is_some = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = icmp ne ptr {s}, null\n", .{ is_some, subject });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n", .{ is_some, some_label, none_label });

        var all_terminated = true;
        try self.out.print(self.allocator, "{s}:\n", .{some_label});
        const old_type = self.local_types.fetchRemove(bind.text);
        const old_slot = self.local_slots.fetchRemove(bind.text);
        defer restoreLocal(&self.local_types, bind.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, bind.text, old_slot) catch {};

        const binding_ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{bind.text});
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ binding_ptr, try self.llvmType(inner_ty) });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ try self.llvmType(inner_ty), subject, binding_ptr });
        try self.local_types.put(bind.text, inner_ty);
        try self.local_slots.put(bind.text, .{ .ty = inner_ty, .ptr = binding_ptr });
        const some_terminated = try self.emitSwitchBody(node.arms[some_i].body, ret_ty);
        if (!some_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}\n", .{end_label});
        }
        _ = self.local_types.remove(bind.text);
        _ = self.local_slots.remove(bind.text);

        try self.out.print(self.allocator, "{s}:\n", .{none_label});
        const none_terminated = try self.emitSwitchBody(node.arms[none_i].body, ret_ty);
        if (!none_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}\n", .{end_label});
        }
        if (all_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitScalarSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !bool {
        const subject_ty = self.exprType(node.subject) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(self.resolveAliasType(subject_ty), "bool") and self.integerBitsOf(subject_ty) == null and self.enumDeclForType(subject_ty) == null) return error.UnsupportedLlvmEmission;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const subject_llvm = try self.llvmType(subject_ty);
        const end_label = try self.nextLabel("switch_end");
        var arm_labels = try self.scratch.allocator().alloc([]const u8, node.arms.len);
        var wildcard_index: ?usize = null;
        for (node.arms, 0..) |arm, i| {
            arm_labels[i] = try self.nextLabel("switch_arm");
            for (arm.patterns) |pattern| {
                if (pattern.kind == .wildcard and wildcard_index == null) wildcard_index = i;
            }
        }

        const default_label = if (wildcard_index) |index| arm_labels[index] else end_label;
        try self.out.print(self.allocator, "  switch {s} {s}, label %{s} [\n", .{ subject_llvm, subject, default_label });
        for (node.arms, 0..) |arm, i| {
            for (arm.patterns) |pattern| {
                if (pattern.kind == .wildcard) continue;
                const value = try self.switchPatternValue(pattern, subject_ty);
                try self.out.print(self.allocator, "    {s} {s}, label %{s}\n", .{ subject_llvm, value, arm_labels[i] });
            }
        }
        try self.out.appendSlice(self.allocator, "  ]\n");

        var all_terminated = true;
        for (node.arms, 0..) |arm, i| {
            try self.out.print(self.allocator, "{s}:\n", .{arm_labels[i]});
            const terminated = try self.emitSwitchBody(arm.body, ret_ty);
            if (!terminated) {
                all_terminated = false;
                try self.out.print(self.allocator, "  br label %{s}\n", .{end_label});
            }
        }
        if (wildcard_index == null and !typeNameEql(self.resolveAliasType(subject_ty), "bool") and self.enumDeclForType(subject_ty) == null) all_terminated = false;
        if (all_terminated) {
            if (wildcard_index == null) {
                try self.out.print(self.allocator, "{s}:\n  call void @mc_trap_InvalidRepresentation(){s}\n  unreachable\n", .{ end_label, try self.debugCallSuffix() });
            }
            return true;
        }
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn switchPatternValue(self: *LlvmEmitter, pattern: ast.Pattern, subject_ty: ast.TypeExpr) ![]const u8 {
        const expr = switch (pattern.kind) {
            .literal => |expr| expr,
            .tag => |tag| {
                const enum_decl = self.enumDeclForType(subject_ty) orelse return error.UnsupportedLlvmEmission;
                return try self.enumCaseValueByName(enum_decl, tag.text);
            },
            else => return error.UnsupportedLlvmEmission,
        };
        if (typeNameEql(self.resolveAliasType(subject_ty), "bool")) {
            return switch (expr.kind) {
                .bool_literal => |value| if (value) "1" else "0",
                .grouped => |inner| self.switchLiteralValue(inner.*, subject_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        return self.switchLiteralValue(expr, subject_ty);
    }

    fn switchLiteralValue(self: *LlvmEmitter, expr: ast.Expr, subject_ty: ast.TypeExpr) ![]const u8 {
        return switch (expr.kind) {
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .char_literal => |literal| if (eval.parseCharLiteral(literal)) |value|
                try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value})
            else
                error.UnsupportedLlvmEmission,
            .enum_literal => |literal| if (self.enumDeclForType(subject_ty)) |enum_decl|
                try self.enumCaseValueByName(enum_decl, literal.text)
            else
                error.UnsupportedLlvmEmission,
            .grouped => |inner| self.switchLiteralValue(inner.*, subject_ty),
            .unary => |node| blk: {
                if (node.op != .neg) break :blk error.UnsupportedLlvmEmission;
                const literal = switch ((node.expr.*).kind) {
                    .int_literal => |literal| literal,
                    .grouped => |inner| switch (inner.kind) {
                        .int_literal => |literal| literal,
                        else => break :blk error.UnsupportedLlvmEmission,
                    },
                    else => break :blk error.UnsupportedLlvmEmission,
                };
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedIntLiteral(self.scratch.allocator(), literal)});
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitSwitchBody(self: *LlvmEmitter, body: ast.SwitchBody, ret_ty: ast.TypeExpr) !bool {
        return switch (body) {
            .block => |block| try self.emitBlock(block, ret_ty),
            .expr => |expr| blk: {
                if (typeNameEql(ret_ty, "void")) {
                    try self.emitExprStatement(expr);
                    break :blk false;
                }
                const value = try self.emitExpr(expr, ret_ty);
                try self.emitReturnValue(ret_ty, value, expr.span);
                break :blk true;
            },
        };
    }

    fn emitReturnVoid(self: *LlvmEmitter, span: ast.Span) !void {
        if (try self.debugLocation(span)) |dbg| {
            try self.out.print(self.allocator, "  ret void, !dbg !{d}\n", .{dbg});
        } else {
            try self.out.appendSlice(self.allocator, "  ret void\n");
        }
    }

    fn emitReturnValue(self: *LlvmEmitter, ret_ty: ast.TypeExpr, value: []const u8, span: ast.Span) !void {
        if (try self.debugLocation(span)) |dbg| {
            try self.out.print(self.allocator, "  ret {s} {s}, !dbg !{d}\n", .{ try self.llvmType(ret_ty), value, dbg });
        } else {
            try self.out.print(self.allocator, "  ret {s} {s}\n", .{ try self.llvmType(ret_ty), value });
        }
    }

    fn emitAddressOf(self: *LlvmEmitter, target: ast.Expr) ![]const u8 {
        switch (target.kind) {
            .ident => |ident| {
                if (self.local_slots.get(ident.text)) |slot| return slot.ptr;
                if (self.global_types.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                return error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| return self.emitAddressOf(inner.*),
            .deref => |inner| return self.emitExpr(inner.*, self.exprType(inner.*) orelse return error.UnsupportedLlvmEmission),
            .index => |node| return self.emitIndexAddress(node),
            .member => |node| return self.emitMemberAddress(node),
            else => return error.UnsupportedLlvmEmission,
        }
    }

    fn emitDeref(self: *LlvmEmitter, ptr_expr: ast.Expr, pointee_ty: ast.TypeExpr) ![]const u8 {
        const ptr = try self.emitExpr(ptr_expr, try self.pointerTypeFor(pointee_ty));
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(pointee_ty), ptr });
        return result;
    }

    fn emitMemberLoad(self: *LlvmEmitter, node: anytype) ![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        if (base_ty.kind == .slice and std.mem.eql(u8, node.name.text, "len")) {
            const base = try self.emitExpr(node.base.*, base_ty);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ result, try self.llvmType(base_ty), base });
            return result;
        }
        if (self.packedBitsInfoForType(base_ty)) |info| {
            const bit_index = self.packedBitsFieldIndex(info, node.name.text) orelse return error.UnsupportedLlvmEmission;
            const base = try self.emitExpr(node.base.*, base_ty);
            const masked = try self.nextTemp();
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = and {s} {s}, {d}\n", .{ masked, try self.llvmType(info.repr), base, packedBitsMask(bit_index) });
            try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, 0\n", .{ result, try self.llvmType(info.repr), masked });
            return result;
        }
        const field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitMemberAddress(node);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(field.ty), ptr });
        return result;
    }

    fn emitMemberAddress(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const struct_ty = self.memberBaseStructType(base_ty) orelse return error.UnsupportedLlvmEmission;
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        const index = structFieldIndex(struct_decl, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = if (self.resolveAliasType(base_ty).kind == .pointer)
            try self.emitExpr(node.base.*, base_ty)
        else
            try self.aggregateBasePointer(node.base.*);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i32 {d}\n", .{ result, try self.llvmType(struct_ty), base_ptr, index });
        return result;
    }

    fn emitIndexLoad(self: *LlvmEmitter, node: anytype) ![]const u8 {
        const element_ty = self.indexElementType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitIndexAddress(node);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(element_ty), ptr });
        return result;
    }

    fn emitIndexAddress(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const resolved_base_ty = self.resolveAliasType(base_ty);
        const index = try self.emitExpr(node.index.*, simpleType((node.index.*).span, "usize"));
        return switch (resolved_base_ty.kind) {
            .array => |array| blk: {
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const base_ptr = try self.arrayBasePointer(node.base.*);
                try self.emitBoundsCheck(index, len);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i64 {s}\n", .{ result, try self.llvmType(resolved_base_ty), base_ptr, index });
                break :blk result;
            },
            .slice => |slice| blk: {
                const base = try self.emitExpr(node.base.*, resolved_base_ty);
                const base_llvm = try self.llvmType(resolved_base_ty);
                const ptr = try self.nextTemp();
                const len = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ ptr, base_llvm, base });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, base_llvm, base });
                try self.emitDynamicBoundsCheck(index, len);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(slice.child.*), ptr, index });
                break :blk result;
            },
            else => return error.UnsupportedLlvmEmission,
        };
    }

    fn arrayBasePointer(self: *LlvmEmitter, expr: ast.Expr) anyerror![]const u8 {
        return self.aggregateBasePointer(expr);
    }

    fn aggregateBasePointer(self: *LlvmEmitter, expr: ast.Expr) anyerror![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                if (self.local_slots.get(ident.text)) |slot| break :blk slot.ptr;
                if (self.global_types.contains(ident.text)) break :blk try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                break :blk error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| self.aggregateBasePointer(inner.*),
            .index => |node| self.emitIndexAddress(node),
            .member => |node| self.emitMemberAddress(node),
            .call, .array_literal, .struct_literal => self.materializeAggregateRvalue(expr),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn materializeAggregateRvalue(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        const ty = self.exprType(expr) orelse return error.UnsupportedLlvmEmission;
        if (!self.isAggregateType(ty)) return error.UnsupportedLlvmEmission;
        const value = try self.emitExpr(expr, ty);
        const ptr = try self.nextTemp();
        const llvm_ty = try self.llvmType(ty);
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, llvm_ty });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ llvm_ty, value, ptr });
        return ptr;
    }

    fn isStableAggregateAddress(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |ident| self.local_slots.contains(ident.text) or self.global_types.contains(ident.text),
            .grouped => |inner| self.isStableAggregateAddress(inner.*),
            .index => |node| self.isStableAggregateAddress(node.base.*),
            .member => |node| self.isStableAggregateAddress(node.base.*),
            else => false,
        };
    }

    fn emitBoundsCheck(self: *LlvmEmitter, index: []const u8, len: u64) !void {
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {d}\n", .{ ok, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_Bounds(){s}\n  unreachable\n{s}:\n", .{ ok, cont, trap, trap, try self.debugCallSuffix(), cont });
    }

    fn emitDynamicBoundsCheck(self: *LlvmEmitter, index: []const u8, len: []const u8) !void {
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ ok, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_Bounds(){s}\n  unreachable\n{s}:\n", .{ ok, cont, trap, trap, try self.debugCallSuffix(), cont });
    }

    fn emitSliceBoundsCheck(self: *LlvmEmitter, start: []const u8, end: []const u8, len: []const u8) !void {
        const ordered = try self.nextTemp();
        const in_len = try self.nextTemp();
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ule i64 {s}, {s}\n", .{ ordered, start, end });
        try self.out.print(self.allocator, "  {s} = icmp ule i64 {s}, {s}\n", .{ in_len, end, len });
        try self.out.print(self.allocator, "  {s} = and i1 {s}, {s}\n", .{ ok, ordered, in_len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_Bounds(){s}\n  unreachable\n{s}:\n", .{ ok, cont, trap, trap, try self.debugCallSuffix(), cont });
    }

    fn emitSlice(self: *LlvmEmitter, node: anytype) ![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const slice_ty = self.sliceTypeForBase(base_ty, node.base.*.span) orelse return error.UnsupportedLlvmEmission;
        const slice = switch (slice_ty.kind) {
            .slice => |slice| slice,
            else => return error.UnsupportedLlvmEmission,
        };
        const start = try self.emitExpr(node.start.*, simpleType((node.start.*).span, "usize"));
        const end = try self.emitExpr(node.end.*, simpleType((node.end.*).span, "usize"));
        const base_ptr = switch (base_ty.kind) {
            .array => |array| blk: {
                const array_ptr = try self.arrayBasePointer(node.base.*);
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const elem_ptr = try self.nextTemp();
                try self.emitSliceBoundsCheck(start, end, try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{len}));
                try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i64 {s}\n", .{ elem_ptr, try self.llvmType(base_ty), array_ptr, start });
                break :blk elem_ptr;
            },
            .slice => blk: {
                const base = try self.emitExpr(node.base.*, base_ty);
                const base_llvm = try self.llvmType(base_ty);
                const ptr = try self.nextTemp();
                const len = try self.nextTemp();
                const elem_ptr = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ ptr, base_llvm, base });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, base_llvm, base });
                try self.emitSliceBoundsCheck(start, end, len);
                try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 {s}\n", .{ elem_ptr, try self.llvmType(slice.child.*), ptr, start });
                break :blk elem_ptr;
            },
            else => return error.UnsupportedLlvmEmission,
        };
        const result0 = try self.nextTemp();
        const slice_len = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} undef, ptr {s}, 0\n", .{ result0, try self.llvmType(slice_ty), base_ptr });
        try self.out.print(self.allocator, "  {s} = sub i64 {s}, {s}\n", .{ slice_len, end, start });
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 {s}, 1\n", .{ result, try self.llvmType(slice_ty), result0, slice_len });
        return result;
    }

    fn emitArrayLiteralStores(self: *LlvmEmitter, array_ptr: []const u8, array_ty: ast.TypeExpr, items: []const ast.Expr) !void {
        const array = switch (array_ty.kind) {
            .array => |array| array,
            else => return error.UnsupportedLlvmEmission,
        };
        const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
        if (items.len != len) return error.UnsupportedLlvmEmission;
        const element_ty = array.child.*;
        const element_llvm = try self.llvmType(element_ty);
        for (items, 0..) |item, i| {
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i64 {d}\n", .{ ptr, try self.llvmType(array_ty), array_ptr, i });
            const value = try self.emitExpr(item, element_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ element_llvm, value, ptr });
        }
    }

    fn emitStructLiteralStores(self: *LlvmEmitter, struct_ptr: []const u8, struct_ty: ast.TypeExpr, fields: []const ast.StructLiteralField) !void {
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        for (struct_decl.fields, 0..) |field, i| {
            const value_expr = structLiteralField(fields, field.name.text) orelse return error.UnsupportedLlvmEmission;
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i32 {d}\n", .{ ptr, try self.llvmType(struct_ty), struct_ptr, i });
            const value = try self.emitExpr(value_expr, field.ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ try self.llvmType(field.ty), value, ptr });
        }
    }

    fn emitArrayLiteralValue(self: *LlvmEmitter, array_ty: ast.TypeExpr, items: []const ast.Expr) ![]const u8 {
        if (array_ty.kind != .array) return error.UnsupportedLlvmEmission;
        const ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, try self.llvmType(array_ty) });
        try self.emitArrayLiteralStores(ptr, array_ty, items);
        const value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(array_ty), ptr });
        return value;
    }

    fn emitStructLiteralValue(self: *LlvmEmitter, struct_ty: ast.TypeExpr, fields: []const ast.StructLiteralField) ![]const u8 {
        if (self.structDeclForType(struct_ty) == null) return error.UnsupportedLlvmEmission;
        const ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, try self.llvmType(struct_ty) });
        try self.emitStructLiteralStores(ptr, struct_ty, fields);
        const value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(struct_ty), ptr });
        return value;
    }

    fn emitCall(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        if (try self.emitBuiltinValueCall(call, expected_ty)) |value| return value;
        if (self.directCallName(call.callee.*)) |callee| {
            return try self.emitDirectCall(callee, call, expected_ty);
        }
        const fn_ty = self.fnPointerCalleeType(call.callee.*) orelse return error.UnsupportedLlvmEmission;
        return try self.emitFnPointerCall(call.callee.*, call.args, fn_ty);
    }

    fn emitDirectCall(self: *LlvmEmitter, callee: []const u8, call: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        const ret_ast_ty = if (self.fn_sigs.get(callee)) |sig| sig.ret else expected_ty;
        const ret_ty = try self.llvmType(ret_ast_ty);
        if (typeNameEql(ret_ast_ty, "void")) return error.UnsupportedLlvmEmission;
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (call.args, 0..) |arg, i| {
            const arg_ty = self.expectedTyForCallArg(callee, i) orelse expected_ty;
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExpr(arg, arg_ty) });
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}(", .{ result, ret_ty, callee });
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitFnPointerCall(self: *LlvmEmitter, callee_expr: ast.Expr, args_expr: []const ast.Expr, fn_ty: ast.TypeExpr) ![]const u8 {
        const sig = fn_ty.kind.fn_pointer;
        if (typeNameEql(sig.ret.*, "void")) return error.UnsupportedLlvmEmission;
        if (args_expr.len != sig.params.len) return error.UnsupportedLlvmEmission;
        const callee = try self.emitExpr(callee_expr, fn_ty);
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_expr, 0..) |arg, i| {
            const arg_ty = sig.params[i];
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExpr(arg, arg_ty) });
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} {s}(", .{ result, try self.llvmType(sig.ret.*), callee });
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitBuiltinValueCall(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr) !?[]const u8 {
        if (self.constGetCallInfo(call)) |info| {
            if (call.args.len != 0) return error.UnsupportedLlvmEmission;
            const base_ptr = try self.arrayBasePointer(info.base);
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i64 {d}\n", .{ ptr, try self.llvmType(info.array_ty), base_ptr, info.index });
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(info.element_ty), ptr });
            return result;
        }
        if (bitcastTargetType(call)) |target_ty| {
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const source_ty = self.exprType(call.args[0]) orelse return error.UnsupportedLlvmEmission;
            const value = try self.emitExpr(call.args[0], source_ty);
            return try self.emitBitcastValue(value, source_ty, target_ty);
        }
        if (isPhysCall(call.callee.*)) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            return try self.emitExpr(call.args[0], simpleType(call.args[0].span, "usize"));
        }
        if (isAtomicInitCall(call.callee.*)) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload_ty = self.atomicPayloadType(expected_ty) orelse return error.UnsupportedLlvmEmission;
            return try self.emitAtomicValueForStorage(call.args[0], payload_ty);
        }
        if (isRawLoadCall(call.callee.*)) {
            if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const value_ty = call.type_args[0];
            _ = rawScalarTypeName(value_ty) orelse return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const ptr = try self.nextTemp();
            const result = try self.nextTemp();
            const llvm_ty = try self.llvmType(value_ty);
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
            try self.out.print(self.allocator, "  {s} = load volatile {s}, ptr {s}\n", .{ result, llvm_ty, ptr });
            return result;
        }
        if (isRawPtrCall(call.callee.*)) {
            if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ result, addr });
            return result;
        }
        if (self.enumRawCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            const value = try self.emitExpr(info.base, info.enum_ty);
            return try self.castValue(value, info.enum_ty, info.repr_ty);
        }
        if (self.domainResidueCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            return try self.emitExpr(info.base, info.domain_ty);
        }
        if (self.conversionCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const source_ty = self.exprType(call.args[0]) orelse info.target_ty;
            const value = try self.emitExpr(call.args[0], source_ty);
            if (std.mem.eql(u8, info.op, "trap_from")) return try self.emitTrapConversion(value, source_ty, info.target_ty);
            if (std.mem.eql(u8, info.op, "sat_from")) return try self.emitSaturatingConversion(value, source_ty, info.target_ty);
            if (!std.mem.eql(u8, info.op, "from") and !std.mem.eql(u8, info.op, "wrap_from") and !std.mem.eql(u8, info.op, "from_mod")) return error.UnsupportedLlvmEmission;
            return try self.castValue(value, source_ty, info.target_ty);
        }
        if (wrappingBuiltinOp(call.callee.*)) |op| {
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            if (self.integerBitsOf(expected_ty) == null) return error.UnsupportedLlvmEmission;
            const left = try self.emitExpr(call.args[0], expected_ty);
            const right = try self.emitExpr(call.args[1], expected_ty);
            return try self.emitPlainBinaryValues(op, try self.llvmType(expected_ty), left, right);
        }
        if (self.atomicCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "load")) {
                if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
                const ordering = atomicOrderingArg(call.args, 0) orelse return error.UnsupportedLlvmEmission;
                const llvm_order = atomicLlvmOrdering(ordering, .load) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.atomicBaseAddress(info.base);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load atomic {s}, ptr {s} {s}, align {d}\n", .{ result, try self.atomicStorageLlvmType(info.payload_ty), ptr, llvm_order, self.llvmAlignOf(info.payload_ty) });
                if (typeNameEql(info.payload_ty, "bool")) {
                    const bool_result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = trunc i8 {s} to i1\n", .{ bool_result, result });
                    return bool_result;
                }
                return result;
            }
            if (std.mem.eql(u8, info.op, "fetch_add") or std.mem.eql(u8, info.op, "fetch_sub")) {
                if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
                const ordering = atomicOrderingArg(call.args, 1) orelse return error.UnsupportedLlvmEmission;
                const llvm_order = atomicLlvmOrdering(ordering, .rmw) orelse return error.UnsupportedLlvmEmission;
                if (self.integerBitsOf(info.payload_ty) == null) return error.UnsupportedLlvmEmission;
                const ptr = try self.atomicBaseAddress(info.base);
                const delta = try self.emitExpr(call.args[0], info.payload_ty);
                const result = try self.nextTemp();
                const op: []const u8 = if (std.mem.eql(u8, info.op, "fetch_sub")) "sub" else "add";
                try self.out.print(self.allocator, "  {s} = atomicrmw {s} ptr {s}, {s} {s} {s}\n", .{ result, op, ptr, try self.llvmType(info.payload_ty), delta, llvm_order });
                return result;
            }
        }
        if (self.rawManyOffsetCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const base = try self.emitExpr(info.base, info.base_ty);
            const index = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "usize"));
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(info.element_ty), base, index });
            return result;
        }
        return null;
    }

    fn emitVoidCall(self: *LlvmEmitter, callee: []const u8, call: anytype) !void {
        const sig = self.fn_sigs.get(callee) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(sig.ret, "void")) return error.UnsupportedLlvmEmission;
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (call.args, 0..) |arg, i| {
            const arg_ty = self.expectedTyForCallArg(callee, i) orelse self.exprType(arg) orelse return error.UnsupportedLlvmEmission;
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExpr(arg, arg_ty) });
        }
        try self.out.print(self.allocator, "  call void @{s}(", .{callee});
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
    }

    fn emitBinary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        if (binaryIsComparison(node.op)) return self.emitComparison(node, ty);
        if (node.op == .logical_and or node.op == .logical_or) return self.emitLogicalBinary(node, ty);
        const llvm_ty = try self.llvmType(ty);
        if (self.isFloatTypeOf(ty)) {
            return switch (node.op) {
                .add => try self.emitPlainBinary("fadd", node, ty, llvm_ty),
                .sub => try self.emitPlainBinary("fsub", node, ty, llvm_ty),
                .mul => try self.emitPlainBinary("fmul", node, ty, llvm_ty),
                .div => try self.emitPlainBinary("fdiv", node, ty, llvm_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        if (self.isWrapDomainType(ty)) {
            return switch (node.op) {
                .add => try self.emitPlainBinary("add", node, ty, llvm_ty),
                .sub => try self.emitPlainBinary("sub", node, ty, llvm_ty),
                .mul => try self.emitPlainBinary("mul", node, ty, llvm_ty),
                .bit_and => try self.emitPlainBinary("and", node, ty, llvm_ty),
                .bit_or => try self.emitPlainBinary("or", node, ty, llvm_ty),
                .bit_xor => try self.emitPlainBinary("xor", node, ty, llvm_ty),
                .shl, .shr => try self.emitWrapShift(node, ty, llvm_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        if (self.isSatDomainType(ty)) {
            return switch (node.op) {
                .add, .sub, .mul => try self.emitSaturatingArithmetic(node, ty, llvm_ty),
                else => error.UnsupportedLlvmEmission,
            };
        }
        return switch (node.op) {
            .add, .sub, .mul => try self.emitCheckedArithmetic(node, ty, llvm_ty),
            .div, .mod => try self.emitCheckedDivRem(node, ty, llvm_ty),
            .bit_and => try self.emitPlainBinary("and", node, ty, llvm_ty),
            .bit_or => try self.emitPlainBinary("or", node, ty, llvm_ty),
            .bit_xor => try self.emitPlainBinary("xor", node, ty, llvm_ty),
            .shl, .shr => try self.emitCheckedShift(node, ty, llvm_ty),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitLogicalBinary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        if (!typeNameEql(ty, "bool")) return error.UnsupportedLlvmEmission;
        const left_ty = self.exprType(node.left.*) orelse return error.UnsupportedLlvmEmission;
        const right_ty = self.exprType(node.right.*) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(left_ty, "bool") or !typeNameEql(right_ty, "bool")) return error.UnsupportedLlvmEmission;

        const result_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = alloca i1\n", .{result_ptr});

        const left = try self.emitExpr(node.left.*, left_ty);
        const rhs_label = try self.nextLabel(if (node.op == .logical_and) "logic_and_rhs" else "logic_or_rhs");
        const short_label = try self.nextLabel(if (node.op == .logical_and) "logic_and_false" else "logic_or_true");
        const end_label = try self.nextLabel("logic_end");
        switch (node.op) {
            .logical_and => try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n", .{ left, rhs_label, short_label }),
            .logical_or => try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n", .{ left, short_label, rhs_label }),
            else => unreachable,
        }

        try self.out.print(self.allocator, "{s}:\n", .{rhs_label});
        const right = try self.emitExpr(node.right.*, right_ty);
        try self.out.print(self.allocator, "  store i1 {s}, ptr {s}\n", .{ right, result_ptr });
        try self.out.print(self.allocator, "  br label %{s}\n{s}:\n", .{ end_label, short_label });
        const short_value = if (node.op == .logical_and) "0" else "1";
        try self.out.print(self.allocator, "  store i1 {s}, ptr {s}\n", .{ short_value, result_ptr });
        try self.out.print(self.allocator, "  br label %{s}\n{s}:\n", .{ end_label, end_label });
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i1, ptr {s}\n", .{ result, result_ptr });
        return result;
    }

    fn emitUnary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        return switch (node.op) {
            .logical_not => blk: {
                const value = try self.emitExpr(node.expr.*, ty);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ result, value });
                break :blk result;
            },
            .bit_not => blk: {
                if (self.integerBitsOf(ty) == null) return error.UnsupportedLlvmEmission;
                const value = try self.emitExpr(node.expr.*, ty);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = xor {s} {s}, -1\n", .{ result, try self.llvmType(ty), value });
                break :blk result;
            },
            .neg => blk: {
                if (try self.negativeIntegerLiteralValue(node.expr.*)) |literal| break :blk literal;
                const value = try self.emitExpr(node.expr.*, ty);
                if (self.isFloatTypeOf(ty)) {
                    const result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = fneg {s} {s}\n", .{ result, try self.llvmType(ty), value });
                    break :blk result;
                }
                if (self.integerBitsOf(ty) != null and self.isSignedIntegerType(ty)) {
                    const min_literal = self.signedMinLiteralOf(ty) orelse return error.UnsupportedLlvmEmission;
                    const overflow = try self.nextTemp();
                    const trap = try self.nextLabel("trap_neg_overflow");
                    const cont = try self.nextLabel("neg_ok");
                    const result = try self.nextTemp();
                    const llvm_ty = try self.llvmType(ty);
                    try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}\n", .{ overflow, llvm_ty, value, min_literal });
                    try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow(){s}\n  unreachable\n{s}:\n", .{ overflow, trap, cont, trap, try self.debugCallSuffix(), cont });
                    try self.out.print(self.allocator, "  {s} = sub {s} 0, {s}\n", .{ result, llvm_ty, value });
                    break :blk result;
                }
                if (self.isWrapDomainType(ty)) {
                    const result = try self.nextTemp();
                    try self.out.print(self.allocator, "  {s} = sub {s} 0, {s}\n", .{ result, try self.llvmType(ty), value });
                    break :blk result;
                }
                return error.UnsupportedLlvmEmission;
            },
        };
    }

    fn negativeIntegerLiteralValue(self: *LlvmEmitter, expr: ast.Expr) !?[]const u8 {
        return switch (expr.kind) {
            .int_literal => |literal| try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try normalizedIntLiteral(self.scratch.allocator(), literal)}),
            .grouped => |inner| try self.negativeIntegerLiteralValue(inner.*),
            else => null,
        };
    }

    fn emitCast(self: *LlvmEmitter, value_expr: ast.Expr, target_ty: ast.TypeExpr) ![]const u8 {
        const source_ty = self.exprType(value_expr) orelse {
            return self.emitExpr(value_expr, target_ty);
        };
        const value = try self.emitExpr(value_expr, source_ty);
        return try self.castValue(value, source_ty, target_ty);
    }

    fn castValue(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        if ((self.integerBitsOf(source_ty) != null or self.enumDeclForType(source_ty) != null) and
            (self.integerBitsOf(target_ty) != null or self.enumDeclForType(target_ty) != null))
        {
            return try self.castIntegerValue(value, source_ty, target_ty);
        }
        return error.UnsupportedLlvmEmission;
    }

    fn emitBitcastValue(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const source_bits = self.fixedLayoutBitsOf(source_ty) orelse return error.UnsupportedLlvmEmission;
        const target_bits = self.fixedLayoutBitsOf(target_ty) orelse return error.UnsupportedLlvmEmission;
        if (source_bits != target_bits) return error.UnsupportedLlvmEmission;

        const source_llvm = try self.llvmType(source_ty);
        const target_llvm = try self.llvmType(target_ty);
        if (std.mem.eql(u8, source_llvm, target_llvm)) return value;

        const op: []const u8 = if (std.mem.eql(u8, source_llvm, "ptr"))
            "ptrtoint"
        else if (std.mem.eql(u8, target_llvm, "ptr"))
            "inttoptr"
        else
            "bitcast";

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
        return result;
    }

    fn castIntegerValue(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const source_bits = self.integerBitsOf(source_ty) orelse return error.UnsupportedLlvmEmission;
        const target_bits = self.integerBitsOf(target_ty) orelse return error.UnsupportedLlvmEmission;
        if (source_bits == target_bits) return value;

        const result = try self.nextTemp();
        const source_llvm = try self.llvmType(source_ty);
        const target_llvm = try self.llvmType(target_ty);
        if (source_bits < target_bits) {
            const op: []const u8 = if (self.isSignedIntegerType(source_ty)) "sext" else "zext";
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
        } else {
            try self.out.print(self.allocator, "  {s} = trunc {s} {s} to {s}\n", .{ result, source_llvm, value, target_llvm });
        }
        return result;
    }

    fn emitTrapConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const check = try self.emitConversionOutOfRange(value, source_ty, target_ty);
        if (check) |out_of_range| {
            const trap = try self.nextLabel("trap_conversion");
            const cont = try self.nextLabel("conversion_ok");
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow(){s}\n  unreachable\n{s}:\n", .{ out_of_range, trap, cont, trap, try self.debugCallSuffix(), cont });
        }
        return try self.castValue(value, source_ty, target_ty);
    }

    fn emitSaturatingConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const src_range = self.intRangeOf(source_ty) orelse return error.UnsupportedLlvmEmission;
        const dst_range = self.intRangeOf(target_ty) orelse return error.UnsupportedLlvmEmission;
        const source_llvm = try self.llvmType(source_ty);
        var current = value;
        if (src_range.min < dst_range.min) {
            const below = try self.nextTemp();
            const selected = try self.nextTemp();
            const pred: []const u8 = if (self.isSignedIntegerType(source_ty)) "slt" else "ult";
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ below, pred, source_llvm, current, dst_range.min });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} {s}\n", .{ selected, below, source_llvm, dst_range.min, source_llvm, current });
            current = selected;
        }
        if (src_range.max > dst_range.max) {
            const above = try self.nextTemp();
            const selected = try self.nextTemp();
            const pred: []const u8 = if (self.isSignedIntegerType(source_ty)) "sgt" else "ugt";
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ above, pred, source_llvm, current, dst_range.max });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} {s}\n", .{ selected, above, source_llvm, dst_range.max, source_llvm, current });
            current = selected;
        }
        return try self.castValue(current, source_ty, target_ty);
    }

    fn emitConversionOutOfRange(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) !?[]const u8 {
        const src_range = self.intRangeOf(source_ty) orelse return error.UnsupportedLlvmEmission;
        const dst_range = self.intRangeOf(target_ty) orelse return error.UnsupportedLlvmEmission;
        const source_llvm = try self.llvmType(source_ty);
        var result: ?[]const u8 = null;
        if (src_range.min < dst_range.min) {
            const below = try self.nextTemp();
            const pred: []const u8 = if (self.isSignedIntegerType(source_ty)) "slt" else "ult";
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ below, pred, source_llvm, value, dst_range.min });
            result = below;
        }
        if (src_range.max > dst_range.max) {
            const above = try self.nextTemp();
            const pred: []const u8 = if (self.isSignedIntegerType(source_ty)) "sgt" else "ugt";
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ above, pred, source_llvm, value, dst_range.max });
            if (result) |previous| {
                const combined = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = or i1 {s}, {s}\n", .{ combined, previous, above });
                result = combined;
            } else {
                result = above;
            }
        }
        return result;
    }

    fn intRangeOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?IntRange {
        const bits = self.integerBitsOf(ty) orelse return null;
        if (self.isSignedIntegerType(ty)) {
            const max = (@as(i128, 1) << @intCast(bits - 1)) - 1;
            return .{ .min = -max - 1, .max = max };
        }
        const max = (@as(i128, 1) << @intCast(bits)) - 1;
        return .{ .min = 0, .max = max };
    }

    fn emitComparison(self: *LlvmEmitter, node: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        if (!typeNameEql(expected_ty, "bool")) return error.UnsupportedLlvmEmission;
        const operand_ty = self.exprType(node.left.*) orelse self.exprType(node.right.*) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(operand_ty);
        const pred = if (self.isFloatTypeOf(operand_ty))
            floatComparisonPredicate(node.op) orelse return error.UnsupportedLlvmEmission
        else
            comparisonPredicate(node.op, self.isSignedIntegerType(operand_ty)) orelse return error.UnsupportedLlvmEmission;
        const left = try self.emitExpr(node.left.*, operand_ty);
        const right = try self.emitExpr(node.right.*, operand_ty);
        const result = try self.nextTemp();
        const cmp_op: []const u8 = if (self.isFloatTypeOf(operand_ty)) "fcmp" else "icmp";
        try self.out.print(self.allocator, "  {s} = {s} {s} {s} {s}, {s}\n", .{ result, cmp_op, pred, llvm_ty, left, right });
        return result;
    }

    fn emitCheckedArithmetic(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const signed = self.isSignedIntegerType(ty);
        const intrinsic = try self.overflowIntrinsic(node.op, signed, bits);
        const pair_ty = try std.fmt.allocPrint(self.scratch.allocator(), "{{ {s}, i1 }}", .{llvm_ty});
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        const pair = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}, {s} {s}){s}\n", .{ pair, pair_ty, intrinsic, llvm_ty, left, llvm_ty, right, try self.debugCallSuffix() });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const cont = try self.nextLabel("cont");
        const trap = try self.nextLabel("trap_overflow");
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow(){s}\n  unreachable\n{s}:\n", .{ overflow, trap, cont, trap, try self.debugCallSuffix(), cont });
        return value;
    }

    fn emitSaturatingArithmetic(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        if (self.isSignedIntegerType(ty)) return error.UnsupportedLlvmEmission;
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const intrinsic = try self.overflowIntrinsic(node.op, false, bits);
        const pair_ty = try std.fmt.allocPrint(self.scratch.allocator(), "{{ {s}, i1 }}", .{llvm_ty});
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        const pair = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}, {s} {s}){s}\n", .{ pair, pair_ty, intrinsic, llvm_ty, left, llvm_ty, right, try self.debugCallSuffix() });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const range = self.intRangeOf(ty) orelse return error.UnsupportedLlvmEmission;
        const saturated = if (node.op == .sub) range.min else range.max;
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {d}, {s} {s}\n", .{ result, overflow, llvm_ty, saturated, llvm_ty, value });
        return result;
    }

    fn emitCheckedDivRem(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        if (self.integerBitsOf(ty) == null) return error.UnsupportedLlvmEmission;
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        const zero_cmp = try self.nextTemp();
        const zero_trap = try self.nextLabel("trap_div_zero");
        const nonzero = try self.nextLabel("div_nonzero");
        try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, 0\n", .{ zero_cmp, llvm_ty, right });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_DivideByZero(){s}\n  unreachable\n{s}:\n", .{ zero_cmp, zero_trap, nonzero, zero_trap, try self.debugCallSuffix(), nonzero });

        if (self.isSignedIntegerType(ty)) {
            const min_literal = self.signedMinLiteralOf(ty) orelse return error.UnsupportedLlvmEmission;
            const min_cmp = try self.nextTemp();
            const neg_one_cmp = try self.nextTemp();
            const overflow_cmp = try self.nextTemp();
            const overflow_trap = try self.nextLabel("trap_div_overflow");
            const safe = try self.nextLabel("div_safe");
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}\n", .{ min_cmp, llvm_ty, left, min_literal });
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, -1\n", .{ neg_one_cmp, llvm_ty, right });
            try self.out.print(self.allocator, "  {s} = and i1 {s}, {s}\n", .{ overflow_cmp, min_cmp, neg_one_cmp });
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow(){s}\n  unreachable\n{s}:\n", .{ overflow_cmp, overflow_trap, safe, overflow_trap, try self.debugCallSuffix(), safe });
        }

        const op: []const u8 = switch (node.op) {
            .div => if (self.isSignedIntegerType(ty)) "sdiv" else "udiv",
            .mod => if (self.isSignedIntegerType(ty)) "srem" else "urem",
            else => unreachable,
        };
        return try self.emitPlainBinaryValues(op, llvm_ty, left, right);
    }

    fn emitWrapShift(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const shifted_bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const amount_ty = self.exprType(node.right.*) orelse ty;
        const amount_llvm = try self.llvmType(amount_ty);
        const left = try self.emitExpr(node.left.*, ty);
        const raw_amount = try self.emitExpr(node.right.*, amount_ty);

        try self.emitShiftCountCheck(raw_amount, amount_ty, amount_llvm, shifted_bits);
        const amount = try self.castIntegerValue(raw_amount, amount_ty, ty);

        const op: []const u8 = switch (node.op) {
            .shl => "shl",
            .shr => if (self.isSignedIntegerType(ty)) "ashr" else "lshr",
            else => unreachable,
        };
        return try self.emitPlainBinaryValues(op, llvm_ty, left, amount);
    }

    fn emitCheckedShift(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const shifted_bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const amount_ty = self.exprType(node.right.*) orelse ty;
        const amount_llvm = try self.llvmType(amount_ty);
        const left = try self.emitExpr(node.left.*, ty);
        const raw_amount = try self.emitExpr(node.right.*, amount_ty);

        try self.emitShiftCountCheck(raw_amount, amount_ty, amount_llvm, shifted_bits);
        const amount = try self.castIntegerValue(raw_amount, amount_ty, ty);

        const op: []const u8 = switch (node.op) {
            .shl => "shl",
            .shr => if (self.isSignedIntegerType(ty)) "ashr" else "lshr",
            else => unreachable,
        };
        const result = try self.emitPlainBinaryValues(op, llvm_ty, left, amount);
        if (node.op == .shl) {
            try self.emitLeftShiftOverflowCheck(result, left, amount, ty, llvm_ty);
        }
        return result;
    }

    fn emitShiftCountCheck(self: *LlvmEmitter, amount: []const u8, amount_ty: ast.TypeExpr, amount_llvm: []const u8, shifted_bits: u16) !void {
        if (self.integerBitsOf(amount_ty) == null) return error.UnsupportedLlvmEmission;
        if (self.isSignedIntegerType(amount_ty)) {
            const negative = try self.nextTemp();
            const neg_trap = try self.nextLabel("trap_shift_neg");
            const nonnegative = try self.nextLabel("shift_nonnegative");
            try self.out.print(self.allocator, "  {s} = icmp slt {s} {s}, 0\n", .{ negative, amount_llvm, amount });
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_InvalidShift(){s}\n  unreachable\n{s}:\n", .{ negative, neg_trap, nonnegative, neg_trap, try self.debugCallSuffix(), nonnegative });
        }

        const too_large = try self.nextTemp();
        const invalid = try self.nextLabel("trap_shift_count");
        const valid = try self.nextLabel("shift_count_ok");
        const pred: []const u8 = if (self.isSignedIntegerType(amount_ty)) "sge" else "uge";
        try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ too_large, pred, amount_llvm, amount, shifted_bits });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_InvalidShift(){s}\n  unreachable\n{s}:\n", .{ too_large, invalid, valid, invalid, try self.debugCallSuffix(), valid });
    }

    fn emitLeftShiftOverflowCheck(self: *LlvmEmitter, result: []const u8, left: []const u8, amount: []const u8, ty: ast.TypeExpr, llvm_ty: []const u8) !void {
        const reverse_op: []const u8 = if (self.isSignedIntegerType(ty)) "ashr" else "lshr";
        const reversed = try self.emitPlainBinaryValues(reverse_op, llvm_ty, result, amount);
        const overflow = try self.nextTemp();
        const overflow_trap = try self.nextLabel("trap_shift_overflow");
        const ok = try self.nextLabel("shift_overflow_ok");
        try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, {s}\n", .{ overflow, llvm_ty, reversed, left });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow(){s}\n  unreachable\n{s}:\n", .{ overflow, overflow_trap, ok, overflow_trap, try self.debugCallSuffix(), ok });
    }

    fn emitPlainBinary(self: *LlvmEmitter, op: []const u8, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        return try self.emitPlainBinaryValues(op, llvm_ty, left, right);
    }

    fn emitPlainBinaryValues(self: *LlvmEmitter, op: []const u8, llvm_ty: []const u8, left: []const u8, right: []const u8) ![]const u8 {
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ result, op, llvm_ty, left, right });
        return result;
    }

    fn overflowIntrinsic(self: *LlvmEmitter, op: ast.BinaryOp, signed: bool, bits: u16) ![]const u8 {
        const prefix = if (signed) "s" else "u";
        const name = switch (op) {
            .add => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}add.with.overflow.i{d}", .{ prefix, bits }),
            .sub => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}sub.with.overflow.i{d}", .{ prefix, bits }),
            .mul => try std.fmt.allocPrint(self.scratch.allocator(), "llvm.{s}mul.with.overflow.i{d}", .{ prefix, bits }),
            else => unreachable,
        };
        const set = switch (op) {
            .add => if (signed) &self.need_sadd else &self.need_uadd,
            .sub => if (signed) &self.need_ssub else &self.need_usub,
            .mul => if (signed) &self.need_smul else &self.need_umul,
            else => unreachable,
        };
        try set.put(name, {});
        return name;
    }

    fn emitIntrinsicDecls(self: *LlvmEmitter) !void {
        try self.emitIntrinsicSet(self.need_uadd);
        try self.emitIntrinsicSet(self.need_usub);
        try self.emitIntrinsicSet(self.need_umul);
        try self.emitIntrinsicSet(self.need_sadd);
        try self.emitIntrinsicSet(self.need_ssub);
        try self.emitIntrinsicSet(self.need_smul);
    }

    fn emitIntrinsicSet(self: *LlvmEmitter, set: std.StringHashMap(void)) !void {
        var it = set.keyIterator();
        while (it.next()) |name| {
            const bits = intrinsicBits(name.*) orelse continue;
            try self.out.print(self.allocator, "declare {{ i{d}, i1 }} @{s}(i{d}, i{d})\n", .{ bits, name.*, bits, bits });
        }
    }

    fn emitStringLiteral(self: *LlvmEmitter, literal: []const u8, expected_ty: ast.TypeExpr) ![]const u8 {
        if (!isStringLiteralTarget(self.resolveAliasType(expected_ty))) return error.UnsupportedLlvmEmission;

        const bytes = try llvmStringLiteralBytes(self.scratch.allocator(), literal);
        const name = try std.fmt.allocPrint(self.scratch.allocator(), ".str.{d}", .{self.string_literals.items.len});
        try self.string_literals.append(self.allocator, .{
            .name = name,
            .escaped_bytes = bytes.escaped,
            .len = bytes.len,
        });

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr inbounds [{d} x i8], ptr @{s}, i64 0, i64 0\n", .{ result, bytes.len, name });
        return result;
    }

    fn emitStringLiteralGlobals(self: *LlvmEmitter) !void {
        if (self.string_literals.items.len == 0) return;
        for (self.string_literals.items) |global| {
            try self.out.print(self.allocator, "@{s} = private unnamed_addr constant [{d} x i8] c\"{s}\", align 1\n", .{ global.name, global.len, global.escaped_bytes });
        }
        try self.out.appendSlice(self.allocator, "\n");
    }

    fn emitDebugMetadata(self: *LlvmEmitter) !void {
        if (self.debug_functions.items.len == 0) return;
        const escaped_path = try escapedLlvmString(self.scratch.allocator(), self.source_path);
        try self.out.appendSlice(self.allocator, "\n!llvm.dbg.cu = !{!0}\n");
        try self.out.appendSlice(self.allocator, "!llvm.module.flags = !{!2, !3}\n");
        try self.out.print(self.allocator, "!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: \"mcc emit-llvm\", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug)\n", .{});
        try self.out.print(self.allocator, "!1 = !DIFile(filename: \"{s}\", directory: \".\")\n", .{escaped_path});
        try self.out.appendSlice(self.allocator, "!2 = !{i32 2, !\"Debug Info Version\", i32 3}\n");
        try self.out.appendSlice(self.allocator, "!3 = !{i32 1, !\"wchar_size\", i32 4}\n");
        try self.out.appendSlice(self.allocator, "!4 = !DISubroutineType(types: !5)\n");
        try self.out.appendSlice(self.allocator, "!5 = !{null}\n");
        for (self.debug_functions.items) |function| {
            const name = try escapedLlvmString(self.scratch.allocator(), function.name);
            try self.out.print(
                self.allocator,
                "!{d} = distinct !DISubprogram(name: \"{s}\", linkageName: \"{s}\", scope: !1, file: !1, line: {d}, type: !4, scopeLine: {d}, spFlags: DISPFlagDefinition, unit: !0)\n",
                .{ function.id, name, name, function.line, function.line },
            );
        }
        for (self.debug_locations.items) |location| {
            try self.out.print(
                self.allocator,
                "!{d} = !DILocation(line: {d}, column: {d}, scope: !{d})\n",
                .{ location.id, location.line, location.column, location.scope },
            );
        }
    }

    fn debugLocation(self: *LlvmEmitter, span: ast.Span) !?usize {
        const scope = self.current_debug_scope orelse return null;
        const id = self.debug_next_id;
        self.debug_next_id += 1;
        try self.debug_locations.append(self.allocator, .{
            .id = id,
            .scope = scope,
            .line = debugLine(span),
            .column = debugColumn(span),
        });
        return id;
    }

    fn debugCallSuffix(self: *LlvmEmitter) ![]const u8 {
        const span = self.current_debug_span orelse return "";
        const location = (try self.debugLocation(span)) orelse return "";
        return try std.fmt.allocPrint(self.scratch.allocator(), ", !dbg !{d}", .{location});
    }

    fn llvmType(self: *LlvmEmitter, ty: ast.TypeExpr) anyerror![]const u8 {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "void"))
                "void"
            else if (std.mem.eql(u8, name.text, "never"))
                "void"
            else if (isOpaqueAddressTypeName(name.text))
                "i64"
            else if (std.mem.eql(u8, name.text, "c_void"))
                "i8"
            else if (std.mem.eql(u8, name.text, "bool"))
                "i1"
            else if (std.mem.eql(u8, name.text, "f32"))
                "float"
            else if (std.mem.eql(u8, name.text, "f64"))
                "double"
            else if (self.integerBitsOf(resolved_ty)) |bits|
                try std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{bits})
            else if (self.enum_types.get(name.text)) |enum_decl|
                try self.llvmType(enumReprType(enum_decl))
            else if (self.packed_bits.get(name.text)) |info|
                try self.llvmType(info.repr)
            else if (self.struct_types.get(name.text)) |struct_decl|
                try self.structLlvmType(struct_decl)
            else
                error.UnsupportedLlvmEmission,
            .pointer, .raw_many_pointer, .nullable => "ptr",
            .array => |node| try std.fmt.allocPrint(self.scratch.allocator(), "[{d} x {s}]", .{ self.arrayLenValue(node.len) orelse return error.UnsupportedLlvmEmission, try self.llvmType(node.child.*) }),
            .slice => "{ ptr, i64 }",
            .fn_pointer => "ptr",
            .generic => |node| if (std.mem.eql(u8, node.base.text, "atomic") and node.args.len == 1)
                try self.atomicStorageLlvmType(node.args[0])
            else if ((std.mem.eql(u8, node.base.text, "wrap") or std.mem.eql(u8, node.base.text, "sat")) and node.args.len == 1)
                try self.llvmType(node.args[0])
            else
                error.UnsupportedLlvmEmission,
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn nextTemp(self: *LlvmEmitter) ![]const u8 {
        const index = self.temp_index;
        self.temp_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "%t{d}", .{index});
    }

    fn nextLabel(self: *LlvmEmitter, prefix: []const u8) ![]const u8 {
        const index = self.trap_index;
        self.trap_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "{s}{d}", .{ prefix, index });
    }

    fn exprType(self: *LlvmEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| self.local_types.get(ident.text) orelse self.global_types.get(ident.text) orelse self.fnPointerTypeForName(ident.text),
            .bool_literal => simpleType(expr.span, "bool"),
            .unary => |node| if (node.op == .logical_not) simpleType(expr.span, "bool") else self.exprType(node.expr.*),
            .int_literal => null,
            .float_literal => null,
            .grouped => |inner| self.exprType(inner.*),
            .call => |call| self.callReturnType(call),
            .cast => |node| node.ty.*,
            .address_of => |inner| if (self.exprType(inner.*)) |ty| self.pointerTypeFor(ty) catch null else null,
            .deref => |inner| self.derefPointeeType(inner.*),
            .index => |node| self.indexElementType(node.base.*),
            .slice => |node| if (self.exprType(node.base.*)) |base_ty| self.sliceTypeForBase(base_ty, node.base.*.span) else null,
            .member => |node| if (self.exprType(node.base.*)) |base_ty| blk: {
                const resolved_base_ty = self.resolveAliasType(base_ty);
                if (resolved_base_ty.kind == .slice and std.mem.eql(u8, node.name.text, "len")) break :blk simpleType(expr.span, "usize");
                if (self.packedBitsInfoForType(base_ty)) |info| {
                    if (self.packedBitsFieldIndex(info, node.name.text) != null) break :blk simpleType(expr.span, "bool");
                }
                if (self.memberField(node.base.*, node.name.text)) |field| break :blk field.ty;
                break :blk null;
            } else null,
            .binary => |node| if (binaryIsComparison(node.op) or node.op == .logical_and or node.op == .logical_or) simpleType(expr.span, "bool") else self.exprType(node.left.*),
            .try_expr => |node| if (self.exprType(node.operand.*)) |ty| self.nullableInnerType(ty) else null,
            else => null,
        };
    }

    fn derefPointeeType(self: *LlvmEmitter, expr: ast.Expr) ?ast.TypeExpr {
        const ty = self.resolveAliasType(self.exprType(expr) orelse return null);
        return switch (ty.kind) {
            .pointer => |node| node.child.*,
            .raw_many_pointer => |node| node.child.*,
            else => null,
        };
    }

    fn pointerTypeFor(self: *LlvmEmitter, child: ast.TypeExpr) !ast.TypeExpr {
        const child_ptr = try self.scratch.allocator().create(ast.TypeExpr);
        child_ptr.* = child;
        return .{
            .span = child.span,
            .kind = .{ .pointer = .{ .mutability = .mut, .child = child_ptr } },
        };
    }

    fn nullableInnerType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .nullable => |child| child.*,
            else => null,
        };
    }

    fn atomicPayloadType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .generic => |node| {
                if (!std.mem.eql(u8, node.base.text, "atomic") or node.args.len != 1) return null;
                return node.args[0];
            },
            .qualified => |node| self.atomicPayloadType(node.child.*),
            else => null,
        };
    }

    fn domainPayloadType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .generic => |node| {
                if ((!std.mem.eql(u8, node.base.text, "wrap") and !std.mem.eql(u8, node.base.text, "sat")) or node.args.len != 1) return null;
                return node.args[0];
            },
            .qualified => |node| self.domainPayloadType(node.child.*),
            else => null,
        };
    }

    fn isWrapDomainType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .generic => |node| std.mem.eql(u8, node.base.text, "wrap") and node.args.len == 1,
            .qualified => |node| self.isWrapDomainType(node.child.*),
            else => false,
        };
    }

    fn isSatDomainType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .generic => |node| std.mem.eql(u8, node.base.text, "sat") and node.args.len == 1,
            .qualified => |node| self.isSatDomainType(node.child.*),
            else => false,
        };
    }

    fn atomicStorageLlvmType(self: *LlvmEmitter, payload_ty: ast.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(payload_ty), "bool")) return "i8";
        return self.llvmType(payload_ty);
    }

    fn emitAtomicValueForStorage(self: *LlvmEmitter, expr: ast.Expr, payload_ty: ast.TypeExpr) ![]const u8 {
        const value = try self.emitExpr(expr, payload_ty);
        if (!typeNameEql(self.resolveAliasType(payload_ty), "bool")) return value;
        if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "1")) return value;
        const widened = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = zext i1 {s} to i8\n", .{ widened, value });
        return widened;
    }

    fn indexElementType(self: *LlvmEmitter, base: ast.Expr) ?ast.TypeExpr {
        const ty = self.resolveAliasType(self.exprType(base) orelse return null);
        return switch (ty.kind) {
            .array => |array| array.child.*,
            .slice => |slice| slice.child.*,
            else => null,
        };
    }

    fn sliceTypeForBase(self: *LlvmEmitter, ty: ast.TypeExpr, span: ast.Span) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .slice => ty,
            .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
            else => null,
        };
    }

    fn structDeclForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.StructDecl {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .name => |name| self.struct_types.get(name.text),
            else => null,
        };
    }

    fn packedBitsInfoForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?PackedBitsInfo {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .name => |name| self.packed_bits.get(name.text),
            else => null,
        };
    }

    fn packedBitsFieldIndex(self: *LlvmEmitter, info: PackedBitsInfo, field_name: []const u8) ?usize {
        _ = self;
        for (info.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name.text, field_name)) return i;
        }
        return null;
    }

    fn enumDeclForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.EnumDecl {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .name => |name| self.enum_types.get(name.text),
            else => null,
        };
    }

    fn memberBaseStructType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .pointer => |node| node.child.*,
            else => ty,
        };
    }

    fn memberBaseStructDecl(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.StructDecl {
        const struct_ty = self.memberBaseStructType(ty) orelse return null;
        return self.structDeclForType(struct_ty);
    }

    fn enumReprType(enum_decl: ast.EnumDecl) ast.TypeExpr {
        return enum_decl.repr orelse simpleType(enum_decl.name.span, "isize");
    }

    fn enumCaseValueByName(self: *LlvmEmitter, enum_decl: ast.EnumDecl, case_name: []const u8) ![]const u8 {
        for (enum_decl.cases) |case| {
            if (std.mem.eql(u8, case.name.text, case_name)) return try self.enumCaseValue(enum_decl, case);
        }
        return error.UnsupportedLlvmEmission;
    }

    fn enumCaseValue(self: *LlvmEmitter, enum_decl: ast.EnumDecl, case: ast.EnumCase) ![]const u8 {
        if (case.value) |value| return try self.enumLiteralValue(value);
        for (enum_decl.cases, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate.name.text, case.name.text)) {
                return try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{i});
            }
        }
        return error.UnsupportedLlvmEmission;
    }

    fn enumLiteralValue(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .char_literal => |literal| if (eval.parseCharLiteral(literal)) |value|
                try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value})
            else
                error.UnsupportedLlvmEmission,
            .grouped => |inner| try self.enumLiteralValue(inner.*),
            .unary => |node| blk: {
                if (node.op != .neg) break :blk error.UnsupportedLlvmEmission;
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "-{s}", .{try self.enumLiteralValue(node.expr.*)});
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn packedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast.StructLiteralField) ![]const u8 {
        var value: u64 = 0;
        for (fields) |field| {
            const bit_index = self.packedBitsFieldIndex(info, field.name.text) orelse return error.UnsupportedLlvmEmission;
            const enabled = switch (field.value.kind) {
                .bool_literal => |enabled| enabled,
                .grouped => |inner| switch ((inner.*).kind) {
                    .bool_literal => |enabled| enabled,
                    else => return error.UnsupportedLlvmEmission,
                },
                else => return error.UnsupportedLlvmEmission,
            };
            if (enabled) value |= packedBitsMask(bit_index);
        }
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    fn packedBitsComptimeValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const eval.ComptimeStructField) ![]const u8 {
        var value: u64 = 0;
        for (fields) |field| {
            const bit_index = self.packedBitsFieldIndex(info, field.name) orelse return error.UnsupportedLlvmEmission;
            const enabled = switch (field.value) {
                .boolean => |enabled| enabled,
                else => return error.UnsupportedLlvmEmission,
            };
            if (enabled) value |= packedBitsMask(bit_index);
        }
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
    }

    fn resolveAliasType(self: *LlvmEmitter, ty: ast.TypeExpr) ast.TypeExpr {
        return switch (ty.kind) {
            .name => |name| if (self.type_aliases.get(name.text)) |aliased| self.resolveAliasType(aliased) else ty,
            else => ty,
        };
    }

    fn structLlvmType(self: *LlvmEmitter, struct_decl: ast.StructDecl) anyerror![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.scratch.allocator(), "{ ");
        for (struct_decl.fields, 0..) |field, i| {
            if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
            try text.appendSlice(self.scratch.allocator(), try self.llvmType(field.ty));
        }
        try text.appendSlice(self.scratch.allocator(), " }");
        return text.toOwnedSlice(self.scratch.allocator());
    }

    fn memberField(self: *LlvmEmitter, base: ast.Expr, field_name: []const u8) ?ast.Field {
        const base_ty = self.exprType(base) orelse return null;
        const struct_decl = self.memberBaseStructDecl(base_ty) orelse return null;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn expectedTyForCallArg(self: *LlvmEmitter, callee: []const u8, index: usize) ?ast.TypeExpr {
        const sig = self.fn_sigs.get(callee) orelse return null;
        if (index >= sig.params.len) return null;
        return sig.params[index].ty;
    }

    fn directCallName(self: *LlvmEmitter, callee: ast.Expr) ?[]const u8 {
        return switch (callee.kind) {
            .ident => |ident| if (self.fn_sigs.contains(ident.text)) ident.text else null,
            .grouped => |inner| self.directCallName(inner.*),
            else => null,
        };
    }

    fn fnPointerCalleeType(self: *LlvmEmitter, callee: ast.Expr) ?ast.TypeExpr {
        const ty = self.exprType(callee) orelse return null;
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .fn_pointer => resolved_ty,
            else => null,
        };
    }

    fn fnPointerTypeForName(self: *LlvmEmitter, name: []const u8) ?ast.TypeExpr {
        const sig = self.fn_sigs.get(name) orelse return null;
        const params = self.scratch.allocator().alloc(ast.TypeExpr, sig.params.len) catch return null;
        for (sig.params, 0..) |param, i| params[i] = param.ty;
        const ret = self.scratch.allocator().create(ast.TypeExpr) catch return null;
        ret.* = sig.ret;
        return .{
            .span = sig.ret.span,
            .kind = .{ .fn_pointer = .{ .params = params, .ret = ret } },
        };
    }

    fn isFnPointerType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return self.resolveAliasType(ty).kind == .fn_pointer;
    }

    fn callReturnType(self: *LlvmEmitter, call: anytype) ?ast.TypeExpr {
        if (self.constGetCallInfo(call)) |info| return info.element_ty;
        if (bitcastTargetType(call)) |ty| return ty;
        if (builtinCallReturnType(call)) |ty| return ty;
        if (self.enumRawCallInfo(call)) |info| return info.repr_ty;
        if (self.domainResidueCallInfo(call)) |info| return info.payload_ty;
        if (self.conversionCallInfo(call)) |info| return info.target_ty;
        if (self.atomicCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "load") or std.mem.eql(u8, info.op, "fetch_add") or std.mem.eql(u8, info.op, "fetch_sub")) return info.payload_ty;
            if (std.mem.eql(u8, info.op, "store")) return simpleType(call.callee.*.span, "void");
        }
        if (self.rawManyOffsetCallInfo(call)) |info| return info.base_ty;
        if (self.fnPointerCalleeType(call.callee.*)) |fn_ty| return fn_ty.kind.fn_pointer.ret.*;
        const callee = self.directCallName(call.callee.*) orelse return null;
        return if (self.fn_sigs.get(callee)) |sig| sig.ret else null;
    }

    fn enumRawCallInfo(self: *LlvmEmitter, call: anytype) ?EnumRawCallInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "raw")) return null;
        const enum_ty = self.exprType(member.base.*) orelse return null;
        const enum_decl = self.enumDeclForType(enum_ty) orelse return null;
        if (!enum_decl.is_open) return null;
        return .{ .base = member.base.*, .enum_ty = enum_ty, .repr_ty = enumReprType(enum_decl) };
    }

    fn domainResidueCallInfo(self: *LlvmEmitter, call: anytype) ?DomainResidueCallInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "residue")) return null;
        const domain_ty = self.exprType(member.base.*) orelse return null;
        const payload_ty = self.domainPayloadType(domain_ty) orelse return null;
        const resolved = self.resolveAliasType(domain_ty);
        const generic = switch (resolved.kind) {
            .generic => |node| node,
            else => return null,
        };
        if (!std.mem.eql(u8, generic.base.text, "wrap")) return null;
        return .{ .base = member.base.*, .domain_ty = domain_ty, .payload_ty = payload_ty };
    }

    fn conversionCallInfo(self: *LlvmEmitter, call: anytype) ?ConversionCallInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "from") and
            !std.mem.eql(u8, member.name.text, "wrap_from") and
            !std.mem.eql(u8, member.name.text, "from_mod") and
            !std.mem.eql(u8, member.name.text, "trap_from") and
            !std.mem.eql(u8, member.name.text, "sat_from"))
        {
            return null;
        }
        const ident = switch (member.base.kind) {
            .ident => |id| id,
            else => return null,
        };
        const target_ty = self.resolveAliasType(simpleType(ident.span, ident.text));
        if (self.integerBitsOf(target_ty) == null) return null;
        return .{ .target_ty = target_ty, .op = member.name.text };
    }

    fn constGetCallInfo(self: *LlvmEmitter, call: anytype) ?ConstGetCallInfo {
        if (call.type_args.len != 1) return null;
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "const_get")) return null;
        const index = constGetIndexArg(call.type_args[0]) orelse return null;
        const base_ty = self.exprType(member.base.*) orelse return null;
        const array_ty = self.resolveAliasType(base_ty);
        const array = switch (array_ty.kind) {
            .array => |node| node,
            .qualified => |node| switch (self.resolveAliasType(node.child.*).kind) {
                .array => |array_node| array_node,
                else => return null,
            },
            else => return null,
        };
        const len = self.arrayLenValue(array.len) orelse return null;
        if (index >= len) return null;
        return .{
            .base = member.base.*,
            .array_ty = array_ty,
            .element_ty = array.child.*,
            .index = index,
        };
    }

    fn atomicCallInfo(self: *LlvmEmitter, call: anytype) ?AtomicCallInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "load") and
            !std.mem.eql(u8, member.name.text, "store") and
            !std.mem.eql(u8, member.name.text, "fetch_add") and
            !std.mem.eql(u8, member.name.text, "fetch_sub"))
        {
            return null;
        }
        const base_ty = self.exprType(member.base.*) orelse return null;
        const payload_ty = self.atomicPayloadType(base_ty) orelse return null;
        return .{ .base = member.base.*, .op = member.name.text, .payload_ty = payload_ty };
    }

    fn atomicBaseAddress(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| if (self.local_slots.get(ident.text)) |slot|
                slot.ptr
            else if (self.global_types.contains(ident.text))
                try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text})
            else
                error.UnsupportedLlvmEmission,
            .member => |node| try self.emitMemberAddress(node),
            .grouped => |inner| try self.atomicBaseAddress(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn llvmAlignOf(self: *LlvmEmitter, ty: ast.TypeExpr) u8 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.llvmAlignOf(enumReprType(enum_decl));
        const resolved_ty = self.resolveAliasType(ty);
        if (self.atomicPayloadType(resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        if (self.domainPayloadType(resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "bool") or
                std.mem.eql(u8, name.text, "i8") or
                std.mem.eql(u8, name.text, "u8"))
                1
            else if (std.mem.eql(u8, name.text, "i16") or
                std.mem.eql(u8, name.text, "u16"))
                2
            else if (std.mem.eql(u8, name.text, "i32") or
                std.mem.eql(u8, name.text, "u32") or
                std.mem.eql(u8, name.text, "f32"))
                4
            else
                8,
            .pointer, .raw_many_pointer, .nullable, .slice => 8,
            else => 8,
        };
    }

    fn arrayLenValue(self: *LlvmEmitter, expr: ast.Expr) ?u64 {
        if (literalArrayLenValue(expr)) |len| return len;
        var buf: [64 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var scope = eval.ComptimeScope.init(fba.allocator());
        defer scope.deinit();
        self.seedConstFoldScope(&scope);
        return switch (eval.foldComptimeExpr(&scope, expr)) {
            .value => |value| switch (value) {
                .int => |n| if (n >= 0 and n <= std.math.maxInt(u64)) @intCast(n) else null,
                else => null,
            },
            else => null,
        };
    }

    fn comptimeReflect(self: *LlvmEmitter, call: ast.Expr) ?i128 {
        const node = switch (call.kind) {
            .call => |n| n,
            else => return null,
        };
        const kind = reflectionCallKind(node.callee.*) orelse return null;
        if (node.type_args.len != 1) return null;
        const ty = node.type_args[0];
        return switch (kind) {
            .size => if (node.args.len == 0) self.comptimeSizeOf(ty, 0) else null,
            .alignment => if (node.args.len == 0) self.comptimeAlignOf(ty, 0) else null,
            .field_offset => if (node.args.len == 1) self.comptimeFieldOffset(ty, reflectionFieldName(node.args[0]) orelse return null, 0) else null,
        };
    }

    fn comptimeSizeOf(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (depth > 32) return null;
        return switch (ty.kind) {
            .name => |name| {
                if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
                if (self.type_aliases.get(name.text)) |aliased| return self.comptimeSizeOf(aliased, depth + 1);
                if (self.struct_types.get(name.text)) |struct_decl| return self.comptimeStructSize(struct_decl, depth + 1);
                if (self.enum_types.get(name.text)) |enum_decl| return self.comptimeSizeOf(enumReprType(enum_decl), depth + 1);
                if (self.packed_bits.get(name.text)) |info| return self.comptimeSizeOf(info.repr, depth + 1);
                return null;
            },
            .pointer, .raw_many_pointer => 8,
            .nullable => |child| if (isPointerLikeType(child.*)) 8 else null,
            .slice => 16,
            .generic => |g| {
                if (std.mem.eql(u8, g.base.text, "atomic") and g.args.len == 1) return self.comptimeSizeOf(g.args[0], depth + 1);
                if ((std.mem.eql(u8, g.base.text, "wrap") or std.mem.eql(u8, g.base.text, "sat")) and g.args.len == 1) return self.comptimeSizeOf(g.args[0], depth + 1);
                return null;
            },
            .array => |node| {
                const len = self.arrayLenValue(node.len) orelse return null;
                const elem = self.comptimeSizeOf(node.child.*, depth + 1) orelse return null;
                return @as(i128, @intCast(len)) * elem;
            },
            .qualified => |node| self.comptimeSizeOf(node.child.*, depth + 1),
            else => null,
        };
    }

    fn comptimeAlignOf(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (depth > 32) return null;
        return switch (ty.kind) {
            .name => |name| {
                if (scalarLayout(name.text)) |layout| return @intCast(layout.alignment);
                if (self.type_aliases.get(name.text)) |aliased| return self.comptimeAlignOf(aliased, depth + 1);
                if (self.struct_types.get(name.text)) |struct_decl| return self.comptimeStructAlign(struct_decl, depth + 1);
                if (self.enum_types.get(name.text)) |enum_decl| return self.comptimeAlignOf(enumReprType(enum_decl), depth + 1);
                if (self.packed_bits.get(name.text)) |info| return self.comptimeAlignOf(info.repr, depth + 1);
                return null;
            },
            .pointer, .raw_many_pointer, .slice => 8,
            .nullable => |child| if (isPointerLikeType(child.*)) 8 else null,
            .generic => |g| {
                if (std.mem.eql(u8, g.base.text, "atomic") and g.args.len == 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                if ((std.mem.eql(u8, g.base.text, "wrap") or std.mem.eql(u8, g.base.text, "sat")) and g.args.len == 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                return null;
            },
            .array => |node| self.comptimeAlignOf(node.child.*, depth + 1),
            .qualified => |node| self.comptimeAlignOf(node.child.*, depth + 1),
            else => null,
        };
    }

    fn comptimeStructSize(self: *LlvmEmitter, struct_decl: ast.StructDecl, depth: usize) ?i128 {
        const layout = self.comptimeStructLayout(struct_decl, null, depth + 1) orelse return null;
        return layout.size;
    }

    fn comptimeStructAlign(self: *LlvmEmitter, struct_decl: ast.StructDecl, depth: usize) ?i128 {
        const layout = self.comptimeStructLayout(struct_decl, null, depth + 1) orelse return null;
        return layout.alignment;
    }

    fn comptimeFieldOffset(self: *LlvmEmitter, ty: ast.TypeExpr, field: []const u8, depth: usize) ?i128 {
        if (depth > 32) return null;
        const name = typeName(ty) orelse return null;
        if (self.type_aliases.get(name)) |aliased| return self.comptimeFieldOffset(aliased, field, depth + 1);
        if (self.struct_types.get(name)) |struct_decl| {
            const layout = self.comptimeStructLayout(struct_decl, field, depth + 1) orelse return null;
            return layout.field_offset;
        }
        return null;
    }

    fn comptimeStructLayout(self: *LlvmEmitter, struct_decl: ast.StructDecl, wanted_field: ?[]const u8, depth: usize) ?ComptimeStructLayout {
        if (depth > 32) return null;
        var offset: i128 = 0;
        var max_align: i128 = 1;
        var found: ?i128 = null;
        for (struct_decl.fields) |field| {
            const size = self.comptimeSizeOf(field.ty, depth + 1) orelse return null;
            const alignment = self.comptimeAlignOf(field.ty, depth + 1) orelse return null;
            if (alignment <= 0) return null;
            if (alignment > max_align) max_align = alignment;
            offset = alignForward(offset, alignment) orelse return null;
            if (wanted_field) |wanted| {
                if (std.mem.eql(u8, field.name.text, wanted)) found = offset;
            }
            offset += size;
        }
        return .{
            .size = alignForward(offset, max_align) orelse return null,
            .alignment = max_align,
            .field_offset = found,
        };
    }

    fn integerBitsOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?u16 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.integerBitsOf(enumReprType(enum_decl));
        if (self.packedBitsInfoForType(ty)) |info| return self.integerBitsOf(info.repr);
        if (self.domainPayloadType(ty)) |payload_ty| return self.integerBitsOf(payload_ty);
        return integerBits(self.resolveAliasType(ty));
    }

    fn isSignedIntegerType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        if (self.enumDeclForType(ty)) |enum_decl| return self.isSignedIntegerType(enumReprType(enum_decl));
        if (self.packedBitsInfoForType(ty)) |info| return self.isSignedIntegerType(info.repr);
        if (self.domainPayloadType(ty)) |payload_ty| return self.isSignedIntegerType(payload_ty);
        return isSignedInteger(self.resolveAliasType(ty));
    }

    fn isFloatTypeOf(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return isFloatType(self.resolveAliasType(ty));
    }

    fn isF32TypeOf(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .name => |name| std.mem.eql(u8, name.text, "f32"),
            else => false,
        };
    }

    fn fixedLayoutBitsOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?u16 {
        if (self.integerBitsOf(ty)) |bits| return bits;
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "f32"))
                32
            else if (std.mem.eql(u8, name.text, "f64") or isOpaqueAddressTypeName(name.text))
                64
            else
                null,
            .pointer, .raw_many_pointer, .nullable, .slice, .fn_pointer => 64,
            .qualified => |node| self.fixedLayoutBitsOf(node.child.*),
            else => null,
        };
    }

    fn signedMinLiteralOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?[]const u8 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.signedMinLiteralOf(enumReprType(enum_decl));
        return signedMinLiteral(self.resolveAliasType(ty));
    }

    fn rawManyOffsetCallInfo(self: *LlvmEmitter, call: anytype) ?RawManyOffsetInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "offset")) return null;
        const base_ty = self.exprType(member.base.*) orelse return null;
        const element_ty = switch (self.resolveAliasType(base_ty).kind) {
            .raw_many_pointer => |node| node.child.*,
            else => return null,
        };
        return .{ .base = member.base.*, .base_ty = base_ty, .element_ty = element_ty };
    }

    fn isAggregateType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .array => true,
            .slice => true,
            .name => self.structDeclForType(resolved_ty) != null,
            else => false,
        };
    }
};

const LocalSlot = struct {
    ty: ast.TypeExpr,
    ptr: []const u8,
};

const FnSig = struct {
    ret: ast.TypeExpr,
    params: []const ast.Param,
    debug_id: ?usize = null,
};

const PackedBitsInfo = struct {
    repr: ast.TypeExpr,
    fields: []const ast.Field,
};

const ArgValue = struct {
    ty: ast.TypeExpr,
    value: []const u8,
};

const StringLiteralGlobal = struct {
    name: []const u8,
    escaped_bytes: []const u8,
    len: usize,
};

const DebugFunction = struct {
    id: usize,
    name: []const u8,
    line: usize,
    column: usize,
};

const DebugLocation = struct {
    id: usize,
    scope: usize,
    line: usize,
    column: usize,
};

const LoopLabels = struct {
    break_label: []const u8,
    continue_label: []const u8,
};

const RawManyOffsetInfo = struct {
    base: ast.Expr,
    base_ty: ast.TypeExpr,
    element_ty: ast.TypeExpr,
};

const EnumRawCallInfo = struct {
    base: ast.Expr,
    enum_ty: ast.TypeExpr,
    repr_ty: ast.TypeExpr,
};

const DomainResidueCallInfo = struct {
    base: ast.Expr,
    domain_ty: ast.TypeExpr,
    payload_ty: ast.TypeExpr,
};

const ConversionCallInfo = struct {
    target_ty: ast.TypeExpr,
    op: []const u8,
};

const ConstGetCallInfo = struct {
    base: ast.Expr,
    array_ty: ast.TypeExpr,
    element_ty: ast.TypeExpr,
    index: u64,
};

const IntRange = struct {
    min: i128,
    max: i128,
};

const ComptimeStructLayout = struct {
    size: i128,
    alignment: i128,
    field_offset: ?i128,
};

const AtomicCallInfo = struct {
    base: ast.Expr,
    op: []const u8,
    payload_ty: ast.TypeExpr,
};

const AtomicOrderContext = enum {
    load,
    store,
    rmw,
};

fn restoreLocal(map: anytype, key: []const u8, old: anytype) !void {
    if (old) |entry| {
        try map.put(key, entry.value);
    } else {
        _ = map.remove(key);
    }
}

fn assignmentIdent(target: ast.Expr) ?ast.Ident {
    return switch (target.kind) {
        .ident => |ident| ident,
        .grouped => |inner| assignmentIdent(inner.*),
        else => null,
    };
}

fn derefTarget(target: ast.Expr) ?ast.Expr {
    return switch (target.kind) {
        .deref => |inner| inner.*,
        .grouped => |inner| derefTarget(inner.*),
        else => null,
    };
}

fn structFieldIndex(struct_decl: ast.StructDecl, field_name: []const u8) ?usize {
    for (struct_decl.fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name.text, field_name)) return i;
    }
    return null;
}

fn structLiteralField(fields: []const ast.StructLiteralField, field_name: []const u8) ?ast.Expr {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name.text, field_name)) return field.value;
    }
    return null;
}

fn simpleType(span: ast.Span, name: []const u8) ast.TypeExpr {
    return .{ .span = span, .kind = .{ .name = .{ .span = span, .text = name } } };
}

fn debugLine(span: ast.Span) usize {
    return if (span.line == 0) 1 else span.line;
}

fn debugColumn(span: ast.Span) usize {
    return if (span.column == 0) 1 else span.column;
}

fn escapedLlvmString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        switch (ch) {
            '\\' => try escaped.appendSlice(allocator, "\\5C"),
            '"' => try escaped.appendSlice(allocator, "\\22"),
            '\n' => try escaped.appendSlice(allocator, "\\0A"),
            '\r' => try escaped.appendSlice(allocator, "\\0D"),
            '\t' => try escaped.appendSlice(allocator, "\\09"),
            else => try escaped.append(allocator, ch),
        }
    }
    return escaped.toOwnedSlice(allocator);
}

const LlvmStringBytes = struct {
    escaped: []const u8,
    len: usize,
};

fn llvmStringLiteralBytes(allocator: std.mem.Allocator, literal: []const u8) !LlvmStringBytes {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return error.UnsupportedLlvmEmission;

    var escaped: std.ArrayList(u8) = .empty;
    var len: usize = 0;
    var i: usize = 1;
    while (i + 1 < literal.len) {
        const byte = if (literal[i] == '\\') blk: {
            i += 1;
            if (i + 1 >= literal.len) return error.UnsupportedLlvmEmission;
            break :blk switch (literal[i]) {
                '\\' => @as(u8, '\\'),
                '\'' => @as(u8, '\''),
                '"' => @as(u8, '"'),
                '0' => @as(u8, 0),
                'n' => @as(u8, '\n'),
                'r' => @as(u8, '\r'),
                't' => @as(u8, '\t'),
                else => return error.UnsupportedLlvmEmission,
            };
        } else literal[i];
        try appendLlvmStringByte(allocator, &escaped, byte);
        len += 1;
        i += 1;
    }
    try appendLlvmStringByte(allocator, &escaped, 0);
    len += 1;
    return .{ .escaped = try escaped.toOwnedSlice(allocator), .len = len };
}

fn appendLlvmStringByte(allocator: std.mem.Allocator, escaped: *std.ArrayList(u8), byte: u8) !void {
    switch (byte) {
        '\\' => try escaped.appendSlice(allocator, "\\5C"),
        '"' => try escaped.appendSlice(allocator, "\\22"),
        0 => try escaped.appendSlice(allocator, "\\00"),
        32...33, 35...91, 93...126 => try escaped.append(allocator, byte),
        else => {
            try escaped.append(allocator, '\\');
            try escaped.append(allocator, hexDigit(byte >> 4));
            try escaped.append(allocator, hexDigit(byte & 0x0f));
        },
    }
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + (value - 10);
}

fn packedBitsMask(bit_index: usize) u64 {
    return @as(u64, 1) << @intCast(bit_index);
}

fn builtinCallReturnType(call: anytype) ?ast.TypeExpr {
    if (isPhysCall(call.callee.*) and call.type_args.len == 0 and call.args.len == 1) return simpleType(call.callee.*.span, "PAddr");
    if (isRawLoadCall(call.callee.*) and call.type_args.len == 1 and call.args.len == 1) return call.type_args[0];
    if (isRawPtrCall(call.callee.*) and call.type_args.len == 1 and call.args.len == 1) {
        const child = @constCast(&call.type_args[0]);
        return .{
            .span = call.callee.*.span,
            .kind = .{ .pointer = .{ .mutability = .mut, .child = child } },
        };
    }
    return null;
}

fn typeNameEql(ty: ast.TypeExpr, expected: []const u8) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, expected),
        else => false,
    };
}

fn isStringLiteralTarget(ty: ast.TypeExpr) bool {
    const child = switch (ty.kind) {
        .pointer => |node| node.child.*,
        .raw_many_pointer => |node| node.child.*,
        else => return false,
    };
    const name = typeName(child) orelse return false;
    return std.mem.eql(u8, name, "u8");
}

fn isRawStoreCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "store") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawStoreCall(inner.*),
        else => false,
    };
}

fn isRawLoadCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "load") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawLoadCall(inner.*),
        else => false,
    };
}

fn isRawPtrCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "ptr") and isIdentNamed(member.base.*, "raw"),
        .grouped => |inner| isRawPtrCall(inner.*),
        else => false,
    };
}

fn isCpuPauseCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "pause") and isIdentNamed(member.base.*, "cpu"),
        .grouped => |inner| isCpuPauseCall(inner.*),
        else => false,
    };
}

fn isPhysCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "phys"),
        .grouped => |inner| isPhysCall(inner.*),
        else => false,
    };
}

fn isAtomicInitCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "init") and isIdentNamed(member.base.*, "atomic"),
        .grouped => |inner| isAtomicInitCall(inner.*),
        else => false,
    };
}

fn isAtomicInitExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |call| isAtomicInitCall(call.callee.*) and call.type_args.len == 0 and call.args.len == 1,
        .grouped => |inner| isAtomicInitExpr(inner.*),
        else => false,
    };
}

fn wrappingBuiltinOp(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |member| if (isIdentNamed(member.base.*, "wrapping"))
            if (std.mem.eql(u8, member.name.text, "add"))
                "add"
            else if (std.mem.eql(u8, member.name.text, "sub"))
                "sub"
            else if (std.mem.eql(u8, member.name.text, "mul"))
                "mul"
            else
                null
        else
            null,
        .grouped => |inner| wrappingBuiltinOp(inner.*),
        else => null,
    };
}

fn atomicInitValue(expr: ast.Expr) ?ast.Expr {
    return switch (expr.kind) {
        .call => |call| if (isAtomicInitCall(call.callee.*) and call.args.len == 1) call.args[0] else null,
        .grouped => |inner| atomicInitValue(inner.*),
        else => null,
    };
}

fn comptimeStructFieldValue(fields: []const eval.ComptimeStructField, name: []const u8) ?eval.ComptimeValue {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field.value;
    }
    return null;
}

fn bitcastTargetType(call: anytype) ?ast.TypeExpr {
    const callee = switch (call.callee.kind) {
        .ident => |ident| ident,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident,
            else => return null,
        },
        else => return null,
    };
    if (!std.mem.eql(u8, callee.text, "bitcast") or call.type_args.len != 1) return null;
    return call.type_args[0];
}

fn constGetIndexArg(ty: ast.TypeExpr) ?u64 {
    return switch (ty.kind) {
        .name => |name| parseU64Literal(name.text),
        .qualified => |node| constGetIndexArg(node.child.*),
        else => null,
    };
}

fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        .grouped => |inner| isIdentNamed(inner.*, name),
        else => false,
    };
}

fn rawScalarTypeName(ty: ast.TypeExpr) ?[]const u8 {
    const name = typeName(ty) orelse return null;
    if (std.mem.eql(u8, name, "u8")) return name;
    if (std.mem.eql(u8, name, "u16")) return name;
    if (std.mem.eql(u8, name, "u32")) return name;
    if (std.mem.eql(u8, name, "u64")) return name;
    if (std.mem.eql(u8, name, "usize")) return name;
    if (std.mem.eql(u8, name, "i8")) return name;
    if (std.mem.eql(u8, name, "i16")) return name;
    if (std.mem.eql(u8, name, "i32")) return name;
    if (std.mem.eql(u8, name, "i64")) return name;
    if (std.mem.eql(u8, name, "isize")) return name;
    if (std.mem.eql(u8, name, "f32")) return name;
    if (std.mem.eql(u8, name, "f64")) return name;
    return null;
}

fn atomicOrderingArg(args: []const ast.Expr, index: usize) ?[]const u8 {
    if (index >= args.len) return null;
    return atomicOrderingExpr(args[index]);
}

fn atomicOrderingExpr(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| atomicOrderingExpr(inner.*),
        else => null,
    };
}

fn atomicLlvmOrdering(ordering: []const u8, context: AtomicOrderContext) ?[]const u8 {
    if (std.mem.eql(u8, ordering, "relaxed")) return "monotonic";
    return switch (context) {
        .load => {
            if (std.mem.eql(u8, ordering, "acquire")) return "acquire";
            if (std.mem.eql(u8, ordering, "seq_cst")) return "seq_cst";
            return null;
        },
        .store => {
            if (std.mem.eql(u8, ordering, "release")) return "release";
            if (std.mem.eql(u8, ordering, "seq_cst")) return "seq_cst";
            return null;
        },
        .rmw => {
            if (std.mem.eql(u8, ordering, "acquire")) return "acquire";
            if (std.mem.eql(u8, ordering, "release")) return "release";
            if (std.mem.eql(u8, ordering, "acq_rel")) return "acq_rel";
            if (std.mem.eql(u8, ordering, "seq_cst")) return "seq_cst";
            return null;
        },
    };
}

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

fn llvmComptimeReflectThunk(ctx: ?*anyopaque, call: ast.Expr) ?i128 {
    const self: *LlvmEmitter = @ptrCast(@alignCast(ctx orelse return null));
    return self.comptimeReflect(call);
}

const ReflectionCallKind = enum {
    size,
    alignment,
    field_offset,
};

fn reflectionCallKind(callee: ast.Expr) ?ReflectionCallKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            return null;
        },
        .grouped => |inner| reflectionCallKind(inner.*),
        else => null,
    };
}

fn reflectionFieldName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| reflectionFieldName(inner.*),
        else => null,
    };
}

const ScalarLayout = struct { size: u32, alignment: u32 };

fn scalarLayout(name: []const u8) ?ScalarLayout {
    const table = [_]struct { n: []const u8, s: u32 }{
        .{ .n = "u8", .s = 1 },      .{ .n = "i8", .s = 1 },    .{ .n = "bool", .s = 1 },
        .{ .n = "u16", .s = 2 },     .{ .n = "i16", .s = 2 },   .{ .n = "u32", .s = 4 },
        .{ .n = "i32", .s = 4 },     .{ .n = "f32", .s = 4 },   .{ .n = "u64", .s = 8 },
        .{ .n = "i64", .s = 8 },     .{ .n = "f64", .s = 8 },   .{ .n = "usize", .s = 8 },
        .{ .n = "isize", .s = 8 },   .{ .n = "PAddr", .s = 8 }, .{ .n = "VAddr", .s = 8 },
        .{ .n = "DmaAddr", .s = 8 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry.n)) return .{ .size = entry.s, .alignment = entry.s };
    }
    return null;
}

fn isPointerLikeType(ty: ast.TypeExpr) bool {
    return switch (ty.kind) {
        .pointer, .raw_many_pointer => true,
        .qualified => |node| isPointerLikeType(node.child.*),
        else => false,
    };
}

fn alignForward(value: i128, alignment: i128) ?i128 {
    if (alignment <= 0) return null;
    const rem = @rem(value, alignment);
    if (rem == 0) return value;
    return std.math.add(i128, value, alignment - rem) catch null;
}

fn isOpaqueAddressTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "PAddr") or
        std.mem.eql(u8, name, "VAddr") or
        std.mem.eql(u8, name, "DmaAddr");
}

fn trapHelperForCall(call: anytype) ?[]const u8 {
    const callee = switch (call.callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident.text,
            else => return null,
        },
        else => return null,
    };
    if (!std.mem.eql(u8, callee, "trap") or call.type_args.len != 0 or call.args.len != 1) return null;
    return switch (call.args[0].kind) {
        .enum_literal => |literal| trapHelperForKind(literal.text),
        .grouped => |inner| switch (inner.kind) {
            .enum_literal => |literal| trapHelperForKind(literal.text),
            else => null,
        },
        else => null,
    };
}

fn trapHelperForKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "Bounds")) return "mc_trap_Bounds";
    if (std.mem.eql(u8, kind, "IntegerOverflow")) return "mc_trap_IntegerOverflow";
    if (std.mem.eql(u8, kind, "DivideByZero")) return "mc_trap_DivideByZero";
    if (std.mem.eql(u8, kind, "InvalidShift")) return "mc_trap_InvalidShift";
    if (std.mem.eql(u8, kind, "InvalidRepresentation")) return "mc_trap_InvalidRepresentation";
    if (std.mem.eql(u8, kind, "Assert")) return "mc_trap_Assert";
    if (std.mem.eql(u8, kind, "Unreachable")) return "mc_trap_Unreachable";
    return null;
}

fn findBoolSwitchArm(arms: []const ast.SwitchArm, value: bool) ?ast.SwitchArm {
    for (arms) |arm| {
        for (arm.patterns) |pattern| {
            switch (pattern.kind) {
                .literal => |expr| switch (expr.kind) {
                    .bool_literal => |literal| if (literal == value) return arm,
                    else => {},
                },
                else => {},
            }
        }
    }
    return null;
}

fn findWildcardSwitchArm(arms: []const ast.SwitchArm) ?ast.SwitchArm {
    for (arms) |arm| {
        for (arm.patterns) |pattern| {
            if (pattern.kind == .wildcard) return arm;
        }
    }
    return null;
}

fn binaryIsComparison(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

fn comparisonPredicate(op: ast.BinaryOp, signed: bool) ?[]const u8 {
    return switch (op) {
        .eq => "eq",
        .ne => "ne",
        .lt => if (signed) "slt" else "ult",
        .le => if (signed) "sle" else "ule",
        .gt => if (signed) "sgt" else "ugt",
        .ge => if (signed) "sge" else "uge",
        else => null,
    };
}

fn floatComparisonPredicate(op: ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .eq => "oeq",
        .ne => "une",
        .lt => "olt",
        .le => "ole",
        .gt => "ogt",
        .ge => "oge",
        else => null,
    };
}

fn normalizedIntLiteral(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (ch != '_') try cleaned.append(allocator, ch);
    }
    const text = try cleaned.toOwnedSlice(allocator);
    const value = std.fmt.parseInt(i128, text, 0) catch return text;
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn normalizedFloatLiteral(allocator: std.mem.Allocator, literal: []const u8, f32_target: bool) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (ch != '_') try cleaned.append(allocator, ch);
    }
    const text = try cleaned.toOwnedSlice(allocator);
    if (!f32_target) return text;
    const parsed = std.fmt.parseFloat(f32, text) catch return text;
    const widened: f64 = parsed;
    const bits: u64 = @bitCast(widened);
    return std.fmt.allocPrint(allocator, "0x{X:0>16}", .{bits});
}

fn charLiteralValue(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    const value = eval.parseCharLiteral(literal) orelse return error.UnsupportedLlvmEmission;
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn literalArrayLenValue(expr: ast.Expr) ?u64 {
    return switch (expr.kind) {
        .int_literal => |literal| parseU64Literal(literal),
        .grouped => |inner| literalArrayLenValue(inner.*),
        else => null,
    };
}

fn parseU64Literal(literal: []const u8) ?u64 {
    var value: u64 = 0;
    for (literal) |ch| {
        if (ch == '_') continue;
        if (ch < '0' or ch > '9') return null;
        value = std.math.mul(u64, value, 10) catch return null;
        value = std.math.add(u64, value, ch - '0') catch return null;
    }
    return value;
}

fn integerBits(ty: ast.TypeExpr) ?u16 {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "u8") or std.mem.eql(u8, name, "i8")) return 8;
    if (std.mem.eql(u8, name, "u16") or std.mem.eql(u8, name, "i16")) return 16;
    if (std.mem.eql(u8, name, "u32") or std.mem.eql(u8, name, "i32")) return 32;
    if (std.mem.eql(u8, name, "u64") or std.mem.eql(u8, name, "i64")) return 64;
    if (std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize")) return 64;
    return null;
}

fn isSignedInteger(ty: ast.TypeExpr) bool {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return false,
    };
    return std.mem.startsWith(u8, name, "i") or std.mem.eql(u8, name, "isize");
}

fn isFloatType(ty: ast.TypeExpr) bool {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return false,
    };
    return std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64");
}

fn signedMinLiteral(ty: ast.TypeExpr) ?[]const u8 {
    const name = switch (ty.kind) {
        .name => |name| name.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "i8")) return "-128";
    if (std.mem.eql(u8, name, "i16")) return "-32768";
    if (std.mem.eql(u8, name, "i32")) return "-2147483648";
    if (std.mem.eql(u8, name, "i64") or std.mem.eql(u8, name, "isize")) return "-9223372036854775808";
    return null;
}

fn intrinsicBits(name: []const u8) ?u16 {
    if (std.mem.endsWith(u8, name, ".i8")) return 8;
    if (std.mem.endsWith(u8, name, ".i16")) return 16;
    if (std.mem.endsWith(u8, name, ".i32")) return 32;
    if (std.mem.endsWith(u8, name, ".i64")) return 64;
    return null;
}

test "LLVM backend emits checked integer add from MIR-gated source" {
    const source =
        \\fn add_one(value: u32) -> u32 {
        \\    return value + 1;
        \\}
    ;

    var reporter = @import("diagnostics.zig").Reporter.init(std.testing.allocator, "llvm_smoke.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = @import("parser.zig").Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendLlvm(std.testing.allocator, module, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "define i32 @add_one(i32 %value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@llvm.uadd.with.overflow.i32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "call void @mc_trap_IntegerOverflow()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " nsw ") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " nuw ") == null);
}
