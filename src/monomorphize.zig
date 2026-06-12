const std = @import("std");

const ast = @import("ast.zig");
const eval = @import("eval.zig");

// Comptime-parameter monomorphization (section 22). A *type-generic* function —
// one whose `comptime` parameter appears in a type position, e.g.
// `fn zeros(comptime N: usize) -> [N]u8` — cannot lower as a single C function,
// because its types depend on the argument. `transform` specializes such
// functions per call: it clones the generic body with the comptime parameters
// substituted by their constant values (`[N]u8` -> `[4]u8`, `N` -> `4`), gives
// each instantiation a mangled name, rewrites call sites to call it (dropping
// the comptime arguments), and removes the generic. The rest of the pipeline
// (sema / MIR / backend) then sees only ordinary, concrete functions.
//
// Crucially, when a module has no type-generic functions — the entire existing
// corpus — `transform` returns it unchanged, so monomorphization has zero
// effect on non-generic code.

// A substitution binds a generic parameter to either a constant value (for
// `comptime N: usize` value params) or a type name (for `comptime T: type`
// type params).
pub const SubstValue = union(enum) {
    int: i128,
    type_name: []const u8,
};
pub const Subst = std.StringHashMap(SubstValue);

const TypeGenericInfo = struct {
    decl: ast.FnDecl,
    // names of the comptime parameters that this function is generic over
    comptime_params: []const []const u8,
};

const Instance = struct {
    decl: ast.FnDecl, // the generic source decl
    subst: Subst,
    mangled: []const u8,
    generated: bool = false,
};

const StructInstance = struct {
    decl: ast.StructDecl,
    subst: Subst,
    mangled: []const u8,
    generated: bool = false,
};

const CloneCtx = struct {
    arena: std.mem.Allocator,
    subst: ?*const Subst = null,
    // Set during the module-rewrite pass to rewrite type-generic call sites and
    // generic-struct type uses.
    rewrite: ?*Rewriter = null,
};

const Rewriter = struct {
    arena: std.mem.Allocator,
    type_generic: *const std.StringHashMap(TypeGenericInfo),
    const_fns: *const std.StringHashMap(ast.FnDecl),
    // Instances are arena-allocated (stable pointers) so adding one mid-pass — which a
    // generic fn calling another generic fn does — never dangles an in-progress subst.
    // The maps dedup by mangled name; the lists drive the worklist passes.
    instances: *std.StringHashMap(*Instance),
    inst_list: *std.ArrayList(*Instance),
    generic_structs: *const std.StringHashMap(ast.StructDecl),
    struct_instances: *std.StringHashMap(*StructInstance),
    struct_list: *std.ArrayList(*StructInstance),
    // Module-level integer `const`s, so a const can be used as a const-generic argument
    // (`Ring<u32, RQ_CAP>`), not just an integer literal.
    int_consts: *const std.StringHashMap(i128),
    // Field lookup for `field_type(T, .field)` when used as a `comptime T: type`
    // argument. This intentionally resolves only fields whose type is a named type,
    // matching the existing type-parameter substitution model.
    field_types: *const std.StringHashMap(std.StringHashMap(ast.TypeExpr)),
    oom: bool = false,
};

