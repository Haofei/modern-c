// `mcc symbols <file>` — a JSON symbol index for the language server.
//
// Walks the parsed AST and resolves every identifier occurrence by lexical scope (params and
// locals in the enclosing function, then module-level functions/globals/types), emitting
// `defs` (every declaration: functions, globals, params, locals, types, with a stringified
// type), `refs` (every identifier use, with the span of the declaration it resolves to), and
// `fields` (aggregate fields keyed by owning type). The language server turns this into
// go-to-definition, find-references, document-highlight, rename, hover, semantic tokens, and
// completion — all from one CLI call.
//
// This is a deliberately self-contained best-effort pass: it does not perturb sema and does
// not do full type inference. An identifier that does not resolve (a builtin or an inferred
// local's exact type) is simply omitted or typed `"?"` — the worst case is "no navigation
// here", never a wrong jump. Types come from the declared `TypeExpr`.

const std = @import("std");
const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");

const Span = diagnostics.Span;

const DefInfo = struct {
    span: Span,
    kind: []const u8,
    ty: []const u8,
};

const Def = struct {
    name: []const u8,
    kind: []const u8,
    ty: []const u8,
    span: Span,
};

const Ref = struct {
    name: []const u8,
    kind: []const u8,
    ty: []const u8,
    span: Span,
    def: Span,
};

const FieldInfo = struct {
    owner: []const u8,
    owner_kind: []const u8,
    name: []const u8,
    ty: []const u8,
    span: Span,
};

const Local = struct {
    name: []const u8,
    info: DefInfo,
};

const Builder = struct {
    arena: std.mem.Allocator,
    globals: std.StringHashMap(DefInfo),
    defs: std.ArrayList(Def),
    refs: std.ArrayList(Ref),
    fields: std.ArrayList(FieldInfo),
    frames: std.ArrayList(std.ArrayList(Local)),

    fn addDef(self: *Builder, name: ast.Ident, kind: []const u8, ty: []const u8) !void {
        try self.defs.append(self.arena, .{ .name = name.text, .kind = kind, .ty = ty, .span = name.span });
    }

    fn addField(self: *Builder, owner: ast.Ident, owner_kind: []const u8, field: ast.Field) !void {
        const ty = try renderType(self.arena, field.ty);
        try self.fields.append(self.arena, .{
            .owner = owner.text,
            .owner_kind = owner_kind,
            .name = field.name.text,
            .ty = ty,
            .span = field.name.span,
        });
    }

    fn resolve(self: *Builder, name: []const u8) ?DefInfo {
        var i = self.frames.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.frames.items[i];
            var j = frame.items.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, frame.items[j].name, name)) return frame.items[j].info;
            }
        }
        return self.globals.get(name);
    }

    fn addRef(self: *Builder, name: ast.Ident) !void {
        const info = self.resolve(name.text) orelse return;
        try self.refs.append(self.arena, .{
            .name = name.text,
            .kind = info.kind,
            .ty = info.ty,
            .span = name.span,
            .def = info.span,
        });
    }

    fn pushFrame(self: *Builder) !void {
        try self.frames.append(self.arena, .empty);
    }

    fn popFrame(self: *Builder) void {
        _ = self.frames.pop();
    }

    // Declare a local/param in the current (innermost) frame and emit its definition.
    fn bindLocal(self: *Builder, name: ast.Ident, kind: []const u8, ty: []const u8) !void {
        try self.addDef(name, kind, ty);
        const top = &self.frames.items[self.frames.items.len - 1];
        try top.append(self.arena, .{ .name = name.text, .info = .{ .span = name.span, .kind = kind, .ty = ty } });
    }
};

// ----- type rendering -----------------------------------------------------------------------

fn writeMut(buf: *std.ArrayList(u8), a: std.mem.Allocator, m: ast.Mutability) !void {
    switch (m) {
        .mut => try buf.appendSlice(a, "mut "),
        .@"const" => try buf.appendSlice(a, "const "),
        .none => {},
    }
}

