const std = @import("std");

const ast = @import("ast.zig");
const ast_query = @import("ast_query.zig");
const eval = @import("eval.zig");
const type_layout = @import("layout.zig");
const mir = @import("mir.zig");

// Pure AST-shape queries shared with sema/mir/lower_c (see `ast_query.zig`); aliased so the
// existing call sites read unchanged.
const isIdentNamed = ast_query.isIdentNamed;
const mmioMapCallPayloadType = ast_query.mmioMapCallPayloadType;
const typeName = ast_query.typeName;
const ByteViewCallKind = ast_query.ByteViewCallKind;
const byteViewCallKind = ast_query.byteViewCallKind;
const byteViewAddressTarget = ast_query.byteViewAddressTarget;
const calleeIdentName = ast_query.calleeIdentName;
const isCpuPauseCall = ast_query.isCpuPauseCall;
const isRawLoadCall = ast_query.isRawLoadCall;
const isRawPtrCall = ast_query.isRawPtrCall;
const isRawStoreCall = ast_query.isRawStoreCall;
const isOpaqueAddressTypeName = ast_query.isOpaqueAddressTypeName;
const isStringLiteralTarget = ast_query.isStringLiteralTarget;
const isMmioStructAbi = ast_query.isMmioStructAbi;
const reflectionFieldName = ast_query.reflectionFieldName;
const overlayByteArrayElementType = ast_query.overlayByteArrayElementType;
const overlayMemberFromIndexBase = ast_query.overlayMemberFromIndexBase;
const taggedUnionCase = ast_query.taggedUnionCase;
const scalarLayout = type_layout.scalarLayout;
const ComptimeStructLayout = type_layout.ComptimeStructLayout;

pub fn appendLlvm(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    try appendLlvmWithSourcePath(allocator, module, out, "input.mc", false);
}

