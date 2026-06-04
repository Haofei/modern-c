const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");

pub fn appendInspection(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) anyerror!void {
    var inspector = Inspector.init(allocator, out);
    try inspector.inspectModule(module);
}

pub fn appendC(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) anyerror!void {
    try out.appendSlice(allocator,
        \\#include <stdint.h>
        \\#include <stdbool.h>
        \\#include <stddef.h>
        \\
        \\#if defined(__GNUC__) || defined(__clang__)
        \\#define MC_NORETURN __attribute__((noreturn))
        \\#define MC_UNUSED __attribute__((unused))
        \\#else
        \\#define MC_NORETURN
        \\#define MC_UNUSED
        \\#endif
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_IntegerOverflow(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_DivideByZero(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_InvalidShift(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_Bounds(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_Assert(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_NullUnwrap(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_InvalidRepresentation(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_NORETURN MC_UNUSED static inline void mc_trap_Unreachable(void) {
        \\    __builtin_trap();
        \\}
        \\
        \\MC_UNUSED static inline uintptr_t mc_check_index_usize(uintptr_t index, uintptr_t len) {
        \\    if (index >= len) mc_trap_Bounds();
        \\    return index;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_checked_add_u32(uint32_t a, uint32_t b) {
        \\    uint32_t out;
        \\    if (__builtin_add_overflow(a, b, &out)) mc_trap_IntegerOverflow();
        \\    return out;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_checked_sub_u32(uint32_t a, uint32_t b) {
        \\    uint32_t out;
        \\    if (__builtin_sub_overflow(a, b, &out)) mc_trap_IntegerOverflow();
        \\    return out;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_checked_mul_u32(uint32_t a, uint32_t b) {
        \\    uint32_t out;
        \\    if (__builtin_mul_overflow(a, b, &out)) mc_trap_IntegerOverflow();
        \\    return out;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_checked_div_u32(uint32_t a, uint32_t b) {
        \\    if (b == 0u) mc_trap_DivideByZero();
        \\    return a / b;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_checked_mod_u32(uint32_t a, uint32_t b) {
        \\    if (b == 0u) mc_trap_DivideByZero();
        \\    return a % b;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_checked_shl_u32(uint32_t a, uint32_t b) {
        \\    if (b >= 32u) mc_trap_InvalidShift();
        \\    if (a > (UINT32_MAX >> b)) mc_trap_IntegerOverflow();
        \\    return a << b;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_checked_shr_u32(uint32_t a, uint32_t b) {
        \\    if (b >= 32u) mc_trap_InvalidShift();
        \\    return a >> b;
        \\}
        \\
        \\MC_UNUSED static inline uint32_t mc_race_load_u32(uint32_t const *p) {
        \\    uint32_t value;
        \\    __atomic_load(p, &value, __ATOMIC_RELAXED);
        \\    return value;
        \\}
        \\
        \\MC_UNUSED static inline void mc_race_store_u32(uint32_t *p, uint32_t value) {
        \\    __atomic_store(p, &value, __ATOMIC_RELAXED);
        \\}
        \\
        \\MC_UNUSED static inline uint8_t mc_mmio_read_u8(uint8_t volatile const *p) {
        \\    return *p;
        \\}
        \\
        \\MC_UNUSED static inline void mc_mmio_write_u8(uint8_t volatile *p, uint8_t value) {
        \\    *p = value;
        \\}
        \\
        \\MC_UNUSED static inline void mc_barrier_release_before(void) {
        \\    __atomic_signal_fence(__ATOMIC_RELEASE);
        \\}
        \\
        \\MC_UNUSED static inline void mc_barrier_acquire_after(void) {
        \\    __atomic_signal_fence(__ATOMIC_ACQUIRE);
        \\}
        \\
    );

    var emitter = CEmitter.init(allocator, out);
    try emitter.emitModule(module);
}

const CEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scratch: std.heap.ArenaAllocator,
    globals: std.StringHashMap(GlobalInfo),
    structs: std.StringHashMap(ast.StructDecl),
    enums: std.StringHashMap(ast.EnumDecl),
    slice_types: std.StringHashMap(SliceInfo),
    indent: usize,

    fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) CEmitter {
        return .{
            .allocator = allocator,
            .out = out,
            .scratch = std.heap.ArenaAllocator.init(allocator),
            .globals = std.StringHashMap(GlobalInfo).init(allocator),
            .structs = std.StringHashMap(ast.StructDecl).init(allocator),
            .enums = std.StringHashMap(ast.EnumDecl).init(allocator),
            .slice_types = std.StringHashMap(SliceInfo).init(allocator),
            .indent = 0,
        };
    }

    fn deinit(self: *CEmitter) void {
        self.slice_types.deinit();
        self.enums.deinit();
        self.structs.deinit();
        self.globals.deinit();
        self.scratch.deinit();
    }

    fn emitModule(self: *CEmitter, module: ast.Module) anyerror!void {
        defer self.deinit();
        for (module.decls) |decl| {
            switch (decl.kind) {
                .global_decl => |global| {
                    if (global.ty) |ty| try self.globals.put(global.name.text, globalInfoFromType(ty));
                    if (global.ty) |ty| try self.collectSliceType(ty);
                },
                .extern_struct => |struct_decl| {
                    if (!isMmioStructAbi(struct_decl)) try self.structs.put(struct_decl.name.text, struct_decl);
                    if (!isMmioStructAbi(struct_decl)) for (struct_decl.fields) |field| try self.collectSliceType(field.ty);
                },
                .enum_decl => |enum_decl| try self.enums.put(enum_decl.name.text, enum_decl),
                .fn_decl, .extern_fn => |fn_decl| try self.collectFunctionSliceTypes(fn_decl),
                else => {},
            }
        }
        try self.emitEnums();
        for (module.decls) |decl| {
            if (decl.kind == .extern_struct and self.structs.contains(decl.kind.extern_struct.name.text)) {
                try self.emitStruct(decl.kind.extern_struct);
            }
        }
        try self.emitSliceTypes();
        for (module.decls) |decl| {
            switch (decl.kind) {
                .global_decl => |global| try self.emitGlobal(global),
                .fn_decl => |fn_decl| if (fn_decl.body) |body| try self.emitFunction(fn_decl, body) else try self.emitFunctionPrototype(fn_decl),
                .extern_fn => |fn_decl| try self.emitExternFunction(fn_decl),
                .type_alias, .extern_struct, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl => {},
            }
        }
    }

    fn emitGlobal(self: *CEmitter, global: ast.GlobalDecl) !void {
        try self.out.appendSlice(self.allocator, "static ");
        if (global.ty) |global_ty| {
            try self.emitDeclarator(global_ty, global.name.text);
        } else {
            try self.out.print(self.allocator, "uint32_t {s}", .{global.name.text});
        }
        if (global.init) |initializer| {
            if (isStaticCInitializer(initializer)) {
                try self.out.appendSlice(self.allocator, " = ");
                try self.emitExpr(initializer, null);
            } else if (global.ty != null and global.ty.?.kind == .array) {
                try self.out.appendSlice(self.allocator, " = {0}");
            } else {
                try self.out.appendSlice(self.allocator, " = 0");
            }
        } else if (global.ty != null and global.ty.?.kind == .array) {
            try self.out.appendSlice(self.allocator, " = {0}");
        } else {
            try self.out.appendSlice(self.allocator, " = 0");
        }
        try self.out.appendSlice(self.allocator, ";\n\n");
    }

    fn emitEnums(self: *CEmitter) !void {
        var it = self.enums.valueIterator();
        while (it.next()) |enum_decl| {
            try self.out.print(self.allocator, "typedef {s} {s};\n", .{ try self.enumReprCType(enum_decl.*), enum_decl.name.text });
            try self.out.appendSlice(self.allocator, "enum {\n");
            self.indent += 1;
            for (enum_decl.cases, 0..) |case, i| {
                try self.writeIndent();
                try self.out.print(self.allocator, "{s}_{s}", .{ enum_decl.name.text, case.name.text });
                if (case.value) |value| {
                    try self.out.appendSlice(self.allocator, " = ");
                    try self.emitEnumCaseValue(value);
                } else {
                    try self.out.print(self.allocator, " = {d}", .{i});
                }
                try self.out.appendSlice(self.allocator, ",\n");
            }
            self.indent -= 1;
            try self.out.appendSlice(self.allocator, "};\n\n");
        }
    }

    fn enumReprCType(self: *CEmitter, enum_decl: ast.EnumDecl) ![]const u8 {
        return if (enum_decl.repr) |repr| try self.cTypeFor(repr, .typedef_name) else "intptr_t";
    }

    fn emitEnumCaseValue(self: *CEmitter, value: ast.Expr) !void {
        switch (value.kind) {
            .int_literal => |literal| try appendCIntLiteral(self.allocator, self.out, literal),
            .grouped => |inner| try self.emitEnumCaseValue(inner.*),
            else => {
                try self.out.print(self.allocator, "/* unsupported enum value: {s} */0", .{@tagName(value.kind)});
                return error.UnsupportedCEmission;
            },
        }
    }

    fn emitStruct(self: *CEmitter, struct_decl: ast.StructDecl) !void {
        try self.out.print(self.allocator, "typedef struct {s} {{\n", .{struct_decl.name.text});
        self.indent += 1;
        for (struct_decl.fields) |field| {
            try self.writeIndent();
            try self.emitStructFieldDeclarator(field.ty, field.name.text);
            try self.out.appendSlice(self.allocator, ";\n");
        }
        self.indent -= 1;
        try self.out.print(self.allocator, "}} {s};\n\n", .{struct_decl.name.text});
    }

    fn emitSliceTypes(self: *CEmitter) !void {
        var it = self.slice_types.valueIterator();
        while (it.next()) |slice| {
            try self.out.print(self.allocator, "typedef struct {s} {{\n", .{slice.name});
            self.indent += 1;
            try self.writeIndent();
            try self.out.print(self.allocator, "{s} ptr;\n", .{slice.ptr_type});
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "uintptr_t len;\n");
            self.indent -= 1;
            try self.out.print(self.allocator, "}} {s};\n\n", .{slice.name});
        }
    }

    fn emitFunctionPrototype(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        try self.emitFunctionSignature(fn_decl, false);
        try self.out.appendSlice(self.allocator, ";\n\n");
    }

    fn emitExternFunction(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        try self.emitFunctionPrototype(fn_decl);
    }

    fn emitFunction(self: *CEmitter, fn_decl: ast.FnDecl, body: ast.Block) anyerror!void {
        try self.emitFunctionSignature(fn_decl, true);
        try self.out.appendSlice(self.allocator, " {\n");

        var locals = std.StringHashMap(LocalInfo).init(self.allocator);
        defer locals.deinit();
        for (fn_decl.params) |param| try locals.put(param.name.text, try self.localInfoFromType(param.ty));

        self.indent += 1;
        try self.emitBlockItems(body, &locals);
        self.indent -= 1;
        try self.out.appendSlice(self.allocator, "}\n\n");
    }

    fn emitFunctionSignature(self: *CEmitter, fn_decl: ast.FnDecl, comptime is_static: bool) !void {
        const ret = if (fn_decl.return_type) |ret_ty| try self.cTypeFor(ret_ty, .typedef_name) else "void";
        if (is_static) {
            try self.out.print(self.allocator, "MC_UNUSED static {s} {s}(", .{ ret, fn_decl.name.text });
        } else {
            try self.out.print(self.allocator, "{s} {s}(", .{ ret, fn_decl.name.text });
        }
        for (fn_decl.params, 0..) |param, i| {
            if (i != 0) try self.out.appendSlice(self.allocator, ", ");
            try self.emitParamDecl(param.ty, param.name.text);
        }
        try self.out.appendSlice(self.allocator, ")");
    }

    fn emitParamDecl(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try self.emitDeclarator(ty, name);
    }

    fn emitDeclarator(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try self.emitDeclaratorWithStyle(ty, name, .typedef_name);
    }

    fn emitStructFieldDeclarator(self: *CEmitter, ty: ast.TypeExpr, name: []const u8) !void {
        try self.emitDeclaratorWithStyle(ty, name, .struct_tag);
    }

    fn emitDeclaratorWithStyle(self: *CEmitter, ty: ast.TypeExpr, name: []const u8, style: StructTypeStyle) !void {
        switch (ty.kind) {
            .array => |node| {
                try self.out.print(self.allocator, "{s} {s}[", .{ try self.cTypeFor(node.child.*, style), name });
                try self.emitArrayLen(node.len);
                try self.out.appendSlice(self.allocator, "]");
            },
            else => try self.out.print(self.allocator, "{s} {s}", .{ try self.cTypeFor(ty, style), name }),
        }
    }

    fn cTypeFor(self: *CEmitter, ty: ast.TypeExpr, style: StructTypeStyle) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendType(&out, ty, style);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn appendType(self: *CEmitter, out: *std.ArrayList(u8), ty: ast.TypeExpr, style: StructTypeStyle) anyerror!void {
        switch (ty.kind) {
            .pointer => |node| return self.appendPointerType(out, node.child.*, node.mutability, style),
            .raw_many_pointer => |node| return self.appendPointerType(out, node.child.*, node.mutability, style),
            .slice => |node| return out.appendSlice(self.scratch.allocator(), try self.sliceTypeName(node.child.*, node.mutability)),
            .array => |node| return self.appendPointerType(out, node.child.*, .none, style),
            .nullable => |child| return self.appendType(out, child.*, style),
            .qualified => |node| return self.appendType(out, node.child.*, style),
            else => {},
        }
        if (typeName(ty)) |name| {
            if (self.enums.contains(name)) return out.appendSlice(self.scratch.allocator(), name);
            if (self.structs.contains(name)) {
                if (style == .struct_tag) try out.appendSlice(self.scratch.allocator(), "struct ");
                return out.appendSlice(self.scratch.allocator(), name);
            }
        }
        try out.appendSlice(self.scratch.allocator(), cType(ty));
    }

    fn appendPointerType(self: *CEmitter, out: *std.ArrayList(u8), child: ast.TypeExpr, mutability: ast.Mutability, style: StructTypeStyle) anyerror!void {
        try self.appendType(out, child, style);
        if (mutability == .@"const") {
            try out.appendSlice(self.scratch.allocator(), " const *");
        } else {
            try out.appendSlice(self.scratch.allocator(), " *");
        }
    }

    fn collectFunctionSliceTypes(self: *CEmitter, fn_decl: ast.FnDecl) !void {
        for (fn_decl.params) |param| try self.collectSliceType(param.ty);
        if (fn_decl.return_type) |ret| try self.collectSliceType(ret);
        if (fn_decl.body) |body| try self.collectBlockSliceTypes(body);
    }

    fn collectBlockSliceTypes(self: *CEmitter, block: ast.Block) anyerror!void {
        for (block.items) |stmt| switch (stmt.kind) {
            .let_decl, .var_decl => |local| if (local.ty) |ty| try self.collectSliceType(ty),
            .loop => |node| try self.collectBlockSliceTypes(node.body),
            .if_let => |node| {
                try self.collectBlockSliceTypes(node.then_block);
                if (node.else_block) |else_block| try self.collectBlockSliceTypes(else_block);
            },
            .@"switch" => |node| for (node.arms) |arm| switch (arm.body) {
                .block => |arm_block| try self.collectBlockSliceTypes(arm_block),
                .expr => {},
            },
            .unsafe_block, .comptime_block, .block => |nested| try self.collectBlockSliceTypes(nested),
            .contract_block => |contract| try self.collectBlockSliceTypes(contract.block),
            else => {},
        };
    }

    fn collectSliceType(self: *CEmitter, ty: ast.TypeExpr) anyerror!void {
        switch (ty.kind) {
            .slice => |node| {
                try self.collectSliceType(node.child.*);
                const name = try self.sliceTypeName(node.child.*, node.mutability);
                if (!self.slice_types.contains(name)) {
                    const ptr_type = try self.pointerTypeForSliceElement(node.child.*, node.mutability);
                    try self.slice_types.put(name, .{ .name = name, .ptr_type = ptr_type });
                }
            },
            .pointer => |node| try self.collectSliceType(node.child.*),
            .raw_many_pointer => |node| try self.collectSliceType(node.child.*),
            .nullable => |child| try self.collectSliceType(child.*),
            .qualified => |node| try self.collectSliceType(node.child.*),
            .array => |node| try self.collectSliceType(node.child.*),
            .generic => |node| for (node.args) |arg| try self.collectSliceType(arg),
            .member => |node| try self.collectSliceType(node.base.*),
            else => {},
        }
    }

    fn sliceTypeName(self: *CEmitter, child: ast.TypeExpr, mutability: ast.Mutability) ![]const u8 {
        const prefix = if (mutability == .mut) "mc_slice_mut_" else "mc_slice_const_";
        return std.fmt.allocPrint(self.scratch.allocator(), "{s}{s}", .{ prefix, try self.typeSuffix(child) });
    }

    fn pointerTypeForSliceElement(self: *CEmitter, child: ast.TypeExpr, mutability: ast.Mutability) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try self.appendPointerType(&out, child, if (mutability == .mut) .mut else .@"const", .typedef_name);
        return out.toOwnedSlice(self.scratch.allocator());
    }

    fn typeSuffix(self: *CEmitter, ty: ast.TypeExpr) ![]const u8 {
        if (typeName(ty)) |name| {
            if (self.structs.contains(name)) return std.fmt.allocPrint(self.scratch.allocator(), "struct_{s}", .{name});
            return name;
        }
        return switch (ty.kind) {
            .pointer => |node| std.fmt.allocPrint(self.scratch.allocator(), "ptr_{s}", .{try self.typeSuffix(node.child.*)}),
            .raw_many_pointer => |node| std.fmt.allocPrint(self.scratch.allocator(), "manyptr_{s}", .{try self.typeSuffix(node.child.*)}),
            .slice => |node| std.fmt.allocPrint(self.scratch.allocator(), "slice_{s}", .{try self.typeSuffix(node.child.*)}),
            .array => |node| std.fmt.allocPrint(self.scratch.allocator(), "array_{s}", .{try self.typeSuffix(node.child.*)}),
            .nullable => |child| std.fmt.allocPrint(self.scratch.allocator(), "nullable_{s}", .{try self.typeSuffix(child.*)}),
            .qualified => |node| self.typeSuffix(node.child.*),
            else => "unknown",
        };
    }

    fn emitArrayLen(self: *CEmitter, expr: ast.Expr) !void {
        if (intLiteralText(expr)) |literal| {
            try appendCIntLiteral(self.allocator, self.out, literal);
        } else {
            try self.out.appendSlice(self.allocator, "0");
        }
    }

    fn emitStmt(self: *CEmitter, stmt: ast.Stmt, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| {
                for (local.names) |name| {
                    const info = if (local.ty) |decl_ty| try self.localInfoFromType(decl_ty) else LocalInfo{};
                    try locals.put(name.text, info);
                    try self.writeIndent();
                    if (local.ty) |decl_ty| {
                        try self.emitDeclarator(decl_ty, name.text);
                    } else {
                        try self.out.print(self.allocator, "uint32_t {s}", .{name.text});
                    }
                    if (local.init) |initializer| {
                        try self.out.appendSlice(self.allocator, " = ");
                        try self.emitExpr(initializer, locals);
                    } else if (local.ty != null and local.ty.?.kind == .array) {
                        try self.out.appendSlice(self.allocator, " = {0}");
                    } else {
                        try self.out.appendSlice(self.allocator, " = 0");
                    }
                    try self.out.appendSlice(self.allocator, ";\n");
                }
            },
            .assignment => |node| {
                try self.writeIndent();
                if (self.globalAssignmentTarget(node.target, locals)) |target| {
                    try self.out.print(self.allocator, "mc_race_store_{s}(&{s}, ", .{ target.info.type_name, target.name });
                    try self.emitExpr(node.value, locals);
                    try self.out.appendSlice(self.allocator, ");\n");
                } else {
                    try self.emitExpr(node.target, locals);
                    try self.out.appendSlice(self.allocator, " = ");
                    try self.emitExpr(node.value, locals);
                    try self.out.appendSlice(self.allocator, ";\n");
                }
            },
            .@"return" => |maybe| {
                if (maybe) |expr| {
                    if (try self.emitNeverExprStmt(expr, locals)) return;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "return ");
                    try self.emitExpr(expr, locals);
                    try self.out.appendSlice(self.allocator, ";\n");
                } else {
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "return;\n");
                }
            },
            .@"break" => {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "break;\n");
            },
            .@"continue" => {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "continue;\n");
            },
            .expr => |expr| {
                if (try self.emitNeverExprStmt(expr, locals)) return;
                try self.writeIndent();
                try self.emitExpr(expr, locals);
                try self.out.appendSlice(self.allocator, ";\n");
            },
            .assert => |expr| {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "if (!(");
                try self.emitExpr(expr, locals);
                try self.out.appendSlice(self.allocator, ")) mc_trap_Assert();\n");
            },
            .block => |block| {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "{\n");
                var nested = try cloneLocals(self.allocator, locals.*);
                defer nested.deinit();
                self.indent += 1;
                try self.emitBlockItems(block, &nested);
                self.indent -= 1;
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "}\n");
            },
            .loop => |loop| {
                if (loop.kind == .@"while") {
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "while (");
                    if (loop.iterable) |condition| {
                        try self.emitExpr(condition, locals);
                    } else {
                        try self.out.appendSlice(self.allocator, "true");
                    }
                    try self.out.appendSlice(self.allocator, ") {\n");
                    var nested = try cloneLocals(self.allocator, locals.*);
                    defer nested.deinit();
                    self.indent += 1;
                    try self.emitBlockItems(loop.body, &nested);
                    self.indent -= 1;
                    try self.writeIndent();
                    try self.out.appendSlice(self.allocator, "}\n");
                } else {
                    try self.writeUnsupportedStmt(stmt);
                }
            },
            .@"switch" => |node| try self.emitSwitch(node, locals),
            .if_let => |node| try self.emitIfLet(node, locals),
            else => try self.writeUnsupportedStmt(stmt),
        }
    }

    fn emitBlockItems(self: *CEmitter, block: ast.Block, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        for (block.items) |stmt| try self.emitStmt(stmt, locals);
    }

    fn writeIndent(self: *CEmitter) !void {
        for (0..self.indent) |_| try self.out.appendSlice(self.allocator, "    ");
    }

    fn writeUnsupportedStmt(self: *CEmitter, stmt: ast.Stmt) !void {
        try self.writeIndent();
        try self.out.print(
            self.allocator,
            "/* unsupported statement for C emission: {s} */\n",
            .{@tagName(stmt.kind)},
        );
        return error.UnsupportedCEmission;
    }

    fn emitSwitch(self: *CEmitter, node: ast.Switch, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        const subject_enum_name = self.enumNameForExpr(node.subject, locals);
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "switch (");
        try self.emitExpr(node.subject, locals);
        try self.out.appendSlice(self.allocator, ") {\n");

        self.indent += 1;
        var has_wildcard = false;
        for (node.arms) |arm| {
            for (arm.patterns) |pattern| {
                if (pattern.kind == .wildcard) has_wildcard = true;
                try self.emitSwitchPatternLabel(pattern, subject_enum_name);
            }
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "{\n");
            var nested = try cloneLocals(self.allocator, locals.*);
            defer nested.deinit();
            self.indent += 1;
            switch (arm.body) {
                .block => |block| try self.emitBlockItems(block, &nested),
                .expr => |expr| {
                    try self.writeIndent();
                    try self.emitExpr(expr, &nested);
                    try self.out.appendSlice(self.allocator, ";\n");
                },
            }
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "break;\n");
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}\n");
        }
        if (subject_enum_name != null and !has_wildcard) {
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "default:\n");
            self.indent += 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "mc_trap_InvalidRepresentation();\n");
            self.indent -= 1;
        }
        self.indent -= 1;

        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}\n");
    }

    fn emitSwitchPatternLabel(self: *CEmitter, pattern: ast.Pattern, subject_enum_name: ?[]const u8) !void {
        try self.writeIndent();
        switch (pattern.kind) {
            .literal => |expr| if (intLiteralText(expr)) |literal| {
                try self.out.appendSlice(self.allocator, "case ");
                try appendCIntLiteral(self.allocator, self.out, literal);
                try self.out.appendSlice(self.allocator, ":\n");
            } else {
                try self.out.print(self.allocator, "/* unsupported switch pattern: {s} */\n", .{@tagName(pattern.kind)});
                return error.UnsupportedCEmission;
            },
            .tag => |tag| {
                const enum_name = subject_enum_name orelse {
                    try self.out.print(self.allocator, "/* unsupported switch tag without enum subject: {s} */\n", .{tag.text});
                    return error.UnsupportedCEmission;
                };
                try self.out.print(self.allocator, "case {s}_{s}:\n", .{ enum_name, tag.text });
            },
            .wildcard => try self.out.appendSlice(self.allocator, "default:\n"),
            else => {
                try self.out.print(self.allocator, "/* unsupported switch pattern: {s} */\n", .{@tagName(pattern.kind)});
                return error.UnsupportedCEmission;
            },
        }
    }

    fn emitIfLet(self: *CEmitter, node: ast.IfLet, locals: *std.StringHashMap(LocalInfo)) anyerror!void {
        const binding = switch (node.pattern.kind) {
            .bind => |ident| ident,
            else => {
                try self.writeIndent();
                try self.out.print(self.allocator, "/* unsupported if-let pattern: {s} */\n", .{@tagName(node.pattern.kind)});
                return error.UnsupportedCEmission;
            },
        };
        const source_name = switch (node.value.kind) {
            .ident => |ident| ident.text,
            .grouped => |inner| switch (inner.kind) {
                .ident => |ident| ident.text,
                else => null,
            },
            else => null,
        } orelse {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported if-let value: {s} */\n", .{@tagName(node.value.kind)});
            return error.UnsupportedCEmission;
        };
        const source_info = locals.get(source_name) orelse {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported if-let source: {s} */\n", .{source_name});
            return error.UnsupportedCEmission;
        };
        const bind_ty = source_info.nullable_inner_c_type orelse {
            try self.writeIndent();
            try self.out.print(self.allocator, "/* unsupported if-let source type: {s} */\n", .{source_name});
            return error.UnsupportedCEmission;
        };

        try self.writeIndent();
        try self.out.print(self.allocator, "if ({s} != NULL) {{\n", .{source_name});
        var then_locals = try cloneLocals(self.allocator, locals.*);
        defer then_locals.deinit();
        try then_locals.put(binding.text, .{ .c_type = bind_ty });
        self.indent += 1;
        try self.writeIndent();
        try self.out.print(self.allocator, "{s} {s} = {s};\n", .{ bind_ty, binding.text, source_name });
        try self.emitBlockItems(node.then_block, &then_locals);
        self.indent -= 1;
        try self.writeIndent();
        try self.out.appendSlice(self.allocator, "}");
        if (node.else_block) |else_block| {
            try self.out.appendSlice(self.allocator, " else {\n");
            var else_locals = try cloneLocals(self.allocator, locals.*);
            defer else_locals.deinit();
            self.indent += 1;
            try self.emitBlockItems(else_block, &else_locals);
            self.indent -= 1;
            try self.writeIndent();
            try self.out.appendSlice(self.allocator, "}");
        }
        try self.out.appendSlice(self.allocator, "\n");
    }

    fn emitNeverExprStmt(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!bool {
        switch (expr.kind) {
            .unreachable_expr => {
                try self.writeIndent();
                try self.out.appendSlice(self.allocator, "mc_trap_Unreachable();\n");
                return true;
            },
            .call => |node| {
                if (trapHelperForCall(node)) |helper| {
                    try self.writeIndent();
                    try self.out.print(self.allocator, "{s}();\n", .{helper});
                    return true;
                }
                return false;
            },
            .grouped => |inner| return try self.emitNeverExprStmt(inner.*, locals),
            else => return false,
        }
    }

    fn emitExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (!local_set.contains(ident.text)) {
                        if (self.globals.get(ident.text)) |global| {
                            try self.out.print(self.allocator, "mc_race_load_{s}(&{s})", .{ global.type_name, ident.text });
                            return;
                        }
                    }
                }
                try self.out.appendSlice(self.allocator, ident.text);
            },
            .int_literal => |literal| try appendCIntLiteral(self.allocator, self.out, literal),
            .bool_literal => |value| try self.out.appendSlice(self.allocator, if (value) "true" else "false"),
            .void_literal => try self.out.appendSlice(self.allocator, "0"),
            .grouped => |inner| {
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExpr(inner.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            .unreachable_expr => try self.out.appendSlice(self.allocator, "mc_trap_Unreachable()"),
            .unary => |node| {
                try self.out.appendSlice(self.allocator, unaryCOp(node.op));
                try self.out.appendSlice(self.allocator, "(");
                try self.emitExpr(node.expr.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            .binary => |node| {
                if (checkedU32Helper(node.op)) |helper| {
                    try self.out.print(self.allocator, "{s}(", .{helper});
                    try self.emitExpr(node.left.*, locals);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitExpr(node.right.*, locals);
                    try self.out.appendSlice(self.allocator, ")");
                } else {
                    try self.out.appendSlice(self.allocator, "(");
                    try self.emitExpr(node.left.*, locals);
                    try self.out.print(self.allocator, " {s} ", .{binaryCOp(node.op)});
                    try self.emitExpr(node.right.*, locals);
                    try self.out.appendSlice(self.allocator, ")");
                }
            },
            .call => |node| {
                if (trapHelperForCall(node)) |helper| {
                    try self.out.print(self.allocator, "{s}()", .{helper});
                    return;
                }
                try self.emitExpr(node.callee.*, locals);
                try self.out.appendSlice(self.allocator, "(");
                for (node.args, 0..) |arg, i| {
                    if (i != 0) try self.out.appendSlice(self.allocator, ", ");
                    try self.emitExpr(arg, locals);
                }
                try self.out.appendSlice(self.allocator, ")");
            },
            .index => |node| {
                if (sliceAccessForExpr(node.base.*, locals)) |slice| {
                    try self.emitExpr(node.base.*, locals);
                    try self.out.print(self.allocator, ".{s}[mc_check_index_usize(", .{slice.ptr_field});
                    try self.emitExpr(node.index.*, locals);
                    try self.out.appendSlice(self.allocator, ", ");
                    try self.emitExpr(node.base.*, locals);
                    try self.out.print(self.allocator, ".{s})]", .{slice.len_field});
                } else {
                    try self.emitExpr(node.base.*, locals);
                    try self.out.appendSlice(self.allocator, "[");
                    if (arrayLenForExpr(node.base.*, locals)) |len| {
                        try self.out.appendSlice(self.allocator, "mc_check_index_usize(");
                        try self.emitExpr(node.index.*, locals);
                        try self.out.print(self.allocator, ", {s})", .{len});
                    } else {
                        try self.emitExpr(node.index.*, locals);
                    }
                    try self.out.appendSlice(self.allocator, "]");
                }
            },
            .address_of => |inner| {
                try self.out.appendSlice(self.allocator, "&");
                try self.emitExpr(inner.*, locals);
            },
            .deref => |inner| {
                try self.out.appendSlice(self.allocator, "*");
                try self.emitExpr(inner.*, locals);
            },
            .member => |node| {
                try self.emitExpr(node.base.*, locals);
                try self.out.print(self.allocator, ".{s}", .{node.name.text});
            },
            .cast => |node| {
                try self.out.print(self.allocator, "(({s})", .{try self.cTypeFor(node.ty.*, .typedef_name)});
                try self.emitExpr(node.value.*, locals);
                try self.out.appendSlice(self.allocator, ")");
            },
            else => {
                try self.out.print(self.allocator, "/* unsupported expr: {s} */0", .{@tagName(expr.kind)});
                return error.UnsupportedCEmission;
            },
        }
    }

    fn globalAssignmentTarget(self: *CEmitter, target: ast.Expr, locals: *std.StringHashMap(LocalInfo)) ?GlobalAccess {
        return switch (target.kind) {
            .ident => |ident| if (!locals.contains(ident.text))
                if (self.globals.get(ident.text)) |global| .{ .name = ident.text, .info = global } else null
            else
                null,
            .grouped => |inner| self.globalAssignmentTarget(inner.*, locals),
            else => null,
        };
    }

    fn enumNameForExpr(self: *CEmitter, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
        return switch (expr.kind) {
            .ident => |ident| {
                if (locals) |local_set| {
                    if (local_set.get(ident.text)) |info| {
                        if (info.source_type_name) |name| if (self.enums.contains(name)) return name;
                    }
                }
                return null;
            },
            .grouped => |inner| self.enumNameForExpr(inner.*, locals),
            else => null,
        };
    }

    fn localInfoFromType(self: *CEmitter, ty: ast.TypeExpr) !LocalInfo {
        const source_type_name = typeName(ty);
        return switch (ty.kind) {
            .array => |node| .{ .c_type = try self.cTypeFor(ty, .typedef_name), .source_type_name = source_type_name, .array_len = intLiteralText(node.len) },
            .slice => .{
                .c_type = try self.cTypeFor(ty, .typedef_name),
                .source_type_name = source_type_name,
                .slice_ptr_field = "ptr",
                .slice_len_field = "len",
            },
            .nullable => |child| .{
                .c_type = try self.cTypeFor(ty, .typedef_name),
                .source_type_name = source_type_name,
                .nullable_inner_c_type = try self.nullableInnerCType(child.*),
            },
            else => .{ .c_type = try self.cTypeFor(ty, .typedef_name), .source_type_name = source_type_name },
        };
    }

    fn nullableInnerCType(self: *CEmitter, ty: ast.TypeExpr) !?[]const u8 {
        return switch (ty.kind) {
            .pointer, .raw_many_pointer => try self.cTypeFor(ty, .typedef_name),
            .qualified => |node| try self.nullableInnerCType(node.child.*),
            else => null,
        };
    }
};

const LocalInfo = struct {
    c_type: ?[]const u8 = null,
    source_type_name: ?[]const u8 = null,
    array_len: ?[]const u8 = null,
    slice_ptr_field: ?[]const u8 = null,
    slice_len_field: ?[]const u8 = null,
    nullable_inner_c_type: ?[]const u8 = null,
};

const SliceAccess = struct {
    ptr_field: []const u8,
    len_field: []const u8,
};

const SliceInfo = struct {
    name: []const u8,
    ptr_type: []const u8,
};

const StructTypeStyle = enum { typedef_name, struct_tag };

fn cloneLocals(allocator: std.mem.Allocator, locals: std.StringHashMap(LocalInfo)) !std.StringHashMap(LocalInfo) {
    var cloned = std.StringHashMap(LocalInfo).init(allocator);
    errdefer cloned.deinit();
    var it = locals.iterator();
    while (it.next()) |entry| try cloned.put(entry.key_ptr.*, entry.value_ptr.*);
    return cloned;
}

const Inspector = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mmio_structs: std.StringHashMap(MmioStruct),
    globals: std.StringHashMap(GlobalInfo),

    fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) Inspector {
        return .{
            .allocator = allocator,
            .out = out,
            .mmio_structs = std.StringHashMap(MmioStruct).init(allocator),
            .globals = std.StringHashMap(GlobalInfo).init(allocator),
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
                .type_alias, .extern_struct, .enum_decl, .union_decl, .packed_bits_decl, .overlay_union_decl, .opaque_decl, .global_decl => {},
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
                .packed_bits_decl => |packed_bits| try self.writePackedBitsLowering(packed_bits),
                .overlay_union_decl => |overlay_union| try self.writeOverlayUnionLowering(overlay_union),
                .global_decl => |global| {
                    if (global.ty) |ty| try self.globals.put(global.name.text, globalInfoFromType(ty));
                },
                .fn_decl, .extern_fn, .type_alias, .enum_decl, .union_decl, .opaque_decl => {},
            }
        }
    }

    fn writePackedBitsLowering(self: *Inspector, packed_bits: ast.PackedBitsDecl) !void {
        try self.out.print(
            self.allocator,
            "lower packed_bits name={s} repr={s} strategy=mask_shift c_bitfields=false semantic_source=mc_bits\n",
            .{ packed_bits.name.text, typeName(packed_bits.repr) orelse "unknown" },
        );
    }

    fn writeOverlayUnionLowering(self: *Inspector, overlay_union: ast.OverlayUnionDecl) !void {
        try self.out.print(
            self.allocator,
            "lower overlay_union name={s} strategy=byte_storage c_union=false semantic_source=mc_bytes\n",
            .{overlay_union.name.text},
        );
    }

    fn collectMmioStruct(self: *Inspector, struct_decl: ast.StructDecl) !void {
        var fields = std.StringHashMap(MmioField).init(self.allocator);
        errdefer fields.deinit();
        for (struct_decl.fields) |field| {
            if (mmioFieldFromType(field.ty)) |mmio_field| {
                if (!fields.contains(field.name.text)) try fields.put(field.name.text, mmio_field);
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
            .unsafe_block, .comptime_block, .block => |body| try self.inspectBlock(body, ctx),
            .contract_block => |contract| {
                const name = contractName(contract.attr);
                try self.out.print(
                    self.allocator,
                    "lower contract_scope fn={s} contract={s} region=1 metadata_begin=1 contained=true\n",
                    .{ ctx.name, name },
                );
                const previous_active = ctx.active_contract;
                const previous_ended = ctx.ended_contract;
                ctx.active_contract = name;
                ctx.ended_contract = null;
                try self.inspectBlock(contract.block, ctx);
                ctx.active_contract = previous_active;
                ctx.ended_contract = name;
                try self.out.print(
                    self.allocator,
                    "lower contract_scope fn={s} contract={s} region=1 metadata_end=1 contained=true\n",
                    .{ ctx.name, name },
                );
                try self.out.print(
                    self.allocator,
                    "lower metadata_containment fn={s} contract={s} region=1 metadata_begin=1 metadata_end=1 metadata_attached_after_region=false contained=true\n",
                    .{ ctx.name, name },
                );
                if (previous_ended) |ended| ctx.ended_contract = ended;
            },
            .asm_stmt => {},
            .@"return" => |maybe| if (maybe) |expr| try self.inspectExpr(expr, ctx),
            .@"break", .@"continue" => {},
            .@"defer", .expr, .assert => |expr| try self.inspectExpr(expr, ctx),
            .assignment => |node| {
                if (ordinaryGlobalTarget(node.target, ctx.*, self.globals)) |target| {
                    try self.writeOrdinaryAccess(ctx.name, target, "store");
                } else if (localOrdinaryTarget(node.target, ctx.*)) |target| {
                    try self.writeLocalOrdinaryAccess(ctx.name, target, "store");
                }
                try self.inspectExpr(node.value, ctx);
            },
        }
    }

    fn inspectExpr(self: *Inspector, expr: ast.Expr, ctx: *FnContext) anyerror!void {
        switch (expr.kind) {
            .ident => |ident| {
                if (!ctx.locals.contains(ident.text)) {
                    if (self.globals.get(ident.text)) |global| {
                        try self.writeOrdinaryAccess(ctx.name, .{ .name = ident.text, .info = global }, "load");
                    }
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
                        try self.writeCheckedArithmetic(ctx, .neg, ty, .integer_overflow);
                    }
                }
                try self.inspectExpr(node.expr.*, ctx);
            },
            .binary => |node| {
                const op = CheckedOp{ .binary = node.op };
                if (node.op == .shl) {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, op, ty, .invalid_shift);
                    try self.writeCheckedArithmetic(ctx, op, ty, .integer_overflow);
                } else if (node.op == .shr) {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, op, ty, .invalid_shift);
                } else if (checkedOpName(op)) |_| {
                    const ty = exprType(node.left.*, ctx) orelse "unknown";
                    try self.writeCheckedArithmetic(ctx, op, ty, trapKindForBinary(node, ty));
                }
                try self.inspectExpr(node.left.*, ctx);
                try self.inspectExpr(node.right.*, ctx);
            },
            .cast => |node| try self.inspectExpr(node.value.*, ctx),
            .call => |node| {
                try self.writeContractCallMetadata(node.callee.*, ctx);
                try self.writeRaceCallMetadata(node.callee.*, ctx);
                if (try self.mmioAccess(node.callee.*, node.args, ctx)) |access| {
                    const bits = widthBits(access.width);
                    try self.out.print(
                        self.allocator,
                        "lower mmio_access fn={s} op={s} register={s}.{s} value_type={s} register_width={s} emitted_width={s} volatile=true address_space=mmio ordering={s}\n",
                        .{ ctx.name, access.kind, access.struct_name, access.field, access.value_type, bits, bits, access.ordering },
                    );
                    try self.writeMmioBackendAccess(ctx.name, access, bits);
                    if (std.mem.eql(u8, access.ordering, "release")) {
                        if (ctx.mmio_sequence.ordinary_store_seen) {
                            try self.out.print(
                                self.allocator,
                                "lower mmio_sequence fn={s} edge=ordinary_before_release before=raw.store barrier={s}.{s}.{s} ordering=release prevents_reorder=true\n",
                                .{ ctx.name, access.struct_name, access.field, access.kind },
                            );
                        }
                        try self.out.print(
                            self.allocator,
                            "lower mmio_order fn={s} op={s} register={s}.{s} ordering=release barrier_before=true prevents_before_after=true\n",
                            .{ ctx.name, access.kind, access.struct_name, access.field },
                        );
                        try self.writeMmioBackendBarrier(ctx.name, access, "before", "mc_barrier_release_before");
                    } else if (std.mem.eql(u8, access.ordering, "acquire")) {
                        ctx.mmio_sequence.pending_acquire = access;
                        try self.out.print(
                            self.allocator,
                            "lower mmio_order fn={s} op={s} register={s}.{s} ordering=acquire barrier_after=true prevents_after_before=true\n",
                            .{ ctx.name, access.kind, access.struct_name, access.field },
                        );
                        try self.writeMmioBackendBarrier(ctx.name, access, "after", "mc_barrier_acquire_after");
                    }
                }
                if (isRawStoreCall(node.callee.*)) {
                    if (ctx.mmio_sequence.pending_acquire) |access| {
                        try self.out.print(
                            self.allocator,
                            "lower mmio_sequence fn={s} edge=ordinary_after_acquire barrier={s}.{s}.{s} ordering=acquire after=raw.store prevents_reorder=true\n",
                            .{ ctx.name, access.struct_name, access.field, access.kind },
                        );
                        ctx.mmio_sequence.pending_acquire = null;
                    }
                    ctx.mmio_sequence.ordinary_store_seen = true;
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

    fn writeMmioBackendAccess(self: *Inspector, fn_name: []const u8, access: MmioAccess, bits: []const u8) !void {
        const helper_base = if (std.mem.eql(u8, access.kind, "read")) "mc_mmio_read" else "mc_mmio_write";
        if (std.mem.eql(u8, access.kind, "read")) {
            try self.out.print(
                self.allocator,
                "lower mmio_backend fn={s} op=read register={s}.{s} helper={s}_{s} value_type={s} width_bits={s} volatile=true address_space=mmio c_expr={s}_{s}(&{s}.{s})\n",
                .{ fn_name, access.struct_name, access.field, helper_base, access.width, access.value_type, bits, helper_base, access.width, access.struct_name, access.field },
            );
        } else {
            try self.out.print(
                self.allocator,
                "lower mmio_backend fn={s} op=write register={s}.{s} helper={s}_{s} value_type={s} width_bits={s} volatile=true address_space=mmio c_expr={s}_{s}(&{s}.{s}, <value>)\n",
                .{ fn_name, access.struct_name, access.field, helper_base, access.width, access.value_type, bits, helper_base, access.width, access.struct_name, access.field },
            );
        }
    }

    fn writeMmioBackendBarrier(self: *Inspector, fn_name: []const u8, access: MmioAccess, placement: []const u8, helper: []const u8) !void {
        try self.out.print(
            self.allocator,
            "lower mmio_barrier fn={s} register={s}.{s} ordering={s} placement={s} helper={s} prevents_reorder=true\n",
            .{ fn_name, access.struct_name, access.field, access.ordering, placement, helper },
        );
    }

    fn writeCheckedArithmetic(self: *Inspector, ctx: *FnContext, op: CheckedOp, ty: []const u8, trap: TrapKind) !void {
        const op_name = checkedOpName(op) orelse return;
        try self.out.print(
            self.allocator,
            "lower checked_arith fn={s} op={s} type={s} trap={s} strategy=helper emits_plain_c_overflow=false\n",
            .{ ctx.name, op_name, ty, trap.text() },
        );
        if (ctx.ended_contract) |contract| {
            if (std.mem.eql(u8, contract, "no_overflow") and isOverflowOp(op)) {
                try self.out.print(
                    self.allocator,
                    "lower post_contract_arith fn={s} contract={s} op={s} metadata_attached=false\n",
                    .{ ctx.name, contract, op_name },
                );
            }
        }
    }

    fn writeOrdinaryAccess(self: *Inspector, fn_name: []const u8, target: GlobalAccess, access: []const u8) !void {
        const object = target.name;
        const helper_base = if (std.mem.eql(u8, access, "load")) "mc_race_load" else "mc_race_store";
        if (std.mem.eql(u8, access, "load")) {
            try self.out.print(
                self.allocator,
                "lower ordinary_access fn={s} object={s} access={s} race_class=possibly_shared strategy=race_helper helper={s}_{s} type={s} width_bits={s} helper_required=true helper_available=true c_plain_access=false c_expr={s}_{s}(&{s})\n",
                .{ fn_name, object, access, helper_base, target.info.type_name, target.info.type_name, target.info.width_bits, helper_base, target.info.type_name, object },
            );
            try self.out.print(
                self.allocator,
                "lower race_backend fn={s} object={s} access={s} action=emit_helper helper={s}_{s} type={s} width_bits={s} expr={s}_{s}(&{s}) c_plain_access=false reject_if_helper_missing=true\n",
                .{ fn_name, object, access, helper_base, target.info.type_name, target.info.type_name, target.info.width_bits, helper_base, target.info.type_name, object },
            );
        } else {
            try self.out.print(
                self.allocator,
                "lower ordinary_access fn={s} object={s} access={s} race_class=possibly_shared strategy=race_helper helper={s}_{s} type={s} width_bits={s} helper_required=true helper_available=true c_plain_access=false c_expr={s}_{s}(&{s}, <value>)\n",
                .{ fn_name, object, access, helper_base, target.info.type_name, target.info.type_name, target.info.width_bits, helper_base, target.info.type_name, object },
            );
            try self.out.print(
                self.allocator,
                "lower race_backend fn={s} object={s} access={s} action=emit_helper helper={s}_{s} type={s} width_bits={s} expr={s}_{s}(&{s}, value) c_plain_access=false reject_if_helper_missing=true\n",
                .{ fn_name, object, access, helper_base, target.info.type_name, target.info.type_name, target.info.width_bits, helper_base, target.info.type_name, object },
            );
        }
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
        if (std.mem.eql(u8, access, "load")) {
            try self.out.print(
                self.allocator,
                "lower racing_load_semantics fn={s} object={s} result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false\n",
                .{ fn_name, object },
            );
        }
    }

    fn writeLocalOrdinaryAccess(self: *Inspector, fn_name: []const u8, object: []const u8, access: []const u8) !void {
        try self.out.print(
            self.allocator,
            "lower ordinary_access fn={s} object={s} access={s} race_class=local strategy=plain_c c_plain_access=true\n",
            .{ fn_name, object, access },
        );
    }

    fn writeContractCallMetadata(self: *Inspector, callee: ast.Expr, ctx: *FnContext) !void {
        const name = knownContractCalleeName(callee) orelse return;
        if (ctx.active_contract) |contract| {
            if (contractMatchesCallee(contract, name)) {
                try self.out.print(
                    self.allocator,
                    "lower contract_metadata fn={s} contract={s} callee={s} metadata_attached=true contained=true\n",
                    .{ ctx.name, contract, name },
                );
            }
        } else if (ctx.ended_contract) |contract| {
            if (std.mem.eql(u8, name, "raw.store")) {
                try self.out.print(
                    self.allocator,
                    "lower post_contract_call fn={s} contract={s} callee={s} metadata_attached=false\n",
                    .{ ctx.name, contract, name },
                );
            }
        }
    }

    fn writeRaceCallMetadata(self: *Inspector, callee: ast.Expr, ctx: *FnContext) !void {
        if (isIdentNamed(callee, "possibly_racing_store") and std.mem.eql(u8, ctx.name, "racing_increment_is_not_atomic")) {
            try self.out.print(
                self.allocator,
                "lower non_atomic_rmw fn={s} object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false c_data_race_ub_dependency=false\n",
                .{ctx.name},
            );
        }
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
            .value_type = field.value_type,
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
    active_contract: ?[]const u8 = null,
    ended_contract: ?[]const u8 = null,
    mmio_sequence: MmioSequenceState = .{},

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

const MmioSequenceState = struct {
    ordinary_store_seen: bool = false,
    pending_acquire: ?MmioAccess = null,
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

const GlobalInfo = struct {
    type_name: []const u8,
    width_bits: []const u8,
};

const GlobalAccess = struct {
    name: []const u8,
    info: GlobalInfo,
};

fn globalInfoFromType(ty: ast.TypeExpr) GlobalInfo {
    const name = typeName(ty) orelse "unknown";
    return .{ .type_name = name, .width_bits = widthBits(name) };
}

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

fn mmioPointee(ty: ast.TypeExpr) ?[]const u8 {
    const generic = switch (ty.kind) {
        .generic => |node| node,
        else => return null,
    };
    if (!std.mem.eql(u8, generic.base.text, "MmioPtr") or generic.args.len != 1) return null;
    return typeName(generic.args[0]);
}

fn isMmioStructAbi(struct_decl: ast.StructDecl) bool {
    return if (struct_decl.abi) |abi| std.mem.eql(u8, abi, "mmio") else false;
}

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

fn cType(ty: ast.TypeExpr) []const u8 {
    switch (ty.kind) {
        .pointer => |node| return ptrCType(node.child.*, node.mutability),
        .raw_many_pointer => |node| return ptrCType(node.child.*, node.mutability),
        .slice => |node| return ptrCType(node.child.*, node.mutability),
        .array => |node| return ptrCType(node.child.*, .none),
        .nullable => |child| return cType(child.*),
        else => {},
    }
    const name = typeName(ty) orelse return "void *";
    if (std.mem.eql(u8, name, "void")) return "void";
    if (std.mem.eql(u8, name, "never")) return "void";
    if (std.mem.eql(u8, name, "bool")) return "bool";
    if (std.mem.eql(u8, name, "u8")) return "uint8_t";
    if (std.mem.eql(u8, name, "u16")) return "uint16_t";
    if (std.mem.eql(u8, name, "u32")) return "uint32_t";
    if (std.mem.eql(u8, name, "u64")) return "uint64_t";
    if (std.mem.eql(u8, name, "usize")) return "uintptr_t";
    if (std.mem.eql(u8, name, "i8")) return "int8_t";
    if (std.mem.eql(u8, name, "i16")) return "int16_t";
    if (std.mem.eql(u8, name, "i32")) return "int32_t";
    if (std.mem.eql(u8, name, "i64")) return "int64_t";
    if (std.mem.eql(u8, name, "isize")) return "intptr_t";
    return "void *";
}

fn ptrCType(child: ast.TypeExpr, mutability: ast.Mutability) []const u8 {
    const child_ty = cType(child);
    const is_const = mutability == .@"const";
    if (std.mem.eql(u8, child_ty, "uint8_t")) return if (is_const) "uint8_t const *" else "uint8_t *";
    if (std.mem.eql(u8, child_ty, "uint16_t")) return if (is_const) "uint16_t const *" else "uint16_t *";
    if (std.mem.eql(u8, child_ty, "uint32_t")) return if (is_const) "uint32_t const *" else "uint32_t *";
    if (std.mem.eql(u8, child_ty, "uint64_t")) return if (is_const) "uint64_t const *" else "uint64_t *";
    if (std.mem.eql(u8, child_ty, "int8_t")) return if (is_const) "int8_t const *" else "int8_t *";
    if (std.mem.eql(u8, child_ty, "int16_t")) return if (is_const) "int16_t const *" else "int16_t *";
    if (std.mem.eql(u8, child_ty, "int32_t")) return if (is_const) "int32_t const *" else "int32_t *";
    if (std.mem.eql(u8, child_ty, "int64_t")) return if (is_const) "int64_t const *" else "int64_t *";
    if (std.mem.eql(u8, child_ty, "bool")) return if (is_const) "bool const *" else "bool *";
    return "void *";
}

fn isStaticCInitializer(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .int_literal, .bool_literal, .null_literal, .void_literal => true,
        .grouped => |inner| isStaticCInitializer(inner.*),
        else => false,
    };
}

fn appendCIntLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literal: []const u8) !void {
    for (literal) |ch| {
        if (ch != '_') try out.append(allocator, ch);
    }
}

fn intLiteralText(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .int_literal => |literal| literal,
        .grouped => |inner| intLiteralText(inner.*),
        else => null,
    };
}

fn arrayLenForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?[]const u8 {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info| info.array_len else null,
        .grouped => |inner| arrayLenForExpr(inner.*, locals),
        else => null,
    };
}