fn writeLen(buf: *std.ArrayList(u8), a: std.mem.Allocator, len: ast.Expr) !void {
    switch (len.kind) {
        .int_literal => |t| try buf.appendSlice(a, t),
        .ident => |id| try buf.appendSlice(a, id.text),
        else => try buf.append(a, '_'),
    }
}

fn writeType(buf: *std.ArrayList(u8), a: std.mem.Allocator, ty: ast.TypeExpr) error{OutOfMemory}!void {
    switch (ty.kind) {
        .name => |n| try buf.appendSlice(a, n.text),
        .enum_literal => |n| {
            try buf.append(a, '.');
            try buf.appendSlice(a, n.text);
        },
        .member => |m| {
            try writeType(buf, a, m.base.*);
            try buf.append(a, '.');
            try buf.appendSlice(a, m.field.text);
        },
        .nullable => |c| {
            try buf.append(a, '?');
            try writeType(buf, a, c.*);
        },
        .qualified => |q| {
            try writeMut(buf, a, q.mutability);
            try writeType(buf, a, q.child.*);
        },
        .pointer => |p| {
            try buf.append(a, '*');
            try writeMut(buf, a, p.mutability);
            try writeType(buf, a, p.child.*);
        },
        .raw_many_pointer => |p| {
            try buf.appendSlice(a, "[*]");
            try writeMut(buf, a, p.mutability);
            try writeType(buf, a, p.child.*);
        },
        .slice => |p| {
            try buf.appendSlice(a, "[]");
            try writeMut(buf, a, p.mutability);
            try writeType(buf, a, p.child.*);
        },
        .array => |arr| {
            try buf.append(a, '[');
            try writeLen(buf, a, arr.len);
            try buf.append(a, ']');
            try writeType(buf, a, arr.child.*);
        },
        .generic => |g| {
            try buf.appendSlice(a, g.base.text);
            try buf.append(a, '<');
            for (g.args, 0..) |arg, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try writeType(buf, a, arg);
            }
            try buf.append(a, '>');
        },
        .fn_pointer => |f| {
            try buf.appendSlice(a, "fn(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try writeType(buf, a, p);
            }
            try buf.appendSlice(a, ") -> ");
            try writeType(buf, a, f.ret.*);
        },
        .closure_type => |f| {
            try buf.appendSlice(a, "closure(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(a, ", ");
                try writeType(buf, a, p);
            }
            try buf.appendSlice(a, ") -> ");
            try writeType(buf, a, f.ret.*);
        },
        .dyn_trait => |d| {
            try buf.appendSlice(a, if (d.mutability == .mut) "*mut dyn " else "*dyn ");
            try buf.appendSlice(a, d.trait_name.text);
        },
    }
}

fn renderType(a: std.mem.Allocator, ty: ast.TypeExpr) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try writeType(&buf, a, ty);
    return buf.toOwnedSlice(a);
}

fn renderTypeOpt(a: std.mem.Allocator, ty: ?ast.TypeExpr) ![]const u8 {
    return if (ty) |t| renderType(a, t) else "?";
}

fn renderFnType(a: std.mem.Allocator, f: ast.FnDecl) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a, "fn(");
    for (f.params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(a, ", ");
        try writeType(&buf, a, p.ty);
    }
    try buf.appendSlice(a, ") -> ");
    if (f.return_type) |rt| try writeType(&buf, a, rt) else try buf.appendSlice(a, "void");
    return buf.toOwnedSlice(a);
}

// ----- walking ------------------------------------------------------------------------------

