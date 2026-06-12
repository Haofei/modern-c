const std = @import("std");

const ast = @import("ast.zig");
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
        .global_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_types = std.StringHashMap(ast.TypeExpr).init(allocator),
        .local_slots = std.StringHashMap(LocalSlot).init(allocator),
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
    global_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_types: std.StringHashMap(ast.TypeExpr) = undefined,
    local_slots: std.StringHashMap(LocalSlot) = undefined,

    fn deinit(self: *LlvmEmitter) void {
        self.need_uadd.deinit();
        self.need_usub.deinit();
        self.need_umul.deinit();
        self.need_sadd.deinit();
        self.need_ssub.deinit();
        self.need_smul.deinit();
        self.struct_types.deinit();
        self.global_types.deinit();
        self.local_types.deinit();
        self.local_slots.deinit();
        self.scratch.deinit();
    }

    fn collectStruct(self: *LlvmEmitter, struct_decl: ast.StructDecl) !void {
        if (struct_decl.type_params.len != 0 or struct_decl.is_move or struct_decl.abi != null) return error.UnsupportedLlvmEmission;
        for (struct_decl.fields) |field| _ = try self.llvmType(field.ty);
        try self.struct_types.put(struct_decl.name.text, struct_decl);
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
        for (fn_decl.params) |param| try self.local_types.put(param.name.text, param.ty);

        if (!try self.emitBlock(body, ret_ty)) return error.UnsupportedLlvmEmission;
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
            .binary => |node| try self.emitBinary(node, expected_ty),
            .unary => |node| try self.emitUnary(node, expected_ty),
            .address_of => |inner| try self.emitAddressOf(inner.*),
            .deref => |inner| try self.emitDeref(inner.*, expected_ty),
            .index => |node| try self.emitIndexLoad(node),
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
                    if (try self.emitWhile(node, ret_ty)) return true;
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
                    if (try self.emitBoolSwitch(node, ret_ty)) return true;
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
        const body_terminated = try self.emitBlock(loop.body, ret_ty);
        if (!body_terminated) try self.out.print(self.allocator, "  br label %{s}\n", .{cond_label});
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
    }

    fn emitBoolSwitch(self: *LlvmEmitter, node: ast.Switch, ret_ty: ast.TypeExpr) !bool {
        const subject_ty = self.exprType(node.subject) orelse return error.UnsupportedLlvmEmission;
        if (!typeNameEql(subject_ty, "bool")) return error.UnsupportedLlvmEmission;

        const true_arm = findBoolSwitchArm(node.arms, true);
        const false_arm = findBoolSwitchArm(node.arms, false) orelse findWildcardSwitchArm(node.arms);
        if (true_arm == null or false_arm == null) return error.UnsupportedLlvmEmission;

        const subject = try self.emitExpr(node.subject, subject_ty);
        const true_label = try self.nextLabel("switch_true");
        const false_label = try self.nextLabel("switch_false");
        const end_label = try self.nextLabel("switch_end");
        try self.out.print(self.allocator, "  br i1 {s}, label %{s}, label %{s}\n", .{ subject, true_label, false_label });
        try self.out.print(self.allocator, "{s}:\n", .{true_label});
        const true_terminated = try self.emitSwitchBody(true_arm.?.body, ret_ty);
        if (!true_terminated) try self.out.print(self.allocator, "  br label %{s}\n", .{end_label});
        try self.out.print(self.allocator, "{s}:\n", .{false_label});
        const false_terminated = try self.emitSwitchBody(false_arm.?.body, ret_ty);
        if (!false_terminated) try self.out.print(self.allocator, "  br label %{s}\n", .{end_label});
        if (true_terminated and false_terminated) return true;
        try self.out.print(self.allocator, "{s}:\n", .{end_label});
        return false;
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
        const field = self.memberField(node.base.*, node.name.text) orelse return error.UnsupportedLlvmEmission;
        const ptr = try self.emitMemberAddress(node);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = load {s}, ptr {s}\n", .{ result, try self.llvmType(field.ty), ptr });
        return result;
    }

    fn emitMemberAddress(self: *LlvmEmitter, node: anytype) ![]const u8 {
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

    fn emitIndexAddress(self: *LlvmEmitter, node: anytype) ![]const u8 {
        const array_ty = self.exprType(node.base.*) orelse return error.UnsupportedLlvmEmission;
        const array = switch (array_ty.kind) {
            .array => |array| array,
            else => return error.UnsupportedLlvmEmission,
        };
        const len = arrayLenValue(array.len) orelse return error.UnsupportedLlvmEmission;
        const base_ptr = try self.arrayBasePointer(node.base.*);
        const index = try self.emitExpr(node.index.*, simpleType((node.index.*).span, "usize"));
        try self.emitBoundsCheck(index, len);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = getelementptr inbounds {s}, ptr {s}, i64 0, i64 {s}\n", .{ result, try self.llvmType(array_ty), base_ptr, index });
        return result;
    }

    fn arrayBasePointer(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return self.aggregateBasePointer(expr);
    }

    fn aggregateBasePointer(self: *LlvmEmitter, expr: ast.Expr) ![]const u8 {
        return switch (expr.kind) {
            .ident => |ident| blk: {
                if (self.local_slots.get(ident.text)) |slot| break :blk slot.ptr;
                if (self.global_types.contains(ident.text)) break :blk try std.fmt.allocPrint(self.scratch.allocator(), "@{s}", .{ident.text});
                break :blk error.UnsupportedLlvmEmission;
            },
            .grouped => |inner| self.aggregateBasePointer(inner.*),
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

    fn emitCall(self: *LlvmEmitter, call: anytype, expected_ty: ast.TypeExpr) ![]const u8 {
        const callee = switch (call.callee.kind) {
            .ident => |ident| ident.text,
            else => return error.UnsupportedLlvmEmission,
        };
        const ret_ty = try self.llvmType(expected_ty);
        const result = try self.nextTemp();
        try self.out.print(self.allocator, "  {s} = call {s} @{s}(", .{ result, ret_ty, callee });
        for (call.args, 0..) |arg, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            const arg_ty = expected_tyForCallArg(self.mir_module, callee, i) orelse expected_ty;
            try self.out.print(self.allocator, "{s} {s}", .{ try self.llvmType(arg_ty), try self.emitExpr(arg, arg_ty) });
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
            else => error.UnsupportedLlvmEmission,
        };
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
            .bool_literal, .unary => simpleType(expr.span, "bool"),
            .int_literal => null,
            .grouped => |inner| self.exprType(inner.*),
            .address_of => |inner| if (self.exprType(inner.*)) |ty| self.pointerTypeFor(ty) catch null else null,
            .deref => |inner| self.derefPointeeType(inner.*),
            .index => |node| self.indexElementType(node.base.*),
            .member => |node| if (self.memberField(node.base.*, node.name.text)) |field| field.ty else null,
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
};

const LocalSlot = struct {
    ty: ast.TypeExpr,
    ptr: []const u8,
};

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

fn expected_tyForCallArg(module_mir: mir.Module, callee: []const u8, index: usize) ?ast.TypeExpr {
    _ = module_mir;
    _ = callee;
    _ = index;
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
    var out: std.ArrayList(u8) = .empty;
    for (literal) |ch| {
        if (ch != '_') try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
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