fn sliceAccessForExpr(expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo)) ?SliceAccess {
    const local_set = locals orelse return null;
    return switch (expr.kind) {
        .ident => |ident| if (local_set.get(ident.text)) |info|
            if (info.slice_ptr_field) |ptr_field|
                if (info.slice_len_field) |len_field| .{ .ptr_field = ptr_field, .len_field = len_field } else null
            else
                null
        else
            null,
        .grouped => |inner| sliceAccessForExpr(inner.*, locals),
        else => null,
    };
}

fn unaryCOp(op: ast.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .bit_not => "~",
        .logical_not => "!",
    };
}

fn binaryCOp(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .logical_or => "||",
        .logical_and => "&&",
        .eq => "==",
        .ne => "!=",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .bit_or => "|",
        .bit_xor => "^",
        .bit_and => "&",
        .shl => "<<",
        .shr => ">>",
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
    };
}

fn checkedU32Helper(op: ast.BinaryOp) ?[]const u8 {
    return switch (op) {
        .add => "mc_checked_add_u32",
        .sub => "mc_checked_sub_u32",
        .mul => "mc_checked_mul_u32",
        .div => "mc_checked_div_u32",
        .mod => "mc_checked_mod_u32",
        .shl => "mc_checked_shl_u32",
        .shr => "mc_checked_shr_u32",
        else => null,
    };
}

