const std = @import("std");

const ast = @import("ast.zig");
const eval = @import("eval.zig");
const diagnostics = @import("diagnostics.zig");

// The set of `(trait, concrete)` pairs with an `impl Trait for Concrete`, flattened
// to a single map keyed on `"{trait}\x00{concrete}"` so a bound check is one hash
// lookup instead of a nested trait->set->contains double lookup (Phase 2.5). The keys
// are identifier strings (stable within a compilation), so membership is identical to
// the old nested form — no observable change.
const ConformanceSet = std.StringHashMap(void);

pub const default_max_monomorphization_depth: usize = 128;
pub const default_max_monomorphization_instances: usize = 4096;

pub const Limits = struct {
    max_depth: usize = default_max_monomorphization_depth,
    max_instances: usize = default_max_monomorphization_instances,
};

pub const Options = struct {
    limits: Limits = .{},
};

// Build the combined conformance key into `buf` (or arena-allocate if it doesn't fit).
// Names are identifiers, so the stack buffer covers every realistic case.
fn conformanceKey(arena: std.mem.Allocator, buf: []u8, trait: []const u8, concrete: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}\x00{s}", .{ trait, concrete }) catch
        std.fmt.allocPrint(arena, "{s}\x00{s}", .{ trait, concrete }) catch "\x00";
}

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
    // The generic decl's attributes (e.g. `#[irq_context]`), carried onto each
    // specialization so effect/context checks survive monomorphization.
    attrs: []ast.Attr = &.{},
};

const Instance = struct {
    decl: ast.FnDecl, // the generic source decl
    subst: Subst,
    mangled: []const u8,
    attrs: []ast.Attr = &.{},
    depth: usize = 0,
    generated: bool = false,
    // A `where T: Trait` bound was unsatisfied for this instantiation (already reported
    // E_TRAIT_NOT_SATISFIED at the call). We still emit a specialization so the call
    // resolves, but with an `unreachable` body — the real body would reference a missing
    // `Type__method`, spilling a deep-body cascade the design forbids.
    bound_failed: bool = false,
    limit_failed: bool = false,
};

const StructInstance = struct {
    decl: ast.StructDecl,
    subst: Subst,
    mangled: []const u8,
    depth: usize = 0,
    generated: bool = false,
    limit_failed: bool = false,
};

const UnionInstance = struct {
    decl: ast.UnionDecl,
    subst: Subst,
    mangled: []const u8,
    depth: usize = 0,
    generated: bool = false,
    limit_failed: bool = false,
};

pub const CloneCtx = struct {
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
    // Generic tagged unions, parallel to the struct machinery: each concrete use
    // `Opt<u32>` monomorphizes to a distinct non-generic tagged union `Opt__u32`.
    generic_unions: *const std.StringHashMap(ast.UnionDecl),
    union_instances: *std.StringHashMap(*UnionInstance),
    union_list: *std.ArrayList(*UnionInstance),
    // Module-level integer `const`s, so a const can be used as a const-generic argument
    // (`Ring<u32, RQ_CAP>`), not just an integer literal.
    int_consts: *const std.StringHashMap(i128),
    // Field lookup for `field_type(T, .field)` when used as a `comptime T: type`
    // argument. This intentionally resolves only fields whose type is a named type,
    // matching the existing type-parameter substitution model.
    field_types: *const std.StringHashMap(std.StringHashMap(ast.TypeExpr)),
    // All top-level (and impl-method) function names. Used to resolve a trait-method
    // call written `T.method(recv, ...)` — after a `where T: Trait` substitution makes
    // the receiver type concrete (`Square.area(recv)`), this becomes a DIRECT call to
    // the desugared impl method `Square__area(recv)` (Tier 1: zero runtime dispatch).
    fn_names: *const std.StringHashMap(void),
    // Trait-bound checking at the instantiation site (Tier 1). `conformance` holds the
    // `(trait, concrete)` pairs with an `impl Trait for Concrete` (see ConformanceSet);
    // when a generic fn with `where T: Trait` is instantiated with a concrete `T`, an unmet bound is
    // E_TRAIT_NOT_SATISFIED reported at the call. Null reporter => no diagnostics (the
    // surviving trait_decl/impl_trait still let sema run its other trait checks).
    conformance: *const ConformanceSet,
    reporter: ?*diagnostics.Reporter,
    limits: Limits = .{},
    current_depth: usize = 0,
    limit_reported: bool = false,
    oom: bool = false,
};