// Emit a reference for a named type that resolves to a module-level type definition (so
// go-to-definition works on type names). Builtins (u32, bool, …) are not in `globals` and are
// silently skipped.
fn walkTypeRefs(b: *Builder, ty: ast.TypeExpr) error{OutOfMemory}!void {
    switch (ty.kind) {
        .name => |n| try b.addRef(n),
        .enum_literal => {},
        .member => |m| try walkTypeRefs(b, m.base.*),
        .nullable => |c| try walkTypeRefs(b, c.*),
        .qualified => |q| try walkTypeRefs(b, q.child.*),
        .pointer => |p| try walkTypeRefs(b, p.child.*),
        .raw_many_pointer => |p| try walkTypeRefs(b, p.child.*),
        .slice => |p| try walkTypeRefs(b, p.child.*),
        .array => |arr| try walkTypeRefs(b, arr.child.*),
        .generic => |g| {
            try b.addRef(g.base);
            for (g.args) |arg| try walkTypeRefs(b, arg);
        },
        .fn_pointer => |f| {
            for (f.params) |p| try walkTypeRefs(b, p);
            try walkTypeRefs(b, f.ret.*);
        },
        .closure_type => |f| {
            for (f.params) |p| try walkTypeRefs(b, p);
            try walkTypeRefs(b, f.ret.*);
        },
        // `*dyn Trait` references the trait name (go-to-definition on the trait).
        .dyn_trait => |d| try b.addRef(d.trait_name),
    }
}

fn walkExpr(b: *Builder, expr: ast.Expr) error{OutOfMemory}!void {
    switch (expr.kind) {
        .ident => |id| try b.addRef(id),
        .grouped => |e| try walkExpr(b, e.*),
        .unary => |u| try walkExpr(b, u.expr.*),
        .binary => |bin| {
            try walkExpr(b, bin.left.*);
            try walkExpr(b, bin.right.*);
        },
        .cast => |c| {
            try walkExpr(b, c.value.*);
            try walkTypeRefs(b, c.ty.*);
        },
        .address_of => |e| try walkExpr(b, e.*),
        .call => |c| {
            try walkExpr(b, c.callee.*);
            for (c.type_args) |t| try walkTypeRefs(b, t);
            for (c.args) |arg| try walkExpr(b, arg);
        },
        .index => |idx| {
            try walkExpr(b, idx.base.*);
            try walkExpr(b, idx.index.*);
        },
        .slice => |s| {
            try walkExpr(b, s.base.*);
            try walkExpr(b, s.start.*);
            try walkExpr(b, s.end.*);
        },
        .deref => |e| try walkExpr(b, e.*),
        .member => |m| try walkExpr(b, m.base.*), // base resolves; the field name does not (yet)
        .try_expr => |t| {
            try walkExpr(b, t.operand.*);
            if (t.mapped) |m| try walkExpr(b, m.*);
        },
        .array_literal => |items| for (items) |e| try walkExpr(b, e),
        .struct_literal => |fields| for (fields) |f| try walkExpr(b, f.value),
        .block => |blk| try walkBlock(b, blk),
        else => {}, // literals, enum_literal, etc.
    }
}

fn bindPattern(b: *Builder, pat: ast.Pattern) error{OutOfMemory}!void {
    switch (pat.kind) {
        .bind => |id| try b.bindLocal(id, "local", "?"),
        .tag_bind => |tb| try b.bindLocal(tb.binding, "local", "?"),
        .literal => |e| try walkExpr(b, e),
        .tag, .wildcard => {},
    }
}

fn walkStmt(b: *Builder, stmt: ast.Stmt) error{OutOfMemory}!void {
    switch (stmt.kind) {
        .let_decl, .var_decl => |d| {
            if (d.init) |init| try walkExpr(b, init);
            if (d.ty) |t| try walkTypeRefs(b, t);
            const ty = try renderTypeOpt(b.arena, d.ty);
            const kind: []const u8 = if (stmt.kind == .let_decl) "local" else "local_mut";
            for (d.names) |name| try b.bindLocal(name, kind, ty);
        },
        .loop => |l| {
            if (l.iterable) |it| try walkExpr(b, it);
            try walkBlock(b, l.body);
        },
        .if_let => |il| {
            try walkExpr(b, il.value);
            try b.pushFrame();
            try bindPattern(b, il.pattern);
            try walkBlock(b, il.then_block);
            b.popFrame();
            if (il.else_block) |eb| try walkBlock(b, eb);
        },
        .@"switch" => |sw| {
            try walkExpr(b, sw.subject);
            for (sw.arms) |arm| {
                try b.pushFrame();
                for (arm.patterns) |p| try bindPattern(b, p);
                switch (arm.body) {
                    .block => |blk| try walkBlock(b, blk),
                    .expr => |e| try walkExpr(b, e),
                }
                b.popFrame();
            }
        },
        .unsafe_block, .comptime_block, .block => |blk| try walkBlock(b, blk),
        .contract_block => |cb| try walkBlock(b, cb.block),
        .asm_stmt => |a| for (a.inputs) |in| try walkExpr(b, in.value),
        .@"return" => |maybe| if (maybe) |e| try walkExpr(b, e),
        .@"defer" => |e| try walkExpr(b, e),
        .assert => |e| try walkExpr(b, e),
        .assignment => |asn| {
            try walkExpr(b, asn.target);
            try walkExpr(b, asn.value);
        },
        .expr => |e| try walkExpr(b, e),
        .@"break", .@"continue" => {},
    }
}