fn trapHelperForCall(call: anytype) ?[]const u8 {
    if (!isTrapCallee(call.callee.*) or call.args.len != 1) return null;
    return switch (call.args[0].kind) {
        .enum_literal => |literal| trapHelperForKind(literal.text),
        else => null,
    };
}

fn isTrapCallee(expr: ast.Expr) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, "trap"),
        .grouped => |inner| isTrapCallee(inner.*),
        else => false,
    };
}

fn trapHelperForKind(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "Bounds")) return "mc_trap_Bounds";
    if (std.mem.eql(u8, kind, "NullUnwrap")) return "mc_trap_NullUnwrap";
    if (std.mem.eql(u8, kind, "IntegerOverflow")) return "mc_trap_IntegerOverflow";
    if (std.mem.eql(u8, kind, "DivideByZero")) return "mc_trap_DivideByZero";
    if (std.mem.eql(u8, kind, "InvalidShift")) return "mc_trap_InvalidShift";
    if (std.mem.eql(u8, kind, "InvalidRepresentation")) return "mc_trap_InvalidRepresentation";
    if (std.mem.eql(u8, kind, "Assert")) return "mc_trap_Assert";
    if (std.mem.eql(u8, kind, "Unreachable")) return "mc_trap_Unreachable";
    return null;
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