pub fn transformReport(arena: std.mem.Allocator, module: ast.Module, reporter: ?*diagnostics.Reporter) !ast.Module {
    return transformReportOptions(arena, module, reporter, .{});
}

pub fn transformReportOptions(arena: std.mem.Allocator, module: ast.Module, reporter: ?*diagnostics.Reporter, options: Options) !ast.Module {
    var type_generic = std.StringHashMap(TypeGenericInfo).init(arena);
    var const_fns = std.StringHashMap(ast.FnDecl).init(arena);
    var generic_structs = std.StringHashMap(ast.StructDecl).init(arena);
    var generic_unions = std.StringHashMap(ast.UnionDecl).init(arena);
    var int_consts = std.StringHashMap(i128).init(arena);
    var field_types = std.StringHashMap(std.StringHashMap(ast.TypeExpr)).init(arena);
    var fn_names = std.StringHashMap(void).init(arena);
    var conformance = ConformanceSet.init(arena);
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl, .extern_fn => |fn_decl| {
                try fn_names.put(fn_decl.name.text, {});
            },
            .impl_trait => |it| {
                const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ it.trait_name.text, it.type_name.text });
                try conformance.put(key, {});
            },
            else => {},
        }
    }
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| {
                if (fn_decl.is_const and !const_fns.contains(fn_decl.name.text)) try const_fns.put(fn_decl.name.text, fn_decl);
                if (try typeGenericParams(arena, fn_decl)) |params| {
                    try type_generic.put(fn_decl.name.text, .{ .decl = fn_decl, .comptime_params = params, .attrs = decl.attrs });
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
            .union_decl => |u| {
                if (u.type_params.len > 0) try generic_unions.put(u.name.text, u);
                try collectUnionCaseTypes(arena, &field_types, u);
            },
            // Record integer module consts (folded against earlier ones), so they can be
            // used as const-generic arguments.
            .global_decl => |g| {
                if (g.is_const) {
                    if (g.init) |init_expr| {
                        if (try foldIntConst(&const_fns, &int_consts, init_expr)) |value| {
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
    if (type_generic.count() == 0 and generic_structs.count() == 0 and generic_unions.count() == 0) return module;

    var instances = std.StringHashMap(*Instance).init(arena);
    var struct_instances = std.StringHashMap(*StructInstance).init(arena);
    var union_instances = std.StringHashMap(*UnionInstance).init(arena);
    var inst_list: std.ArrayList(*Instance) = .empty;
    var struct_list: std.ArrayList(*StructInstance) = .empty;
    var union_list: std.ArrayList(*UnionInstance) = .empty;
    var rewriter = Rewriter{
        .arena = arena,
        .type_generic = &type_generic,
        .const_fns = &const_fns,
        .instances = &instances,
        .inst_list = &inst_list,
        .generic_structs = &generic_structs,
        .struct_instances = &struct_instances,
        .struct_list = &struct_list,
        .generic_unions = &generic_unions,
        .union_instances = &union_instances,
        .union_list = &union_list,
        .int_consts = &int_consts,
        .field_types = &field_types,
        .fn_names = &fn_names,
        .conformance = &conformance,
        .reporter = reporter,
        .limits = options.limits,
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
            .union_decl => |u| {
                if (u.type_params.len > 0) continue; // generic; replaced by instances
                try out.append(arena, .{ .span = decl.span, .attrs = decl.attrs, .kind = .{ .union_decl = try cloneUnionDeclCtx(&ctx, u) } });
            },
            .global_decl => |g| {
                const ty = if (g.ty) |t| try cloneType(&ctx, t) else null;
                const init = if (g.init) |init_expr| try cloneExprCtx(&ctx, init_expr) else null;
                try out.append(arena, .{ .span = decl.span, .attrs = decl.attrs, .kind = .{ .global_decl = .{ .name = g.name, .ty = ty, .init = init, .is_const = g.is_const } } });
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
            const saved_depth = rewriter.current_depth;
            rewriter.current_depth = inst.depth;
            defer rewriter.current_depth = saved_depth;
            var spec_ctx = CloneCtx{ .arena = arena, .subst = &inst.subst, .rewrite = &rewriter };
            var spec = if (inst.limit_failed) try cloneFnDeclSignatureCtx(&spec_ctx, inst.decl) else try cloneFnDeclCtx(&spec_ctx, inst.decl);
            spec.name = .{ .text = inst.mangled, .span = inst.decl.name.span };
            spec.params = try dropComptimeParams(arena, spec.params);
            // A bound-failed instantiation already reported E_TRAIT_NOT_SATISFIED; emit an
            // `unreachable`-only body so the call resolves but the real body (which would
            // reference a missing `Type__method`) cannot spill a deep-body cascade.
            if (inst.bound_failed or inst.limit_failed) spec.body = try unreachableBody(arena, inst.decl.name.span);
            try out.append(arena, .{ .span = inst.decl.name.span, .attrs = inst.attrs, .kind = .{ .fn_decl = spec } });
        }
    }
    if (rewriter.oom) return error.OutOfMemory;

    // Pass 2b: generate one concrete struct/tagged-union per instantiation. A field or
    // case-payload type may reference a further instantiation of either kind, appending
    // to struct_list/union_list; a single fixpoint loop drains both worklists (they can
    // cross-feed: a generic struct field of a generic-union type, and vice versa).
    {
        var si: usize = 0;
        var ui: usize = 0;
        while (si < struct_list.items.len or ui < union_list.items.len) {
            while (si < struct_list.items.len) : (si += 1) {
                const inst = struct_list.items[si];
                if (inst.generated) continue;
                inst.generated = true;
                const saved_depth = rewriter.current_depth;
                rewriter.current_depth = inst.depth;
                defer rewriter.current_depth = saved_depth;
                var sctx = CloneCtx{ .arena = arena, .subst = &inst.subst, .rewrite = &rewriter };
                var spec = if (inst.limit_failed) inst.decl else try cloneStructDeclCtx(&sctx, inst.decl);
                spec.name = .{ .text = inst.mangled, .span = inst.decl.name.span };
                spec.type_params = &.{};
                if (inst.limit_failed) spec.fields = &.{};
                try out.append(arena, .{ .span = inst.decl.name.span, .attrs = &.{}, .kind = .{ .struct_decl = spec } });
            }
            while (ui < union_list.items.len) : (ui += 1) {
                const inst = union_list.items[ui];
                if (inst.generated) continue;
                inst.generated = true;
                const saved_depth = rewriter.current_depth;
                rewriter.current_depth = inst.depth;
                defer rewriter.current_depth = saved_depth;
                var uctx = CloneCtx{ .arena = arena, .subst = &inst.subst, .rewrite = &rewriter };
                var spec = if (inst.limit_failed) inst.decl else try cloneUnionDeclCtx(&uctx, inst.decl);
                spec.name = .{ .text = inst.mangled, .span = inst.decl.name.span };
                spec.type_params = &.{};
                if (inst.limit_failed) spec.cases = &.{};
                try out.append(arena, .{ .span = inst.decl.name.span, .attrs = &.{}, .kind = .{ .union_decl = spec } });
            }
        }
    }
    if (rewriter.oom) return error.OutOfMemory;

    return .{ .decls = try out.toOwnedSlice(arena) };
}

// A `{ return unreachable; }` body for a bound-failed specialization. `unreachable`
// is a diverging expression in MC, so it type-checks as any return type.
fn unreachableBody(arena: std.mem.Allocator, span: ast.Span) !ast.Block {
    const unreachable_expr = ast.Expr{ .span = span, .kind = .{ .unreachable_expr = {} } };
    const items = try arena.alloc(ast.Stmt, 1);
    items[0] = .{ .span = span, .kind = .{ .@"return" = unreachable_expr } };
    return .{ .span = span, .items = items };
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

fn collectUnionCaseTypes(arena: std.mem.Allocator, out: *std.StringHashMap(std.StringHashMap(ast.TypeExpr)), union_decl: ast.UnionDecl) !void {
    if (out.contains(union_decl.name.text)) return;
    var map = std.StringHashMap(ast.TypeExpr).init(arena);
    for (union_decl.cases) |case| {
        const ty = case.ty orelse continue;
        if (!map.contains(case.name.text)) try map.put(case.name.text, ty);
    }
    try out.put(union_decl.name.text, map);
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

pub fn isTypeGenericFunction(fn_decl: ast.FnDecl) bool {
    for (fn_decl.params) |param| {
        if (!param.is_comptime) continue;
        if (fnTypeMentions(fn_decl, param.name.text)) return true;
    }
    return false;
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
        // A `*dyn Trait` erases the concrete type; it never mentions a comptime param.
        .dyn_trait => false,
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
        .block => |block| blockExprMentionsIdent(block, name),
        else => false,
    };
}

fn blockExprMentionsIdent(block: ast.Block, name: []const u8) bool {
    for (block.items) |stmt| {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| if (local.init) |expr| {
                if (exprMentionsIdent(expr, name)) return true;
            },
            .loop => |loop| {
                if (loop.iterable) |expr| if (exprMentionsIdent(expr, name)) return true;
                if (blockExprMentionsIdent(loop.body, name)) return true;
            },
            .block, .unsafe_block, .comptime_block => |inner| if (blockExprMentionsIdent(inner, name)) return true,
            .contract_block => |node| if (blockExprMentionsIdent(node.block, name)) return true,
            .if_let => |node| {
                if (exprMentionsIdent(node.value, name)) return true;
                if (blockExprMentionsIdent(node.then_block, name)) return true;
                if (node.else_block) |inner| if (blockExprMentionsIdent(inner, name)) return true;
            },
            .@"switch" => |node| {
                if (exprMentionsIdent(node.subject, name)) return true;
                for (node.arms) |arm| {
                    for (arm.patterns) |pattern| {
                        if (pattern.kind == .literal and exprMentionsIdent(pattern.kind.literal, name)) return true;
                    }
                    switch (arm.body) {
                        .block => |inner| if (blockExprMentionsIdent(inner, name)) return true,
                        .expr => |expr| if (exprMentionsIdent(expr, name)) return true,
                    }
                }
            },
            .@"return" => |maybe| if (maybe) |expr| {
                if (exprMentionsIdent(expr, name)) return true;
            },
            .@"defer", .assert, .expr => |expr| if (exprMentionsIdent(expr, name)) return true,
            .assignment => |node| {
                if (exprMentionsIdent(node.target, name) or exprMentionsIdent(node.value, name)) return true;
            },
            else => {},
        }
    }
    return false;
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

fn cloneFnDeclCtx(ctx: *const CloneCtx, fn_decl: ast.FnDecl) !ast.FnDecl {
    var out = try cloneFnDeclSignatureCtx(ctx, fn_decl);
    out.body = if (fn_decl.body) |body| try cloneBlock(ctx, body) else null;
    return out;
}

fn cloneFnDeclSignatureCtx(ctx: *const CloneCtx, fn_decl: ast.FnDecl) !ast.FnDecl {
    var params = try ctx.arena.alloc(ast.Param, fn_decl.params.len);
    for (fn_decl.params, 0..) |param, i| {
        params[i] = .{ .name = param.name, .ty = try cloneType(ctx, param.ty), .is_comptime = param.is_comptime };
    }
    return .{
        .name = fn_decl.name,
        .abi = fn_decl.abi,
        .params = params,
        .return_type = if (fn_decl.return_type) |ty| try cloneType(ctx, ty) else null,
        .body = null,
        .is_const = fn_decl.is_const,
        .exported = fn_decl.exported,
        // Preserve the C-ABI variadic marker + trait bounds across cloning; dropping
        // is_variadic silently turned `snprintf(..., ...)` into a fixed-arity function.
        .is_variadic = fn_decl.is_variadic,
        .bounds = fn_decl.bounds,
        .is_async = fn_decl.is_async,
    };
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
        // `await` is normally eliminated by the async transform before monomorphize; clone it
        // total-ly anyway so the cloner stays correct if the ordering ever changes.
        .await_expr => |inner| .{ .await_expr = try clonePtr(ctx, inner.*) },
        .member => |node| .{ .member = .{ .base = try clonePtr(ctx, node.base.*), .name = node.name } },
        .index => |node| .{ .index = .{ .base = try clonePtr(ctx, node.base.*), .index = try clonePtr(ctx, node.index.*) } },
        .slice => |node| .{ .slice = .{ .base = try clonePtr(ctx, node.base.*), .start = try clonePtr(ctx, node.start.*), .end = try clonePtr(ctx, node.end.*) } },
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
    // Clone the callee (applying any `where T: Trait` substitution, so a generic-typed
    // receiver `T.method` becomes the concrete `Square.method`).
    const cloned_callee = try clonePtr(ctx, node.callee.*);
    // Tier 1 trait-method resolution: a member-callee `Concrete.method` whose desugared
    // impl function `Concrete__method` exists becomes a DIRECT call to that function.
    // This completes the `Owner.member` resolution for the case where the owner was a
    // generic type parameter (so the parser could not pre-resolve it). No vtable.
    if (ctx.rewrite) |rw| {
        if (memberCalleeDirect(rw, cloned_callee.*)) |mangled| {
            const callee = try ast.makePtr(rw.arena, ast.Expr{ .span = cloned_callee.span, .kind = .{ .ident = .{ .text = mangled, .span = cloned_callee.span } } });
            return .{ .span = expr.span, .kind = .{ .call = .{
                .callee = callee,
                .type_args = try cloneTypeSlice(ctx, node.type_args),
                .args = try cloneExprSlice(ctx, node.args),
            } } };
        }
    }
    return .{ .span = expr.span, .kind = .{ .call = .{
        .callee = cloned_callee,
        .type_args = try cloneTypeSlice(ctx, node.type_args),
        .args = try cloneExprSlice(ctx, node.args),
    } } };
}

// If `callee` is a member access `Concrete.method` on a bare type-name identifier and
// the desugared impl method `Concrete__method` is a known function, return that mangled
// name; otherwise null. Used to lower a Tier-1 trait-method call to a direct call.
fn memberCalleeDirect(rw: *Rewriter, callee: ast.Expr) ?[]const u8 {
    const m = switch (callee.kind) {
        .member => |node| node,
        .grouped => |inner| return memberCalleeDirect(rw, inner.*),
        else => return null,
    };
    const owner = switch (m.base.*.kind) {
        .ident => |id| id.text,
        else => return null,
    };
    const mangled = std.fmt.allocPrint(rw.arena, "{s}__{s}", .{ owner, m.name.text }) catch {
        rw.oom = true;
        return null;
    };
    if (rw.fn_names.contains(mangled)) return mangled;
    return null;
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
    // Tier 1 bound satisfaction (checked at the instantiation site): each `where
    // P: Trait` requires an `impl Trait for <subst(P)>`. An unmet bound names the type
    // and trait — not a deep-body failure (cf. Zig comptime duck typing). On failure we
    // report E_TRAIT_NOT_SATISFIED at the call and DO NOT instantiate (returning null
    // leaves the original call, which then resolves to E_UNKNOWN_FUNCTION on the SAME
    // line) — so a non-conforming instantiation never spills a cascade of deep-body
    // "unknown method" errors.
    var bound_failed = false;
    if (rw.reporter) |reporter| {
        for (info.decl.bounds) |bound| {
            const concrete = switch (subst.get(bound.type_param.text) orelse continue) {
                .type_name => |tn| tn,
                .int => continue,
            };
            var key_buf: [512]u8 = undefined;
            const conforms = rw.conformance.contains(conformanceKey(rw.arena, &key_buf, bound.trait_name.text, concrete));
            if (!conforms) {
                bound_failed = true;
                reporter.err(node.callee.*.span, "{s}: {s}", .{
                    "E_TRAIT_NOT_SATISFIED",
                    std.fmt.allocPrint(rw.arena, "type '{s}' does not satisfy the bound '{s}: {s}' (no `impl {s} for {s}`)", .{ concrete, bound.type_param.text, bound.trait_name.text, bound.trait_name.text, concrete }) catch "trait bound not satisfied",
                });
            }
        }
    }
    const mangled_name = try mangled.toOwnedSlice(rw.arena);
    if (!rw.instances.contains(mangled_name)) {
        const depth = rw.current_depth + 1;
        const limit_failed = !admitInstance(rw, node.callee.*.span, depth);
        const inst = rw.arena.create(Instance) catch {
            rw.oom = true;
            return null;
        };
        inst.* = .{
            .decl = info.decl,
            .subst = subst,
            .mangled = mangled_name,
            .attrs = info.attrs,
            .depth = depth,
            .bound_failed = bound_failed,
            .limit_failed = limit_failed,
        };
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

fn admitInstance(rw: *Rewriter, span: ast.Span, depth: usize) bool {
    if (depth > rw.limits.max_depth) {
        reportMonomorphizationLimit(rw, span, "instantiation depth", depth, rw.limits.max_depth);
        return false;
    }
    const total = rw.instances.count() + rw.struct_instances.count() + rw.union_instances.count();
    if (total >= rw.limits.max_instances) {
        reportMonomorphizationLimit(rw, span, "total specialization count", total + 1, rw.limits.max_instances);
        return false;
    }
    return true;
}

fn reportMonomorphizationLimit(rw: *Rewriter, span: ast.Span, kind: []const u8, actual: usize, limit: usize) void {
    if (rw.limit_reported) return;
    rw.limit_reported = true;
    if (rw.reporter) |reporter| {
        reporter.err(span, "{s}: {s}", .{
            "E_MONOMORPHIZATION_LIMIT",
            std.fmt.allocPrint(
                rw.arena,
                "monomorphization exceeded {s} ({d} > {d}); possible polymorphic recursion or specialization explosion",
                .{ kind, actual, limit },
            ) catch "monomorphization limit exceeded",
        });
    }
}

fn foldConst(rw: *Rewriter, expr: ast.Expr) ?i128 {
    return foldIntConst(rw.const_fns, rw.int_consts, expr) catch {
        rw.oom = true;
        return null;
    };
}

// Fold `expr` to an integer at comptime, resolving module const-fn calls and integer
// module consts (so a `const` can stand in for an integer literal, e.g. as a const-
// generic argument). Returns null if it isn't a comptime integer.
fn foldIntConst(
    const_fns: *const std.StringHashMap(ast.FnDecl),
    int_consts: *const std.StringHashMap(i128),
    expr: ast.Expr,
) std.mem.Allocator.Error!?i128 {
    var fb_arena: ?std.heap.ArenaAllocator = null;
    defer if (fb_arena) |*a| a.deinit();
    const fold_alloc = eval.tryFoldScratch() orelse blk: {
        fb_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        break :blk fb_arena.?.allocator();
    };
    defer if (fb_arena == null) eval.releaseFoldScratch();
    var scope = eval.ComptimeScope.init(fold_alloc);
    scope.funcs = const_fns;
    var it = int_consts.iterator();
    while (it.next()) |entry| {
        try scope.bind(entry.key_ptr.*, .{ .int = entry.value_ptr.* });
    }
    const folded = eval.foldComptimeExpr(&scope, expr);
    if (scope.hasOom()) return error.OutOfMemory;
    return switch (folded) {
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
                if (rw.generic_unions.get(node.base.text)) |ud| {
                    if (try rewriteGenericUnion(ctx, rw, ud, node)) |name| break :blk ast.TypeExpr.Kind{ .name = .{ .text = name, .span = node.base.span } };
                }
            }
            break :blk .{ .generic = .{ .base = node.base, .args = try cloneTypeSlice(ctx, node.args) } };
        },
        .fn_pointer => |node| .{ .fn_pointer = .{ .params = try cloneTypeSlice(ctx, node.params), .ret = try cloneTypePtr(ctx, node.ret.*) } },
        .closure_type => |node| .{ .closure_type = .{ .params = try cloneTypeSlice(ctx, node.params), .ret = try cloneTypePtr(ctx, node.ret.*) } },
        // `*dyn Trait` carries no substitutable type argument; clone verbatim.
        .dyn_trait => ty.kind,
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

// Compute the mangled concrete name and type-parameter substitution for a use of a
// generic declaration `Base<Arg, …>` (shared by generic structs and generic tagged
// unions). Returns null if the argument count is wrong or an argument is not a concrete
// type name / const-generic value (the use is left generic for sema to diagnose).
const InstantiationKey = struct {
    name: []const u8,
    subst: Subst,
};
fn instantiateGeneric(ctx: *const CloneCtx, rw: *Rewriter, base: []const u8, type_params: []const ast.Ident, node: anytype) anyerror!?InstantiationKey {
    if (node.args.len != type_params.len) return null;
    var subst = Subst.init(rw.arena);
    var mangled: std.ArrayList(u8) = .empty;
    try mangled.appendSlice(rw.arena, base);
    for (type_params, node.args) |param, arg| {
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
    return .{ .name = try mangled.toOwnedSlice(rw.arena), .subst = subst };
}

fn rewriteGenericStruct(ctx: *const CloneCtx, rw: *Rewriter, sd: ast.StructDecl, node: anytype) anyerror!?[]const u8 {
    const key = (try instantiateGeneric(ctx, rw, sd.name.text, sd.type_params, node)) orelse return null;
    if (!rw.struct_instances.contains(key.name)) {
        const depth = rw.current_depth + 1;
        const limit_failed = !admitInstance(rw, node.base.span, depth);
        const si = rw.arena.create(StructInstance) catch {
            rw.oom = true;
            return key.name;
        };
        si.* = .{ .decl = sd, .subst = key.subst, .mangled = key.name, .depth = depth, .limit_failed = limit_failed };
        rw.struct_instances.put(key.name, si) catch {
            rw.oom = true;
        };
        rw.struct_list.append(rw.arena, si) catch {
            rw.oom = true;
        };
    }
    return key.name;
}

// Collect (if new) and name the monomorphization of a generic tagged-union use
// `Opt<u32>` → `Opt__u32`, mirroring rewriteGenericStruct.
fn rewriteGenericUnion(ctx: *const CloneCtx, rw: *Rewriter, ud: ast.UnionDecl, node: anytype) anyerror!?[]const u8 {
    const key = (try instantiateGeneric(ctx, rw, ud.name.text, ud.type_params, node)) orelse return null;
    if (!rw.union_instances.contains(key.name)) {
        const depth = rw.current_depth + 1;
        const limit_failed = !admitInstance(rw, node.base.span, depth);
        const ui = rw.arena.create(UnionInstance) catch {
            rw.oom = true;
            return key.name;
        };
        ui.* = .{ .decl = ud, .subst = key.subst, .mangled = key.name, .depth = depth, .limit_failed = limit_failed };
        rw.union_instances.put(key.name, ui) catch {
            rw.oom = true;
        };
        rw.union_list.append(rw.arena, ui) catch {
            rw.oom = true;
        };
    }
    return key.name;
}

fn cloneStructDeclCtx(ctx: *const CloneCtx, sd: ast.StructDecl) anyerror!ast.StructDecl {
    var fields = try ctx.arena.alloc(ast.Field, sd.fields.len);
    for (sd.fields, 0..) |field, i| {
        fields[i] = .{ .name = field.name, .ty = try cloneType(ctx, field.ty), .offset = field.offset };
    }
    return .{ .name = sd.name, .abi = sd.abi, .fields = fields, .type_params = sd.type_params, .is_move = sd.is_move, .is_opaque = sd.is_opaque, .is_c_union = sd.is_c_union };
}

fn cloneUnionDeclCtx(ctx: *const CloneCtx, ud: ast.UnionDecl) anyerror!ast.UnionDecl {
    var cases = try ctx.arena.alloc(ast.UnionCase, ud.cases.len);
    for (ud.cases, 0..) |case, i| {
        // Substitute a case payload type (`some: T` → `some: u32`); payload-less
        // cases (`none`) carry a null type and pass through unchanged.
        cases[i] = .{ .name = case.name, .ty = if (case.ty) |ty| try cloneType(ctx, ty) else null };
    }
    return .{ .name = ud.name, .cases = cases, .type_params = ud.type_params };
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
            .patterns = try clonePatterns(ctx, arm.patterns),
            .body = switch (arm.body) {
                .block => |b| .{ .block = try cloneBlock(ctx, b) },
                .expr => |e| .{ .expr = try cloneExprCtx(ctx, e) },
            },
            // Preserve the async-lowering flag (set pre-monomorphize by async_lower) so a generic async
            // fn's switch keeps its bare-`.bind` shadow check through instantiation — monomorphize runs
            // between async_lower and sema, so dropping it here would re-mask the collision sema relies
            // on. Holds the "every SwitchArm rebuild preserves dup_local_if_binds" invariant.
            .dup_local_if_binds = arm.dup_local_if_binds,
        };
    }
    return .{ .subject = try cloneExprCtx(ctx, node.subject), .arms = arms };
}

fn clonePatterns(ctx: *const CloneCtx, patterns: []const ast.Pattern) anyerror![]ast.Pattern {
    var out = try ctx.arena.alloc(ast.Pattern, patterns.len);
    for (patterns, 0..) |pattern, i| {
        out[i] = .{
            .span = pattern.span,
            .kind = switch (pattern.kind) {
                .literal => |expr| .{ .literal = try cloneExprCtx(ctx, expr) },
                else => pattern.kind,
            },
        };
    }
    return out;
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