pub fn transform(arena: std.mem.Allocator, module: ast.Module) !ast.Module {
    var type_generic = std.StringHashMap(TypeGenericInfo).init(arena);
    var const_fns = std.StringHashMap(ast.FnDecl).init(arena);
    var generic_structs = std.StringHashMap(ast.StructDecl).init(arena);
    var int_consts = std.StringHashMap(i128).init(arena);
    var field_types = std.StringHashMap(std.StringHashMap(ast.TypeExpr)).init(arena);
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| {
                if (fn_decl.is_const and !const_fns.contains(fn_decl.name.text)) try const_fns.put(fn_decl.name.text, fn_decl);
                if (try typeGenericParams(arena, fn_decl)) |params| {
                    try type_generic.put(fn_decl.name.text, .{ .decl = fn_decl, .comptime_params = params });
                }
            },
            .struct_decl => |sd| {
                if (sd.type_params.len > 0) try generic_structs.put(sd.name.text, sd);
                try collectFieldTypes(arena, &field_types, sd.name.text, sd.fields);
            },
            .packed_bits_decl => |pb| {
                try collectFieldTypes(arena, &field_types, pb.name.text, pb.fields);
            },
            .overlay_union_decl => |ou| {
                try collectFieldTypes(arena, &field_types, ou.name.text, ou.fields);
            },
            // Record integer module consts (folded against earlier ones), so they can be
            // used as const-generic arguments.
            .global_decl => |g| {
                if (g.is_const) {
                    if (g.init) |init_expr| {
                        if (foldIntConst(&const_fns, &int_consts, init_expr)) |value| {
                            try int_consts.put(g.name.text, value);
                        }
                    }
                }
            },
            else => {},
        }
    }

    // No-op for the common case: a module with no type-generic functions or
    // generic structs is returned unchanged, so existing code is untouched.
    if (type_generic.count() == 0 and generic_structs.count() == 0) return module;

    var instances = std.StringHashMap(*Instance).init(arena);
    var struct_instances = std.StringHashMap(*StructInstance).init(arena);
    var inst_list: std.ArrayList(*Instance) = .empty;
    var struct_list: std.ArrayList(*StructInstance) = .empty;
    var rewriter = Rewriter{
        .arena = arena,
        .type_generic = &type_generic,
        .const_fns = &const_fns,
        .instances = &instances,
        .inst_list = &inst_list,
        .generic_structs = &generic_structs,
        .struct_instances = &struct_instances,
        .struct_list = &struct_list,
        .int_consts = &int_consts,
        .field_types = &field_types,
    };
    const ctx = CloneCtx{ .arena = arena, .rewrite = &rewriter };

    // Pass 1: clone every decl, rewriting type-generic call sites and
    // generic-struct type uses (collecting the instantiations they need).
    // Generic functions and generic structs are themselves dropped.
    var out: std.ArrayList(ast.Decl) = .empty;
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| {
                if (type_generic.contains(fn_decl.name.text)) continue; // dropped; replaced by instances
                try out.append(arena, .{ .span = decl.span, .attrs = decl.attrs, .kind = .{ .fn_decl = try cloneFnDeclCtx(&ctx, fn_decl) } });
            },
            .struct_decl => |sd| {
                if (sd.type_params.len > 0) continue; // generic; replaced by instances
                try out.append(arena, .{ .span = decl.span, .attrs = decl.attrs, .kind = .{ .struct_decl = try cloneStructDeclCtx(&ctx, sd) } });
            },
            .global_decl => |g| {
                const ty = if (g.ty) |t| try cloneType(&ctx, t) else null;
                try out.append(arena, .{ .span = decl.span, .attrs = decl.attrs, .kind = .{ .global_decl = .{ .name = g.name, .ty = ty, .init = g.init, .is_const = g.is_const } } });
            },
            else => try out.append(arena, decl),
        }
    }
    if (rewriter.oom) return error.OutOfMemory;

    // Pass 2a: specialize functions (with the rewriter, so generic-struct uses in a
    // specialized body are rewritten and registered). A specialized body may call another
    // generic function, appending to inst_list; the index loop processes those too.
    {
        var i: usize = 0;
        while (i < inst_list.items.len) : (i += 1) {
            const inst = inst_list.items[i]; // *Instance — stable across appends
            if (inst.generated) continue;
            inst.generated = true;
            var spec_ctx = CloneCtx{ .arena = arena, .subst = &inst.subst, .rewrite = &rewriter };
            var spec = try cloneFnDeclCtx(&spec_ctx, inst.decl);
            spec.name = .{ .text = inst.mangled, .span = inst.decl.name.span };
            spec.params = try dropComptimeParams(arena, spec.params);
            try out.append(arena, .{ .span = inst.decl.name.span, .attrs = &.{}, .kind = .{ .fn_decl = spec } });
        }
    }
    if (rewriter.oom) return error.OutOfMemory;

    // Pass 2b: generate one concrete struct per instantiation. Field types may reference
    // further instantiations, appending to struct_list; the index loop processes those.
    {
        var i: usize = 0;
        while (i < struct_list.items.len) : (i += 1) {
            const si = struct_list.items[i];
            if (si.generated) continue;
            si.generated = true;
            var sctx = CloneCtx{ .arena = arena, .subst = &si.subst, .rewrite = &rewriter };
            var spec = try cloneStructDeclCtx(&sctx, si.decl);
            spec.name = .{ .text = si.mangled, .span = si.decl.name.span };
            spec.type_params = &.{};
            try out.append(arena, .{ .span = si.decl.name.span, .attrs = &.{}, .kind = .{ .struct_decl = spec } });
        }
    }
    if (rewriter.oom) return error.OutOfMemory;

    return .{ .decls = try out.toOwnedSlice(arena) };
}

fn dropComptimeParams(arena: std.mem.Allocator, params: []const ast.Param) ![]ast.Param {
    var kept: std.ArrayList(ast.Param) = .empty;
    for (params) |p| {
        if (!p.is_comptime) try kept.append(arena, p);
    }
    return kept.toOwnedSlice(arena);
}

fn collectFieldTypes(arena: std.mem.Allocator, out: *std.StringHashMap(std.StringHashMap(ast.TypeExpr)), name: []const u8, fields: []const ast.Field) !void {
    if (out.contains(name)) return;
    var map = std.StringHashMap(ast.TypeExpr).init(arena);
    for (fields) |field| {
        if (!map.contains(field.name.text)) try map.put(field.name.text, field.ty);
    }
    try out.put(name, map);
}