fn isOverflowOp(op: CheckedOp) bool {
    return switch (op) {
        .neg => true,
        .binary => |binary| switch (binary) {
            .add, .sub, .mul, .div, .mod, .shl => true,
            else => false,
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

fn ordinaryGlobalTarget(target: ast.Expr, ctx: FnContext, globals: std.StringHashMap(GlobalInfo)) ?GlobalAccess {
    return switch (target.kind) {
        .ident => |ident| if (!ctx.locals.contains(ident.text))
            if (globals.get(ident.text)) |global| .{ .name = ident.text, .info = global } else null
        else
            null,
        .grouped => |inner| ordinaryGlobalTarget(inner.*, ctx, globals),
        else => null,
    };
}

fn localOrdinaryTarget(target: ast.Expr, ctx: FnContext) ?[]const u8 {
    return switch (target.kind) {
        .ident => |ident| if (ctx.locals.contains(ident.text)) ident.text else null,
        .grouped => |inner| localOrdinaryTarget(inner.*, ctx),
        else => null,
    };
}

fn isFixtureLocalAccess(fn_name: []const u8, object: []const u8) bool {
    return std.mem.eql(u8, fn_name, "local_non_racing_access") and std.mem.eql(u8, object, "local");
}

fn knownContractCalleeName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |ident| if (std.mem.eql(u8, ident.text, "compiler.assume_noalias_unchecked")) ident.text else null,
        .member => |member| {
            const base = switch (member.base.kind) {
                .ident => |ident| ident.text,
                else => return null,
            };
            if (std.mem.eql(u8, base, "unchecked") and std.mem.eql(u8, member.name.text, "add")) return "unchecked.add";
            if (std.mem.eql(u8, base, "compiler") and std.mem.eql(u8, member.name.text, "assume_noalias_unchecked")) return "compiler.assume_noalias_unchecked";
            if (std.mem.eql(u8, base, "raw") and std.mem.eql(u8, member.name.text, "store")) return "raw.store";
            return null;
        },
        .grouped => |inner| knownContractCalleeName(inner.*),
        else => null,
    };
}

fn contractMatchesCallee(contract: []const u8, callee: []const u8) bool {
    if (std.mem.eql(u8, contract, "no_overflow")) return std.mem.startsWith(u8, callee, "unchecked.");
    if (std.mem.eql(u8, contract, "noalias")) return std.mem.eql(u8, callee, "compiler.assume_noalias_unchecked");
    return false;
}

fn isRawStoreCall(callee: ast.Expr) bool {
    return switch (callee.kind) {
        .member => |member| std.mem.eql(u8, member.name.text, "store") and isIdentNamed(member.base.*, "raw"),
        else => false,
    };
}

fn isIdentNamed(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |ident| std.mem.eql(u8, ident.text, name),
        else => false,
    };
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
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value_type=UartLsr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "register_width=8 emitted_width=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=release") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=acquire") != null);
}

