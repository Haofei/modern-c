const std = @import("std");

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const mir = @import("mir.zig");

pub fn appendLlvm(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    var module_mir = try mir.build(allocator, module);
    defer module_mir.deinit();

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
        .struct_types = std.StringHashMap(ast.StructDecl).init(allocator),
        .fn_sigs = std.StringHashMap(FnSig).init(allocator),
        .global_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_slots = std.StringHashMap(LocalSlot).init(allocator),
        .loop_stack = std.ArrayList(LoopLabels).empty,
    };
    defer ctx.deinit();
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
    try ctx.emitIntrinsicDecls();
}

fn emitTrapDecl(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "declare void @mc_trap_IntegerOverflow() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_DivideByZero() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_InvalidShift() noreturn\n\n");
    try out.appendSlice(allocator, "declare void @mc_trap_InvalidRepresentation() noreturn\n");
    try out.appendSlice(allocator, "declare void @mc_trap_Bounds() noreturn\n\n");
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
    struct_types: std.StringHashMap(ast.StructDecl) = undefined,
    fn_sigs: std.StringHashMap(FnSig) = undefined,
    global_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_slots: std.StringHashMap(LocalSlot) = undefined,
    loop_stack: std.ArrayList(LoopLabels) = undefined,

    fn deinit(self: *LlvmEmitter) void {
        self.need_uadd.deinit();
        self.need_usub.deinit();
        self.need_umul.deinit();
        self.need_sadd.deinit();
        self.need_ssub.deinit();
        self.need_smul.deinit();
        self.struct_types.deinit();
        self.fn_sigs.deinit();
        self.global_types.deinit();
        self.local_types.deinit();
        self.local_slots.deinit();
        self.loop_stack.deinit(self.allocator);
        self.scratch.deinit();
    }

    fn collectStruct(self: *LlvmEmitter, struct_decl: ast.StructDecl) !void {
        if (struct_decl.type_params.len != 0 or struct_decl.is_move or struct_decl.abi != null) return error.UnsupportedLlvmEmission;
        for (struct_decl.fields) |field| _ = try self.llvmType(field.ty);
        try self.struct_types.put(struct_decl.name.text, struct_decl);
    }

    fn collectFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        _ = try self.llvmType(ret_ty);
        for (fn_decl.params) |param| _ = try self.llvmType(param.ty);
        try self.fn_sigs.put(fn_decl.name.text, .{ .ret = ret_ty, .params = fn_decl.params });
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
        switch (ty.kind) {
            .array => |array| {
                const items = switch (expr.kind) {
                    .array_literal => |items| items,
                    .grouped => |inner| return self.emitGlobalInitializer(inner.*, ty),
                    else => return error.UnsupportedLlvmEmission,
                };
                const len = arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
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
            .name => if (self.structDeclForType(ty)) |struct_decl| {
                const fields = switch (expr.kind) {
                    .struct_literal => |fields| fields,
                    .grouped => |inner| return self.emitGlobalInitializer(inner.*, ty),
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
            .bool_literal => |value| if (value) "1" else "0",
            .grouped => |inner| try self.emitGlobalInitializer(inner.*, ty),
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

    fn zeroInitializer(self: *LlvmEmitter, ty: ast.TypeExpr) ![]const u8 {
        return switch (ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "bool"))
                "0"
            else if (integerBits(ty) != null)
                "0"
            else if (self.structDeclForType(ty) != null)
                "zeroinitializer"
            else
                error.UnsupportedLlvmEmission,
            .pointer, .raw_many_pointer => "null",
            .array => "zeroinitializer",
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitFunction(self: *LlvmEmitter, fn_decl: ast.FnDecl, body: ast.Block) !void {
        const ret_ty = fn_decl.return_type orelse simpleType(fn_decl.name.span, "void");
        const ret_llvm = try self.llvmType(ret_ty);
        try self.out.print(self.allocator, "define {s} @{s}(", .{ ret_llvm, fn_decl.name.text });
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.out.print(self.allocator, "{s} %{s}", .{ try self.llvmType(param.ty), param.name.text });
        }
        try self.out.appendSlice(self.allocator, ") {\nentry:\n");
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
                try self.out.appendSlice(self.allocator, "  ret void\n");
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
        return switch (expr.kind) {
            .ident => |ident| try self.emitIdent(ident),
            .int_literal => |literal| try normalizedIntLiteral(self.scratch.allocator(), literal),
            .bool_literal => |value| if (value) "1" else "0",
            .grouped => |inner| self.emitExpr(inner.*, expected_ty),
            .call => |call| try self.emitCall(call, expected_ty),
            .array_literal => |items| try self.emitArrayLiteralValue(expected_ty, items),
            .struct_literal => |fields| try self.emitStructLiteralValue(expected_ty, fields),
            .binary => |node| try self.emitBinary(node, expected_ty),
            .unary => |node| try self.emitUnary(node, expected_ty),
            .cast => |node| try self.emitCast(node.value.*, node.ty.*),
            .address_of => |inner| try self.emitAddressOf(inner.*),
            .deref => |inner| try self.emitDeref(inner.*, expected_ty),
            .index => |node| try self.emitIndexLoad(node),
            .slice => |node| try self.emitSlice(node),
            .member => |node| try self.emitMemberLoad(node),
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitIdent(self: *LlvmEmitter, ident: ast.Ident) ![]const u8 {
        if (self.local_slots.get(ident.text)) |slot| {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(slot.ty), slot.ptr });
            return result;
        }
        if (self.global_types.get(ident.text)) |ty| {
            const result = try self.nextTemp();
            try self.out.print(self.allocator, "  {s} = load {s}, ptr @{s}\n", .{ result, try self.llvmType(ty), ident.text });
            return result;
        }
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
                .@"return" => |maybe_expr| {
                    if (ret_ty.kind == .name and std.mem.eql(u8, ret_ty.kind.name.text, "void")) {
                        try self.out.appendSlice(self.allocator, "  ret void\n");
                    } else {
                        const expr = maybe_expr orelse return error.UnsupportedLlvmEmission;
                        const value = try self.emitExpr(expr, ret_ty);
                        try self.out.print(self.allocator, "  ret {s} {s}\n", .{ try self.llvmType(ret_ty), value });
                    }
                    return true;
                },
                .@"switch" => |node| {
                    if (try self.emitScalarSwitch(node, ret_ty)) return true;
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
                else => return error.UnsupportedLlvmEmission,
            }
        }
        return false;
    }

    fn emitLocalDecl(self: *LlvmEmitter, local: ast.LocalDecl) !void {
        if (local.names.len != 1) return error.UnsupportedLlvmEmission;
        const ty = local.ty orelse return error.UnsupportedLlvmEmission;
        const init = local.init orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(ty);
        const name = local.names[0].text;
        const ptr = try std.fmt.allocPrint(self.scratch.allocator(), "%{s}.addr", .{name});
        try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, llvm_ty });
        try self.local_types.put(name, ty);
        try self.local_slots.put(name, .{ .ty = ty, .ptr = ptr });
        if (ty.kind == .array) {
            const items = switch (init.kind) {
                .array_literal => |items| items,
                else => return error.UnsupportedLlvmEmission,
            };
            try self.emitArrayLiteralStores(ptr, ty, items);
            return;
        }
        if (self.structDeclForType(ty)) |_| {
            const fields = switch (init.kind) {
                .struct_literal => |fields| fields,
                else => return error.UnsupportedLlvmEmission,
            };
            try self.emitStructLiteralStores(ptr, ty, fields);
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
        if (iterable_ty.kind == .slice) {
            const ptr = try self.nextTemp();
            const value = try self.emitExpr(iterable, iterable_ty);
            try self.out.print(self.allocator, "  {s} = alloca {s}\n", .{ ptr, try self.llvmType(iterable_ty) });
            try self.out.print(self.allocator, "  store {s} {s}, ptr {s}\n", .{ try self.llvmType(iterable_ty), value, ptr });
            iterable_slot = .{ .ty = iterable_ty, .ptr = ptr };
            iterable_ptr = ptr;
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
            .array => |array| try std.fmt.allocPrint(self.scratch.allocator(), "{d}", .{arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission}),
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
                const base_ptr = try self.arrayBasePointer(iterable);
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

    fn emitScalarSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !bool {
        const subject_ty = self.exprType(node.subject) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(subject_ty, "bool") and integerBits(subject_ty) == null) return error.UnsupportedLlvmEmission;

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
        if (wildcard_index == null and !typeNameEql(subject_ty, "bool")) all_terminated = false;
        if (all_terminated) {
            if (wildcard_index == null) {
                try self.out.print(self.allocator, "{s}:\n  call void @mc_trap_InvalidRepresentation()\n  unreachable\n", .{end_label});
            }
            return true;
        }
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn switchPatternValue(self: *LlvmEmitter, pattern: ast.Pattern, subject_ty: ast.TypeExpr) ![]const u8 {
        const expr = switch (pattern.kind) {
            .literal => |expr| expr,
            else => return error.UnsupportedLlvmEmission,
        };
        if (typeNameEql(subject_ty, "bool")) {
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
                const value = try self.emitExpr(expr, ret_ty);
                try self.out.print(self.allocator, "  ret {s} {s}\n", .{ try self.llvmType(ret_ty), value });
                break :blk true;
            },
        };
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
        const field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitMemberAddress(node);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(field.ty), ptr });
        return result;
    }

    fn emitMemberAddress(self: *LlvmEmitter, node: anytype) anyerror![]const u8 {
        const base_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const struct_decl = self.structDeclForType(base_ty) orelse return error.UnsupportedLlvmEmission;
        const index = structFieldIndex(struct_decl, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = try self.aggregateBasePointer(node.base.*);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i32 {d}\n", .{ result, try self.llvmType(base_ty), base_ptr, index });
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
        const index = try self.emitExpr(node.index.*, simpleType((node.index.*).span, "usize"));
        return switch (base_ty.kind) {
            .array => |array| blk: {
                const len = arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
                const base_ptr = try self.arrayBasePointer(node.base.*);
                try self.emitBoundsCheck(index, len);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i64 {s}\n", .{ result, try self.llvmType(base_ty), base_ptr, index });
                break :blk result;
            },
            .slice => |slice| blk: {
                const base = try self.emitExpr(node.base.*, base_ty);
                const base_llvm = try self.llvmType(base_ty);
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
            else => error.UnsupportedLlvmEmission,
        };
    }

    fn emitBoundsCheck(self: *LlvmEmitter, index: []const u8, len: u64) !void {
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {d}\n", .{ ok, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_Bounds()\n  unreachable\n{s}:\n", .{ ok, cont, trap, trap, cont });
    }

    fn emitDynamicBoundsCheck(self: *LlvmEmitter, index: []const u8, len: []const u8) !void {
        const ok = try self.nextTemp();
        const trap = try self.nextLabel("trap_bounds");
        const cont = try self.nextLabel("bounds_ok");
        try self.out.print(self.allocator, "  {s} = icmp ult i64 {s}, {s}\n", .{ ok, index, len });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_Bounds()\n  unreachable\n{s}:\n", .{ ok, cont, trap, trap, cont });
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
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_Bounds()\n  unreachable\n{s}:\n", .{ ok, cont, trap, trap, cont });
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
                const len = arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
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
        const len = arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
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
        const callee = switch (call.callee.kind) {
            .ident => |ident| ident.text,
            else => return error.UnsupportedLlvmEmission,
        };
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
        try self.out.appendSlice(self.allocator, ")\n");
        return result;
    }

    fn emitBinary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        if (binaryIsComparison(node.op)) return self.emitComparison(node, ty);
        const llvm_ty = try self.llvmType(ty);
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

    fn emitUnary(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr) ![]const u8 {
        return switch (node.op) {
            .logical_not => blk: {
                const value = try self.emitExpr(node.expr.*, ty);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = xor i1 {s}, true\n", .{ result, value });
                break :blk result;
            },
            .bit_not => blk: {
                if (integerBits(ty) == null) return error.UnsupportedLlvmEmission;
                const value = try self.emitExpr(node.expr.*, ty);
                const result = try self.nextTemp();
                try self.out.print(self.allocator, "  {s} = xor {s} {s}, -1\n", .{ result, try self.llvmType(ty), value });
                break :blk result;
            },
            else => error.UnsupportedLlvmEmission,
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
        if (integerBits(source_ty) != null and integerBits(target_ty) != null) {
            return try self.castIntegerValue(value, source_ty, target_ty);
        }
        return error.UnsupportedLlvmEmission;
    }

    fn castIntegerValue(self: *LlvmEmitter, value: []const u8, source_ty: ast.TypeExpr, target_ty: ast.TypeExpr) ![]const u8 {
        const source_bits = integerBits(source_ty) orelse return error.UnsupportedLlvmEmission;
        const target_bits = integerBits(target_ty) orelse return error.UnsupportedLlvmEmission;
        if (source_bits == target_bits) return value;

        const result = try self.nextTemp();
        const source_llvm = try self.llvmType(source_ty);
        const target_llvm = try self.llvmType(target_ty);
        if (source_bits < target_bits) {
            const op: []const u8 = if (isSignedInteger(source_ty)) "sext" else "zext";
            try self.out.print(self.allocator, "  {s} = {s} {s} {s} to {s}\n", .{ result, op, source_llvm, value, target_llvm });
        } else {
            try self.out.print(self.allocator, "  {s} = trunc {s} {s} to {s}\n", .{ result, source_llvm, value, target_llvm });
        }
        return result;
    }

    fn emitComparison(self: *LlvmEmitter, node: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        if (!typeNameEql(expected_ty, "bool")) return error.UnsupportedLlvmEmission;
        const operand_ty = self.exprType(node.left.*) orelse self.exprType(node.right.*) orelse return error.UnsupportedLlvmEmission;
        const llvm_ty = try self.llvmType(operand_ty);
        const pred = comparisonPredicate(node.op, isSignedInteger(operand_ty)) orelse return error.UnsupportedLlvmEmission;
        const left = try self.emitExpr(node.left.*, operand_ty);
        const right = try self.emitExpr(node.right.*, operand_ty);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {s}\n", .{ result, pred, llvm_ty, left, right });
        return result;
    }

    fn emitCheckedArithmetic(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const bits = integerBits(ty) orelse return error.UnsupportedLlvmEmission;
        const signed = isSignedInteger(ty);
        const intrinsic = try self.overflowIntrinsic(node.op, signed, bits);
        const pair_ty = try std.fmt.allocPrint(self.scratch.allocator(), "{{ {s}, i1 }}", .{llvm_ty});
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        const pair = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}({s} {s}, {s} {s})\n", .{ pair, pair_ty, intrinsic, llvm_ty, left, llvm_ty, right });
        const value = try self.nextTemp();
        const overflow = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 0\n", .{ value, pair_ty, pair });
        try self.out.print(self.allocator, "  {s} = extractvalue {s} {s}, 1\n", .{ overflow, pair_ty, pair });
        const cont = try self.nextLabel("cont");
        const trap = try self.nextLabel("trap_overflow");
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow()\n  unreachable\n{s}:\n", .{ overflow, trap, cont, trap, cont });
        return value;
    }

    fn emitCheckedDivRem(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        if (integerBits(ty) == null) return error.UnsupportedLlvmEmission;
        const left = try self.emitExpr(node.left.*, ty);
        const right = try self.emitExpr(node.right.*, ty);
        const zero_cmp = try self.nextTemp();
        const zero_trap = try self.nextLabel("trap_div_zero");
        const nonzero = try self.nextLabel("div_nonzero");
        try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, 0\n", .{ zero_cmp, llvm_ty, right });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_DivideByZero()\n  unreachable\n{s}:\n", .{ zero_cmp, zero_trap, nonzero, zero_trap, nonzero });

        if (isSignedInteger(ty)) {
            const min_literal = signedMinLiteral(ty) orelse return error.UnsupportedLlvmEmission;
            const min_cmp = try self.nextTemp();
            const neg_one_cmp = try self.nextTemp();
            const overflow_cmp = try self.nextTemp();
            const overflow_trap = try self.nextLabel("trap_div_overflow");
            const safe = try self.nextLabel("div_safe");
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, {s}\n", .{ min_cmp, llvm_ty, left, min_literal });
            try self.out.print(self.allocator, "  {s} = icmp eq {s} {s}, -1\n", .{ neg_one_cmp, llvm_ty, right });
            try self.out.print(self.allocator, "  {s} = and i1 {s}, {s}\n", .{ overflow_cmp, min_cmp, neg_one_cmp });
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow()\n  unreachable\n{s}:\n", .{ overflow_cmp, overflow_trap, safe, overflow_trap, safe });
        }

        const op: []const u8 = switch (node.op) {
            .div => if (isSignedInteger(ty)) "sdiv" else "udiv",
            .mod => if (isSignedInteger(ty)) "srem" else "urem",
            else => unreachable,
        };
        return try self.emitPlainBinaryValues(op, llvm_ty, left, right);
    }

    fn emitCheckedShift(self: *LlvmEmitter, node: anytype, ty: ast.TypeExpr, llvm_ty: []const u8) ![]const u8 {
        const shifted_bits = integerBits(ty) orelse return error.UnsupportedLlvmEmission;
        const amount_ty = self.exprType(node.right.*) orelse ty;
        const amount_llvm = try self.llvmType(amount_ty);
        const left = try self.emitExpr(node.left.*, ty);
        const raw_amount = try self.emitExpr(node.right.*, amount_ty);

        try self.emitShiftCountCheck(raw_amount, amount_ty, amount_llvm, shifted_bits);
        const amount = try self.castIntegerValue(raw_amount, amount_ty, ty);

        const op: []const u8 = switch (node.op) {
            .shl => "shl",
            .shr => if (isSignedInteger(ty)) "ashr" else "lshr",
            else => unreachable,
        };
        const result = try self.emitPlainBinaryValues(op, llvm_ty, left, amount);
        if (node.op == .shl) {
            try self.emitLeftShiftOverflowCheck(result, left, amount, ty, llvm_ty);
        }
        return result;
    }

    fn emitShiftCountCheck(self: *LlvmEmitter, amount: []const u8, amount_ty: ast.TypeExpr, amount_llvm: []const u8, shifted_bits: u16) !void {
        if (integerBits(amount_ty) == null) return error.UnsupportedLlvmEmission;
        if (isSignedInteger(amount_ty)) {
            const negative = try self.nextTemp();
            const neg_trap = try self.nextLabel("trap_shift_neg");
            const nonnegative = try self.nextLabel("shift_nonnegative");
            try self.out.print(self.allocator, "  {s} = icmp slt {s} {s}, 0\n", .{ negative, amount_llvm, amount });
            try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_InvalidShift()\n  unreachable\n{s}:\n", .{ negative, neg_trap, nonnegative, neg_trap, nonnegative });
        }

        const too_large = try self.nextTemp();
        const invalid = try self.nextLabel("trap_shift_count");
        const valid = try self.nextLabel("shift_count_ok");
        const pred: []const u8 = if (isSignedInteger(amount_ty)) "sge" else "uge";
        try self.out.print(self.allocator, "  {s} = icmp {s} {s} {s}, {d}\n", .{ too_large, pred, amount_llvm, amount, shifted_bits });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_InvalidShift()\n  unreachable\n{s}:\n", .{ too_large, invalid, valid, invalid, valid });
    }

    fn emitLeftShiftOverflowCheck(self: *LlvmEmitter, result: []const u8, left: []const u8, amount: []const u8, ty: ast.TypeExpr, llvm_ty: []const u8) !void {
        const reverse_op: []const u8 = if (isSignedInteger(ty)) "ashr" else "lshr";
        const reversed = try self.emitPlainBinaryValues(reverse_op, llvm_ty, result, amount);
        const overflow = try self.nextTemp();
        const overflow_trap = try self.nextLabel("trap_shift_overflow");
        const ok = try self.nextLabel("shift_overflow_ok");
        try self.out.print(self.allocator, "  {s} = icmp ne {s} {s}, {s}\n", .{ overflow, llvm_ty, reversed, left });
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n{s}:\n  call void @mc_trap_IntegerOverflow()\n  unreachable\n{s}:\n", .{ overflow, overflow_trap, ok, overflow_trap, ok });
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

    fn llvmType(self: *LlvmEmitter, ty: ast.TypeExpr) anyerror![]const u8 {
        return switch (ty.kind) {
            .name => |name| if (std.mem.eql(u8, name.text, "void"))
                "void"
            else if (std.mem.eql(u8, name.text, "bool"))
                "i1"
            else if (integerBits(ty)) |bits|
                try std.fmt.allocPrint(self.scratch.allocator(), "i{d}", .{bits})
            else if (self.struct_types.get(name.text)) |struct_decl|
                try self.structLlvmType(struct_decl)
            else
                error.UnsupportedLlvmEmission,
            .pointer, .raw_many_pointer => "ptr",
            .array => |node| try std.fmt.allocPrint(self.scratch.allocator(), "[{d} x {s}]", .{ arrayLenValue(node.len) orelse return error.UnsupportedLlvmEmission, try self.llvmType(node.child.*) }),
            .slice => "{ ptr, i64 }",
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
            .ident => |ident| self.local_types.get(ident.text) orelse self.global_types.get(ident.text),
            .bool_literal => simpleType(expr.span, "bool"),
            .unary => |node| if (node.op == .logical_not) simpleType(expr.span, "bool") else self.exprType(node.expr.*),
            .int_literal => null,
            .grouped => |inner| self.exprType(inner.*),
            .call => |call| self.callReturnType(call),
            .cast => |node| node.ty.*,
            .address_of => |inner| if (self.exprType(inner.*)) |ty| self.pointerTypeFor(ty) catch null else null,
            .deref => |inner| self.derefPointeeType(inner.*),
            .index => |node| self.indexElementType(node.base.*),
            .slice => |node| if (self.exprType(node.base.*)) |base_ty| self.sliceTypeForBase(base_ty, node.base.*.span) else null,
            .member => |node| if (self.exprType(node.base.*)) |base_ty| blk: {
                if (base_ty.kind == .slice and std.mem.eql(u8, node.name.text, "len")) break :blk simpleType(expr.span, "usize");
                if (self.memberField(node.base.*, node.name.text)) |field| break :blk field.ty;
                break :blk null;
            } else null,
            .binary => |node| if (binaryIsComparison(node.op)) simpleType(expr.span, "bool") else self.exprType(node.left.*),
            else => null,
        };
    }

    fn derefPointeeType(self: *LlvmEmitter, expr: ast.Expr) ?ast.TypeExpr {
        const ty = self.exprType(expr) orelse return null;
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

    fn indexElementType(self: *LlvmEmitter, base: ast.Expr) ?ast.TypeExpr {
        const ty = self.exprType(base) orelse return null;
        return switch (ty.kind) {
            .array => |array| array.child.*,
            .slice => |slice| slice.child.*,
            else => null,
        };
    }

    fn sliceTypeForBase(self: *LlvmEmitter, ty: ast.TypeExpr, span: ast.Span) ?ast.TypeExpr {
        _ = self;
        return switch (ty.kind) {
            .slice => ty,
            .array => |node| .{ .span = span, .kind = .{ .slice = .{ .mutability = .mut, .child = node.child } } },
            else => null,
        };
    }

    fn structDeclForType(self: *LlvmEmitter, ty: ast.TypeExpr) ?ast.StructDecl {
        return switch (ty.kind) {
            .name => |name| self.struct_types.get(name.text),
            else => null,
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
        const struct_decl = self.structDeclForType(base_ty) orelse return null;
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

    fn callReturnType(self: *LlvmEmitter, call: anytype) ?ast.TypeExpr {
        const callee = switch (call.callee.kind) {
            .ident => |ident| ident.text,
            else => return null,
        };
        return if (self.fn_sigs.get(callee)) |sig| sig.ret else null;
    }

    fn isAggregateType(self: *LlvmEmitter, ty: ast.TypeExpr) bool {
        return switch (ty.kind) {
            .array => true,
            .slice => true,
            .name => self.structDeclForType(ty) != null,
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
};

const ArgValue = struct {
    ty: ast.TypeExpr,
    value: []const u8,
};

const LoopLabels = struct {
    break_label: []const u8,
    continue_label: []const u8,
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

fn typeNameEql(ty: ast.TypeExpr, expected: []const u8) bool {
    return switch (ty.kind) {
        .name => |name| std.mem.eql(u8, name.text, expected),
        else => false,
    };
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

fn normalizedIntLiteral(allocator: std.mem.Allocator, literal: []const u8) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (ch != '_') try cleaned.append(allocator, ch);
    }
    const text = try cleaned.toOwnedSlice(allocator);
    const value = std.fmt.parseInt(i128, text, 0) catch return text;
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn arrayLenValue(expr: ast.Expr) ?u64 {
    return switch (expr.kind) {
        .int_literal => |literal| parseU64Literal(literal),
        .grouped => |inner| arrayLenValue(inner.*),
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