pub fn appendLlvmWithSourcePath(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8), source_path: []const u8, optimize: bool) !void {
    var module_mir = try mir.buildOpt(allocator, module, .{ .optimize = optimize });
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
        .overlay_unions = std.StringHashMap(OverlayUnionInfo).init(allocator),
        .tagged_unions = std.StringHashMap(ast.UnionDecl).init(allocator),
        .struct_types = std.StringHashMap(ast.StructDecl).init(allocator),
        .fn_sigs = std.StringHashMap(FnSig).init(allocator),
        .bind_thunks = std.StringHashMap(BindThunk).init(allocator),
        .backend_names = std.StringHashMap([]const u8).init(allocator),
        .global_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .global_initializers = std.StringHashMap(ast.Expr).init(allocator),
        .local_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_slots = std.StringHashMap(LocalSlot).init(allocator),
        .loop_stack = std.ArrayList(LoopLabels).empty,
        .defer_stack = std.ArrayList(ast.Expr).empty,
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
            for (decl.attrs) |attr| switch (attr.kind) {
                .backend_name => |name| try ctx.backend_names.put(fn_decl.name.text, name),
                else => {},
            };
        }
    }
    try ctx.preRegisterTypeDecls(module);
    try eval.collectConstGlobalsWithOptions(allocator, module, &ctx.const_fns, &ctx.const_globals, .{
        .reflect = llvmComptimeReflectThunk,
        .reflect_ctx = &ctx,
    });
    try ctx.collectConstGlobalWidths(module);
    for (module.decls) |decl| {
        switch (decl.kind) {
            .packed_bits_decl => |packed_bits| try ctx.collectPackedBits(packed_bits),
            .overlay_union_decl => |overlay_union| try ctx.collectOverlayUnion(overlay_union),
            .union_decl => |union_decl| try ctx.collectTaggedUnion(union_decl),
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
    // Scalar-env closure thunks discovered while emitting bodies. LLVM IR allows
    // forward references to these `@mc_envthunk_*` symbols, so emitting them after
    // the function bodies is fine.
    try ctx.emitBindThunks();
    try ctx.emitBackendNameAliases(module);
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
    overlay_unions: std.StringHashMap(OverlayUnionInfo) = undefined,
    tagged_unions: std.StringHashMap(ast.UnionDecl) = undefined,
    struct_types: std.StringHashMap(ast.StructDecl) = undefined,
    fn_sigs: std.StringHashMap(FnSig) = undefined,
    // `bind(scalar, f)` closures whose env is a non-pointer integer scalar. The
    // closure's env slot is `ptr`, so the scalar is widened via `inttoptr` and the
    // code pointer points at a generated thunk that narrows it back with `ptrtoint`
    // before calling `f`. Keyed by target function name.
    bind_thunks: std.StringHashMap(BindThunk) = undefined,
    // Source function name -> `#[backend_name("Y")]` override; emitted as a module-level
    // alias `@Y = alias <fnty>, ptr @name` so the override symbol is linkable (the C backend
    // achieves the same via an asm label).
    backend_names: std.StringHashMap([]const u8) = undefined,
    global_types: std.StringHashMap(ast.TypeExpr) = undefined,
    global_initializers: std.StringHashMap(ast.Expr) = undefined,
    local_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_slots: std.StringHashMap(LocalSlot) = undefined,
    loop_stack: std.ArrayList(LoopLabels) = undefined,
    defer_stack: std.ArrayList(ast.Expr) = undefined,
    string_literals: std.ArrayList(StringLiteralGlobal) = undefined,
    debug_functions: std.ArrayList(DebugFunction) = undefined,
    debug_locations: std.ArrayList(DebugLocation) = undefined,
    debug_next_id: usize = 6,
    current_debug_scope: ?usize = null,
    current_debug_span: ?ast.Span = null,
    current_return_ty: ?ast.TypeExpr = null,
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
        self.overlay_unions.deinit();
        self.tagged_unions.deinit();
        self.struct_types.deinit();
        self.fn_sigs.deinit();
        self.bind_thunks.deinit();
        self.backend_names.deinit();
        self.global_types.deinit();
        self.global_initializers.deinit();
        self.local_types.deinit();
        self.local_slots.deinit();
        self.loop_stack.deinit(self.allocator);
        self.defer_stack.deinit(self.allocator);
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

    fn preRegisterTypeDecls(self: *LlvmEmitter, module: ast.Module) !void {
        for (module.decls) |decl| {
            switch (decl.kind) {
                .type_alias => |alias| try self.type_aliases.put(alias.name.text, alias.ty),
                .enum_decl => |enum_decl| try self.enum_types.put(enum_decl.name.text, enum_decl),
                .union_decl => |union_decl| try self.tagged_unions.put(union_decl.name.text, union_decl),
                .packed_bits_decl => |packed_bits| try self.packed_bits.put(packed_bits.name.text, .{
                    .repr = packed_bits.repr,
                    .fields = packed_bits.fields,
                }),
                .struct_decl => |struct_decl| {
                    if (struct_decl.type_params.len != 0) return error.UnsupportedLlvmEmission;
                    if (struct_decl.abi) |abi| {
                        if (!std.mem.eql(u8, abi, "mmio")) return error.UnsupportedLlvmEmission;
                    }
                    try self.struct_types.put(struct_decl.name.text, struct_decl);
                },
                else => {},
            }
        }
    }

    fn collectStruct(self: *LlvmEmitter, struct_decl: ast.StructDecl) !void {
        if (struct_decl.type_params.len != 0) return error.UnsupportedLlvmEmission;
        if (struct_decl.abi) |abi| {
            if (!std.mem.eql(u8, abi, "mmio")) return error.UnsupportedLlvmEmission;
        }
        for (struct_decl.fields) |field| {
            if (isMmioStructAbi(struct_decl)) {
                _ = self.mmioFieldInfo(field) orelse return error.UnsupportedLlvmEmission;
            } else {
                _ = try self.llvmType(field.ty);
            }
        }
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

    fn collectOverlayUnion(self: *LlvmEmitter, overlay_union: ast.OverlayUnionDecl) !void {
        var size: u64 = 1;
        var alignment: u64 = 1;
        for (overlay_union.fields) |field| {
            const layout = self.overlayFieldLayout(field.ty, 0) orelse return error.UnsupportedLlvmEmission;
            size = @max(size, layout.size);
            alignment = @max(alignment, layout.alignment);
        }
        try self.overlay_unions.put(overlay_union.name.text, .{
            .fields = overlay_union.fields,
            .size = size,
            .alignment = alignment,
        });
    }

    fn collectTaggedUnion(self: *LlvmEmitter, union_decl: ast.UnionDecl) !void {
        for (union_decl.cases) |case| {
            if (case.ty) |ty| _ = try self.llvmType(ty);
        }
        try self.tagged_unions.put(union_decl.name.text, union_decl);
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
        if (global.init) |expr| try self.global_initializers.put(global.name.text, expr);
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
        switch (expr.kind) {
            .ident => |ident| {
                if (!self.isFnPointerType(ty)) {
                    if (self.global_initializers.get(ident.text)) |initializer| {
                        return try self.emitGlobalInitializer(initializer, ty);
                    }
                }
            },
            .cast => |node| return try self.emitGlobalInitializer(node.value.*, node.ty.*),
            else => {},
        }
        switch (resolved_ty.kind) {
            .closure_type => if (isBindCall(expr)) {
                return try self.emitGlobalBindInitializer(expr, resolved_ty);
            },
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
            .string_literal => |literal| blk: {
                if (!isStringLiteralTarget(resolved_ty)) break :blk error.UnsupportedLlvmEmission;
                const global = try self.internStringLiteral(literal);
                break :blk try std.fmt.allocPrint(
                    self.scratch.allocator(),
                    "getelementptr ([{d} x i8], ptr @{s}, i64 0, i64 0)",
                    .{ global.len, global.name },
                );
            },
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
            .address_of => |inner| try self.globalAddressInitializer(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn globalAddressInitializer(self: *LlvmEmitter, expr: ast.Expr) anyerror![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| if (self.global_types.contains(ident.text))
                try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text})
            else
                error.UnsupportedLlvmEmission,
            .index => |node| try self.globalIndexAddressInitializer(node),
            .member => |node| try self.globalMemberAddressInitializer(node),
            .grouped => |inner| try self.globalAddressInitializer(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitGlobalBindInitializer(self: *LlvmEmitter, expr: ast.Expr, closure_ty: ast.TypeExpr) ![]const u8 {
        const call = switch (expr.kind) {
            .call => |call| call,
            .grouped => |inner| return self.emitGlobalBindInitializer(inner.*, closure_ty),
            else => return error.UnsupportedLlvmEmission,
        };
        if (self.resolveAliasType(closure_ty).kind != .closure_type) return error.UnsupportedLlvmEmission;
        const fname = calleeIdentName(call.args[1]) orelse return error.UnsupportedLlvmEmission;
        if (!self.fn_sigs.contains(fname)) return error.UnsupportedLlvmEmission;
        const env = try self.globalAddressInitializer(call.args[0]);
        return try std.fmt.allocPrint(self.scratch.allocator(), "{{ ptr @{s}, ptr {s} }}", .{ fname, env });
    }

    fn globalIndexAddressInitializer(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const resolved_base_ty = self.resolveAliasType(base_ty);
        const index = self.globalConstIndexValue(node.index.*) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = try self.globalAddressInitializer(node.base.*);
        return switch (resolved_base_ty.kind) {
            .array => try std.fmt.allocPrint(
                self.scratch.allocator(),
                "getelementptr ({s}, ptr {s}, i64 0, i64 {d})",
                .{ try self.llvmType(resolved_base_ty), base_ptr, index },
            ),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn globalMemberAddressInitializer(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const struct_ty = self.memberBaseStructType(base_ty) orelse return error.UnsupportedLlvmEmission;
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        const index = structFieldIndex(struct_decl, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = try self.globalAddressInitializer(node.base.*);
        return std.fmt.allocPrint(
            self.scratch.allocator(),
            "getelementptr ({s}, ptr {s}, i64 0, i32 {d})",
            .{ try self.llvmType(struct_ty), base_ptr, index },
        );
    }

    fn globalConstIndexValue(self: *LlvmEmitter, expr: ast.Expr) ?u64 {
        if (self.foldConstGlobalValue(expr)) |value| {
            return switch (value) {
                .int => |n| if (n >= 0 and n <= std.math.maxInt(u64)) @intCast(n) else null,
                else => null,
            };
        }
        return switch (expr.kind) {
            .ident => |ident| if (self.global_initializers.get(ident.text)) |initializer|
                self.globalConstIndexValue(initializer)
            else
                null,
            .grouped => |inner| self.globalConstIndexValue(inner.*),
            else => null,
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
            // LLVM float/double constants accept the exact f64 bit pattern in hex. For an
            // f32 target, round to f32 first (then widen) so the value is representable.
            .float => |f| blk: {
                const tname = switch (resolved.kind) {
                    .name => |n| n.text,
                    else => "",
                };
                const fv: f64 = if (std.mem.eql(u8, tname, "f32")) @floatCast(@as(f32, @floatCast(f))) else f;
                break :blk try std.fmt.allocPrint(self.scratch.allocator(), "0x{X:0>16}", .{@as(u64, @bitCast(fv))});
            },
            .void, .bytes => error.UnsupportedLlvmEmission,
        };
    }

    fn zeroInitializer(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        const resolved_ty = self.resolveAliasType(ty);
        if (self.atomicPayloadType(resolved_ty)) |payload_ty| return self.zeroInitializer(payload_ty);
        if (self.maybeUninitPayloadType(resolved_ty)) |payload_ty| return self.zeroInitializer(payload_ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "bool"))
                "0"
            else if (self.isFloatTypeOf(resolved_ty))
                "0.0"
            else if (isOpaqueAddressTypeName(name.text))
                "0"
            else if (self.integerBitsOf(resolved_ty) != null or self.enumDeclForType(resolved_ty) != null)
                "0"
            else if (self.overlayInfoForType(resolved_ty) != null)
                "zeroinitializer"
            else if (self.taggedUnionForType(resolved_ty) != null)
                "zeroinitializer"
            else if (self.structDeclForType(resolved_ty) != null)
                "zeroinitializer"
            else if (libraryScalarLlvmType(name.text) != null)
                "0"
            else
                error.UnsupportedLlvmEmission,
            .pointer, .raw_many_pointer, .nullable => "null",
            .slice => "zeroinitializer",
            .array => "zeroinitializer",
            .qualified => |node| try self.zeroInitializer(node.child.*),
            .generic => |node| if (self.resultInfo(resolved_ty)) |_|
                "zeroinitializer"
            else if (isPayloadDomainGenericName(node.base.text) and node.args.len == 1)
                try self.zeroInitializer(node.args[0])
            else
                error.UnsupportedLlvmEmission,
            else => error.UnsupportedLlvmEmission,
        };
    }

    // `#[backend_name("Y")]`: a module-level alias exposing the override symbol, pointing at the
    // function emitted under its source name. The aliasee type is the function type.
    fn emitBackendNameAliases(self: *LlvmEmitter, module: ast.Module) !void {
        for (module.decls) |decl| {
            if (decl.kind != .fn_decl) continue;
            const fn_decl = decl.kind.fn_decl;
            if (fn_decl.body == null) continue;
            const backend = self.backend_names.get(fn_decl.name.text) orelse continue;
            const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
            try self.out.print(self.allocator, "@{s} = alias {s} (", .{ backend, try self.llvmType(ret_ty) });
            for (fn_decl.params, 0..) |param, i| {
                if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                try self.out.appendSlice(self.allocator, try self.llvmType(param.ty));
            }
            try self.out.print(self.allocator, "), ptr @{s}\n", .{fn_decl.name.text});
        }
    }

    fn emitFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl, body: ast.Block) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        const ret_llvm = try self.llvmType(ret_ty);
        const old_scope = self.current_debug_scope;
        const old_span = self.current_debug_span;
        const old_return_ty = self.current_return_ty;
        self.current_debug_scope = if (self.fn_sigs.get(fn_decl.name.text)) |sig| sig.debug_id else null;
        self.current_debug_span = fn_decl.name.span;
        self.current_return_ty = ret_ty;
        defer {
            self.current_debug_scope = old_scope;
            self.current_debug_span = old_span;
            self.current_return_ty = old_return_ty;
        }
        try self.out.print(self.allocator, "define {s} @{s}(", .{ ret_llvm, fn_decl.name.text });
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} %{s}", .{ try self.llvmType(param.ty), param.name.text });
        }
        if (self.current_debug_scope) |scope| {
            try self.out.print(self.allocator, ") !dbg !{d} {{\nbb_entry:\n", .{scope});
        } else {
            try self.out.appendSlice(self.allocator, ") {\nbb_entry:\n");
        }
        self.temp_index = 0;
        self.trap_index = 0;
        self.local_types.clearRetainingCapacity();
        self.local_slots.clearRetainingCapacity();
        self.defer_stack.clearRetainingCapacity();
        for (fn_decl.params) |param| {
            try self.local_types.put(param.name.text, param.ty);
            if (self.isAggregateType(param.ty) or self.atomicPayloadType(param.ty) != null) {
                const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{param.name.text});
                try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, try self.llvmType(param.ty) });
                try self.out.print(self.allocator, "  store {s} %{s}, ptr {s}\n", .{ try self.llvmType(param.ty), param.name.text, ptr });
                try self.local_slots.put(param.name.text, .{ .ty = param.ty, .ptr = ptr });
            }
        }

        if (!try self.emitBlock(body, ret_ty)) {
            if (typeNameEql(ret_ty, "void")) {
                try self.emitReturnVoid(fn_decl.name.span);
            } else if (typeNameEql(ret_ty, "never")) {
                try self.out.appendSlice(self.allocator, "  unreachable\n");
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
                try self.emitPackedBitsLiteralValue(info, fields)
            else
                try self.emitStructLiteralValue(expected_ty, fields),
            .binary => |node| try self.emitBinary(node, expected_ty),
            .unary => |node| try self.emitUnary(node, expected_ty),
            .cast => |node| try self.emitCast(node.value.*, node.ty.*),
            .address_of => |inner| try self.emitAddressOf(inner.*),
            .deref => |inner| try self.emitDeref(inner.*, expected_ty),
            .index => |node| try self.emitIndexLoad(node),
            .slice => |node| try self.emitSlice(node, expr.span),
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
        if (self.pointerAddressCoercion(source_ty, expected_ty)) {
            return try self.emitBitcastValue(value, source_ty, expected_ty);
        }
        return value;
    }

    fn emitIdent(self: *LlvmEmitter, ident: ast.Ident) ![]const u8 {
        if (self.local_slots.get(ident.text)) |slot| {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(slot.ty), slot.ptr, try self.debugCallSuffix() });
            return result;
        }
        if (self.local_types.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
        if (self.global_types.get(ident.text)) |ty| {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr @{s}{s}\n", .{ result, try self.llvmType(ty), ident.text, try self.debugCallSuffix() });
            return result;
        }
        if (self.fn_sigs.contains(ident.text)) return try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
        return try std.fmt.allocPrint(self.scratch.allocator(), "%{s}", .{ident.text});
    }

    fn emitBlock(self: *LlvmEmitter, block: ast.Block, ret_ty: ast.TypeExpr) anyerror!bool {
        const defer_start = self.defer_stack.items.len;
        errdefer self.defer_stack.items.len = defer_start;
        for (block.items) |stmt| {
            const old_debug_span = self.current_debug_span;
            self.current_debug_span = stmt.span;
            defer self.current_debug_span = old_debug_span;

            switch (stmt.kind) {
                .let_decl => |local| try self.emitLocalDecl(local),
                .var_decl => |local| try self.emitLocalDecl(local),
                .assignment => |node| try self.emitAssignment(node.target, node.value),
                .@"defer" => |expr| try self.defer_stack.append(self.allocator, expr),
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
                        try self.emitDeferredCleanupsFrom(0, ret_ty);
                        try self.emitReturnVoid(stmt.span);
                    } else if (typeNameEql(ret_ty, "never")) {
                        return error.UnsupportedLlvmEmission;
                    } else {
                        const expr = maybe_expr orelse return error.UnsupportedLlvmEmission;
                        const value = try self.emitExpr(expr, ret_ty);
                        try self.emitDeferredCleanupsFrom(0, ret_ty);
                        try self.emitReturnValue(ret_ty, value, stmt.span);
                    }
                    return true;
                },
                .@"switch" => |node| {
                    if (try self.emitNullableSwitch(node, ret_ty)) |terminated| {
                        if (terminated) return true;
                        continue;
                    }
                    if (try self.emitResultSwitch(node, ret_ty)) |terminated| {
                        if (terminated) return true;
                        continue;
                    }
                    if (try self.emitTaggedUnionSwitch(node, ret_ty)) |terminated| {
                        if (terminated) return true;
                        continue;
                    }
                    if (try self.emitScalarSwitch(node, ret_ty)) |terminated| {
                        if (terminated) return true;
                        continue;
                    }
                    return error.UnsupportedLlvmEmission;
                },
                .if_let => |node| {
                    if (try self.emitResultIfLet(node, ret_ty)) return true;
                    if (try self.emitNullableIfLet(node, ret_ty)) return true;
                },
                .@"break" => {
                    const labels = self.loop_stack.getLastOrNull() orelse return error.UnsupportedLlvmEmission;
                    try self.emitDeferredCleanupsFrom(labels.cleanup_start, ret_ty);
                    self.defer_stack.items.len = labels.cleanup_start;
                    try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ labels.break_label, try self.debugCallSuffix() });
                    return true;
                },
                .@"continue" => {
                    const labels = self.loop_stack.getLastOrNull() orelse return error.UnsupportedLlvmEmission;
                    try self.emitDeferredCleanupsFrom(labels.cleanup_start, ret_ty);
                    self.defer_stack.items.len = labels.cleanup_start;
                    try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ labels.continue_label, try self.debugCallSuffix() });
                    return true;
                },
                .expr => |expr| {
                    try self.emitExprStatement(expr);
                    // A diverging statement (`trap(...)`, `unreachable`, a `-> never` call) emits
                    // its own `unreachable` terminator, so the block ends here — even if the
                    // function returns a value, this path does not fall through.
                    if (self.exprStatementDiverges(expr)) return true;
                },
                .asm_stmt => |asm_stmt| try self.emitAsmStmt(asm_stmt),
            }
        }
        try self.emitDeferredCleanupsFrom(defer_start, ret_ty);
        self.defer_stack.items.len = defer_start;
        return false;
    }

    fn emitDeferredCleanupsFrom(self: *LlvmEmitter, start: usize, ret_ty: ast.TypeExpr) !void {
        var index = self.defer_stack.items.len;
        while (index > start) {
            index -= 1;
            try self.emitDeferredCleanup(self.defer_stack.items[index], ret_ty);
        }
    }

    fn emitDeferredCleanup(self: *LlvmEmitter, expr: ast.Expr, ret_ty: ast.TypeExpr) !void {
        switch (expr.kind) {
            .block => |block| {
                if (try self.emitScopedBlock(block, ret_ty)) return error.UnsupportedLlvmEmission;
            },
            else => try self.emitExprStatement(expr),
        }
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

    fn emitAsmStmt(self: *LlvmEmitter, asm_stmt: ast.AsmStmt) !void {
        if (asm_stmt.form == .precise) return self.emitPreciseAsmStmt(asm_stmt);
        if (asm_stmt.form != .@"opaque" or asm_stmt.inputs.len != 0 or asm_stmt.outputs.len != 0) return error.UnsupportedLlvmEmission;
        const template = try llvmAsmTemplate(self.scratch.allocator(), asm_stmt.templates);
        const constraints = try llvmAsmClobbers(self.scratch.allocator(), asm_stmt.clobbers);
        const sideeffect: []const u8 = if (asm_stmt.is_volatile) " sideeffect" else "";
        try self.out.print(self.allocator, "  call void asm{s} \"{s}\", \"{s}\"(){s}\n", .{ sideeffect, template, constraints, try self.debugCallSuffix() });
    }

    fn emitPreciseAsmStmt(self: *LlvmEmitter, asm_stmt: ast.AsmStmt) !void {
        const template = try llvmPreciseAsmTemplate(self.scratch.allocator(), asm_stmt.templates);
        const constraints = try llvmPreciseAsmConstraints(self.scratch.allocator(), asm_stmt);
        const ret_ty = try self.preciseAsmReturnType(asm_stmt.outputs);
        const sideeffect: []const u8 = if (asm_stmt.is_volatile) " sideeffect" else "";

        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (asm_stmt.inputs) |input| {
            try args.append(self.allocator, .{ .ty = input.ty, .value = try self.emitExpr(input.value, input.ty) });
        }

        const result: ?[]const u8 = if (asm_stmt.outputs.len == 0) null else try self.nextTemp();
        if (result) |name| {
            try self.out.print(self.allocator, "  {s} = call {s} asm{s} \"{s}\", \"{s}\"(", .{ name, ret_ty, sideeffect, template, constraints });
        } else {
            try self.out.print(self.allocator, "  call void asm{s} \"{s}\", \"{s}\"(", .{ sideeffect, template, constraints });
        }
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});

        const asm_result = result orelse return;
        for (asm_stmt.outputs, 0..) |output, i| {
            const slot = self.local_slots.get(output.name.text) orelse return error.UnsupportedLlvmEmission;
            const value = if (asm_stmt.outputs.len == 1) asm_result else blk: {
                const extracted = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ extracted, ret_ty, asm_result, i });
                break :blk extracted;
            };
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(output.ty), value, slot.ptr, try self.debugCallSuffix() });
        }
    }

    fn preciseAsmReturnType(self: *LlvmEmitter, outputs: []const ast.AsmOutput) ![]const u8 {
        if (outputs.len == 0) return "void";
        if (outputs.len == 1) return try self.llvmType(outputs[0].ty);
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(self.scratch.allocator(), "{ ");
        for (outputs, 0..) |output, i| {
            if (i != 0) try text.appendSlice(self.scratch.allocator(), ", ");
            try text.appendSlice(self.scratch.allocator(), try self.llvmType(output.ty));
        }
        try text.appendSlice(self.scratch.allocator(), " }");
        return text.toOwnedSlice(self.scratch.allocator());
    }

    fn emitExprStatement(self: *LlvmEmitter, expr: ast.Expr) !void {
        switch (expr.kind) {
            .unreachable_expr => {
                _ = try self.emitNeverExpr(expr);
                return;
            },
            .call => |call| {
                // A diverging call statement — `trap(.Assert);` or a `-> never` function — halts
                // the program; emit the trap/call followed by `unreachable` (no value needed even
                // in a value-returning function, since this path does not fall through).
                if (try self.emitNeverExpr(expr)) return;
                if (isDropCall(call.callee.*)) {
                    if (call.args.len != 1) return error.UnsupportedLlvmEmission;
                    const arg_ty = self.exprType(call.args[0]) orelse return error.UnsupportedLlvmEmission;
                    _ = try self.emitExpr(call.args[0], arg_ty);
                    return;
                }
                if (try self.emitBuiltinVoidCall(call)) return;
                if (self.callReturnType(call)) |ret_ty| {
                    // A `void` or `-> never` call statement produces no value, so it is emitted
                    // without a result name (a named void instruction is invalid LLVM).
                    if (typeNameEql(ret_ty, "void") or typeNameEql(ret_ty, "never")) {
                        try self.emitVoidStatementCall(call);
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

    /// Emit the common "allocate a slot then store a value into it" idiom:
    ///   {ptr} = alloca {ty}
    ///   store {ty} {value}, ptr {ptr}{dbg}
    fn emitAllocaStore(self: *LlvmEmitter, ptr: []const u8, ty: []const u8, value: []const u8) !void {
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, ty });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ ty, value, ptr, try self.debugCallSuffix() });
    }

    /// Emit a conditional branch where one side leads to a trap-and-unreachable block.
    /// `label1`/`label2` are the true/false branch targets; `block_label` is the label
    /// whose block contains the trap call (followed by `unreachable`), and `after_label`
    /// is the continuation label printed after that block. This faithfully reproduces
    /// both branch polarities — callers choose which label is the trap target.
    fn emitTrapBranch(
        self: *LlvmEmitter,
        cond: []const u8,
        label1: []const u8,
        label2: []const u8,
        block_label: []const u8,
        after_label: []const u8,
        trap_fn: []const u8,
    ) !void {
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n  call void @mc_trap_{s}(){s}\n  unreachable\n{s}:\n", .{ cond, label1, label2, try self.debugCallSuffix(), block_label, trap_fn, try self.debugCallSuffix(), after_label });
    }

    fn emitAssert(self: *LlvmEmitter, expr: ast.Expr) !void {
        const ty = self.exprType(expr) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(ty, "bool")) return error.UnsupportedLlvmEmission;
        const condition = try self.emitExpr(expr, ty);
        const cont = try self.nextLabel("assert_ok");
        const trap = try self.nextLabel("trap_assert");
        try self.emitTrapBranch(condition, cont, trap, trap, cont, "Assert");
    }

    fn emitTryExpr(self: *LlvmEmitter, operand: ast.Expr, expected_ty: ast.TypeExpr) ![]const u8 {
        const operand_ty = self.exprType(operand) orelse return error.UnsupportedLlvmEmission;
        _ = try self.llvmType(expected_ty);
        if (self.resultInfo(operand_ty)) |info| {
            _ = try self.resultPayloadLlvmType(info.ok_ty);
            const value = try self.emitExpr(operand, operand_ty);
            if (try self.emitResultPropagationCheck(value, operand_ty, info, operand.span)) {
                // continued in the ok block
            } else {
                try self.emitResultUnwrapCheck(value, operand_ty);
            }
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ payload, try self.llvmType(operand_ty), value });
            return payload;
        }
        const inner_ty = self.nullableInnerType(operand_ty) orelse return error.UnsupportedLlvmEmission;
        const value = try self.emitExpr(operand, operand_ty);
        try self.emitNullUnwrapCheck(value);
        _ = inner_ty;
        return value;
    }

    fn emitResultPropagationCheck(self: *LlvmEmitter, value: []const u8, operand_ty: ast.TypeExpr, info: ResultTypeInfo, span: ast.Span) !bool {
        const return_ty = self.current_return_ty orelse return false;
        const return_info = self.resultInfo(return_ty) orelse return false;
        if (!std.mem.eql(u8, try self.llvmType(info.err_ty), try self.llvmType(return_info.err_ty))) return false;

        const is_ok = try self.nextTemp();
        const ok_label = try self.nextLabel("try_ok");
        const err_label = try self.nextLabel("try_err");
        const err_value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(operand_ty), value });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ is_ok, ok_label, err_label, try self.debugCallSuffix(), err_label });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 2\n", .{ err_value, try self.llvmType(operand_ty), value });
        const ok_zero = try self.resultPayloadZero(return_info.ok_ty);
        const propagated_value = try self.emitResultValue(return_ty, "false", ok_zero, err_value);
        // `?` returns from the function on the error branch, so it must run every active
        // defer first — exactly like an explicit `return`. Flush from 0 (whole function
        // scope) without truncating: the ok path continues after this block with the same
        // active defers.
        try self.emitDeferredCleanupsFrom(0, return_ty);
        try self.emitReturnValue(return_ty, propagated_value, span);
        try self.out.print(self.allocator, "{s}:\n", .{ok_label});
        return true;
    }

    fn emitResultUnwrapCheck(self: *LlvmEmitter, value: []const u8, result_ty: ast.TypeExpr) !void {
        const is_ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_result");
        const cont = try self.nextLabel("result_ok");
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(result_ty), value });
        try self.emitTrapBranch(is_ok, cont, trap, trap, cont, "InvalidRepresentation");
    }

    fn emitNullUnwrapCheck(self: *LlvmEmitter, value: []const u8) !void {
        const is_null = try self.nextTemp();
        const trap = try self.nextLabel("trap_null");
        const cont = try self.nextLabel("nonnull");
        try self.out.print(self.allocator, "  {s} = icmp eq ptr {s}, null\n", .{ is_null, value });
        try self.emitTrapBranch(is_null, trap, cont, trap, cont, "NullUnwrap");
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
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ is_some, then_label, else_label, try self.debugCallSuffix(), then_label });

        const old_type = self.local_types.fetchRemove(binding.text);
        const old_slot = self.local_slots.fetchRemove(binding.text);
        defer restoreLocal(&self.local_types, binding.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, binding.text, old_slot) catch {};

        const binding_ptr = try self.nextBindingPtr(binding.text);
        try self.emitAllocaStore(binding_ptr, try self.llvmType(inner_ty), subject);
        try self.local_types.put(binding.text, inner_ty);
        try self.local_slots.put(binding.text, .{ .ty = inner_ty, .ptr = binding_ptr });

        const then_terminated = try self.emitBlock(node.then_block, ret_ty);
        if (!then_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });

        _ = self.local_types.remove(binding.text);
        _ = self.local_slots.remove(binding.text);

        try self.out.print(self.allocator, "{s}:\n", .{else_label});
        const else_terminated = if (node.else_block) |else_block| try self.emitBlock(else_block, ret_ty) else false;
        if (!else_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        if (then_terminated and else_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitResultIfLet(self: *LlvmEmitter, node: ast.IfLet, ret_ty: ast.TypeExpr) !bool {
        const tag_bind = switch (node.pattern.kind) {
            .tag_bind => |tag_bind| tag_bind,
            else => return false,
        };
        const is_ok_pattern = if (std.mem.eql(u8, tag_bind.tag.text, "ok"))
            true
        else if (std.mem.eql(u8, tag_bind.tag.text, "err"))
            false
        else
            return false;
        const subject_ty = self.exprType(node.value) orelse return false;
        const info = self.resultInfo(subject_ty) orelse return false;
        const binding_ty = if (is_ok_pattern) info.ok_ty else info.err_ty;
        const payload_index: u8 = if (is_ok_pattern) 1 else 2;
        const subject = try self.emitExpr(node.value, subject_ty);
        const then_label = try self.nextLabel(if (is_ok_pattern) "result_ok" else "result_err");
        const else_label = try self.nextLabel(if (is_ok_pattern) "result_err" else "result_ok");
        const end_label = try self.nextLabel("result_end");
        const is_ok = try self.nextTemp();
        const matches = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(subject_ty), subject });
        if (is_ok_pattern) {
            try self.out.print(self.allocator, "  {s} = icmp eq i1 {s}, true\n", .{ matches, is_ok });
        } else {
            try self.out.print(self.allocator, "  {s} = icmp eq i1 {s}, false\n", .{ matches, is_ok });
        }
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ matches, then_label, else_label, try self.debugCallSuffix(), then_label });

        const old_type = self.local_types.fetchRemove(tag_bind.binding.text);
        const old_slot = self.local_slots.fetchRemove(tag_bind.binding.text);
        defer restoreLocal(&self.local_types, tag_bind.binding.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, tag_bind.binding.text, old_slot) catch {};

        const binding_ptr = try self.nextBindingPtr(tag_bind.binding.text);
        const payload = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ payload, try self.llvmType(subject_ty), subject, payload_index });
        try self.emitAllocaStore(binding_ptr, try self.resultPayloadLlvmType(binding_ty), payload);
        try self.local_types.put(tag_bind.binding.text, binding_ty);
        try self.local_slots.put(tag_bind.binding.text, .{ .ty = binding_ty, .ptr = binding_ptr });

        const then_terminated = try self.emitBlock(node.then_block, ret_ty);
        if (!then_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });

        _ = self.local_types.remove(tag_bind.binding.text);
        _ = self.local_slots.remove(tag_bind.binding.text);

        try self.out.print(self.allocator, "{s}:\n", .{else_label});
        const else_terminated = if (node.else_block) |else_block| try self.emitBlock(else_block, ret_ty) else false;
        if (!else_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
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

    // True when an expression *statement* emits its own `unreachable` terminator: `unreachable`
    // or a `trap(...)`. Such a statement terminates its block, so even in a value-returning
    // function the block ends there with no fall-through. (A `-> never` call is NOT included: it
    // lowers as an ordinary call and the enclosing block falls through to its normal terminator.)
    fn exprStatementDiverges(self: *LlvmEmitter, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .unreachable_expr => true,
            .call => |call| trapHelperForCall(call) != null,
            .grouped => |inner| self.exprStatementDiverges(inner.*),
            else => false,
        };
    }

    fn emitLocalDecl(self: *LlvmEmitter, local: ast.LocalDecl) !void {
        if (local.names.len != 1) return error.UnsupportedLlvmEmission;
        const init = local.init orelse return error.UnsupportedLlvmEmission;
        const ty = local.ty orelse self.exprType(init) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(ty);
        const resolved_ty = self.resolveAliasType(ty);
        const name = local.names[0].text;
        const ptr = try self.nextBindingPtr(name);
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, llvm_ty });
        try self.local_types.put(name, ty);
        try self.local_slots.put(name, .{ .ty = ty, .ptr = ptr });
        if (isUninitExpr(init)) {
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, try self.zeroInitializer(ty), ptr, try self.debugCallSuffix() });
            return;
        }
        if (resolved_ty.kind == .array) {
            if (init.kind == .array_literal) {
                try self.emitArrayLiteralStores(ptr, resolved_ty, init.kind.array_literal);
            } else {
                const value = try self.emitExpr(init, ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
            }
            return;
        }
        if (self.structDeclForType(resolved_ty)) |_| {
            if (init.kind == .struct_literal) {
                try self.emitStructLiteralStores(ptr, resolved_ty, init.kind.struct_literal);
            } else {
                const value = try self.emitExpr(init, ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
            }
            return;
        }
        const value = try self.emitExpr(init, ty);
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
    }

    fn emitAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr) !void {
        if (try self.emitIndexAssignment(target, value_expr)) return;
        if (try self.emitMemberAssignment(target, value_expr)) return;
        if (assignmentIdent(target)) |ident| {
            if (self.local_slots.get(ident.text)) |slot| {
                const llvm_ty = try self.llvmType(slot.ty);
                const value = try self.emitExpr(value_expr, slot.ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, slot.ptr, try self.debugCallSuffix() });
                return;
            }
            if (self.global_types.get(ident.text)) |ty| {
                const llvm_ty = try self.llvmType(ty);
                const value = try self.emitExpr(value_expr, ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr @{s}{s}\n", .{ llvm_ty, value, ident.text, try self.debugCallSuffix() });
                return;
            }
            return error.UnsupportedLlvmEmission;
        }
        if (derefTarget(target)) |ptr_expr| {
            const pointee_ty = self.derefPointeeType(ptr_expr) orelse return error.UnsupportedLlvmEmission;
            const llvm_ty = try self.llvmType(pointee_ty);
            const ptr = try self.emitExpr(ptr_expr, try self.pointerTypeFor(pointee_ty));
            const value = try self.emitExpr(value_expr, pointee_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
            return;
        }
        return error.UnsupportedLlvmEmission;
    }

    fn emitIndexAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr) !bool {
        return switch (target.kind) {
            .index => |node| blk: {
                if (overlayMemberFromIndexBase(node.base.*)) |member| {
                    if (self.overlayField(member.base.*, member.name.text)) |field| {
                        const element_ty = overlayByteArrayElementType(field.ty) orelse return error.UnsupportedLlvmEmission;
                        const ptr = try self.emitIndexAddress(node);
                        const value = try self.emitExpr(value_expr, element_ty);
                        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(element_ty), value, ptr, try self.debugCallSuffix() });
                        break :blk true;
                    }
                }
                const element_ty = self.indexElementType(node.base.*) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.emitIndexAddress(node);
                const value = try self.emitExpr(value_expr, element_ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(element_ty), value, ptr, try self.debugCallSuffix() });
                break :blk true;
            },
            .grouped => |inner| try self.emitIndexAssignment(inner.*, value_expr),
            else => false,
        };
    }

    fn emitBuiltinVoidCall(self: *LlvmEmitter, call: anytype) !bool {
        if (self.maybeUninitCallInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "write")) return false;
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const ptr = try self.storageBaseAddress(info.base);
            const value = try self.emitExpr(call.args[0], info.payload_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(info.payload_ty), value, ptr, try self.debugCallSuffix() });
            return true;
        }
        if (isRawStoreCall(call.callee.*)) {
            if (call.type_args.len != 1 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const value_ty = call.type_args[0];
            _ = rawScalarTypeName(value_ty) orelse return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const value = try self.emitExpr(call.args[1], value_ty);
            const ptr = try self.nextTemp();
            const llvm_ty = try self.llvmType(value_ty);
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, addr });
            try self.out.print(self.allocator, "  store volatile {s} {s}, ptr {s}{s}\n", .{ llvm_ty, value, ptr, try self.debugCallSuffix() });
            return true;
        }
        if (self.mmioAccessInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "write")) return false;
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const ordering = orderingArg(call.args[1]) orelse return error.UnsupportedLlvmEmission;
            const raw_value = try self.emitExpr(call.args[0], info.value_ty);
            const value = if (std.mem.eql(u8, try self.llvmType(info.value_ty), try self.llvmType(info.storage_ty)))
                raw_value
            else
                try self.castValue(raw_value, info.value_ty, info.storage_ty);
            try self.emitMmioFence(ordering, .before_store);
            const ptr = try self.emitMmioRegisterAddress(info);
            try self.out.print(self.allocator, "  store volatile {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(info.storage_ty), value, ptr, try self.debugCallSuffix() });
            return true;
        }
        if (self.dmaCacheCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            _ = try self.emitExpr(call.args[0], info.dma_ty);
            if (std.mem.eql(u8, info.op, "clean")) {
                try self.out.print(self.allocator, "  fence release{s}\n", .{try self.debugCallSuffix()});
            } else if (std.mem.eql(u8, info.op, "invalidate")) {
                try self.out.print(self.allocator, "  fence acquire{s}\n", .{try self.debugCallSuffix()});
            } else {
                return error.UnsupportedLlvmEmission;
            }
            return true;
        }
        if (fenceOrderingForCall(call.callee.*)) |ordering| {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            try self.out.print(self.allocator, "  fence {s}{s}\n", .{ ordering, try self.debugCallSuffix() });
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
            const ptr = try self.atomicAddress(info);
            const value = try self.emitAtomicValueForStorage(call.args[0], info.payload_ty);
            try self.out.print(self.allocator, "  store atomic {s} {s}, ptr {s} {s}, align {d}{s}\n", .{ try self.atomicStorageLlvmType(info.payload_ty), value, ptr, llvm_order, self.llvmAlignOf(info.payload_ty), try self.debugCallSuffix() });
            return true;
        }
        return false;
    }

    fn emitMemberAssignment(self: *LlvmEmitter, target: ast.Expr, value_expr: ast.Expr) !bool {
        return switch (target.kind) {
            .member => |node| blk: {
                const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
                if (self.packedBitsInfoForType(base_ty)) |info| {
                    const bit_index = self.packedBitsFieldIndex(info, node.name.text) orelse return error.UnsupportedLlvmEmission;
                    const ptr = try self.packedBitsBaseAddress(node.base.*);
                    const llvm_ty = try self.llvmType(info.repr);
                    const current = try self.nextTemp();
                    const set_value = try self.nextTemp();
                    const clear_value = try self.nextTemp();
                    const result = try self.nextTemp();
                    const flag = try self.emitExpr(value_expr, simpleType(value_expr.span, "bool"));
                    try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ current, llvm_ty, ptr });
                    try self.out.print(self.allocator, "  {s} = or {s} {s}, {d}\n", .{ set_value, llvm_ty, current, packedBitsMask(bit_index) });
                    try self.out.print(self.allocator, "  {s} = and {s} {s}, {d}\n", .{ clear_value, llvm_ty, current, packedBitsClearMask(info, bit_index) orelse return error.UnsupportedLlvmEmission });
                    try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {s}, {s} {s}\n", .{ result, flag, llvm_ty, set_value, llvm_ty, clear_value });
                    try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ llvm_ty, result, ptr, try self.debugCallSuffix() });
                    break :blk true;
                }
                if (self.overlayField(node.base.*, node.name.text)) |field| {
                    if (overlayByteArrayElementType(field.ty) != null) return error.UnsupportedLlvmEmission;
                    const ptr = try self.emitOverlayFieldAddress(node.base.*, field);
                    const value = try self.emitExpr(value_expr, field.ty);
                    try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(field.ty), value, ptr, try self.debugCallSuffix() });
                    break :blk true;
                }
                const field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.emitMemberAddress(node);
                const value = try self.emitExpr(value_expr, field.ty);
                try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(field.ty), value, ptr, try self.debugCallSuffix() });
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

        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const condition = try self.emitExpr(condition_expr, condition_ty);
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ condition, body_label, end_label, try self.debugCallSuffix(), body_label });
        try self.loop_stack.append(self.allocator, .{ .break_label = end_label, .continue_label = cond_label, .cleanup_start = self.defer_stack.items.len });
        defer _ = self.loop_stack.pop();
        const body_terminated = try self.emitBlock(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ cond_label, try self.debugCallSuffix() });
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
        const binding_ptr = try self.nextBindingPtr(binding.text);
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

        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const index = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        const len = try self.emitIterableLen(iterable, iterable_ty, iterable_slot);
        const ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ ok, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ ok, body_label, end_label, try self.debugCallSuffix(), body_label });

        const element_ptr = try self.emitForElementPtr(iterable, iterable_ty, iterable_ptr, index);
        const element_value = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ element_value, element_llvm, element_ptr });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ element_llvm, element_value, binding_ptr, try self.debugCallSuffix() });

        try self.loop_stack.append(self.allocator, .{ .break_label = end_label, .continue_label = step_label, .cleanup_start = self.defer_stack.items.len });
        defer _ = self.loop_stack.pop();
        const body_terminated = try self.emitBlock(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ step_label, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "{s}:\n", .{step_label});
        const step_index = try self.nextTemp();
        const next_index = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ step_index, index_ptr });
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, step_index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), end_label });
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
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {s}\n", .{ result, try self.llvmType(iterable_ty), base_ptr, index });
                break :blk result;
            },
            .slice => |slice| blk: {
                const ptr = iterable_ptr orelse return error.UnsupportedLlvmEmission;
                const value = try self.nextTemp();
                const data = try self.nextTemp();
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ value, try self.llvmType(iterable_ty), ptr });
                try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ data, try self.llvmType(iterable_ty), value });
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(slice.child.*), data, index });
                break :blk result;
            },
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitNullableSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !?bool {
        const subject_ty = self.exprType(node.subject) orelse return null;
        const inner_ty = self.nullableInnerType(subject_ty) orelse return null;
        if (node.arms.len == 0) return error.UnsupportedLlvmEmission;

        var bind_index: ?usize = null;
        var binding: ?ast.Ident = null;
        var wildcard_index: ?usize = null;
        for (node.arms, 0..) |arm, i| {
            if (arm.patterns.len != 1) return null;
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
                else => return null,
            }
        }
        const some_i = bind_index orelse return null;
        const none_i = wildcard_index orelse return null;
        const bind = binding orelse return null;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const some_label = try self.nextLabel("nullable_some");
        const none_label = try self.nextLabel("nullable_none");
        const end_label = try self.nextLabel("nullable_end");
        const is_some = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = icmp ne ptr {s}, null\n", .{ is_some, subject });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ is_some, some_label, none_label, try self.debugCallSuffix() });

        var all_terminated = true;
        try self.out.print(self.allocator, "{s}:\n", .{some_label});
        const old_type = self.local_types.fetchRemove(bind.text);
        const old_slot = self.local_slots.fetchRemove(bind.text);
        defer restoreLocal(&self.local_types, bind.text, old_type) catch {};
        defer restoreLocal(&self.local_slots, bind.text, old_slot) catch {};

        const binding_ptr = try self.nextBindingPtr(bind.text);
        try self.emitAllocaStore(binding_ptr, try self.llvmType(inner_ty), subject);
        try self.local_types.put(bind.text, inner_ty);
        try self.local_slots.put(bind.text, .{ .ty = inner_ty, .ptr = binding_ptr });
        const some_terminated = try self.emitSwitchBody(node.arms[some_i].body, ret_ty);
        if (!some_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        }
        _ = self.local_types.remove(bind.text);
        _ = self.local_slots.remove(bind.text);

        try self.out.print(self.allocator, "{s}:\n", .{none_label});
        const none_terminated = try self.emitSwitchBody(node.arms[none_i].body, ret_ty);
        if (!none_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        }
        if (all_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitResultSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !?bool {
        const subject_ty = self.exprType(node.subject) orelse return null;
        const info = self.resultInfo(subject_ty) orelse return null;
        if (node.arms.len != 2) return error.UnsupportedLlvmEmission;

        var ok_index: ?usize = null;
        var ok_binding: ?ast.Ident = null;
        var err_index: ?usize = null;
        var err_binding: ?ast.Ident = null;
        var wildcard_index: ?usize = null;
        for (node.arms, 0..) |arm, i| {
            if (arm.patterns.len != 1) return null;
            const pattern = arm.patterns[0];
            if (pattern.kind == .wildcard) {
                if (wildcard_index != null) return error.UnsupportedLlvmEmission;
                wildcard_index = i;
                continue;
            }
            const tag_info = resultSwitchPattern(pattern) orelse return null;
            if (std.mem.eql(u8, tag_info.tag, "ok")) {
                if (ok_index != null) return error.UnsupportedLlvmEmission;
                ok_index = i;
                ok_binding = tag_info.binding;
            } else if (std.mem.eql(u8, tag_info.tag, "err")) {
                if (err_index != null) return error.UnsupportedLlvmEmission;
                err_index = i;
                err_binding = tag_info.binding;
            } else {
                return null;
            }
        }
        const ok_i = ok_index orelse wildcard_index orelse return null;
        const err_i = err_index orelse wildcard_index orelse return null;
        if (ok_index == null and err_index == null) return null;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const ok_label = try self.nextLabel("result_ok");
        const err_label = try self.nextLabel("result_err");
        const end_label = try self.nextLabel("result_end");
        const is_ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ is_ok, try self.llvmType(subject_ty), subject });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ is_ok, ok_label, err_label, try self.debugCallSuffix() });

        var all_terminated = true;
        try self.out.print(self.allocator, "{s}:\n", .{ok_label});
        const ok_terminated = try self.emitResultSwitchArm(node.arms[ok_i], ret_ty, subject, subject_ty, info.ok_ty, 1, if (ok_index != null) ok_binding else null);
        if (!ok_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        }

        try self.out.print(self.allocator, "{s}:\n", .{err_label});
        const err_terminated = try self.emitResultSwitchArm(node.arms[err_i], ret_ty, subject, subject_ty, info.err_ty, 2, if (err_index != null) err_binding else null);
        if (!err_terminated) {
            all_terminated = false;
            try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
        }
        if (all_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitResultSwitchArm(self: *LlvmEmitter, arm: ast.SwitchArm, ret_ty: ast.TypeExpr, subject: []const u8, subject_ty: ast.TypeExpr, payload_ty: ast.TypeExpr, payload_index: u8, binding: ?ast.Ident) !bool {
        if (binding) |bind| {
            const old_type = self.local_types.fetchRemove(bind.text);
            const old_slot = self.local_slots.fetchRemove(bind.text);
            defer restoreLocal(&self.local_types, bind.text, old_type) catch {};
            defer restoreLocal(&self.local_slots, bind.text, old_slot) catch {};

            const binding_ptr = try self.nextBindingPtr(bind.text);
            const payload = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, {d}\n", .{ payload, try self.llvmType(subject_ty), subject, payload_index });
            try self.emitAllocaStore(binding_ptr, try self.resultPayloadLlvmType(payload_ty), payload);
            try self.local_types.put(bind.text, payload_ty);
            try self.local_slots.put(bind.text, .{ .ty = payload_ty, .ptr = binding_ptr });
            return try self.emitSwitchBody(arm.body, ret_ty);
        }
        return try self.emitSwitchBody(arm.body, ret_ty);
    }

    fn emitTaggedUnionSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !?bool {
        const subject_ty = self.taggedUnionSwitchSubjectType(node) orelse return null;
        const union_decl = self.taggedUnionForType(subject_ty) orelse return null;
        const subject = try self.emitExpr(node.subject, subject_ty);
        const subject_ptr = try self.nextTemp();
        const tag_ptr = try self.nextTemp();
        const tag = try self.nextTemp();
        const union_llvm = try self.llvmType(subject_ty);
        try self.emitAllocaStore(subject_ptr, union_llvm, subject);
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, union_llvm, subject_ptr });
        try self.out.print(self.allocator, "  {s} = load i32, ptr {s}{s}\n", .{ tag, tag_ptr, try self.debugCallSuffix() });

        const end_label = try self.nextLabel("union_switch_end");
        const trap_label = try self.nextLabel("union_switch_trap");
        var arm_labels = try self.scratch.allocator().alloc([]const u8, node.arms.len);
        var wildcard_index: ?usize = null;
        for (node.arms, 0..) |arm, i| {
            arm_labels[i] = try self.nextLabel("union_switch_arm");
            for (arm.patterns) |pattern| {
                if (pattern.kind == .wildcard and wildcard_index == null) wildcard_index = i;
            }
        }
        const default_label = if (wildcard_index) |index| arm_labels[index] else trap_label;
        try self.out.print(self.allocator, "  switch i32 {s}, label %{s} [\n", .{ tag, default_label });
        for (node.arms, 0..) |arm, i| {
            for (arm.patterns) |pattern| {
                const case_name = taggedUnionPatternName(pattern) orelse continue;
                const case_index = self.taggedUnionCaseIndex(union_decl, case_name) orelse return error.UnsupportedLlvmEmission;
                try self.out.print(self.allocator, "    i32 {d}, label %{s}\n", .{ case_index, arm_labels[i] });
            }
        }
        try self.out.print(self.allocator, "  ]{s}\n", .{try self.debugCallSuffix()});

        var all_terminated = true;
        for (node.arms, 0..) |arm, i| {
            try self.out.print(self.allocator, "{s}:\n", .{arm_labels[i]});
            const terminated = try self.emitTaggedUnionSwitchArm(arm, ret_ty, subject_ptr, subject_ty, union_decl);
            if (!terminated) {
                all_terminated = false;
                try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
            }
        }
        if (wildcard_index == null) {
            try self.out.print(self.allocator, "{s}:\n  call void @mc_trap_InvalidRepresentation(){s}\n  unreachable\n", .{ trap_label, try self.debugCallSuffix() });
        }
        if (all_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn taggedUnionSwitchSubjectType(self: *LlvmEmitter, node: ast.Switch) ?ast.TypeExpr {
        if (self.exprType(node.subject)) |subject_ty| {
            if (self.taggedUnionForType(subject_ty) != null) return subject_ty;
        }

        var candidate: ?ast.TypeExpr = null;
        var unions = self.tagged_unions.iterator();
        union_candidate: while (unions.next()) |entry| {
            var matched_named_pattern = false;
            for (node.arms) |arm| {
                for (arm.patterns) |pattern| {
                    const case_name = taggedUnionPatternName(pattern) orelse continue;
                    if (taggedUnionCase(entry.value_ptr.*, case_name) == null) continue :union_candidate;
                    matched_named_pattern = true;
                }
            }
            if (!matched_named_pattern) continue;
            if (candidate != null) return null;
            candidate = simpleType(node.subject.span, entry.key_ptr.*);
        }
        return candidate;
    }

    fn emitTaggedUnionSwitchArm(self: *LlvmEmitter, arm: ast.SwitchArm, ret_ty: ast.TypeExpr, subject_ptr: []const u8, subject_ty: ast.TypeExpr, union_decl: ast.UnionDecl) !bool {
        if (taggedUnionBindingPattern(arm)) |binding| {
            const case = taggedUnionCase(union_decl, binding.tag) orelse return error.UnsupportedLlvmEmission;
            const payload_ty = case.ty orelse return error.UnsupportedLlvmEmission;
            const old_type = self.local_types.fetchRemove(binding.binding.text);
            const old_slot = self.local_slots.fetchRemove(binding.binding.text);
            defer restoreLocal(&self.local_types, binding.binding.text, old_type) catch {};
            defer restoreLocal(&self.local_slots, binding.binding.text, old_slot) catch {};

            const binding_ptr = try self.nextBindingPtr(binding.binding.text);
            const payload = try self.taggedUnionLoadPayload(subject_ptr, subject_ty, payload_ty);
            try self.emitAllocaStore(binding_ptr, try self.llvmType(payload_ty), payload);
            try self.local_types.put(binding.binding.text, payload_ty);
            try self.local_slots.put(binding.binding.text, .{ .ty = payload_ty, .ptr = binding_ptr });
            return try self.emitSwitchBody(arm.body, ret_ty);
        }
        return try self.emitSwitchBody(arm.body, ret_ty);
    }

    fn emitScalarSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !?bool {
        const subject_ty = self.exprType(node.subject) orelse return null;
        if (!typeNameEql(self.resolveAliasType(subject_ty), "bool") and self.integerBitsOf(subject_ty) == null and self.enumDeclForType(subject_ty) == null) return null;

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
        try self.out.print(self.allocator, "  ]{s}\n", .{try self.debugCallSuffix()});

        var all_terminated = true;
        for (node.arms, 0..) |arm, i| {
            try self.out.print(self.allocator, "{s}:\n", .{arm_labels[i]});
            const terminated = try self.emitSwitchBody(arm.body, ret_ty);
            if (!terminated) {
                all_terminated = false;
                try self.out.print(self.allocator, "  br label %{s}{s}\n", .{ end_label, try self.debugCallSuffix() });
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
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(pointee_ty), ptr, try self.debugCallSuffix() });
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
        if (self.overlayField(node.base.*, node.name.text)) |field| {
            if (overlayByteArrayElementType(field.ty) != null) return error.UnsupportedLlvmEmission;
            const ptr = try self.emitOverlayFieldAddress(node.base.*, field);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(field.ty), ptr, try self.debugCallSuffix() });
            return result;
        }
        const field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitMemberAddress(node);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(field.ty), ptr, try self.debugCallSuffix() });
        return result;
    }

    fn emitMemberAddress(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const struct_ty = self.memberBaseStructType(base_ty) orelse return error.UnsupportedLlvmEmission;
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        if (isMmioStructAbi(struct_decl)) {
            const offset = self.mmioFieldOffset(struct_decl, node.name.text) orelse return error.UnsupportedLlvmEmission;
            const base_ptr = try self.emitExpr(node.base.*, base_ty);
            if (offset == 0) return base_ptr;
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {d}\n", .{ result, base_ptr, offset });
            return result;
        }
        const index = structFieldIndex(struct_decl, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = if (self.resolveAliasType(base_ty).kind == .pointer)
            try self.emitExpr(node.base.*, base_ty)
        else
            try self.aggregateBasePointer(node.base.*);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ result, try self.llvmType(struct_ty), base_ptr, index });
        return result;
    }

    fn emitIndexLoad(self: *LlvmEmitter, node: anytype) ![]const u8 {
        if (overlayMemberFromIndexBase(node.base.*)) |member| {
            if (self.overlayField(member.base.*, member.name.text)) |field| {
                const element_ty = overlayByteArrayElementType(field.ty) orelse return error.UnsupportedLlvmEmission;
                const ptr = try self.emitIndexAddress(node);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(element_ty), ptr, try self.debugCallSuffix() });
                return result;
            }
        }
        const element_ty = self.indexElementType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitIndexAddress(node);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, try self.llvmType(element_ty), ptr, try self.debugCallSuffix() });
        return result;
    }

    fn emitIndexAddress(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const resolved_base_ty = self.resolveAliasType(base_ty);
        const index = try self.emitExpr(node.index.*, simpleType((node.index.*).span, "usize"));
        if (overlayMemberFromIndexBase(node.base.*)) |member| {
            if (self.overlayField(member.base.*, member.name.text)) |field| {
                const element_ty = overlayByteArrayElementType(field.ty) orelse return error.UnsupportedLlvmEmission;
                const array = switch (field.ty.kind) {
                    .array => |array| array,
                    else => return error.UnsupportedLlvmEmission,
                };
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const base_ptr = try self.aggregateBasePointer(member.base.*);
                try self.emitBoundsCheck(index, len);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(element_ty), base_ptr, index });
                return result;
            }
        }
        return switch (resolved_base_ty.kind) {
            .array => |array| blk: {
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const base_ptr = try self.arrayBasePointer(node.base.*);
                // OPT (annex E): skip the bounds check when the optimized MIR proved this
                // constant index in range (consumes the optimizer's `elided_bounds`).
                if (!self.mirCheckElided((node.index.*).span)) {
                    try self.emitBoundsCheck(index, len);
                }
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {s}\n", .{ result, try self.llvmType(resolved_base_ty), base_ptr, index });
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
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(slice.child.*), ptr, index });
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
        try self.emitAllocaStore(ptr, llvm_ty, value);
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

    // OPT (annex E): true when the optimizer recorded this operand's source point in
    // `elided_bounds` (only under `--optimize`) — a proven-in-range constant index's Bounds
    // check, or an unsigned div-by-literal's DivideByZero check. Source points are unique per
    // location, so a module-wide match is unambiguous. Without the flag the list is empty and
    // the check is emitted — the backend consumes the optimized MIR, not re-derived proof.
    fn mirCheckElided(self: *LlvmEmitter, span: ast.Span) bool {
        for (self.mir_module.functions) |function| {
            for (function.elided_bounds) |pt| {
                if (pt.line == span.line and pt.column == span.column) return true;
            }
        }
        return false;
    }

    fn emitBoundsCheck(self: *LlvmEmitter, index: []const u8, len: u64) !void {
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {d}\n", .{ ok, index, len });
        try self.emitTrapBranch(ok, cont, trap, trap, cont, "Bounds");
    }

    fn emitDynamicBoundsCheck(self: *LlvmEmitter, index: []const u8, len: []const u8) !void {
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ ok, index, len });
        try self.emitTrapBranch(ok, cont, trap, trap, cont, "Bounds");
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
        try self.emitTrapBranch(ok, cont, trap, trap, cont, "Bounds");
    }

    fn emitSlice(self: *LlvmEmitter, node: anytype, slice_span: ast.Span) ![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const slice_ty = self.sliceTypeForBase(base_ty, node.base.*.span) orelse return error.UnsupportedLlvmEmission;
        const slice = switch (slice_ty.kind) {
            .slice => |slice| slice,
            else => return error.UnsupportedLlvmEmission,
        };
        // OPT (annex E): the optimized MIR proves a constant range in bounds and elides the
        // `start <= end <= len` guard — parity with the C backend and the index elision.
        const elide = self.mirCheckElided(slice_span);
        const start = try self.emitExpr(node.start.*, simpleType((node.start.*).span, "usize"));
        const end = try self.emitExpr(node.end.*, simpleType((node.end.*).span, "usize"));
        const base_ptr = switch (base_ty.kind) {
            .array => |array| blk: {
                const array_ptr = try self.arrayBasePointer(node.base.*);
                const len = self.arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const elem_ptr = try self.nextTemp();
                if (!elide) try self.emitSliceBoundsCheck(start, end, try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{len}));
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {s}\n", .{ elem_ptr, try self.llvmType(base_ty), array_ptr, start });
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
                if (!elide) try self.emitSliceBoundsCheck(start, end, len);
                try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ elem_ptr, try self.llvmType(slice.child.*), ptr, start });
                break :blk elem_ptr;
            },
            else => return error.UnsupportedLlvmEmission,
        };
        const result0 = try self.nextTemp();
        const slice_len = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ result0, try self.llvmType(slice_ty), base_ptr });
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
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ ptr, try self.llvmType(array_ty), array_ptr, i });
            const value = try self.emitExpr(item, element_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ element_llvm, value, ptr, try self.debugCallSuffix() });
        }
    }

    fn emitStructLiteralStores(self: *LlvmEmitter, struct_ptr: []const u8, struct_ty: ast.TypeExpr, fields: []const ast.StructLiteralField) !void {
        const struct_decl = self.structDeclForType(struct_ty) orelse return error.UnsupportedLlvmEmission;
        for (struct_decl.fields, 0..) |field, i| {
            const value_expr = structLiteralField(fields, field.name.text) orelse return error.UnsupportedLlvmEmission;
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ ptr, try self.llvmType(struct_ty), struct_ptr, i });
            const value = try self.emitExpr(value_expr, field.ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(field.ty), value, ptr, try self.debugCallSuffix() });
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
        if (isDropCall(call.callee.*)) return error.UnsupportedLlvmEmission;
        if (isBindCallByNode(call)) return try self.emitBindValue(call, expected_ty);
        if (try self.emitTaggedUnionConstructor(call, expected_ty)) |value| return value;
        if (try self.emitBuiltinValueCall(call, expected_ty)) |value| return value;
        if (self.directCallName(call.callee.*)) |callee| {
            return try self.emitDirectCall(callee, call, expected_ty);
        }
        if (self.closureCalleeType(call.callee.*)) |closure_ty| return try self.emitClosureCall(call.callee.*, call.args, closure_ty);
        const fn_ty = self.fnPointerCalleeType(call.callee.*) orelse return error.UnsupportedLlvmEmission;
        return try self.emitFnPointerCall(call.callee.*, call.args, fn_ty);
    }

    fn emitBindValue(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
        const closure_ty = self.resolveAliasType(expected_ty);
        if (closure_ty.kind != .closure_type) return error.UnsupportedLlvmEmission;
        const fname = calleeIdentName(call.args[1]) orelse return error.UnsupportedLlvmEmission;
        const sig = self.fn_sigs.get(fname) orelse return error.UnsupportedLlvmEmission;
        if (sig.params.len == 0) return error.UnsupportedLlvmEmission;
        // The function's first parameter type is the env type. Use it as the
        // expected type so address-of-param / scalar envs (whose `exprType` may be
        // null) still resolve, instead of the previous `exprType(...) orelse fail`.
        const env_ty = sig.params[0].ty;
        const env_llvm = try self.llvmType(env_ty);

        const code_ptr: []const u8 = blk: {
            if (std.mem.eql(u8, env_llvm, "ptr")) break :blk fname;
            // Scalar env: must be an integer type to widen into the `ptr` slot. A
            // generated thunk narrows it back before calling the real function.
            if (self.integerBitsOf(env_ty) == null) return error.UnsupportedLlvmEmission;
            const thunk_name = try std.fmt.allocPrint(self.scratch.allocator(), "mc_envthunk_{s}", .{fname});
            if (!self.bind_thunks.contains(thunk_name)) try self.bind_thunks.put(thunk_name, .{ .fname = fname, .sig = sig });
            break :blk thunk_name;
        };

        const env_value = try self.emitExpr(call.args[0], env_ty);
        // Widen an integer scalar env into the closure's `ptr` env slot.
        const env_ptr: []const u8 = if (std.mem.eql(u8, env_llvm, "ptr")) env_value else widen: {
            const p = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = inttoptr {s} {s} to ptr\n", .{ p, env_llvm, env_value });
            break :widen p;
        };

        const with_code = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr @{s}, 0\n", .{ with_code, try self.llvmType(closure_ty), code_ptr });
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, ptr {s}, 1\n", .{ result, try self.llvmType(closure_ty), with_code, env_ptr });
        return result;
    }

    // Emit a `define` for each collected scalar-env thunk:
    //   define RET @mc_envthunk_f(ptr %env, P...) { %i = ptrtoint ptr %env to <iN>; ... call @f(<iN> %i, P...) ... }
    // The first parameter is genuinely `ptr`, matching the closure's code-pointer slot.
    fn emitBindThunks(self: *LlvmEmitter) !void {
        var it = self.bind_thunks.iterator();
        while (it.next()) |entry| {
            const thunk = entry.value_ptr.*;
            const sig = thunk.sig;
            const ret_llvm = try self.llvmType(sig.ret);
            const env_llvm = try self.llvmType(sig.params[0].ty);
            self.temp_index = 0;
            try self.out.print(self.allocator, "define {s} @{s}(ptr %env", .{ ret_llvm, entry.key_ptr.* });
            for (sig.params[1..], 0..) |param, i| {
                try self.out.print(self.allocator, ", {s} %a{d}", .{ try self.llvmType(param.ty), i });
            }
            try self.out.appendSlice(self.allocator, ") {\nbb_entry:\n");
            const narrowed = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = ptrtoint ptr %env to {s}\n", .{ narrowed, env_llvm });
            const returns_void = typeNameEql(sig.ret, "void");
            const result = if (returns_void) "" else try self.nextTemp();
            if (returns_void) {
                try self.out.print(self.allocator, "  call void @{s}({s} {s}", .{ thunk.fname, env_llvm, narrowed });
            } else {
                try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}", .{ result, ret_llvm, thunk.fname, env_llvm, narrowed });
            }
            for (sig.params[1..], 0..) |param, i| {
                try self.out.print(self.allocator, ", {s} %a{d}", .{ try self.llvmType(param.ty), i });
            }
            try self.out.appendSlice(self.allocator, ")\n");
            if (returns_void) {
                try self.out.appendSlice(self.allocator, "  ret void\n");
            } else {
                try self.out.print(self.allocator, "  ret {s} {s}\n", .{ ret_llvm, result });
            }
            try self.out.appendSlice(self.allocator, "}\n\n");
        }
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

    fn emitFnPointerVoidCall(self: *LlvmEmitter, callee_expr: ast.Expr, args_expr: []const ast.Expr, fn_ty: ast.TypeExpr) !void {
        const sig = fn_ty.kind.fn_pointer;
        if (!typeNameEql(sig.ret.*, "void")) return error.UnsupportedLlvmEmission;
        if (args_expr.len != sig.params.len) return error.UnsupportedLlvmEmission;
        const callee = try self.emitExpr(callee_expr, fn_ty);
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_expr, 0..) |arg, i| {
            const arg_ty = sig.params[i];
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExpr(arg, arg_ty) });
        }
        try self.out.print(self.allocator, "  call void {s}(", .{callee});
        for (args.items, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
    }

    fn emitClosureCall(self: *LlvmEmitter, callee_expr: ast.Expr, args_expr: []const ast.Expr, closure_ty: ast.TypeExpr) ![]const u8 {
        const sig = closure_ty.kind.closure_type;
        if (typeNameEql(sig.ret.*, "void")) return error.UnsupportedLlvmEmission;
        if (args_expr.len != sig.params.len) return error.UnsupportedLlvmEmission;
        const callee = try self.emitExpr(callee_expr, closure_ty);
        const code = try self.nextTemp();
        const env = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ code, try self.llvmType(closure_ty), callee });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ env, try self.llvmType(closure_ty), callee });
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_expr, 0..) |arg, i| {
            const arg_ty = sig.params[i];
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExpr(arg, arg_ty) });
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} {s}(ptr {s}", .{ result, try self.llvmType(sig.ret.*), code, env });
        for (args.items) |arg| {
            try self.out.print(self.allocator, ", {s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
        return result;
    }

    fn emitClosureVoidCall(self: *LlvmEmitter, callee_expr: ast.Expr, args_expr: []const ast.Expr, closure_ty: ast.TypeExpr) !void {
        const sig = closure_ty.kind.closure_type;
        if (!typeNameEql(sig.ret.*, "void")) return error.UnsupportedLlvmEmission;
        if (args_expr.len != sig.params.len) return error.UnsupportedLlvmEmission;
        const callee = try self.emitExpr(callee_expr, closure_ty);
        const code = try self.nextTemp();
        const env = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ code, try self.llvmType(closure_ty), callee });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ env, try self.llvmType(closure_ty), callee });
        var args: std.ArrayList(ArgValue) = .empty;
        defer args.deinit(self.allocator);
        for (args_expr, 0..) |arg, i| {
            const arg_ty = sig.params[i];
            try args.append(self.allocator, .{ .ty = arg_ty, .value = try self.emitExpr(arg, arg_ty) });
        }
        try self.out.print(self.allocator, "  call void {s}(ptr {s}", .{ code, env });
        for (args.items) |arg| {
            try self.out.print(self.allocator, ", {s} {s}", .{ try self.llvmType(arg.ty), arg.value });
        }
        try self.out.print(self.allocator, "){s}\n", .{try self.debugCallSuffix()});
    }

    fn emitBuiltinValueCall(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr) !?[]const u8 {
        if (self.reflectionCallValue(call)) |value| return value;
        if (isAssumeNoaliasCall(call)) {
            if (call.type_args.len != 0 or call.args.len != 2) return error.UnsupportedLlvmEmission;
            const source_ty = self.exprType(call.args[0]) orelse expected_ty;
            const value = try self.emitExpr(call.args[0], source_ty);
            _ = try self.emitExpr(call.args[1], simpleType(call.args[1].span, "usize"));
            return try self.coerceExprValue(value, call.args[0], expected_ty);
        }
        if (self.constGetCallInfo(call)) |info| {
            if (call.args.len != 0) return error.UnsupportedLlvmEmission;
            const base_ptr = try self.arrayBasePointer(info.base);
            const ptr = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i64 {d}\n", .{ ptr, try self.llvmType(info.array_ty), base_ptr, info.index });
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
        if (mmioMapCallPayloadType(call)) |_| {
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const addr = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "PAddr"));
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ result, addr });
            return result;
        }
        if (self.dmaBufCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            const base = try self.emitExpr(info.base, info.dma_ty);
            if (std.mem.eql(u8, info.op, "dma_addr")) return base;
            if (std.mem.eql(u8, info.op, "as_slice")) {
                const ptr = try self.nextTemp();
                const with_ptr = try self.nextTemp();
                const result = try self.nextTemp();
                const slice_ty = try self.sliceTypeFor(info.payload_ty, .mut, call.callee.*.span);
                try self.out.print(self.allocator, "  {s} = inttoptr i64 {s} to ptr\n", .{ ptr, base });
                try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ with_ptr, try self.llvmType(slice_ty), ptr });
                try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 1, 1\n", .{ result, try self.llvmType(slice_ty), with_ptr });
                return result;
            }
            return error.UnsupportedLlvmEmission;
        }
        if (isAtomicInitCall(call.callee.*)) {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload_ty = self.atomicPayloadType(expected_ty) orelse return error.UnsupportedLlvmEmission;
            return try self.emitAtomicValueForStorage(call.args[0], payload_ty);
        }
        if (self.mmioAccessInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "read")) return null;
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const ordering = orderingArg(call.args[0]) orelse return error.UnsupportedLlvmEmission;
            const ptr = try self.emitMmioRegisterAddress(info);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load volatile {s}, ptr {s}{s}\n", .{ result, try self.llvmType(info.storage_ty), ptr, try self.debugCallSuffix() });
            try self.emitMmioFence(ordering, .after_load);
            if (std.mem.eql(u8, try self.llvmType(info.storage_ty), try self.llvmType(info.value_ty))) return result;
            return try self.castValue(result, info.storage_ty, info.value_ty);
        }
        if (self.maybeUninitCallInfo(call)) |info| {
            if (!std.mem.eql(u8, info.op, "assume_init")) return null;
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            const ptr = try self.storageBaseAddress(info.base);
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(info.payload_ty), ptr });
            return result;
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
            try self.out.print(self.allocator, "  {s} = load volatile {s}, ptr {s}{s}\n", .{ result, llvm_ty, ptr, try self.debugCallSuffix() });
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
        if (byteViewCallKind(call.callee.*)) |kind| return try self.emitByteViewCall(call, kind);
        if (isResultConstructorCall(call)) |tag| return try self.emitResultConstructorValue(call, expected_ty, tag);
        if (self.domainResidueCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 0) return error.UnsupportedLlvmEmission;
            return try self.emitExpr(info.base, info.domain_ty);
        }
        if (self.domainOpCallInfo(call)) |info| return try self.emitDomainOpCall(call, info);
        if (self.reduceCallInfo(call)) |info| return try self.emitReduceCall(call, info);
        if (self.conversionCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const source_ty = self.exprType(call.args[0]) orelse info.target_ty;
            const value = try self.emitExpr(call.args[0], source_ty);
            if (std.mem.eql(u8, info.op, "trap_from")) return try self.emitTrapConversion(value, source_ty, info.target_ty);
            if (std.mem.eql(u8, info.op, "sat_from")) return try self.emitSaturatingConversion(value, source_ty, info.target_ty);
            if (std.mem.eql(u8, info.op, "try_from")) return try self.emitTryConversion(value, source_ty, info.target_ty);
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
        if (uncheckedBuiltinOp(call.callee.*)) |op| {
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
                const ptr = try self.atomicAddress(info);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = load atomic {s}, ptr {s} {s}, align {d}{s}\n", .{ result, try self.atomicStorageLlvmType(info.payload_ty), ptr, llvm_order, self.llvmAlignOf(info.payload_ty), try self.debugCallSuffix() });
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
                const ptr = try self.atomicAddress(info);
                const delta = try self.emitExpr(call.args[0], info.payload_ty);
                const result = try self.nextTemp();
                const op: []const u8 = if (std.mem.eql(u8, info.op, "fetch_sub")) "sub" else "add";
                try self.out.print(self.allocator, "  {s} = atomicrmw {s} ptr {s}, {s} {s} {s}{s}\n", .{ result, op, ptr, try self.llvmType(info.payload_ty), delta, llvm_order, try self.debugCallSuffix() });
                return result;
            }
        }
        if (self.rawManyOffsetCallInfo(call)) |info| {
            if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
            const base = try self.emitExpr(info.base, info.base_ty);
            const index = try self.emitExpr(call.args[0], simpleType(call.args[0].span, "usize"));
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ result, try self.llvmType(info.element_ty), base, index });
            return result;
        }
        return null;
    }

    fn emitVoidCall(self: *LlvmEmitter, callee: []const u8, call: anytype) !void {
        const sig = self.fn_sigs.get(callee) orelse return error.UnsupportedLlvmEmission;
        // A `-> never` function lowers to a `void` LLVM declaration, so its call statement is a
        // plain `call void @fn(args)` (no result name) — handled here alongside `-> void`.
        if (!typeNameEql(sig.ret, "void") and !typeNameEql(sig.ret, "never")) return error.UnsupportedLlvmEmission;
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

    fn emitVoidStatementCall(self: *LlvmEmitter, call: anytype) !void {
        if (self.directCallName(call.callee.*)) |callee| {
            try self.emitVoidCall(callee, call);
            return;
        }
        if (self.closureCalleeType(call.callee.*)) |closure_ty| {
            try self.emitClosureVoidCall(call.callee.*, call.args, closure_ty);
            return;
        }
        if (self.fnPointerCalleeType(call.callee.*)) |fn_ty| {
            try self.emitFnPointerVoidCall(call.callee.*, call.args, fn_ty);
            return;
        }
        return error.UnsupportedLlvmEmission;
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
            .logical_and => try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ left, rhs_label, short_label, try self.debugCallSuffix() }),
            .logical_or => try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n", .{ left, short_label, rhs_label, try self.debugCallSuffix() }),
            else => unreachable,
        }

        try self.out.print(self.allocator, "{s}:\n", .{rhs_label});
        const right = try self.emitExpr(node.right.*, right_ty);
        try self.out.print(self.allocator, "  store i1 {s}, ptr {s}\n", .{ right, result_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ end_label, try self.debugCallSuffix(), short_label });
        const short_value = if (node.op == .logical_and) "0" else "1";
        try self.out.print(self.allocator, "  store i1 {s}, ptr {s}\n", .{ short_value, result_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ end_label, try self.debugCallSuffix(), end_label });
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
                    try self.emitTrapBranch(overflow, trap, cont, trap, cont, "IntegerOverflow");
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
        const value = try self.emitExprNatural(value_expr, source_ty);
        return try self.castValue(value, source_ty, target_ty);
    }

    fn emitExprNatural(self: *LlvmEmitter, expr: ast.Expr, source_ty: ast.TypeExpr) anyerror![]const u8 {
        return switch (expr.kind) {
            .binary => |node| try self.emitBinary(node, source_ty),
            .grouped => |inner| try self.emitExprNatural(inner.*, source_ty),
            else => try self.emitExpr(expr, source_ty),
        };
    }

    fn castValue(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const source_llvm = try self.llvmType(source_ty);
        const target_llvm = try self.llvmType(target_ty);
        if (std.mem.eql(u8, source_llvm, target_llvm) and
            self.fixedLayoutBitsOf(source_ty) != null and
            self.fixedLayoutBitsOf(target_ty) != null)
        {
            return value;
        }
        if (self.pointerAddressCoercion(source_ty, target_ty)) {
            return try self.emitBitcastValue(value, source_ty, target_ty);
        }
        if ((self.integerBitsOf(source_ty) != null or self.enumDeclForType(source_ty) != null) and
            (self.integerBitsOf(target_ty) != null or self.enumDeclForType(target_ty) != null))
        {
            return try self.castIntegerValue(value, source_ty, target_ty);
        }
        if (typeNameEql(self.resolveAliasType(source_ty), "bool") and self.integerBitsOf(target_ty) != null) {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = zext i1 {s} to {s}\n", .{ result, value, target_llvm });
            return result;
        }
        if (self.integerBitsOf(source_ty) != null and typeNameEql(self.resolveAliasType(target_ty), "bool")) {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, 0\n", .{ result, source_llvm, value });
            return result;
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
            try self.emitTrapBranch(out_of_range, trap, cont, trap, cont, "IntegerOverflow");
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

    fn emitByteViewCall(self: *LlvmEmitter, call: anytype, kind: ByteViewCallKind) ![]const u8 {
        if (call.type_args.len != 0) return error.UnsupportedLlvmEmission;
        return switch (kind) {
            .as_bytes => try self.emitAsBytesCall(call),
            .bytes_equal => try self.emitBytesEqualCall(call),
        };
    }

    fn emitAsBytesCall(self: *LlvmEmitter, call: anytype) ![]const u8 {
        if (call.args.len != 1) return error.UnsupportedLlvmEmission;
        const target = byteViewAddressTarget(call.args[0]) orelse return error.UnsupportedLlvmEmission;
        const source_ty = self.exprType(target) orelse return error.UnsupportedLlvmEmission;
        const size = self.comptimeSizeOf(source_ty, 0) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitExpr(call.args[0], try self.pointerTypeFor(source_ty));
        const slice_ty = try self.constU8SliceType(call.callee.*.span);
        const slice_llvm = try self.llvmType(slice_ty);
        const with_ptr = try self.nextTemp();
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, ptr {s}, 0\n", .{ with_ptr, slice_llvm, ptr });
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, i64 {d}, 1\n", .{ result, slice_llvm, with_ptr, size });
        return result;
    }

    fn emitBytesEqualCall(self: *LlvmEmitter, call: anytype) ![]const u8 {
        if (call.args.len != 2) return error.UnsupportedLlvmEmission;
        const slice_ty = try self.constU8SliceType(call.callee.*.span);
        const slice_llvm = try self.llvmType(slice_ty);
        const left = try self.emitExpr(call.args[0], self.exprType(call.args[0]) orelse slice_ty);
        const right = try self.emitExpr(call.args[1], self.exprType(call.args[1]) orelse slice_ty);
        const left_ptr = try self.nextTemp();
        const left_len = try self.nextTemp();
        const right_ptr = try self.nextTemp();
        const right_len = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ left_ptr, slice_llvm, left });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ left_len, slice_llvm, left });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ right_ptr, slice_llvm, right });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ right_len, slice_llvm, right });

        const index_ptr = try self.nextTemp();
        const result_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = alloca i64\n", .{index_ptr});
        try self.out.print(self.allocator, "  {s} = alloca i1\n", .{result_ptr});
        try self.out.print(self.allocator, "  store i64 0, ptr {s}\n", .{index_ptr});
        try self.out.print(self.allocator, "  store i1 0, ptr {s}\n", .{result_ptr});

        const len_match = try self.nextTemp();
        const cond_label = try self.nextLabel("bytes_equal_cond");
        const body_label = try self.nextLabel("bytes_equal_body");
        const step_label = try self.nextLabel("bytes_equal_step");
        const equal_label = try self.nextLabel("bytes_equal_true");
        const done_label = try self.nextLabel("bytes_equal_done");
        try self.out.print(self.allocator, "  {s} = icmp eq i64 {s}, {s}\n", .{ len_match, left_len, right_len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ len_match, cond_label, done_label, try self.debugCallSuffix(), cond_label });

        const index = try self.nextTemp();
        const in_range = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ in_range, index, left_len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ in_range, body_label, equal_label, try self.debugCallSuffix(), body_label });

        const left_elem_ptr = try self.nextTemp();
        const right_elem_ptr = try self.nextTemp();
        const left_byte = try self.nextTemp();
        const right_byte = try self.nextTemp();
        const same = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ left_elem_ptr, left_ptr, index });
        try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {s}\n", .{ right_elem_ptr, right_ptr, index });
        try self.out.print(self.allocator, "  {s} = load i8, ptr {s}\n", .{ left_byte, left_elem_ptr });
        try self.out.print(self.allocator, "  {s} = load i8, ptr {s}\n", .{ right_byte, right_elem_ptr });
        try self.out.print(self.allocator, "  {s} = icmp eq i8 {s}, {s}\n", .{ same, left_byte, right_byte });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ same, step_label, done_label, try self.debugCallSuffix(), step_label });

        const next_index = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), equal_label });
        try self.out.print(self.allocator, "  store i1 1, ptr {s}\n", .{result_ptr});
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ done_label, try self.debugCallSuffix(), done_label });

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i1, ptr {s}\n", .{ result, result_ptr });
        return result;
    }

    fn emitTryConversion(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const result_ty = try self.resultType(target_ty, simpleType(target_ty.span, "ConversionError"), target_ty.span);
        const converted = try self.castValue(value, source_ty, target_ty);
        const out_of_range = try self.emitConversionOutOfRange(value, source_ty, target_ty);
        if (out_of_range) |check| {
            const tag = try self.nextTemp();
            const selected_payload = try self.nextTemp();
            const target_llvm = try self.resultPayloadLlvmType(target_ty);
            try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ tag, check });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {s}, {s} {s}\n", .{ selected_payload, check, target_llvm, try self.resultPayloadZero(target_ty), target_llvm, converted });
            return try self.emitResultValue(result_ty, tag, selected_payload, "0");
        }
        return try self.emitResultValue(result_ty, "true", converted, "0");
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
        const left = try self.emitBinaryOperand(node.left.*, ty);
        const right = try self.emitBinaryOperand(node.right.*, ty);
        const pair = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}, {s} {s}){s}\n", .{ pair, pair_ty, intrinsic, llvm_ty, left, llvm_ty, right, try self.debugCallSuffix() });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const cont = try self.nextLabel("cont");
        const trap = try self.nextLabel("trap_overflow");
        try self.emitTrapBranch(overflow, trap, cont, trap, cont, "IntegerOverflow");
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
        const left = try self.emitBinaryOperand(node.left.*, ty);
        const right = try self.emitBinaryOperand(node.right.*, ty);
        // OPT (annex E): when the optimizer proved this div/mod's check dead (a non-zero
        // literal divisor, and for a signed dividend a divisor that is also not -1), skip
        // BOTH the zero-check branch and the signed INT_MIN/-1 overflow branch below — the
        // same elision source point covers both, since the proof requires the divisor be
        // neither 0 nor -1.
        const div_elided = self.mirCheckElided((node.right.*).span);
        if (!div_elided) {
            const zero_cmp = try self.nextTemp();
            const zero_trap = try self.nextLabel("trap_div_zero");
            const nonzero = try self.nextLabel("div_nonzero");
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, 0\n", .{ zero_cmp, llvm_ty, right });
            try self.emitTrapBranch(zero_cmp, zero_trap, nonzero, zero_trap, nonzero, "DivideByZero");
        }

        if (self.isSignedIntegerType(ty) and !div_elided) {
            const min_literal = self.signedMinLiteralOf(ty) orelse return error.UnsupportedLlvmEmission;
            const min_cmp = try self.nextTemp();
            const neg_one_cmp = try self.nextTemp();
            const overflow_cmp = try self.nextTemp();
            const overflow_trap = try self.nextLabel("trap_div_overflow");
            const safe = try self.nextLabel("div_safe");
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}\n", .{ min_cmp, llvm_ty, left, min_literal });
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, -1\n", .{ neg_one_cmp, llvm_ty, right });
            try self.out.print(self.allocator, "  {s} = and i1 {s}, {s}\n", .{ overflow_cmp, min_cmp, neg_one_cmp });
            try self.emitTrapBranch(overflow_cmp, overflow_trap, safe, overflow_trap, safe, "IntegerOverflow");
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
            try self.emitTrapBranch(negative, neg_trap, nonnegative, neg_trap, nonnegative, "InvalidShift");
        }

        const too_large = try self.nextTemp();
        const invalid = try self.nextLabel("trap_shift_count");
        const valid = try self.nextLabel("shift_count_ok");
        const pred: []const u8 = if (self.isSignedIntegerType(amount_ty)) "sge" else "uge";
        try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ too_large, pred, amount_llvm, amount, shifted_bits });
        try self.emitTrapBranch(too_large, invalid, valid, invalid, valid, "InvalidShift");
    }

    fn emitLeftShiftOverflowCheck(self: *LlvmEmitter, result: []const u8, left: []const u8, amount: []const u8, ty: ast.TypeExpr, llvm_ty: []const u8) !void {
        const reverse_op: []const u8 = if (self.isSignedIntegerType(ty)) "ashr" else "lshr";
        const reversed = try self.emitPlainBinaryValues(reverse_op, llvm_ty, result, amount);
        const overflow = try self.nextTemp();
        const overflow_trap = try self.nextLabel("trap_shift_overflow");
        const ok = try self.nextLabel("shift_overflow_ok");
        try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, {s}\n", .{ overflow, llvm_ty, reversed, left });
        try self.emitTrapBranch(overflow, overflow_trap, ok, overflow_trap, ok, "IntegerOverflow");
    }

    fn emitPlainBinary(self: *LlvmEmitter, op: []const u8, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const left = try self.emitBinaryOperand(node.left.*, ty);
        const right = try self.emitBinaryOperand(node.right.*, ty);
        return try self.emitPlainBinaryValues(op, llvm_ty, left, right);
    }

    fn emitBinaryOperand(self: *LlvmEmitter, expr: ast.Expr, target_ty: ast.TypeExpr) anyerror![]const u8 {
        const source_ty = self.exprType(expr) orelse return self.emitExpr(expr, target_ty);
        const value = try self.emitExprNatural(expr, source_ty);
        return try self.castValue(value, source_ty, target_ty);
    }

    fn emitPlainBinaryValues(self: *LlvmEmitter, op: []const u8, llvm_ty: []const u8, left: []const u8, right: []const u8) ![]const u8 {
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ result, op, llvm_ty, left, right });
        return result;
    }

    fn emitResultConstructorValue(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr, tag: []const u8) ![]const u8 {
        if (call.type_args.len != 0 or call.args.len != 1) return error.UnsupportedLlvmEmission;
        const info = self.resultInfo(expected_ty) orelse return error.UnsupportedLlvmEmission;
        const result_ty = try self.llvmType(expected_ty);
        const ok_ty = try self.resultPayloadLlvmType(info.ok_ty);
        const err_ty = try self.resultPayloadLlvmType(info.err_ty);
        const is_ok = std.mem.eql(u8, tag, "ok");
        const tag_value = if (is_ok) "true" else "false";

        const tagged = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_ty, tag_value });

        const ok_value = if (is_ok)
            try self.emitResultPayloadExpr(call.args[0], info.ok_ty)
        else
            try self.resultPayloadZero(info.ok_ty);
        const with_ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_ok, result_ty, tagged, ok_ty, ok_value });

        const err_value = if (is_ok)
            try self.resultPayloadZero(info.err_ty)
        else
            try self.emitResultPayloadExpr(call.args[0], info.err_ty);
        const with_err = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 2\n", .{ with_err, result_ty, with_ok, err_ty, err_value });
        return with_err;
    }

    fn emitResultValue(self: *LlvmEmitter, result_ty: ast.TypeExpr, is_ok: []const u8, ok_value: []const u8, err_value: []const u8) ![]const u8 {
        const info = self.resultInfo(result_ty) orelse return error.UnsupportedLlvmEmission;
        const result_llvm = try self.llvmType(result_ty);
        const tagged = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} zeroinitializer, i1 {s}, 0\n", .{ tagged, result_llvm, is_ok });
        const with_ok = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 1\n", .{ with_ok, result_llvm, tagged, try self.resultPayloadLlvmType(info.ok_ty), ok_value });
        const with_err = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = insertvalue {s} {s}, {s} {s}, 2\n", .{ with_err, result_llvm, with_ok, try self.resultPayloadLlvmType(info.err_ty), err_value });
        return with_err;
    }

    fn emitTaggedUnionConstructor(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr) !?[]const u8 {
        const tag = taggedUnionConstructorName(call.callee.*) orelse return null;
        const union_decl = self.taggedUnionForType(expected_ty) orelse return null;
        const case_index = self.taggedUnionCaseIndex(union_decl, tag) orelse return null;
        const case = union_decl.cases[case_index];
        const union_llvm = try self.llvmType(expected_ty);
        const ptr = try self.nextTemp();
        const tag_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, union_llvm });
        try self.out.print(self.allocator, "  store {s} zeroinitializer, ptr {s}{s}\n", .{ union_llvm, ptr, try self.debugCallSuffix() });
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 0\n", .{ tag_ptr, union_llvm, ptr });
        try self.out.print(self.allocator, "  store i32 {d}, ptr {s}{s}\n", .{ case_index, tag_ptr, try self.debugCallSuffix() });
        if (case.ty) |payload_ty| {
            if (call.args.len != 1) return error.UnsupportedLlvmEmission;
            const payload = try self.emitExpr(call.args[0], payload_ty);
            const payload_ptr = try self.taggedUnionPayloadPtr(ptr, expected_ty, payload_ty);
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}{s}\n", .{ try self.llvmType(payload_ty), payload, payload_ptr, try self.debugCallSuffix() });
        } else if (call.args.len != 0) {
            return error.UnsupportedLlvmEmission;
        }
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}{s}\n", .{ result, union_llvm, ptr, try self.debugCallSuffix() });
        return result;
    }

    fn taggedUnionPayloadPtr(self: *LlvmEmitter, union_ptr: []const u8, union_ty: ast.TypeExpr, payload_ty: ast.TypeExpr) ![]const u8 {
        const union_decl = self.taggedUnionForType(union_ty) orelse return error.UnsupportedLlvmEmission;
        const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
        const union_llvm = try self.llvmType(union_ty);
        const payload_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 0, i32 {d}\n", .{ payload_ptr, union_llvm, union_ptr, layout.payload_field_index });
        _ = try self.llvmType(payload_ty);
        return payload_ptr;
    }

    fn taggedUnionLoadPayload(self: *LlvmEmitter, union_ptr: []const u8, union_ty: ast.TypeExpr, payload_ty: ast.TypeExpr) ![]const u8 {
        const payload_ptr = try self.taggedUnionPayloadPtr(union_ptr, union_ty, payload_ty);
        const payload = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ payload, try self.llvmType(payload_ty), payload_ptr });
        return payload;
    }

    fn emitResultPayloadExpr(self: *LlvmEmitter, expr: ast.Expr, ty: ast.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "0";
        return try self.emitExpr(expr, ty);
    }

    fn resultPayloadZero(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "0";
        return try self.zeroInitializer(ty);
    }

    fn resultType(self: *LlvmEmitter, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr, span: ast.Span) !ast.TypeExpr {
        const args = try self.scratch.allocator().alloc(ast.TypeExpr, 2);
        args[0] = ok_ty;
        args[1] = err_ty;
        return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = "Result", .span = span }, .args = args } } };
    }

    fn emitDomainOpCall(self: *LlvmEmitter, call: anytype, info: DomainOpCallInfo) ![]const u8 {
        if (call.type_args.len != 0) return error.UnsupportedLlvmEmission;
        const expected_args: usize = if (std.mem.eql(u8, info.op, "elapsed_assume_within") or std.mem.eql(u8, info.op, "elapsed_bounded")) 3 else 2;
        if (call.args.len != expected_args) return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(info.payload_ty);
        const left = try self.emitExpr(call.args[0], info.domain_ty);
        const right = try self.emitExpr(call.args[1], info.domain_ty);
        const diff = try self.emitPlainBinaryValues("sub", llvm_ty, left, right);
        if (std.mem.eql(u8, info.op, "before") or std.mem.eql(u8, info.op, "after")) {
            const pred: []const u8 = if (std.mem.eql(u8, info.op, "before")) "slt" else "sgt";
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, 0\n", .{ result, pred, llvm_ty, diff });
            return result;
        }
        if (std.mem.eql(u8, info.op, "compare")) {
            const min = try self.signedWindowMinLiteral(info.payload_ty);
            const ambiguous = try self.nextTemp();
            const not_ambiguous = try self.nextTemp();
            const is_lt = try self.nextTemp();
            const is_gt = try self.nextTemp();
            const nonnegative_order = try self.nextTemp();
            const order = try self.nextTemp();
            const selected_order = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}\n", .{ ambiguous, llvm_ty, diff, min });
            try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ not_ambiguous, ambiguous });
            try self.out.print(self.allocator, "  {s} = icmp slt {s} {s}, 0\n", .{ is_lt, llvm_ty, diff });
            try self.out.print(self.allocator, "  {s} = icmp sgt {s} {s}, 0\n", .{ is_gt, llvm_ty, diff });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, i8 1, i8 0\n", .{ nonnegative_order, is_gt });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, i8 -1, i8 {s}\n", .{ order, is_lt, nonnegative_order });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, i8 0, i8 {s}\n", .{ selected_order, ambiguous, order });
            return try self.emitResultValue(info.return_ty, not_ambiguous, selected_order, "0");
        }
        if (std.mem.eql(u8, info.op, "elapsed_bounded")) {
            const max = try self.emitExpr(call.args[2], try self.durationType(info.payload_ty, call.args[2].span));
            const in_range = try self.nextTemp();
            const selected_delta = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = icmp ule {s} {s}, {s}\n", .{ in_range, llvm_ty, diff, max });
            try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} {s}, {s} 0\n", .{ selected_delta, in_range, llvm_ty, diff, llvm_ty });
            return try self.emitResultValue(info.return_ty, in_range, selected_delta, "0");
        }
        return diff;
    }

    fn durationType(self: *LlvmEmitter, payload_ty: ast.TypeExpr, span: ast.Span) !ast.TypeExpr {
        const args = try self.scratch.allocator().alloc(ast.TypeExpr, 1);
        args[0] = payload_ty;
        return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = "Duration", .span = span }, .args = args } } };
    }

    fn emitReduceCall(self: *LlvmEmitter, call: anytype, info: ReduceCallInfo) ![]const u8 {
        if (call.type_args.len != 1 or call.args.len != 1) return error.UnsupportedLlvmEmission;
        const slice_ty = self.exprType(call.args[0]) orelse return error.UnsupportedLlvmEmission;
        const slice = switch (self.resolveAliasType(slice_ty).kind) {
            .slice => |node| node,
            else => return error.UnsupportedLlvmEmission,
        };
        if (!std.mem.eql(u8, try self.llvmType(slice.child.*), try self.llvmType(info.element_ty))) return error.UnsupportedLlvmEmission;

        if (std.mem.eql(u8, info.op, "sum_checked")) return try self.emitReduceSumChecked(call.args[0], slice_ty, info.element_ty, info.return_ty);
        if (std.mem.eql(u8, info.op, "sum_left")) return try self.emitReduceFloat(call.args[0], slice_ty, info.element_ty, false);
        if (std.mem.eql(u8, info.op, "sum_fast")) return try self.emitReduceFloat(call.args[0], slice_ty, info.element_ty, true);
        return error.UnsupportedLlvmEmission;
    }

    fn emitReduceSumChecked(self: *LlvmEmitter, arg: ast.Expr, slice_ty: ast.TypeExpr, element_ty: ast.TypeExpr, return_ty: ast.TypeExpr) ![]const u8 {
        const range = self.intRangeOf(element_ty) orelse return error.UnsupportedLlvmEmission;
        const element_llvm = try self.llvmType(element_ty);
        const element_bits = self.integerBitsOf(element_ty) orelse return error.UnsupportedLlvmEmission;
        const result_llvm = try self.resultPayloadLlvmType(element_ty);

        const slice_value = try self.emitExpr(arg, slice_ty);
        const data = try self.nextTemp();
        const len = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ data, try self.llvmType(slice_ty), slice_value });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, try self.llvmType(slice_ty), slice_value });

        const index_ptr = try self.nextTemp();
        const acc_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = alloca i64\n", .{index_ptr});
        try self.out.print(self.allocator, "  {s} = alloca i128\n", .{acc_ptr});
        try self.out.print(self.allocator, "  store i64 0, ptr {s}\n", .{index_ptr});
        try self.out.print(self.allocator, "  store i128 0, ptr {s}\n", .{acc_ptr});

        const cond_label = try self.nextLabel("reduce_cond");
        const body_label = try self.nextLabel("reduce_body");
        const done_label = try self.nextLabel("reduce_done");
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const index = try self.nextTemp();
        const in_range = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ in_range, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ in_range, body_label, done_label, try self.debugCallSuffix(), body_label });

        const element_ptr = try self.nextTemp();
        const element = try self.nextTemp();
        const widened = try self.nextTemp();
        const acc = try self.nextTemp();
        const next_acc = try self.nextTemp();
        const next_index = try self.nextTemp();
        const extend_op: []const u8 = if (self.isSignedIntegerType(element_ty)) "sext" else "zext";
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ element_ptr, element_llvm, data, index });
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ element, element_llvm, element_ptr });
        if (element_bits == 128) {
            try self.out.print(self.allocator, "  {s} = add i128 {s}, 0\n", .{ widened, element });
        } else {
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to i128\n", .{ widened, extend_op, element_llvm, element });
        }
        try self.out.print(self.allocator, "  {s} = load i128, ptr {s}\n", .{ acc, acc_ptr });
        try self.out.print(self.allocator, "  {s} = add i128 {s}, {s}\n", .{ next_acc, acc, widened });
        try self.out.print(self.allocator, "  store i128 {s}, ptr {s}\n", .{ next_acc, acc_ptr });
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), done_label });

        const final_acc = try self.nextTemp();
        const below = try self.nextTemp();
        const above = try self.nextTemp();
        const overflow = try self.nextTemp();
        const ok = try self.nextTemp();
        const narrowed = try self.nextTemp();
        const selected_payload = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i128, ptr {s}\n", .{ final_acc, acc_ptr });
        try self.out.print(self.allocator, "  {s} = icmp slt i128 {s}, {d}\n", .{ below, final_acc, range.min });
        try self.out.print(self.allocator, "  {s} = icmp sgt i128 {s}, {d}\n", .{ above, final_acc, range.max });
        try self.out.print(self.allocator, "  {s} = or i1 {s}, {s}\n", .{ overflow, below, above });
        try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ ok, overflow });
        if (element_bits == 128) {
            try self.out.print(self.allocator, "  {s} = add i128 {s}, 0\n", .{ narrowed, final_acc });
        } else {
            try self.out.print(self.allocator, "  {s} = trunc i128 {s} to {s}\n", .{ narrowed, final_acc, result_llvm });
        }
        try self.out.print(self.allocator, "  {s} = select i1 {s}, {s} 0, {s} {s}\n", .{ selected_payload, overflow, result_llvm, result_llvm, narrowed });
        return try self.emitResultValue(return_ty, ok, selected_payload, "0");
    }

    fn emitReduceFloat(self: *LlvmEmitter, arg: ast.Expr, slice_ty: ast.TypeExpr, element_ty: ast.TypeExpr, fast: bool) ![]const u8 {
        if (!self.isFloatTypeOf(element_ty)) return error.UnsupportedLlvmEmission;
        const element_llvm = try self.llvmType(element_ty);
        const slice_value = try self.emitExpr(arg, slice_ty);
        const data = try self.nextTemp();
        const len = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ data, try self.llvmType(slice_ty), slice_value });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ len, try self.llvmType(slice_ty), slice_value });

        const index_ptr = try self.nextTemp();
        const acc_ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = alloca i64\n", .{index_ptr});
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ acc_ptr, element_llvm });
        try self.out.print(self.allocator, "  store i64 0, ptr {s}\n", .{index_ptr});
        try self.out.print(self.allocator, "  store {s} 0.000000e+00, ptr {s}\n", .{ element_llvm, acc_ptr });

        const cond_label = try self.nextLabel("reduce_cond");
        const body_label = try self.nextLabel("reduce_body");
        const done_label = try self.nextLabel("reduce_done");
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), cond_label });
        const index = try self.nextTemp();
        const in_range = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load i64, ptr {s}\n", .{ index, index_ptr });
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ in_range, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}{s}\n{s}:\n", .{ in_range, body_label, done_label, try self.debugCallSuffix(), body_label });

        const element_ptr = try self.nextTemp();
        const element = try self.nextTemp();
        const acc = try self.nextTemp();
        const next_acc = try self.nextTemp();
        const next_index = try self.nextTemp();
        const add_op: []const u8 = if (fast) "fadd reassoc" else "fadd";
        try self.out.print(self.allocator, "  {s} = getelementptr {s}, ptr {s}, i64 {s}\n", .{ element_ptr, element_llvm, data, index });
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ element, element_llvm, element_ptr });
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ acc, element_llvm, acc_ptr });
        try self.out.print(self.allocator, "  {s} = {s} {s} {s}, {s}\n", .{ next_acc, add_op, element_llvm, acc, element });
        try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ element_llvm, next_acc, acc_ptr });
        try self.out.print(self.allocator, "  {s} = add i64 {s}, 1\n", .{ next_index, index });
        try self.out.print(self.allocator, "  store i64 {s}, ptr {s}\n", .{ next_index, index_ptr });
        try self.out.print(self.allocator, "  br label %{s}{s}\n{s}:\n", .{ cond_label, try self.debugCallSuffix(), done_label });

        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, element_llvm, acc_ptr });
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

        const global = try self.internStringLiteral(literal);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr [{d} x i8], ptr @{s}, i64 0, i64 0\n", .{ result, global.len, global.name });
        return result;
    }

    fn internStringLiteral(self: *LlvmEmitter, literal: []const u8) !StringLiteralGlobal {
        const bytes = try llvmStringLiteralBytes(self.scratch.allocator(), literal);
        const name = try std.fmt.allocPrint(self.scratch.allocator(), ".str.{d}", .{self.string_literals.items.len});
        const global: StringLiteralGlobal = .{
            .name = name,
            .escaped_bytes = bytes.escaped,
            .len = bytes.len,
        };
        try self.string_literals.append(self.allocator, global);
        return global;
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
            else if (std.mem.eql(u8, name.text, "IrqOff"))
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
            else if (self.overlay_unions.get(name.text)) |info|
                try self.overlayLlvmType(info)
            else if (self.tagged_unions.get(name.text)) |union_decl|
                try self.taggedUnionLlvmType(union_decl)
            else if (self.struct_types.get(name.text)) |struct_decl|
                try self.structLlvmType(struct_decl)
            else if (libraryScalarLlvmType(name.text)) |library_ty|
                library_ty
            else
                error.UnsupportedLlvmEmission,
            .pointer, .raw_many_pointer, .nullable => "ptr",
            .array => |node| try std.fmt.allocPrint(self.scratch.allocator(), "[{d} x {s}]", .{ self.arrayLenValue(node.len) orelse return error.UnsupportedLlvmEmission, try self.llvmType(node.child.*) }),
            .slice => "{ ptr, i64 }",
            .fn_pointer => "ptr",
            .closure_type => "{ ptr, ptr }",
            .generic => |node| if (std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2)
                try self.resultLlvmType(node.args[0], node.args[1])
            else if (std.mem.eql(u8, node.base.text, "atomic") and node.args.len == 1)
                try self.atomicStorageLlvmType(node.args[0])
            else if (std.mem.eql(u8, node.base.text, "MaybeUninit") and node.args.len == 1)
                try self.llvmType(node.args[0])
            else if ((std.mem.eql(u8, node.base.text, "Reg") or std.mem.eql(u8, node.base.text, "RegBits")) and node.args.len >= 1)
                try self.llvmType(node.args[0])
            else if (std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1)
                "ptr"
            else if (std.mem.eql(u8, node.base.text, "DmaBuf") and node.args.len == 2)
                "i64"
            else if (isPayloadDomainGenericName(node.base.text) and node.args.len == 1)
                try self.llvmType(node.args[0])
            else if (isOpaqueAddressGenericName(node.base.text) and node.args.len == 1)
                "i64"
            else
                error.UnsupportedLlvmEmission,
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn resultLlvmType(self: *LlvmEmitter, ok_ty: ast.TypeExpr, err_ty: ast.TypeExpr) ![]const u8 {
        return std.fmt.allocPrint(self.scratch.allocator(), "{{ i1, {s}, {s} }}", .{ try self.resultPayloadLlvmType(ok_ty), try self.resultPayloadLlvmType(err_ty) });
    }

    fn resultPayloadLlvmType(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return "i8";
        return try self.llvmType(ty);
    }

    fn nextTemp(self: *LlvmEmitter) ![]const u8 {
        const index = self.temp_index;
        self.temp_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "%t{d}", .{index});
    }

    fn nextBindingPtr(self: *LlvmEmitter, name: []const u8) ![]const u8 {
        const index = self.temp_index;
        self.temp_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr.{d}", .{ name, index });
    }

    fn nextLabel(self: *LlvmEmitter, prefix: []const u8) ![]const u8 {
        const index = self.trap_index;
        self.trap_index += 1;
        return std.fmt.allocPrint(self.scratch.allocator(), "bb_{s}{d}", .{ prefix, index });
    }

    fn exprType(self: *LlvmEmitter, expr: ast.Expr) ?ast.TypeExpr {
        return switch (expr.kind) {
            .ident => |ident| self.local_types.get(ident.text) orelse self.global_types.get(ident.text) orelse self.fnPointerTypeForName(ident.text),
            .bool_literal => simpleType(expr.span, "bool"),
            .unary => |node| if (node.op == .logical_not) simpleType(expr.span, "bool") else self.exprType(node.expr.*),
            .int_literal => null,
            .float_literal => null,
            .grouped => |inner| self.exprType(inner.*),
            .call => |call| if (isAssumeNoaliasCall(call))
                if (call.args.len == 2) self.exprType(call.args[0]) else null
            else
                self.callReturnType(call),
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
                if (self.overlayField(node.base.*, node.name.text)) |field| break :blk field.ty;
                if (self.memberField(node.base.*, node.name.text)) |field| break :blk field.ty;
                break :blk null;
            } else null,
            .binary => |node| if (binaryIsComparison(node.op) or node.op == .logical_and or node.op == .logical_or) simpleType(expr.span, "bool") else self.exprType(node.left.*),
            .try_expr => |node| if (self.exprType(node.operand.*)) |ty|
                if (self.resultInfo(ty)) |info| info.ok_ty else self.nullableInnerType(ty)
            else
                null,
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

    fn maybeUninitPayloadType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .generic => |node| {
                if (!std.mem.eql(u8, node.base.text, "MaybeUninit") or node.args.len != 1) return null;
                return node.args[0];
            },
            .qualified => |node| self.maybeUninitPayloadType(node.child.*),
            else => null,
        };
    }

    fn mmioAccessInfo(self: *LlvmEmitter, call: anytype) ?MmioAccessInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        const op = if (std.mem.eql(u8, member.name.text, "read"))
            "read"
        else if (std.mem.eql(u8, member.name.text, "write"))
            "write"
        else
            return null;
        const reg_member = switch (member.base.kind) {
            .member => |node| node,
            else => return null,
        };
        const base_ty = self.exprType(reg_member.base.*) orelse return null;
        const struct_ty = self.memberBaseStructType(base_ty) orelse return null;
        const struct_decl = self.structDeclForType(struct_ty) orelse return null;
        if (!isMmioStructAbi(struct_decl)) return null;
        const field = self.mmioStructField(struct_decl, reg_member.name.text) orelse return null;
        const field_info = self.mmioFieldInfo(field) orelse return null;
        const offset = self.mmioFieldOffset(struct_decl, reg_member.name.text) orelse return null;
        return .{
            .op = op,
            .base = reg_member.base.*,
            .struct_ty = struct_ty,
            .storage_ty = field_info.storage_ty,
            .value_ty = field_info.value_ty,
            .offset = offset,
        };
    }

    fn emitMmioRegisterAddress(self: *LlvmEmitter, info: MmioAccessInfo) ![]const u8 {
        const base = try self.emitExpr(info.base, try self.mmioPointerType(info.struct_ty, info.base.span));
        if (info.offset == 0) return base;
        const ptr = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr i8, ptr {s}, i64 {d}\n", .{ ptr, base, info.offset });
        return ptr;
    }

    fn emitMmioFence(self: *LlvmEmitter, ordering: []const u8, placement: MmioFencePlacement) !void {
        const fence: ?[]const u8 = switch (placement) {
            .before_store => if (std.mem.eql(u8, ordering, "release"))
                "release"
            else if (std.mem.eql(u8, ordering, "acq_rel"))
                "release"
            else if (std.mem.eql(u8, ordering, "seq_cst"))
                "seq_cst"
            else
                null,
            .after_load => if (std.mem.eql(u8, ordering, "acquire"))
                "acquire"
            else if (std.mem.eql(u8, ordering, "acq_rel"))
                "acquire"
            else if (std.mem.eql(u8, ordering, "seq_cst"))
                "seq_cst"
            else
                null,
        };
        if (fence) |kind| try self.out.print(self.allocator, "  fence {s}{s}\n", .{ kind, try self.debugCallSuffix() });
    }

    fn mmioPointerType(self: *LlvmEmitter, child_ty: ast.TypeExpr, span: ast.Span) !ast.TypeExpr {
        const args = try self.scratch.allocator().alloc(ast.TypeExpr, 1);
        args[0] = child_ty;
        return .{ .span = span, .kind = .{ .generic = .{ .base = .{ .text = "MmioPtr", .span = span }, .args = args } } };
    }

    fn resultInfo(self: *LlvmEmitter, ty: ast.TypeExpr) ?ResultTypeInfo {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .generic => |node| {
                if (!std.mem.eql(u8, node.base.text, "Result") or node.args.len != 2) return null;
                return .{ .ok_ty = node.args[0], .err_ty = node.args[1] };
            },
            .qualified => |node| self.resultInfo(node.child.*),
            else => null,
        };
    }

    fn domainPayloadType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.TypeExpr {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .generic => |node| {
                if (!isPayloadDomainGenericName(node.base.text) or node.args.len != 1) return null;
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

    fn sliceTypeFor(self: *LlvmEmitter, child_ty: ast.TypeExpr, mutability: ast.Mutability, span: ast.Span) !ast.TypeExpr {
        const child = try self.scratch.allocator().create(ast.TypeExpr);
        child.* = child_ty;
        return .{ .span = span, .kind = .{ .slice = .{ .mutability = mutability, .child = child } } };
    }

    fn constU8SliceType(self: *LlvmEmitter, span: ast.Span) !ast.TypeExpr {
        const child = try self.scratch.allocator().create(ast.TypeExpr);
        child.* = simpleType(span, "u8");
        return .{ .span = span, .kind = .{ .slice = .{ .mutability = .@"const", .child = child } } };
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

    fn overlayInfoForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?OverlayUnionInfo {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .name => |name| self.overlay_unions.get(name.text),
            else => null,
        };
    }

    fn taggedUnionForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.UnionDecl {
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .name => |name| self.tagged_unions.get(name.text),
            else => null,
        };
    }

    fn taggedUnionCaseIndex(self: *LlvmEmitter, union_decl: ast.UnionDecl, case_name: []const u8) ?usize {
        _ = self;
        for (union_decl.cases, 0..) |case, i| {
            if (std.mem.eql(u8, case.name.text, case_name)) return i;
        }
        return null;
    }

    fn taggedUnionLlvmType(self: *LlvmEmitter, union_decl: ast.UnionDecl) ![]const u8 {
        const layout = self.taggedUnionLayout(union_decl, 0) orelse return error.UnsupportedLlvmEmission;
        const storage_ty = try self.taggedUnionPayloadStorageType(layout);
        if (layout.padding_size == 0) {
            return std.fmt.allocPrint(self.scratch.allocator(), "{{ i32, {s} }}", .{storage_ty});
        }
        return std.fmt.allocPrint(self.scratch.allocator(), "{{ i32, [{d} x i8], {s} }}", .{ layout.padding_size, storage_ty });
    }

    fn taggedUnionLayout(self: *LlvmEmitter, union_decl: ast.UnionDecl, depth: usize) ?TaggedUnionLayout {
        const payload_size = self.taggedUnionPayloadSize(union_decl, depth + 1) orelse return null;
        const payload_align = self.taggedUnionPayloadAlignment(union_decl, depth + 1) orelse return null;
        if (payload_align != 1 and payload_align != 2 and payload_align != 4 and payload_align != 8) return null;
        var payload_offset: i128 = 4;
        payload_offset = alignForward(payload_offset, @intCast(payload_align)) orelse return null;
        const payload_offset_u64: u64 = @intCast(payload_offset);
        const aligned_payload_size = alignForward(@intCast(payload_size), @intCast(payload_align)) orelse return null;
        const size = alignForward(payload_offset + aligned_payload_size, @intCast(@max(@as(u64, 4), payload_align))) orelse return null;
        const storage_count = @as(u64, @intCast(aligned_payload_size)) / payload_align;
        return .{
            .size = @intCast(size),
            .alignment = @max(@as(u64, 4), payload_align),
            .payload_size = payload_size,
            .payload_alignment = payload_align,
            .padding_size = payload_offset_u64 - 4,
            .storage_count = @max(@as(u64, 1), storage_count),
            .payload_field_index = if (payload_offset_u64 == 4) 1 else 2,
        };
    }

    fn taggedUnionPayloadStorageType(self: *LlvmEmitter, layout: TaggedUnionLayout) ![]const u8 {
        const bits = layout.payload_alignment * 8;
        return std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i{d}]", .{ layout.storage_count, bits });
    }

    fn taggedUnionPayloadSize(self: *LlvmEmitter, union_decl: ast.UnionDecl, depth: usize) ?u64 {
        if (depth > 32) return null;
        var size: u64 = 1;
        for (union_decl.cases) |case| {
            const ty = case.ty orelse continue;
            const payload_size = self.comptimeSizeOf(ty, depth + 1) orelse return null;
            size = @max(size, @as(u64, @intCast(payload_size)));
        }
        return size;
    }

    fn taggedUnionPayloadAlignment(self: *LlvmEmitter, union_decl: ast.UnionDecl, depth: usize) ?u64 {
        if (depth > 32) return null;
        var alignment: u64 = 1;
        for (union_decl.cases) |case| {
            const ty = case.ty orelse continue;
            const payload_alignment = self.comptimeAlignOf(ty, depth + 1) orelse return null;
            alignment = @max(alignment, @as(u64, @intCast(payload_alignment)));
        }
        return alignment;
    }

    fn packedBitsFieldIndex(self: *LlvmEmitter, info: PackedBitsInfo, field_name: []const u8) ?usize {
        _ = self;
        for (info.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name.text, field_name)) return i;
        }
        return null;
    }

    fn packedBitsBaseAddress(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                if (self.local_slots.get(ident.text)) |slot| break :blk slot.ptr;
                if (self.global_types.contains(ident.text)) break :blk try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                break :blk error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| self.packedBitsBaseAddress(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
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
            .generic => |node| if (std.mem.eql(u8, node.base.text, "MmioPtr") and node.args.len == 1) node.args[0] else ty,
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

    fn emitPackedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast.StructLiteralField) ![]const u8 {
        if (self.staticPackedBitsLiteralValue(info, fields)) |value| return value;
        const llvm_ty = try self.llvmType(info.repr);
        var current: []const u8 = "0";
        for (fields) |field| {
            const bit_index = self.packedBitsFieldIndex(info, field.name.text) orelse return error.UnsupportedLlvmEmission;
            const flag = try self.emitExpr(field.value, simpleType(field.value.span, "bool"));
            const widened = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = zext i1 {s} to {s}\n", .{ widened, flag, llvm_ty });
            const shifted = if (bit_index == 0) widened else blk: {
                const shifted = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = shl {s} {s}, {d}\n", .{ shifted, llvm_ty, widened, bit_index });
                break :blk shifted;
            };
            const next = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = or {s} {s}, {s}\n", .{ next, llvm_ty, current, shifted });
            current = next;
        }
        return current;
    }

    fn staticPackedBitsLiteralValue(self: *LlvmEmitter, info: PackedBitsInfo, fields: []const ast.StructLiteralField) ?[]const u8 {
        return self.packedBitsLiteralValue(info, fields) catch null;
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
            const field_ty = if (isMmioStructAbi(struct_decl))
                (self.mmioFieldInfo(field) orelse return error.UnsupportedLlvmEmission).storage_ty
            else
                field.ty;
            try text.appendSlice(self.scratch.allocator(), try self.llvmType(field_ty));
        }
        try text.appendSlice(self.scratch.allocator(), " }");
        return text.toOwnedSlice(self.scratch.allocator());
    }

    fn overlayLlvmType(self: *LlvmEmitter, info: OverlayUnionInfo) ![]const u8 {
        return std.fmt.allocPrint(self.scratch.allocator(), "[{d} x i8]", .{info.size});
    }

    fn overlayField(self: *LlvmEmitter, base: ast.Expr, field_name: []const u8) ?ast.Field {
        const base_ty = self.exprType(base) orelse return null;
        const info = self.overlayInfoForType(base_ty) orelse return null;
        for (info.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn emitOverlayFieldAddress(self: *LlvmEmitter, base: ast.Expr, field: ast.Field) ![]const u8 {
        _ = field;
        return try self.aggregateBasePointer(base);
    }

    fn memberField(self: *LlvmEmitter, base: ast.Expr, field_name: []const u8) ?ast.Field {
        const base_ty = self.exprType(base) orelse return null;
        const struct_decl = self.memberBaseStructDecl(base_ty) orelse return null;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn mmioStructField(self: *LlvmEmitter, struct_decl: ast.StructDecl, field_name: []const u8) ?ast.Field {
        _ = self;
        for (struct_decl.fields) |field| {
            if (std.mem.eql(u8, field.name.text, field_name)) return field;
        }
        return null;
    }

    fn mmioFieldInfo(self: *LlvmEmitter, field: ast.Field) ?MmioFieldInfo {
        _ = self;
        const generic = switch (field.ty.kind) {
            .generic => |node| node,
            else => return null,
        };
        if (std.mem.eql(u8, generic.base.text, "Reg")) {
            if (generic.args.len != 2) return null;
            return .{ .storage_ty = generic.args[0], .value_ty = generic.args[0] };
        }
        if (std.mem.eql(u8, generic.base.text, "RegBits")) {
            if (generic.args.len != 3) return null;
            return .{ .storage_ty = generic.args[0], .value_ty = generic.args[1] };
        }
        return null;
    }

    fn mmioFieldOffset(self: *LlvmEmitter, struct_decl: ast.StructDecl, field_name: []const u8) ?u64 {
        var offset: i128 = 0;
        for (struct_decl.fields) |field| {
            const info = self.mmioFieldInfo(field) orelse return null;
            const size = self.comptimeSizeOf(info.storage_ty, 0) orelse return null;
            const alignment = self.comptimeAlignOf(info.storage_ty, 0) orelse return null;
            if (field.offset) |explicit| {
                offset = @intCast(explicit);
            } else {
                offset = alignForward(offset, alignment) orelse return null;
            }
            if (std.mem.eql(u8, field.name.text, field_name)) return @intCast(offset);
            offset += size;
        }
        return null;
    }

    fn overlayFieldLayout(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?OverlayLayout {
        if (depth > 32) return null;
        return switch (ty.kind) {
            .array => |node| {
                const child = self.overlayFieldLayout(node.child.*, depth + 1) orelse return null;
                const len = self.arrayLenValue(node.len) orelse return null;
                return .{ .size = child.size * len, .alignment = child.alignment };
            },
            .qualified => |node| self.overlayFieldLayout(node.child.*, depth + 1),
            else => blk: {
                const size = self.comptimeSizeOf(ty, depth + 1) orelse return null;
                const alignment = self.comptimeAlignOf(ty, depth + 1) orelse return null;
                break :blk .{ .size = @intCast(size), .alignment = @intCast(alignment) };
            },
        };
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

    fn closureCalleeType(self: *LlvmEmitter, callee: ast.Expr) ?ast.TypeExpr {
        const ty = self.exprType(callee) orelse return null;
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .closure_type => resolved_ty,
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

    fn bindClosureType(self: *LlvmEmitter, call: anytype) ?ast.TypeExpr {
        if (!isBindCallByNode(call) or call.args.len != 2) return null;
        const fname = calleeIdentName(call.args[1]) orelse return null;
        const sig = self.fn_sigs.get(fname) orelse return null;
        if (sig.params.len == 0) return null;
        const params = self.scratch.allocator().alloc(ast.TypeExpr, sig.params.len - 1) catch return null;
        for (sig.params[1..], 0..) |param, i| params[i] = param.ty;
        const ret = self.scratch.allocator().create(ast.TypeExpr) catch return null;
        ret.* = sig.ret;
        return .{
            .span = call.callee.*.span,
            .kind = .{ .closure_type = .{ .params = params, .ret = ret } },
        };
    }

    fn isFnPointerType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return self.resolveAliasType(ty).kind == .fn_pointer;
    }

    fn callReturnType(self: *LlvmEmitter, call: anytype) ?ast.TypeExpr {
        if (reflectionCallKind(call.callee.*) != null) return simpleType(call.callee.*.span, "usize");
        if (self.constGetCallInfo(call)) |info| return info.element_ty;
        if (bitcastTargetType(call)) |ty| return ty;
        if (builtinCallReturnType(call)) |ty| return ty;
        if (self.enumRawCallInfo(call)) |info| return info.repr_ty;
        if (self.domainResidueCallInfo(call)) |info| return info.payload_ty;
        if (self.domainOpCallInfo(call)) |info| return info.return_ty;
        if (self.reduceCallInfo(call)) |info| return info.return_ty;
        if (byteViewCallKind(call.callee.*)) |kind| return switch (kind) {
            .as_bytes => self.constU8SliceType(call.callee.*.span) catch null,
            .bytes_equal => simpleType(call.callee.*.span, "bool"),
        };
        if (mmioMapCallPayloadType(call)) |ty| {
            const child = self.scratch.allocator().create(ast.TypeExpr) catch return null;
            child.* = ty;
            return .{ .span = call.callee.*.span, .kind = .{ .nullable = child } };
        }
        if (self.conversionCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "try_from")) {
                return self.resultType(info.target_ty, simpleType(call.callee.*.span, "ConversionError"), call.callee.*.span) catch null;
            }
            return info.target_ty;
        }
        if (uncheckedBuiltinOp(call.callee.*) != null and call.args.len == 2) return self.exprType(call.args[0]);
        if (self.atomicCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "load") or std.mem.eql(u8, info.op, "fetch_add") or std.mem.eql(u8, info.op, "fetch_sub")) return info.payload_ty;
            if (std.mem.eql(u8, info.op, "store")) return simpleType(call.callee.*.span, "void");
        }
        if (self.mmioAccessInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "read")) return info.value_ty;
            if (std.mem.eql(u8, info.op, "write")) return simpleType(call.callee.*.span, "void");
        }
        if (self.maybeUninitCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "assume_init")) return info.payload_ty;
            if (std.mem.eql(u8, info.op, "write")) return simpleType(call.callee.*.span, "void");
        }
        if (self.dmaCacheCallInfo(call) != null) return simpleType(call.callee.*.span, "void");
        if (self.dmaBufCallInfo(call)) |info| {
            if (std.mem.eql(u8, info.op, "dma_addr")) return simpleType(call.callee.*.span, "DmaAddr");
            if (std.mem.eql(u8, info.op, "as_slice")) return self.sliceTypeFor(info.payload_ty, .mut, call.callee.*.span) catch null;
        }
        if (self.rawManyOffsetCallInfo(call)) |info| return info.base_ty;
        if (isBindCallByNode(call)) return self.bindClosureType(call);
        if (self.closureCalleeType(call.callee.*)) |closure_ty| return closure_ty.kind.closure_type.ret.*;
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
            !std.mem.eql(u8, member.name.text, "sat_from") and
            !std.mem.eql(u8, member.name.text, "try_from"))
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

    fn domainOpCallInfo(self: *LlvmEmitter, call: anytype) ?DomainOpCallInfo {
        if (call.type_args.len != 0) return null;
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        const op = member.name.text;
        const is_serial_op = std.mem.eql(u8, op, "before") or
            std.mem.eql(u8, op, "after") or
            std.mem.eql(u8, op, "distance") or
            std.mem.eql(u8, op, "compare");
        const is_counter_op = std.mem.eql(u8, op, "delta_mod") or
            std.mem.eql(u8, op, "elapsed_assume_within") or
            std.mem.eql(u8, op, "elapsed_bounded");
        if (!is_serial_op and !is_counter_op) return null;
        const ident = switch (member.base.kind) {
            .ident => |id| id,
            else => return null,
        };
        if (self.local_types.contains(ident.text)) return null;
        const domain_ty = self.resolveAliasType(simpleType(ident.span, ident.text));
        const generic = switch (domain_ty.kind) {
            .generic => |node| node,
            else => return null,
        };
        if (generic.args.len != 1) return null;
        const is_serial = std.mem.eql(u8, generic.base.text, "serial");
        const is_counter = std.mem.eql(u8, generic.base.text, "counter");
        if ((is_serial_op and !is_serial) or (is_counter_op and !is_counter)) return null;
        const duration_ty: ast.TypeExpr = .{ .span = member.name.span, .kind = .{ .generic = .{ .base = .{ .text = "Duration", .span = member.name.span }, .args = generic.args } } };
        const return_ty: ast.TypeExpr = if (std.mem.eql(u8, op, "before") or std.mem.eql(u8, op, "after"))
            simpleType(member.name.span, "bool")
        else if (std.mem.eql(u8, op, "compare"))
            self.resultType(simpleType(member.name.span, "Order"), simpleType(member.name.span, "AmbiguousSerialOrder"), member.name.span) catch return null
        else if (std.mem.eql(u8, op, "elapsed_assume_within"))
            duration_ty
        else if (std.mem.eql(u8, op, "elapsed_bounded"))
            self.resultType(duration_ty, simpleType(member.name.span, "AmbiguousCounterInterval"), member.name.span) catch return null
        else
            .{ .span = member.name.span, .kind = .{ .generic = .{ .base = .{ .text = "wrap", .span = member.name.span }, .args = generic.args } } };
        return .{ .domain_ty = domain_ty, .payload_ty = generic.args[0], .return_ty = return_ty, .op = op };
    }

    fn reduceCallInfo(self: *LlvmEmitter, call: anytype) ?ReduceCallInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!isIdentNamed(member.base.*, "reduce")) return null;
        const op = member.name.text;
        if (!std.mem.eql(u8, op, "sum_checked") and !std.mem.eql(u8, op, "sum_left") and !std.mem.eql(u8, op, "sum_fast")) return null;
        if (call.type_args.len != 1) return null;
        const element_ty = call.type_args[0];
        const return_ty = if (std.mem.eql(u8, op, "sum_checked"))
            self.resultType(element_ty, simpleType(member.name.span, "Overflow"), member.name.span) catch return null
        else
            element_ty;
        return .{ .element_ty = element_ty, .return_ty = return_ty, .op = op };
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
        if (self.atomicPayloadType(base_ty)) |payload_ty| {
            return .{ .base = member.base.*, .op = member.name.text, .payload_ty = payload_ty };
        }
        // A `*atomic<T>` base: the pointer is the atomic's address.
        const child = switch (self.resolveAliasType(base_ty).kind) {
            .pointer => |p| p.child.*,
            else => return null,
        };
        const payload_ty = self.atomicPayloadType(child) orelse return null;
        return .{ .base = member.base.*, .op = member.name.text, .payload_ty = payload_ty, .base_is_pointer = true };
    }

    // The address the atomic lives at: for a `*atomic<T>` base the pointer value already IS the
    // address; otherwise it is the storage address of the by-value atomic (local/global/field).
    fn atomicAddress(self: *LlvmEmitter, info: AtomicCallInfo) ![]const u8 {
        if (info.base_is_pointer) {
            const base_ty = self.exprType(info.base) orelse return error.UnsupportedLlvmEmission;
            return try self.emitExpr(info.base, base_ty);
        }
        return self.atomicBaseAddress(info.base);
    }

    fn maybeUninitCallInfo(self: *LlvmEmitter, call: anytype) ?MaybeUninitCallInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "write") and
            !std.mem.eql(u8, member.name.text, "assume_init"))
        {
            return null;
        }
        const base_ty = self.exprType(member.base.*) orelse return null;
        const payload_ty = self.maybeUninitPayloadType(base_ty) orelse return null;
        return .{ .base = member.base.*, .op = member.name.text, .payload_ty = payload_ty };
    }

    fn dmaCacheCallInfo(self: *LlvmEmitter, call: anytype) ?DmaCacheCallInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!isIdentNamed(member.base.*, "cache")) return null;
        if (!std.mem.eql(u8, member.name.text, "clean") and !std.mem.eql(u8, member.name.text, "invalidate")) return null;
        if (call.args.len != 1) return null;
        const dma_ty = self.exprType(call.args[0]) orelse return null;
        _ = self.dmaBufInfo(dma_ty) orelse return null;
        return .{ .op = member.name.text, .dma_ty = dma_ty };
    }

    fn dmaBufCallInfo(self: *LlvmEmitter, call: anytype) ?DmaBufCallInfo {
        const member = switch (call.callee.kind) {
            .member => |node| node,
            .grouped => |inner| switch (inner.kind) {
                .member => |node| node,
                else => return null,
            },
            else => return null,
        };
        if (!std.mem.eql(u8, member.name.text, "dma_addr") and !std.mem.eql(u8, member.name.text, "as_slice")) return null;
        const dma_ty = self.exprType(member.base.*) orelse return null;
        const info = self.dmaBufInfo(dma_ty) orelse return null;
        return .{ .base = member.base.*, .op = member.name.text, .dma_ty = dma_ty, .payload_ty = info.payload_ty };
    }

    fn dmaBufInfo(self: *LlvmEmitter, ty: ast.TypeExpr) ?DmaBufInfo {
        const resolved = self.resolveAliasType(ty);
        return switch (resolved.kind) {
            .generic => |node| {
                if (!std.mem.eql(u8, node.base.text, "DmaBuf") or node.args.len != 2) return null;
                return .{ .payload_ty = node.args[0] };
            },
            .qualified => |node| self.dmaBufInfo(node.child.*),
            else => null,
        };
    }

    fn atomicBaseAddress(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return self.storageBaseAddress(expr);
    }

    fn storageBaseAddress(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| if (self.local_slots.get(ident.text)) |slot|
                slot.ptr
            else if (self.global_types.contains(ident.text))
                try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text})
            else
                error.UnsupportedLlvmEmission,
            .member => |node| try self.emitMemberAddress(node),
            .grouped => |inner| try self.storageBaseAddress(inner.*),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn llvmAlignOf(self: *LlvmEmitter, ty: ast.TypeExpr) u8 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.llvmAlignOf(enumReprType(enum_decl));
        const resolved_ty = self.resolveAliasType(ty);
        if (self.atomicPayloadType(resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        if (self.maybeUninitPayloadType(resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        if (self.domainPayloadType(resolved_ty)) |payload_ty| return self.llvmAlignOf(payload_ty);
        return switch (resolved_ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "bool") or
                std.mem.eql(u8, name.text, "i8") or
                std.mem.eql(u8, name.text, "u8") or
                libraryScalarLlvmType(name.text) != null)
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
        const ty = self.reflectionTypeArg(node) orelse return null;
        const field_arg_index: usize = if (node.type_args.len == 1) 0 else 1;
        return switch (kind) {
            .size => self.comptimeSizeOf(ty, 0),
            .repr => self.comptimeReprOf(ty, 0),
            .alignment => self.comptimeAlignOf(ty, 0),
            .field_offset => if (field_arg_index < node.args.len) self.comptimeFieldOffset(ty, reflectionFieldName(node.args[field_arg_index]) orelse return null, 0) else null,
            .bit_offset => if (field_arg_index < node.args.len) self.comptimeBitOffset(ty, reflectionFieldName(node.args[field_arg_index]) orelse return null) else null,
        };
    }

    fn reflectionTypeArg(self: *LlvmEmitter, node: anytype) ?ast.TypeExpr {
        _ = self;
        if (node.type_args.len == 1) return node.type_args[0];
        if (node.type_args.len != 0 or node.args.len == 0) return null;
        return exprAsType(node.args[0]);
    }

    fn reflectionCallValue(self: *LlvmEmitter, call: anytype) ?[]const u8 {
        const expr: ast.Expr = .{ .span = call.callee.*.span, .kind = .{ .call = call } };
        const value = self.comptimeReflect(expr) orelse return null;
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value}) catch null;
    }

    fn comptimeBitOffset(self: *LlvmEmitter, ty: ast.TypeExpr, field: []const u8) ?i128 {
        if (self.packedBitsInfoForType(ty)) |info| {
            const index = self.packedBitsFieldIndex(info, field) orelse return null;
            return @intCast(index);
        }
        const byte_offset = self.comptimeFieldOffset(ty, field, 0) orelse return null;
        return byte_offset * 8;
    }

    fn comptimeReprOf(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (depth > 32) return null;
        const resolved_ty = self.resolveAliasType(ty);
        return switch (resolved_ty.kind) {
            .name => |name| {
                if (self.enum_types.get(name.text)) |enum_decl| return self.comptimeSizeOf(enumReprType(enum_decl), depth + 1);
                if (self.tagged_unions.get(name.text) != null) return 4;
                return self.comptimeSizeOf(resolved_ty, depth + 1);
            },
            .qualified => |node| self.comptimeReprOf(node.child.*, depth + 1),
            else => self.comptimeSizeOf(resolved_ty, depth + 1),
        };
    }

    fn comptimeSizeOf(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (depth > 32) return null;
        return switch (ty.kind) {
            .name => |name| {
                if (scalarLayout(name.text)) |layout| return @intCast(layout.size);
                if (self.type_aliases.get(name.text)) |aliased| return self.comptimeSizeOf(aliased, depth + 1);
                if (self.overlay_unions.get(name.text)) |info| return @intCast(info.size);
                if (self.tagged_unions.get(name.text)) |union_decl| {
                    const layout = self.taggedUnionLayout(union_decl, depth + 1) orelse return null;
                    return @intCast(layout.size);
                }
                if (self.struct_types.get(name.text)) |struct_decl| return self.comptimeStructSize(struct_decl, depth + 1);
                if (self.enum_types.get(name.text)) |enum_decl| return self.comptimeSizeOf(enumReprType(enum_decl), depth + 1);
                if (self.packed_bits.get(name.text)) |info| return self.comptimeSizeOf(info.repr, depth + 1);
                if (libraryScalarLlvmType(name.text) != null) return 1;
                return null;
            },
            .pointer, .raw_many_pointer => 8,
            .nullable => |child| if (isPointerLikeType(child.*)) 8 else null,
            .slice => 16,
            .generic => |g| {
                if (std.mem.eql(u8, g.base.text, "Result") and g.args.len == 2) {
                    const ok_size = self.comptimeResultPayloadSizeOf(g.args[0], depth + 1) orelse return null;
                    const err_size = self.comptimeResultPayloadSizeOf(g.args[1], depth + 1) orelse return null;
                    const ok_align = self.comptimeResultPayloadAlignOf(g.args[0], depth + 1) orelse return null;
                    const err_align = self.comptimeResultPayloadAlignOf(g.args[1], depth + 1) orelse return null;
                    const max_align = @max(@max(ok_align, err_align), 1);
                    var offset: i128 = 1;
                    offset = alignForward(offset, ok_align) orelse return null;
                    offset += ok_size;
                    offset = alignForward(offset, err_align) orelse return null;
                    offset += err_size;
                    return alignForward(offset, max_align);
                }
                if (isOpaqueAddressGenericName(g.base.text) and g.args.len == 1) return 8;
                if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
                if (std.mem.eql(u8, g.base.text, "atomic") and g.args.len == 1) return self.comptimeSizeOf(g.args[0], depth + 1);
                if (std.mem.eql(u8, g.base.text, "MaybeUninit") and g.args.len == 1) return self.comptimeSizeOf(g.args[0], depth + 1);
                if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return self.comptimeSizeOf(g.args[0], depth + 1);
                if (std.mem.eql(u8, g.base.text, "MmioPtr") and g.args.len == 1) return 8;
                if (isPayloadDomainGenericName(g.base.text) and g.args.len == 1) return self.comptimeSizeOf(g.args[0], depth + 1);
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
                if (self.overlay_unions.get(name.text)) |info| return @intCast(info.alignment);
                if (self.tagged_unions.get(name.text)) |union_decl| {
                    const layout = self.taggedUnionLayout(union_decl, depth + 1) orelse return null;
                    return @intCast(layout.alignment);
                }
                if (self.struct_types.get(name.text)) |struct_decl| return self.comptimeStructAlign(struct_decl, depth + 1);
                if (self.enum_types.get(name.text)) |enum_decl| return self.comptimeAlignOf(enumReprType(enum_decl), depth + 1);
                if (self.packed_bits.get(name.text)) |info| return self.comptimeAlignOf(info.repr, depth + 1);
                if (libraryScalarLlvmType(name.text) != null) return 1;
                return null;
            },
            .pointer, .raw_many_pointer, .slice => 8,
            .nullable => |child| if (isPointerLikeType(child.*)) 8 else null,
            .generic => |g| {
                if (std.mem.eql(u8, g.base.text, "Result") and g.args.len == 2) {
                    const ok_align = self.comptimeResultPayloadAlignOf(g.args[0], depth + 1) orelse return null;
                    const err_align = self.comptimeResultPayloadAlignOf(g.args[1], depth + 1) orelse return null;
                    return @max(@max(ok_align, err_align), 1);
                }
                if (isOpaqueAddressGenericName(g.base.text) and g.args.len == 1) return 8;
                if (std.mem.eql(u8, g.base.text, "DmaBuf") and g.args.len == 2) return 8;
                if (std.mem.eql(u8, g.base.text, "atomic") and g.args.len == 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                if (std.mem.eql(u8, g.base.text, "MaybeUninit") and g.args.len == 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                if ((std.mem.eql(u8, g.base.text, "Reg") or std.mem.eql(u8, g.base.text, "RegBits")) and g.args.len >= 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                if (std.mem.eql(u8, g.base.text, "MmioPtr") and g.args.len == 1) return 8;
                if (isPayloadDomainGenericName(g.base.text) and g.args.len == 1) return self.comptimeAlignOf(g.args[0], depth + 1);
                return null;
            },
            .array => |node| self.comptimeAlignOf(node.child.*, depth + 1),
            .qualified => |node| self.comptimeAlignOf(node.child.*, depth + 1),
            else => null,
        };
    }

    fn comptimeResultPayloadSizeOf(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return 1;
        return self.comptimeSizeOf(ty, depth + 1);
    }

    fn comptimeResultPayloadAlignOf(self: *LlvmEmitter, ty: ast.TypeExpr, depth: usize) ?i128 {
        if (typeNameEql(self.resolveAliasType(ty), "void")) return 1;
        return self.comptimeAlignOf(ty, depth + 1);
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
        if (self.overlay_unions.get(name)) |info| {
            for (info.fields) |overlay_field| {
                if (std.mem.eql(u8, overlay_field.name.text, field)) return 0;
            }
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
            if (field.offset) |explicit| {
                offset = @intCast(explicit);
            } else {
                offset = alignForward(offset, alignment) orelse return null;
            }
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
            .generic => |node| if (isOpaqueAddressGenericName(node.base.text) and node.args.len == 1) 64 else null,
            .qualified => |node| self.fixedLayoutBitsOf(node.child.*),
            else => null,
        };
    }

    fn pointerAddressCoercion(self: *LlvmEmitter, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) bool {
        const source = self.resolveAliasType(source_ty);
        const target = self.resolveAliasType(target_ty);
        return switch (source.kind) {
            .pointer, .raw_many_pointer, .nullable => switch (target.kind) {
                .name => |name| isOpaqueAddressTypeName(name.text) or isPointerWidthIntegerTypeName(name.text),
                else => false,
            },
            .name => |name| if (isOpaqueAddressTypeName(name.text)) switch (target.kind) {
                .pointer, .raw_many_pointer, .nullable => true,
                else => false,
            } else false,
            else => false,
        };
    }

    fn signedMinLiteralOf(self: *LlvmEmitter, ty: ast.TypeExpr) ?[]const u8 {
        if (self.enumDeclForType(ty)) |enum_decl| return self.signedMinLiteralOf(enumReprType(enum_decl));
        return signedMinLiteral(self.resolveAliasType(ty));
    }

    fn signedWindowMinLiteral(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        const bits = self.integerBitsOf(ty) orelse return error.UnsupportedLlvmEmission;
        const value = -(@as(i128, 1) << @intCast(bits - 1));
        return std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{value});
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
        if (self.maybeUninitPayloadType(resolved_ty)) |payload_ty| return self.isAggregateType(payload_ty);
        return switch (resolved_ty.kind) {
            .array => true,
            .slice => true,
            .closure_type => true,
            .name => self.structDeclForType(resolved_ty) != null or self.overlayInfoForType(resolved_ty) != null or self.taggedUnionForType(resolved_ty) != null,
            .generic => |node| std.mem.eql(u8, node.base.text, "Result") and node.args.len == 2,
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

// A generated env-widening thunk for a scalar-env `bind`. `fname` is the real
// target; the thunk takes the env as `ptr`, narrows it back to the scalar env
// type via `ptrtoint`, and forwards the remaining arguments.
const BindThunk = struct {
    fname: []const u8,
    sig: FnSig,
};

const PackedBitsInfo = struct {
    repr: ast.TypeExpr,
    fields: []const ast.Field,
};

const OverlayUnionInfo = struct {
    fields: []const ast.Field,
    size: u64,
    alignment: u64,
};

const OverlayLayout = struct {
    size: u64,
    alignment: u64,
};

const TaggedUnionLayout = struct {
    size: u64,
    alignment: u64,
    payload_size: u64,
    payload_alignment: u64,
    padding_size: u64,
    storage_count: u64,
    payload_field_index: u8,
};

const MmioFieldInfo = struct {
    storage_ty: ast.TypeExpr,
    value_ty: ast.TypeExpr,
};

const MmioAccessInfo = struct {
    op: []const u8,
    base: ast.Expr,
    struct_ty: ast.TypeExpr,
    storage_ty: ast.TypeExpr,
    value_ty: ast.TypeExpr,
    offset: u64,
};

const MmioFencePlacement = enum {
    before_store,
    after_load,
};

const DmaBufInfo = struct {
    payload_ty: ast.TypeExpr,
};

const DmaBufCallInfo = struct {
    base: ast.Expr,
    op: []const u8,
    dma_ty: ast.TypeExpr,
    payload_ty: ast.TypeExpr,
};

const DmaCacheCallInfo = struct {
    op: []const u8,
    dma_ty: ast.TypeExpr,
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
    cleanup_start: usize,
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

const DomainOpCallInfo = struct {
    domain_ty: ast.TypeExpr,
    payload_ty: ast.TypeExpr,
    return_ty: ast.TypeExpr,
    op: []const u8,
};

const ConversionCallInfo = struct {
    target_ty: ast.TypeExpr,
    op: []const u8,
};

const ReduceCallInfo = struct {
    element_ty: ast.TypeExpr,
    return_ty: ast.TypeExpr,
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


const AtomicCallInfo = struct {
    base: ast.Expr,
    op: []const u8,
    payload_ty: ast.TypeExpr,
    // True when the base is a `*atomic<T>` (the atomic accessed by pointer): the pointer value
    // is the atomic's address, rather than the base needing `&place`.
    base_is_pointer: bool = false,
};

const MaybeUninitCallInfo = struct {
    base: ast.Expr,
    op: []const u8,
    payload_ty: ast.TypeExpr,
};

const ResultTypeInfo = struct {
    ok_ty: ast.TypeExpr,
    err_ty: ast.TypeExpr,
};

const ResultSwitchPattern = struct {
    tag: []const u8,
    binding: ?ast.Ident = null,
};

const TaggedUnionBinding = struct {
    tag: []const u8,
    binding: ast.Ident,
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

fn llvmAsmTemplate(allocator: std.mem.Allocator, templates: []const []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    for (templates, 0..) |template, i| {
        if (i != 0) try escaped.appendSlice(allocator, "\\0A\\09");
        try appendLlvmStringLiteralBody(allocator, &escaped, template, null);
    }
    return escaped.toOwnedSlice(allocator);
}

fn llvmPreciseAsmTemplate(allocator: std.mem.Allocator, templates: []const []const u8) ![]const u8 {
    const template = try llvmAsmTemplate(allocator, templates);
    var converted: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '%' and i + 1 < template.len and std.ascii.isDigit(template[i + 1])) {
            try converted.append(allocator, '$');
            i += 1;
            while (i < template.len and std.ascii.isDigit(template[i])) : (i += 1) {
                try converted.append(allocator, template[i]);
            }
            continue;
        }
        try converted.append(allocator, template[i]);
        i += 1;
    }
    return converted.toOwnedSlice(allocator);
}

fn llvmAsmClobbers(allocator: std.mem.Allocator, clobbers: []const []const u8) ![]const u8 {
    var constraints: std.ArrayList(u8) = .empty;
    if (clobbers.len == 0) {
        try constraints.appendSlice(allocator, "~{memory}");
        return constraints.toOwnedSlice(allocator);
    }
    for (clobbers, 0..) |clobber, i| {
        const name = try stringLiteralText(allocator, clobber);
        if (i != 0) try constraints.append(allocator, ',');
        try constraints.print(allocator, "~{{{s}}}", .{name});
    }
    return constraints.toOwnedSlice(allocator);
}

fn llvmPreciseAsmConstraints(allocator: std.mem.Allocator, asm_stmt: ast.AsmStmt) ![]const u8 {
    var constraints: std.ArrayList(u8) = .empty;
    var first = true;
    for (asm_stmt.outputs) |_| {
        if (!first) try constraints.append(allocator, ',');
        first = false;
        try constraints.appendSlice(allocator, "=r");
    }
    for (asm_stmt.inputs) |_| {
        if (!first) try constraints.append(allocator, ',');
        first = false;
        try constraints.append(allocator, 'r');
    }
    for (asm_stmt.clobbers) |clobber| {
        const name = try stringLiteralText(allocator, clobber);
        if (!first) try constraints.append(allocator, ',');
        first = false;
        try constraints.print(allocator, "~{{{s}}}", .{name});
    }
    return constraints.toOwnedSlice(allocator);
}

fn llvmStringLiteralBytes(allocator: std.mem.Allocator, literal: []const u8) !LlvmStringBytes {
    var escaped: std.ArrayList(u8) = .empty;
    var len: usize = 0;
    try appendLlvmStringLiteralBody(allocator, &escaped, literal, &len);
    try appendLlvmStringByte(allocator, &escaped, 0);
    len += 1;
    return .{ .escaped = try escaped.toOwnedSlice(allocator), .len = len };
}

fn stringLiteralText(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    var escaped: std.ArrayList(u8) = .empty;
    try appendLlvmStringLiteralBody(allocator, &escaped, literal, null);
    return escaped.toOwnedSlice(allocator);
}

fn appendLlvmStringLiteralBody(allocator: std.mem.Allocator, escaped: *std.ArrayList(u8), literal: []const u8, maybe_len: ?*usize) !void {
    if (literal.len < 2 or literal[0] != '"' or literal[literal.len - 1] != '"') return error.UnsupportedLlvmEmission;
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
        try appendLlvmStringByte(allocator, escaped, byte);
        if (maybe_len) |len| len.* += 1;
        i += 1;
    }
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

fn packedBitsClearMask(info: PackedBitsInfo, bit_index: usize) ?u64 {
    const bits = integerBits(info.repr) orelse return null;
    if (bits >= 64) return ~packedBitsMask(bit_index);
    return ((@as(u64, 1) << @intCast(bits)) - 1) & ~packedBitsMask(bit_index);
}

fn builtinCallReturnType(call: anytype) ?ast.TypeExpr {
    if (isPhysCall(call.callee.*) and call.type_args.len == 0 and call.args.len == 1) return simpleType(call.callee.*.span, "PAddr");
    if (isAssumeNoaliasCall(call) and call.type_args.len == 0 and call.args.len == 2) return null;
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



fn isAssumeNoaliasCall(call: anytype) bool {
    return switch (call.callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "assume_noalias_unchecked") and isIdentNamed(member.base.*, "compiler"),
        .ident => |ident| std.mem.eql(u8, ident.text, "compiler.assume_noalias_unchecked") or std.mem.eql(u8, ident.text, "assume_noalias_unchecked"),
        .grouped => |inner| switch (inner.kind) {
            .call => |inner_call| isAssumeNoaliasCall(inner_call),
            else => false,
        },
        else => false,
    };
}




fn fenceOrderingForCall(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |member| blk: {
            if (!isIdentNamed(member.base.*, "fence")) break :blk null;
            if (std.mem.eql(u8, member.name.text, "full")) break :blk "seq_cst";
            if (std.mem.eql(u8, member.name.text, "release")) break :blk "release";
            if (std.mem.eql(u8, member.name.text, "acquire")) break :blk "acquire";
            break :blk null;
        },
        .grouped => |inner| fenceOrderingForCall(inner.*),
        else => null,
    };
}

fn isPhysCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "phys"),
        .grouped => |inner| isPhysCall(inner.*),
        else => false,
    };
}

// `drop(x)` and `forget_unchecked(x)` lower identically — evaluate the operand and
// discard it (linearity is a compile-time concept). They differ only in the checker:
// `forget_unchecked` is the unsafe form legal on a linear resource.
fn isDropCall(callee: ast.Expr) bool {
    return isIdentNamed(callee, "drop") or isIdentNamed(callee, "forget_unchecked");
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

fn uncheckedBuiltinOp(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .member => |member| if (isIdentNamed(member.base.*, "unchecked"))
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
        .grouped => |inner| uncheckedBuiltinOp(inner.*),
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

fn isUninitExpr(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .uninit_literal => true,
        .grouped => |inner| isUninitExpr(inner.*),
        else => false,
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

fn orderingArg(expr: ast.Expr) ?[]const u8 {
    return atomicOrderingExpr(expr);
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


fn llvmComptimeReflectThunk(ctx: ?*anyopaque, call: ast.Expr) ?i128 {
    const self: *LlvmEmitter = @ptrCast(@alignCast(ctx orelse return null));
    return self.comptimeReflect(call);
}

const ReflectionCallKind = enum {
    size,
    repr,
    alignment,
    field_offset,
    bit_offset,
};

fn reflectionCallKind(callee: ast.Expr) ?ReflectionCallKind {
    return switch (callee.kind) {
        .ident => |ident| {
            if (std.mem.eql(u8, ident.text, "size_of") or std.mem.eql(u8, ident.text, "sizeof")) return .size;
            if (std.mem.eql(u8, ident.text, "repr_of")) return .repr;
            if (std.mem.eql(u8, ident.text, "alignof")) return .alignment;
            if (std.mem.eql(u8, ident.text, "field_offset")) return .field_offset;
            if (std.mem.eql(u8, ident.text, "bit_offset")) return .bit_offset;
            return null;
        },
        .grouped => |inner| reflectionCallKind(inner.*),
        else => null,
    };
}


fn exprAsType(expr: ast.Expr) ?ast.TypeExpr {
    return switch (expr.kind) {
        .ident => |ident| simpleType(ident.span, ident.text),
        .grouped => |inner| exprAsType(inner.*),
        else => null,
    };
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


fn isPointerWidthIntegerTypeName(name: []const u8) bool {
    return std.mem.eql(u8, name, "usize") or std.mem.eql(u8, name, "isize");
}

fn isOpaqueAddressGenericName(name: []const u8) bool {
    return std.mem.eql(u8, name, "UserPtr") or
        std.mem.eql(u8, name, "PhysPtr");
}

fn isPayloadDomainGenericName(name: []const u8) bool {
    return std.mem.eql(u8, name, "wrap") or
        std.mem.eql(u8, name, "sat") or
        std.mem.eql(u8, name, "serial") or
        std.mem.eql(u8, name, "counter") or
        std.mem.eql(u8, name, "Duration");
}

fn libraryScalarLlvmType(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "Order")) return "i8";
    if (std.mem.eql(u8, name, "Error")) return "i8";
    if (std.mem.eql(u8, name, "AmbiguousSerialOrder")) return "i8";
    if (std.mem.eql(u8, name, "AmbiguousCounterInterval")) return "i8";
    if (std.mem.eql(u8, name, "ConversionError")) return "i8";
    if (std.mem.eql(u8, name, "Overflow")) return "i8";
    return null;
}

fn isResultConstructorCall(call: anytype) ?[]const u8 {
    if (call.type_args.len != 0 or call.args.len != 1) return null;
    const name = switch (call.callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| switch (inner.kind) {
            .ident => |ident| ident.text,
            else => return null,
        },
        else => return null,
    };
    if (std.mem.eql(u8, name, "ok") or std.mem.eql(u8, name, "err")) return name;
    return null;
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

fn resultSwitchPattern(pattern: ast.Pattern) ?ResultSwitchPattern {
    return switch (pattern.kind) {
        .tag => |tag| .{ .tag = tag.text },
        .tag_bind => |tag_bind| .{ .tag = tag_bind.tag.text, .binding = tag_bind.binding },
        else => null,
    };
}

fn taggedUnionConstructorName(callee: ast.Expr) ?[]const u8 {
    return switch (callee.kind) {
        .ident => |ident| ident.text,
        .grouped => |inner| taggedUnionConstructorName(inner.*),
        else => null,
    };
}

fn taggedUnionPatternName(pattern: ast.Pattern) ?[]const u8 {
    return switch (pattern.kind) {
        .tag => |tag| tag.text,
        .tag_bind => |tag_bind| tag_bind.tag.text,
        else => null,
    };
}

fn taggedUnionBindingPattern(arm: ast.SwitchArm) ?TaggedUnionBinding {
    if (arm.patterns.len != 1) return null;
    return switch (arm.patterns[0].kind) {
        .tag_bind => |tag_bind| .{ .tag = tag_bind.tag.text, .binding = tag_bind.binding },
        else => null,
    };
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


fn isBindCall(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .call => |call| isBindCallByNode(call),
        .grouped => |inner| isBindCall(inner.*),
        else => false,
    };
}

fn isBindCallByNode(call: anytype) bool {
    return call.type_args.len == 0 and call.args.len == 2 and isIdentNamed(call.callee.*, "bind");
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

test "LLVM backend emits a backend_name alias for the override symbol" {
    const source =
        \\#[backend_name("rss_helper_x")]
        \\fn helper(x: u64) -> u64 { return x + 1; }
        \\export fn harness() -> u64 { return helper(7); }
    ;

    var reporter = @import("diagnostics.zig").Reporter.init(std.testing.allocator, "bn_llvm.mc", source);
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
    // The function keeps its source name; the override is exposed via a module-level alias.
    try std.testing.expect(std.mem.indexOf(u8, output.items, "define i64 @helper(i64 %x)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "@rss_helper_x = alias i64 (i64), ptr @helper") != null);
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