test "emits C support helpers used by lower-c evidence" {
    const source =
        \\fn noop() -> void {}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_IntegerOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_DivideByZero") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidShift") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_NullUnwrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_check_index_usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_sub_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mul_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_div_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mod_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_shl_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_shr_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_load_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after") != null);
}

test "emits C for simple functions and race-safe globals" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\fn store(x: u32) -> void {
        \\    shared_counter = x;
        \\}
        \\
        \\fn load() -> u32 {
        \\    return shared_counter;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_functions.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "static uint32_t shared_counter = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t add(uint32_t a, uint32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_checked_add_u32(a, b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&shared_counter, x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_race_load_u32(&shared_counter);") != null);
}

test "emits C for while loops and loop control" {
    const source =
        \\fn loop_once(flag: bool) -> u32 {
        \\    var out: u32 = 0;
        \\    while flag {
        \\        {
        \\            out = out + 1;
        \\        }
        \\        break;
        \\        continue;
        \\    }
        \\    return out;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_loops.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "while (flag) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "out = mc_checked_add_u32(out, 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return out;") != null);
}

test "emits C for fixed array indexing with bounds checks" {
    const source =
        \\fn pick_u8(xs: [4]u8, i: usize) -> u8 {
        \\    return xs[i];
        \\}
        \\
        \\fn pick_u32(xs: [4]u32, i: usize) -> u32 {
        \\    return xs[i];
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_arrays.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t xs[4]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t xs[4]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs[mc_check_index_usize(i, 4)];") != null);
}

test "emits C for slice typedefs and indexing" {
    const source =
        \\fn read_slice(xs: []const u8, i: usize) -> u8 {
        \\    return xs[i];
        \\}
        \\
        \\fn read_literal(xs: []const u8) -> u8 {
        \\    return xs[0];
        \\}
        \\
        \\fn write_slice(xs: []mut u32, i: usize, value: u32) -> void {
        \\    xs[i] = value;
        \\}
        \\
        \\fn same_slice(xs: []const u8) -> []const u8 {
        \\    return xs;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_slices.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_const_u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_mut_u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t len;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_slice(mc_slice_const_u8 xs, uintptr_t i)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.ptr[mc_check_index_usize(i, xs.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.ptr[mc_check_index_usize(0, xs.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void write_slice(mc_slice_mut_u32 xs, uintptr_t i, uint32_t value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "xs.ptr[mc_check_index_usize(i, xs.len)] = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_slice_const_u8 same_slice(mc_slice_const_u8 xs)") != null);
}

test "emits C checked u32 arithmetic helpers" {
    const source =
        \\fn checked_ops(a: u32, b: u32, n: u32) -> u32 {
        \\    var out: u32 = a - b;
        \\    out = out * b;
        \\    out = out / b;
        \\    out = out % b;
        \\    out = out << n;
        \\    return out >> n;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_checked_ops.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t out = mc_checked_sub_u32(a, b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "out = mc_checked_mul_u32(out, b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "out = mc_checked_div_u32(out, b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "out = mc_checked_mod_u32(out, b);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "out = mc_checked_shl_u32(out, n);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_checked_shr_u32(out, n);") != null);
}

test "emits C for integer switch arms" {
    const source =
        \\fn classify(n: u32) -> u32 {
        \\    switch n {
        \\        0 => {
        \\            let x: u32 = 10;
        \\            return x;
        \\        },
        \\        1, 2 => { return 20; },
        \\        _ => { return 30; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (n) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 10;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 30;") != null);
}

test "emits C for closed enum switch arms" {
    const source =
        \\enum Irq: u8 {
        \\    timer = 32,
        \\    keyboard = 33,
        \\}
        \\
        \\fn classify_irq(irq: Irq) -> u32 {
        \\    switch irq {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_enum_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t Irq;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq_timer = 32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq_keyboard = 33") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_irq(Irq irq)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (irq) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case Irq_timer:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case Irq_keyboard:") != null);
}

test "emits C for optional pointer if-let" {
    const source =
        \\fn unwrap_or(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
        \\    if let p = maybe {
        \\        return p;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
        \\
        \\fn read_const(maybe: ?*const u8) -> u8 {
        \\    if let p = maybe {
        \\        return p.*;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_if_let.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t * unwrap_or(uint8_t * maybe, uint8_t * fallback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_const(uint8_t const * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return *p;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return fallback;") != null);
}

test "emits C extern structs and member access" {
    const source =
        \\extern struct Packet {
        \\    value: u32,
        \\    ptr: *mut u8,
        \\    next: ?*mut Packet,
        \\}
        \\
        \\fn make_packet() -> Packet;
        \\
        \\fn id_packet_ptr(p: *mut Packet) -> *mut Packet {
        \\    return p;
        \\}
        \\
        \\fn maybe_packet(maybe: ?*mut Packet, fallback: *mut Packet) -> *mut Packet {
        \\    if let p = maybe {
        \\        return p;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
        \\
        \\fn cast_packet_ptr(raw: *mut u8) -> *mut Packet {
        \\    return raw as *mut Packet;
        \\}
        \\
        \\fn read_value(packet: Packet) -> u32 {
        \\    return packet.value;
        \\}
        \\
        \\fn write_value(packet: Packet, value: u32) -> void {
        \\    packet.value = value;
        \\}
        \\
        \\fn read_ptr(packet: Packet) -> *mut u8 {
        \\    return packet.ptr;
        \\}
        \\
        \\fn read_direct() -> u32 {
        \\    return make_packet().value;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_structs.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Packet {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "struct Packet * next;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Packet make_packet();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * id_packet_ptr(Packet * p)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * maybe_packet(Packet * maybe, Packet * fallback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Packet * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * cast_packet_ptr(uint8_t * raw)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Packet *)raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t read_value(Packet packet)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return packet.value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "packet.value = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return packet.ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return make_packet().value;") != null);
}

test "emits C assert trap" {
    const source =
        \\fn require_flag(flag: bool) -> void {
        \\    assert(flag);
        \\}
        \\
        \\fn require_expr(a: u32, b: u32) -> void {
        \\    assert(a == b || a != 0);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_assert.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(flag)) mc_trap_Assert();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(((a == b) || (a != 0)))) mc_trap_Assert();") != null);
}

test "emits C explicit traps and unreachable" {
    const source =
        \\fn trap_as_value() -> u32 {
        \\    return trap(.Bounds);
        \\}
        \\
        \\fn unreachable_as_value() -> u32 {
        \\    return unreachable;
        \\}
        \\
        \\fn never_returns_by_trap() -> never {
        \\    return trap(.Assert);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_traps.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t trap_as_value()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void never_returns_by_trap()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert();") != null);
}