// Returns the names of the comptime parameters a function is generic over (used
// in a type position), or null if the function is not type-generic.
fn typeGenericParams(arena: std.mem.Allocator, fn_decl: ast.FnDecl) !?[]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (fn_decl.params) |param| {
        if (!param.is_comptime) continue;
        if (fnTypeMentions(fn_decl, param.name.text)) try names.append(arena, param.name.text);
    }
    if (names.items.len == 0) return null;
    return try names.toOwnedSlice(arena);
}

fn fnTypeMentions(fn_decl: ast.FnDecl, name: []const u8) bool {
    for (fn_decl.params) |p| if (typeMentionsIdent(p.ty, name)) return true;
    if (fn_decl.return_type) |ty| if (typeMentionsIdent(ty, name)) return true;
    if (fn_decl.body) |body| if (blockTypeMentions(body, name)) return true;
    return false;
}

fn blockTypeMentions(block: ast.Block, name: []const u8) bool {
    for (block.items) |stmt| {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| if (local.ty) |ty| {
                if (typeMentionsIdent(ty, name)) return true;
                if (local.init) |expr| if (exprTypeMentions(expr, name)) return true;
            } else if (local.init) |expr| {
                if (exprTypeMentions(expr, name)) return true;
            },
            .loop => |loop| {
                if (loop.iterable) |expr| if (exprTypeMentions(expr, name)) return true;
                if (blockTypeMentions(loop.body, name)) return true;
            },
            .block, .unsafe_block, .comptime_block => |b| if (blockTypeMentions(b, name)) return true,
            .contract_block => |node| if (blockTypeMentions(node.block, name)) return true,
            .if_let => |n| {
                if (exprTypeMentions(n.value, name)) return true;
                if (blockTypeMentions(n.then_block, name)) return true;
                if (n.else_block) |b| if (blockTypeMentions(b, name)) return true;
            },
            .@"switch" => |node| {
                if (exprTypeMentions(node.subject, name)) return true;
                for (node.arms) |arm| {
                    for (arm.patterns) |pattern| if (patternTypeMentions(pattern, name)) return true;
                    switch (arm.body) {
                        .block => |b| if (blockTypeMentions(b, name)) return true,
                        .expr => |expr| if (exprTypeMentions(expr, name)) return true,
                    }
                }
            },
            .@"return" => |maybe| if (maybe) |expr| {
                if (exprTypeMentions(expr, name)) return true;
            },
            .@"defer", .assert, .expr => |expr| if (exprTypeMentions(expr, name)) return true,
            .assignment => |node| {
                if (exprTypeMentions(node.target, name) or exprTypeMentions(node.value, name)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn typeMentionsIdent(ty: ast.TypeExpr, name: []const u8) bool {
    return switch (ty.kind) {
        // A type parameter `T` is used as the type name itself (`a: T`).
        .name => |n| std.mem.eql(u8, n.text, name),
        .array => |node| exprMentionsIdent(node.len, name) or typeMentionsIdent(node.child.*, name),
        .member => |node| typeMentionsIdent(node.base.*, name),
        .nullable => |child| typeMentionsIdent(child.*, name),
        .qualified => |node| typeMentionsIdent(node.child.*, name),
        .pointer => |node| typeMentionsIdent(node.child.*, name),
        .raw_many_pointer => |node| typeMentionsIdent(node.child.*, name),
        .slice => |node| typeMentionsIdent(node.child.*, name),
        .generic => |node| blk: {
            for (node.args) |arg| if (typeMentionsIdent(arg, name)) break :blk true;
            break :blk false;
        },
        .fn_pointer => |node| blk: {
            for (node.params) |param| if (typeMentionsIdent(param, name)) break :blk true;
            break :blk typeMentionsIdent(node.ret.*, name);
        },
        .closure_type => |node| blk: {
            for (node.params) |param| if (typeMentionsIdent(param, name)) break :blk true;
            break :blk typeMentionsIdent(node.ret.*, name);
        },
        .enum_literal => false,
    };
}

fn exprMentionsIdent(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .ident => |id| std.mem.eql(u8, id.text, name),
        .grouped, .address_of, .deref => |inner| exprMentionsIdent(inner.*, name),
        .try_expr => |inner| exprMentionsIdent(inner.operand.*, name),
        .unary => |n| exprMentionsIdent(n.expr.*, name),
        .binary => |n| exprMentionsIdent(n.left.*, name) or exprMentionsIdent(n.right.*, name),
        .index => |n| exprMentionsIdent(n.base.*, name) or exprMentionsIdent(n.index.*, name),
        .member => |n| exprMentionsIdent(n.base.*, name),
        .cast => |n| exprMentionsIdent(n.value.*, name),
        else => false,
    };
}

fn exprTypeMentions(expr: ast.Expr, name: []const u8) bool {
    return switch (expr.kind) {
        .grouped, .address_of, .deref => |inner| exprTypeMentions(inner.*, name),
        .try_expr => |inner| exprTypeMentions(inner.operand.*, name) or if (inner.mapped) |mapped| exprTypeMentions(mapped.*, name) else false,
        .unary => |node| exprTypeMentions(node.expr.*, name),
        .binary => |node| exprTypeMentions(node.left.*, name) or exprTypeMentions(node.right.*, name),
        .index => |node| exprTypeMentions(node.base.*, name) or exprTypeMentions(node.index.*, name),
        .member => |node| exprTypeMentions(node.base.*, name),
        .cast => |node| typeMentionsIdent(node.ty.*, name) or exprTypeMentions(node.value.*, name),
        .call => |node| blk: {
            if (exprTypeMentions(node.callee.*, name)) break :blk true;
            for (node.type_args) |ty| if (typeMentionsIdent(ty, name)) break :blk true;
            for (node.args) |arg| if (exprTypeMentions(arg, name)) break :blk true;
            break :blk false;
        },
        .array_literal => |items| blk: {
            for (items) |item| if (exprTypeMentions(item, name)) break :blk true;
            break :blk false;
        },
        .struct_literal => |fields| blk: {
            for (fields) |field| if (exprTypeMentions(field.value, name)) break :blk true;
            break :blk false;
        },
        .block => |block| blockTypeMentions(block, name),
        else => false,
    };
}

fn patternTypeMentions(pattern: ast.Pattern, name: []const u8) bool {
    return switch (pattern.kind) {
        .literal => |expr| exprTypeMentions(expr, name),
        else => false,
    };
}

// --- the substituting / rewriting clone ------------------------------------

pub fn cloneFnDecl(arena: std.mem.Allocator, fn_decl: ast.FnDecl, subst: *const Subst) !ast.FnDecl {
    var ctx = CloneCtx{ .arena = arena, .subst = subst };
    return cloneFnDeclCtx(&ctx, fn_decl);
}

fn cloneFnDeclCtx(ctx: *const CloneCtx, fn_decl: ast.FnDecl) !ast.FnDecl {
    var params = try ctx.arena.alloc(ast.Param, fn_decl.params.len);
    for (fn_decl.params, 0..) |param, i| {
        params[i] = .{ .name = param.name, .ty = try cloneType(ctx, param.ty), .is_comptime = param.is_comptime };
    }
    return .{
        .name = fn_decl.name,
        .abi = fn_decl.abi,
        .params = params,
        .return_type = if (fn_decl.return_type) |ty| try cloneType(ctx, ty) else null,
        .body = if (fn_decl.body) |body| try cloneBlock(ctx, body) else null,
        .is_const = fn_decl.is_const,
        .exported = fn_decl.exported,
    };
}

pub fn cloneExpr(arena: std.mem.Allocator, expr: ast.Expr, subst: *const Subst) !ast.Expr {
    var ctx = CloneCtx{ .arena = arena, .subst = subst };
    return cloneExprCtx(&ctx, expr);
}

fn cloneExprCtx(ctx: *const CloneCtx, expr: ast.Expr) anyerror!ast.Expr {
    const kind: ast.Expr.Kind = switch (expr.kind) {
        .ident => |ident| if (ctx.subst) |s| (if (s.get(ident.text)) |value| switch (value) {
            .int => |n| ast.Expr.Kind{ .int_literal = try std.fmt.allocPrint(ctx.arena, "{d}", .{n}) },
            // A type param forwarded as a type-argument to a nested generic call
            // (`inner(T, N, ...)`): substitute the concrete type name so the nested
            // instantiation resolves (`inner(u32, 4, ...)`).
            .type_name => |tn| ast.Expr.Kind{ .ident = .{ .text = tn, .span = ident.span } },
        } else ast.Expr.Kind{ .ident = ident }) else ast.Expr.Kind{ .ident = ident },
        .int_literal,
        .float_literal,
        .string_literal,
        .char_literal,
        .bool_literal,
        .null_literal,
        .uninit_literal,
        .unreachable_expr,
        .void_literal,
        .enum_literal,
        => expr.kind,
        .grouped => |inner| .{ .grouped = try clonePtr(ctx, inner.*) },
        .unary => |node| .{ .unary = .{ .op = node.op, .expr = try clonePtr(ctx, node.expr.*) } },
        .binary => |node| .{ .binary = .{ .op = node.op, .left = try clonePtr(ctx, node.left.*), .right = try clonePtr(ctx, node.right.*) } },
        .cast => |node| .{ .cast = .{ .value = try clonePtr(ctx, node.value.*), .ty = try cloneTypePtr(ctx, node.ty.*) } },
        .address_of => |inner| .{ .address_of = try clonePtr(ctx, inner.*) },
        .deref => |inner| .{ .deref = try clonePtr(ctx, inner.*) },
        .try_expr => |inner| .{ .try_expr = .{ .operand = try clonePtr(ctx, inner.operand.*), .mapped = if (inner.mapped) |m| try clonePtr(ctx, m.*) else null } },
        .member => |node| .{ .member = .{ .base = try clonePtr(ctx, node.base.*), .name = node.name } },
        .index => |node| .{ .index = .{ .base = try clonePtr(ctx, node.base.*), .index = try clonePtr(ctx, node.index.*) } },
        .array_literal => |items| .{ .array_literal = try cloneExprSlice(ctx, items) },
        .struct_literal => |fields| blk: {
            var out = try ctx.arena.alloc(ast.StructLiteralField, fields.len);
            for (fields, 0..) |field, i| out[i] = .{ .name = field.name, .value = try cloneExprCtx(ctx, field.value) };
            break :blk .{ .struct_literal = out };
        },
        .call => |node| return try cloneCall(ctx, expr, node),
        .block => |block| .{ .block = try cloneBlock(ctx, block) },
    };
    return .{ .span = expr.span, .kind = kind };
}

fn cloneCall(ctx: *const CloneCtx, expr: ast.Expr, node: anytype) anyerror!ast.Expr {
    // Rewrite a call to a type-generic function into a call to its specialization.
    if (ctx.rewrite) |rw| {
        if (calleeName(node.callee.*)) |name| {
            if (rw.type_generic.get(name)) |info| {
                if (try rewriteGenericCall(ctx, rw, info, node)) |rewritten| return rewritten;
            }
        }
    }
    return .{ .span = expr.span, .kind = .{ .call = .{
        .callee = try clonePtr(ctx, node.callee.*),
        .type_args = try cloneTypeSlice(ctx, node.type_args),
        .args = try cloneExprSlice(ctx, node.args),
    } } };
}

fn rewriteGenericCall(ctx: *const CloneCtx, rw: *Rewriter, info: TypeGenericInfo, node: anytype) anyerror!?ast.Expr {
    if (node.args.len != info.decl.params.len) return null;
    var subst = Subst.init(rw.arena);
    var mangled: std.ArrayList(u8) = .empty;
    try mangled.appendSlice(rw.arena, info.decl.name.text);
    var kept_args: std.ArrayList(ast.Expr) = .empty;
    for (info.decl.params, node.args) |param, arg| {
        // Apply the enclosing substitution first, so a generic function that forwards its
        // own comptime params to a nested generic call (`inner(T, N, ...)`) resolves them
        // (T -> u32, N -> 4) before we read the type-arg name / fold the value.
        const arg_clone = try cloneExprCtx(ctx, arg);
        if (param.is_comptime and isTypeParam(param)) {
            // `comptime T: type`: bind to the argument's type name.
            const tn = typeArgName(arg_clone, rw.field_types) orelse return null;
            try subst.put(param.name.text, .{ .type_name = tn });
            try mangled.appendSlice(rw.arena, "__");
            try mangled.appendSlice(rw.arena, tn);
        } else if (param.is_comptime) {
            const value = foldConst(rw, arg_clone) orelse return null; // not a constant -> leave call as-is (sema will diagnose)
            try subst.put(param.name.text, .{ .int = value });
            const seg = try std.fmt.allocPrint(rw.arena, "__{d}", .{value});
            try mangled.appendSlice(rw.arena, seg);
        } else {
            try kept_args.append(rw.arena, arg_clone);
        }
    }
    const mangled_name = try mangled.toOwnedSlice(rw.arena);
    if (!rw.instances.contains(mangled_name)) {
        const inst = rw.arena.create(Instance) catch {
            rw.oom = true;
            return null;
        };
        inst.* = .{ .decl = info.decl, .subst = subst, .mangled = mangled_name };
        rw.instances.put(mangled_name, inst) catch {
            rw.oom = true;
        };
        rw.inst_list.append(rw.arena, inst) catch {
            rw.oom = true;
        };
    }
    const callee = try ast.makePtr(rw.arena, ast.Expr{ .span = node.callee.*.span, .kind = .{ .ident = .{ .text = mangled_name, .span = node.callee.*.span } } });
    return ast.Expr{ .span = node.callee.*.span, .kind = .{ .call = .{
        .callee = callee,
        .type_args = &.{},
        .args = try kept_args.toOwnedSlice(rw.arena),
    } } };
}

fn foldConst(rw: *Rewriter, expr: ast.Expr) ?i128 {
    return foldIntConst(rw.const_fns, rw.int_consts, expr);
}

// Fold `expr` to an integer at comptime, resolving module const-fn calls and integer
// module consts (so a `const` can stand in for an integer literal, e.g. as a const-
// generic argument). Returns null if it isn't a comptime integer.
fn foldIntConst(
    const_fns: *const std.StringHashMap(ast.FnDecl),
    int_consts: *const std.StringHashMap(i128),
    expr: ast.Expr,
) ?i128 {
    var buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var scope = eval.ComptimeScope.init(fba.allocator());
    scope.funcs = const_fns;
    var it = int_consts.iterator();
    while (it.next()) |entry| {
        scope.bindings.put(entry.key_ptr.*, .{ .int = entry.value_ptr.* }) catch return null;
    }
    return switch (eval.foldComptimeExpr(&scope, expr)) {
        .value => |v| switch (v) {
            .int => |n| n,
            else => null,
        },
        else => null,
    };
}

fn isTypeParam(param: ast.Param) bool {
    return switch (param.ty.kind) {
        .name => |n| std.mem.eql(u8, n.text, "type"),
        else => false,
    };
}

fn typeArgName(arg: ast.Expr, field_types: *const std.StringHashMap(std.StringHashMap(ast.TypeExpr))) ?[]const u8 {
    return switch (arg.kind) {
        .ident => |id| id.text,
        .grouped => |inner| typeArgName(inner.*, field_types),
        .call => |node| fieldTypeArgName(node, field_types),
        else => null,
    };
}

fn fieldTypeArgName(call: anytype, field_types: *const std.StringHashMap(std.StringHashMap(ast.TypeExpr))) ?[]const u8 {
    const callee = calleeName(call.callee.*) orelse return null;
    if (!std.mem.eql(u8, callee, "field_type")) return null;
    if (call.type_args.len != 1 or call.args.len != 1) return null;
    const type_name = typeName(call.type_args[0]) orelse return null;
    const field_name = enumLiteralName(call.args[0]) orelse return null;
    const fields = field_types.get(type_name) orelse return null;
    const field_ty = fields.get(field_name) orelse return null;
    return typeName(field_ty);
}

fn typeName(ty: ast.TypeExpr) ?[]const u8 {
    return switch (ty.kind) {
        .name => |name| name.text,
        .qualified => |node| typeName(node.child.*),
        else => null,
    };
}

fn enumLiteralName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .enum_literal => |literal| literal.text,
        .grouped => |inner| enumLiteralName(inner.*),
        else => null,
    };
}

fn calleeName(expr: ast.Expr) ?[]const u8 {
    return switch (expr.kind) {
        .ident => |id| id.text,
        .grouped => |inner| calleeName(inner.*),
        else => null,
    };
}

pub fn cloneType(ctx: *const CloneCtx, ty: ast.TypeExpr) anyerror!ast.TypeExpr {
    const kind: ast.TypeExpr.Kind = switch (ty.kind) {
        // Substitute a type parameter `T` with its concrete type name.
        .name => |n| if (ctx.subst) |s| (if (s.get(n.text)) |value| switch (value) {
            .type_name => |tn| ast.TypeExpr.Kind{ .name = .{ .text = tn, .span = n.span } },
            // A const-generic value used as a type argument (`Ring<T, N>`) substitutes
            // to the literal, so the struct instance mangles correctly (`Ring__u32__8`).
            .int => |v| ast.TypeExpr.Kind{ .name = .{ .text = try std.fmt.allocPrint(ctx.arena, "{d}", .{v}), .span = n.span } },
        } else ty.kind) else ty.kind,
        .enum_literal => ty.kind,
        .member => |node| .{ .member = .{ .base = try cloneTypePtr(ctx, node.base.*), .field = node.field } },
        .nullable => |child| .{ .nullable = try cloneTypePtr(ctx, child.*) },
        .qualified => |node| .{ .qualified = .{ .mutability = node.mutability, .child = try cloneTypePtr(ctx, node.child.*) } },
        .pointer => |node| .{ .pointer = .{ .mutability = node.mutability, .child = try cloneTypePtr(ctx, node.child.*) } },
        .raw_many_pointer => |node| .{ .raw_many_pointer = .{ .mutability = node.mutability, .child = try cloneTypePtr(ctx, node.child.*) } },
        .slice => |node| .{ .slice = .{ .mutability = node.mutability, .child = try cloneTypePtr(ctx, node.child.*) } },
        .array => |node| .{ .array = .{ .len = try cloneExprCtx(ctx, node.len), .child = try cloneTypePtr(ctx, node.child.*) } },
        .generic => |node| blk: {
            // Rewrite a use of a generic struct `Name<Arg, …>` to its
            // monomorphized name `Name__Arg…`, collecting the instantiation.
            if (ctx.rewrite) |rw| {
                if (rw.generic_structs.get(node.base.text)) |sd| {
                    if (try rewriteGenericStruct(ctx, rw, sd, node)) |name| break :blk ast.TypeExpr.Kind{ .name = .{ .text = name, .span = node.base.span } };
                }
            }
            break :blk .{ .generic = .{ .base = node.base, .args = try cloneTypeSlice(ctx, node.args) } };
        },
        .fn_pointer => |node| .{ .fn_pointer = .{ .params = try cloneTypeSlice(ctx, node.params), .ret = try cloneTypePtr(ctx, node.ret.*) } },
        .closure_type => |node| .{ .closure_type = .{ .params = try cloneTypeSlice(ctx, node.params), .ret = try cloneTypePtr(ctx, node.ret.*) } },
    };
    return .{ .span = ty.span, .kind = kind };
}

// Collect (if new) and name the monomorphization of a generic struct use.
// Returns the mangled concrete name, or null if the type arguments are not all
// concrete type names (the use is left generic for sema to diagnose).
// A generic argument that is a numeric literal is a const-generic *value* (e.g. the
// `8` in `Ring<u32, 8>`); a type name is not. Returns the value, or null for a type.
fn constGenericValue(text: []const u8) ?i128 {
    if (text.len == 0) return null;
    if (!(text[0] >= '0' and text[0] <= '9')) return null;
    return std.fmt.parseInt(i128, text, 0) catch null;
}

fn rewriteGenericStruct(ctx: *const CloneCtx, rw: *Rewriter, sd: ast.StructDecl, node: anytype) anyerror!?[]const u8 {
    if (node.args.len != sd.type_params.len) return null;
    var subst = Subst.init(rw.arena);
    var mangled: std.ArrayList(u8) = .empty;
    try mangled.appendSlice(rw.arena, sd.name.text);
    for (sd.type_params, node.args) |param, arg| {
        // The argument resolves to a concrete type name (after any outer substitution),
        // or a const-generic *value* (an integer) bound into `[N]T` array lengths.
        const arg_clone = try cloneType(ctx, arg);
        const tn = switch (arg_clone.kind) {
            .name => |n| n.text,
            else => return null,
        };
        try mangled.appendSlice(rw.arena, "__");
        if (constGenericValue(tn)) |value| {
            // an integer literal type-argument (`Ring<u32, 8>`). Mangle from the parsed
            // value's canonical decimal form, not the raw lexeme, so `Buf<0x10>`,
            // `Buf<16>`, and a folded const `Buf<N>` all name the same instance.
            try subst.put(param.text, .{ .int = value });
            try mangled.appendSlice(rw.arena, try std.fmt.allocPrint(rw.arena, "{d}", .{value}));
        } else if (rw.int_consts.get(tn)) |value| {
            // a const used as a const-generic argument (`Ring<u32, RQ_CAP>`)
            try subst.put(param.text, .{ .int = value });
            try mangled.appendSlice(rw.arena, try std.fmt.allocPrint(rw.arena, "{d}", .{value}));
        } else {
            // a concrete type name (`Ring<u32, …>`'s `u32`)
            try subst.put(param.text, .{ .type_name = tn });
            try mangled.appendSlice(rw.arena, tn);
        }
    }
    const name = try mangled.toOwnedSlice(rw.arena);
    if (!rw.struct_instances.contains(name)) {
        const si = rw.arena.create(StructInstance) catch {
            rw.oom = true;
            return name;
        };
        si.* = .{ .decl = sd, .subst = subst, .mangled = name };
        rw.struct_instances.put(name, si) catch {
            rw.oom = true;
        };
        rw.struct_list.append(rw.arena, si) catch {
            rw.oom = true;
        };
    }
    return name;
}

fn cloneStructDeclCtx(ctx: *const CloneCtx, sd: ast.StructDecl) anyerror!ast.StructDecl {
    var fields = try ctx.arena.alloc(ast.Field, sd.fields.len);
    for (sd.fields, 0..) |field, i| {
        fields[i] = .{ .name = field.name, .ty = try cloneType(ctx, field.ty), .offset = field.offset };
    }
    return .{ .name = sd.name, .abi = sd.abi, .fields = fields, .type_params = sd.type_params, .is_move = sd.is_move };
}

fn cloneBlock(ctx: *const CloneCtx, block: ast.Block) anyerror!ast.Block {
    var items = try ctx.arena.alloc(ast.Stmt, block.items.len);
    for (block.items, 0..) |stmt, i| items[i] = try cloneStmt(ctx, stmt);
    return .{ .span = block.span, .items = items };
}

fn cloneStmt(ctx: *const CloneCtx, stmt: ast.Stmt) anyerror!ast.Stmt {
    const kind: ast.Stmt.Kind = switch (stmt.kind) {
        .let_decl => |local| .{ .let_decl = try cloneLocal(ctx, local) },
        .var_decl => |local| .{ .var_decl = try cloneLocal(ctx, local) },
        .loop => |loop| .{ .loop = .{
            .kind = loop.kind,
            .label = loop.label,
            .iterable = if (loop.iterable) |it| try cloneExprCtx(ctx, it) else null,
            .body = try cloneBlock(ctx, loop.body),
        } },
        .if_let => |node| .{ .if_let = .{
            .pattern = node.pattern,
            .value = try cloneExprCtx(ctx, node.value),
            .then_block = try cloneBlock(ctx, node.then_block),
            .else_block = if (node.else_block) |b| try cloneBlock(ctx, b) else null,
        } },
        .@"switch" => |node| .{ .@"switch" = try cloneSwitch(ctx, node) },
        .unsafe_block => |block| .{ .unsafe_block = try cloneBlock(ctx, block) },
        .comptime_block => |block| .{ .comptime_block = try cloneBlock(ctx, block) },
        .contract_block => |node| .{ .contract_block = .{ .attr = node.attr, .block = try cloneBlock(ctx, node.block) } },
        .asm_stmt => stmt.kind,
        .block => |block| .{ .block = try cloneBlock(ctx, block) },
        .@"return" => |maybe| .{ .@"return" = if (maybe) |e| try cloneExprCtx(ctx, e) else null },
        .@"break", .@"continue" => stmt.kind,
        .@"defer" => |e| .{ .@"defer" = try cloneExprCtx(ctx, e) },
        .assert => |e| .{ .assert = try cloneExprCtx(ctx, e) },
        .assignment => |node| .{ .assignment = .{ .target = try cloneExprCtx(ctx, node.target), .value = try cloneExprCtx(ctx, node.value) } },
        .expr => |e| .{ .expr = try cloneExprCtx(ctx, e) },
    };
    return .{ .span = stmt.span, .kind = kind };
}

fn cloneLocal(ctx: *const CloneCtx, local: ast.LocalDecl) anyerror!ast.LocalDecl {
    return .{
        .names = local.names,
        .ty = if (local.ty) |ty| try cloneType(ctx, ty) else null,
        .init = if (local.init) |e| try cloneExprCtx(ctx, e) else null,
    };
}

fn cloneSwitch(ctx: *const CloneCtx, node: ast.Switch) anyerror!ast.Switch {
    var arms = try ctx.arena.alloc(ast.SwitchArm, node.arms.len);
    for (node.arms, 0..) |arm, i| {
        arms[i] = .{
            .patterns = arm.patterns,
            .body = switch (arm.body) {
                .block => |b| .{ .block = try cloneBlock(ctx, b) },
                .expr => |e| .{ .expr = try cloneExprCtx(ctx, e) },
            },
        };
    }
    return .{ .subject = try cloneExprCtx(ctx, node.subject), .arms = arms };
}

fn clonePtr(ctx: *const CloneCtx, expr: ast.Expr) anyerror!*ast.Expr {
    return ast.makePtr(ctx.arena, try cloneExprCtx(ctx, expr));
}

fn cloneTypePtr(ctx: *const CloneCtx, ty: ast.TypeExpr) anyerror!*ast.TypeExpr {
    return ast.makePtr(ctx.arena, try cloneType(ctx, ty));
}

fn cloneExprSlice(ctx: *const CloneCtx, exprs: []const ast.Expr) anyerror![]ast.Expr {
    var out = try ctx.arena.alloc(ast.Expr, exprs.len);
    for (exprs, 0..) |e, i| out[i] = try cloneExprCtx(ctx, e);
    return out;
}

fn cloneTypeSlice(ctx: *const CloneCtx, types: []const ast.TypeExpr) anyerror![]ast.TypeExpr {
    var out = try ctx.arena.alloc(ast.TypeExpr, types.len);
    for (types, 0..) |t, i| out[i] = try cloneType(ctx, t);
    return out;
}

const testing = std.testing;
const zero_span = ast.Span{ .offset = 0, .len = 0, .line = 0, .column = 0 };

test "cloneType substitutes a comptime parameter in an array length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var subst = Subst.init(testing.allocator);
    defer subst.deinit();
    try subst.put("N", .{ .int = 4 });

    const elem = try ast.makePtr(a, ast.TypeExpr{ .span = zero_span, .kind = .{ .name = .{ .text = "u8", .span = zero_span } } });
    const n_ident = ast.Expr{ .span = zero_span, .kind = .{ .ident = .{ .text = "N", .span = zero_span } } };
    const ty = ast.TypeExpr{ .span = zero_span, .kind = .{ .array = .{ .len = n_ident, .child = elem } } };

    var ctx = CloneCtx{ .arena = a, .subst = &subst };
    const cloned = try cloneType(&ctx, ty);
    try testing.expectEqualStrings("4", cloned.kind.array.len.kind.int_literal);
    try testing.expectEqualStrings("u8", cloned.kind.array.child.kind.name.text);
}

test "cloneExpr substitutes comptime params and preserves other idents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var subst = Subst.init(testing.allocator);
    defer subst.deinit();
    try subst.put("N", .{ .int = 8 });

    const left = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .ident = .{ .text = "N", .span = zero_span } } });
    const right = try ast.makePtr(a, ast.Expr{ .span = zero_span, .kind = .{ .ident = .{ .text = "i", .span = zero_span } } });
    const expr = ast.Expr{ .span = zero_span, .kind = .{ .binary = .{ .op = .add, .left = left, .right = right } } };

    const cloned = try cloneExpr(a, expr, &subst);
    try testing.expectEqualStrings("8", cloned.kind.binary.left.kind.int_literal);
    try testing.expectEqualStrings("i", cloned.kind.binary.right.kind.ident.text);
}

test "transform is a no-op when there are no type-generic functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decls = try a.alloc(ast.Decl, 0);
    const module = ast.Module{ .decls = decls };
    const out = try transform(a, module);
    try testing.expectEqual(@as(usize, 0), out.decls.len);
}