fn walkBlock(b: *Builder, block: ast.Block) error{OutOfMemory}!void {
    try b.pushFrame();
    for (block.items) |stmt| try walkStmt(b, stmt);
    b.popFrame();
}

// Pass 1: every module-level declaration becomes a `def` and goes into the resolution map.
fn collectDecl(b: *Builder, decl: ast.Decl) !void {
    switch (decl.kind) {
        .fn_decl, .extern_fn => |f| {
            const ty = try renderFnType(b.arena, f);
            try b.addDef(f.name, "function", ty);
            try b.globals.put(f.name.text, .{ .span = f.name.span, .kind = "function", .ty = ty });
        },
        .global_decl => |g| {
            const ty = try renderTypeOpt(b.arena, g.ty);
            const kind: []const u8 = if (g.is_const) "constant" else "global";
            try b.addDef(g.name, kind, ty);
            try b.globals.put(g.name.text, .{ .span = g.name.span, .kind = kind, .ty = ty });
        },
        .type_alias => |t| {
            const ty = try renderType(b.arena, t.ty);
            try b.addDef(t.name, "type_alias", ty);
            try b.globals.put(t.name.text, .{ .span = t.name.span, .kind = "type_alias", .ty = ty });
        },
        .struct_decl => |s| {
            try collectType(b, s.name, "struct");
            if (!s.is_opaque) try collectFields(b, s.name, "struct", s.fields);
        },
        .enum_decl => |e| try collectType(b, e.name, "enum"),
        .union_decl => |u| try collectType(b, u.name, "union"),
        .packed_bits_decl => |p| {
            try collectType(b, p.name, "packed_bits");
            try collectFields(b, p.name, "packed_bits", p.fields);
        },
        .overlay_union_decl => |o| {
            try collectType(b, o.name, "overlay_union");
            try collectFields(b, o.name, "overlay_union", o.fields);
        },
        .opaque_decl => |n| try collectType(b, n, "opaque"),
        // Trait / impl-trait declarations carry no backend symbol of their own: the
        // trait is a signature set, and an `impl Trait for Type` desugars its methods
        // to `Type__m` fn_decls (collected above). The conformance record is sema-only.
        .trait_decl => |t| try collectType(b, t.name, "trait"),
        .impl_trait => {},
    }
}

fn collectType(b: *Builder, name: ast.Ident, kind: []const u8) !void {
    try b.addDef(name, kind, kind);
    try b.globals.put(name.text, .{ .span = name.span, .kind = kind, .ty = kind });
}

fn collectFields(b: *Builder, owner: ast.Ident, owner_kind: []const u8, fields: []const ast.Field) !void {
    for (fields) |field| try b.addField(owner, owner_kind, field);
}

// Pass 2: walk each declaration's body and type references, emitting param/local defs + refs.
fn walkDeclBody(b: *Builder, decl: ast.Decl) !void {
    switch (decl.kind) {
        .fn_decl, .extern_fn => |f| {
            try b.pushFrame();
            for (f.params) |p| {
                const ty = try renderType(b.arena, p.ty);
                try b.bindLocal(p.name, "param", ty);
                try walkTypeRefs(b, p.ty);
            }
            if (f.return_type) |rt| try walkTypeRefs(b, rt);
            if (f.body) |body| try walkBlock(b, body);
            b.popFrame();
        },
        .global_decl => |g| {
            if (g.ty) |t| try walkTypeRefs(b, t);
            if (g.init) |init| {
                try b.pushFrame();
                try walkExpr(b, init);
                b.popFrame();
            }
        },
        .type_alias => |t| try walkTypeRefs(b, t.ty),
        .struct_decl => |s| for (s.fields) |fld| try walkTypeRefs(b, fld.ty),
        .packed_bits_decl => |p| {
            try walkTypeRefs(b, p.repr);
            for (p.fields) |fld| try walkTypeRefs(b, fld.ty);
        },
        .overlay_union_decl => |o| for (o.fields) |fld| try walkTypeRefs(b, fld.ty),
        .union_decl => |u| for (u.cases) |c| {
            if (c.ty) |t| try walkTypeRefs(b, t);
        },
        .enum_decl => |e| if (e.repr) |r| try walkTypeRefs(b, r),
        .opaque_decl => {},
        .trait_decl => |t| for (t.methods) |m| {
            for (m.params) |p| try walkTypeRefs(b, p.ty);
            if (m.return_type) |rt| try walkTypeRefs(b, rt);
        },
        .impl_trait => {},
    }
}

// ----- JSON serialization -------------------------------------------------------------------

fn writeJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\t' => try out.appendSlice(a, "\\t"),
            '\r' => try out.appendSlice(a, "\\r"),
            else => try out.append(a, c),
        }
    }
    try out.append(a, '"');
}

pub fn emitJson(allocator: std.mem.Allocator, module: ast.Module, out: *std.ArrayList(u8)) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var b = Builder{
        .arena = a,
        .globals = std.StringHashMap(DefInfo).init(a),
        .defs = .empty,
        .refs = .empty,
        .fields = .empty,
        .frames = .empty,
    };

    for (module.decls) |decl| try collectDecl(&b, decl);
    for (module.decls) |decl| try walkDeclBody(&b, decl);

    const w = struct {
        fn span(o: *std.ArrayList(u8), al: std.mem.Allocator, s: Span) !void {
            try o.print(al, "{{\"line\":{d},\"col\":{d},\"len\":{d}}}", .{ s.line, s.column, s.len });
        }
    };

    try out.appendSlice(allocator, "{\"defs\":[");
    for (b.defs.items, 0..) |d, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"name\":");
        try writeJsonString(out, allocator, d.name);
        try out.appendSlice(allocator, ",\"kind\":");
        try writeJsonString(out, allocator, d.kind);
        try out.appendSlice(allocator, ",\"type\":");
        try writeJsonString(out, allocator, d.ty);
        try out.appendSlice(allocator, ",\"span\":");
        try w.span(out, allocator, d.span);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"refs\":[");
    for (b.refs.items, 0..) |r, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"name\":");
        try writeJsonString(out, allocator, r.name);
        try out.appendSlice(allocator, ",\"kind\":");
        try writeJsonString(out, allocator, r.kind);
        try out.appendSlice(allocator, ",\"type\":");
        try writeJsonString(out, allocator, r.ty);
        try out.appendSlice(allocator, ",\"span\":");
        try w.span(out, allocator, r.span);
        try out.appendSlice(allocator, ",\"def\":");
        try w.span(out, allocator, r.def);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"fields\":[");
    for (b.fields.items, 0..) |f, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"owner\":");
        try writeJsonString(out, allocator, f.owner);
        try out.appendSlice(allocator, ",\"owner_kind\":");
        try writeJsonString(out, allocator, f.owner_kind);
        try out.appendSlice(allocator, ",\"name\":");
        try writeJsonString(out, allocator, f.name);
        try out.appendSlice(allocator, ",\"type\":");
        try writeJsonString(out, allocator, f.ty);
        try out.appendSlice(allocator, ",\"span\":");
        try w.span(out, allocator, f.span);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "]}\n");
}
