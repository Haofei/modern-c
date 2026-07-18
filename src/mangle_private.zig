//! G22 — file-private symbol uniquification.
//!
//! MC flattens every imported file into one translation unit (the loader concatenates
//! sources), so all top-level names share ONE namespace. §30 module visibility makes a
//! file's non-`pub` top-level items file-private, but the DUPLICATE-declaration check and
//! the flat name→symbol resolution are still global: two file-private helpers with the same
//! name in DIFFERENT files collide (`E_DUPLICATE_DECLARATION`) even though neither is visible
//! to the other.
//!
//! This pass completes the §30 model. Run pre-sema (after async-lower / monomorphize), it
//! finds every name that is defined ONLY by file-private, value-level (fn/global) decls in
//! two-or-more distinct files, and rewrites each such decl — plus its file-local references —
//! to a per-file-unique mangled name (`name__mcpN`, N = origin-file index). After this pass:
//!   * two file-private `advance`s become `advance__mcp1` / `advance__mcp2` — no collision,
//!     each file's references bind to its own copy in BOTH backends (distinct C/LLVM symbols);
//!   * `pub`/`export`/`extern` names keep their exact spelling (ABI preserved);
//!   * two `pub` same-name decls, or two file-private same-name decls in the SAME file, are
//!     left untouched so sema still reports `E_DUPLICATE_DECLARATION`;
//!   * a file-private name that also has a `pub` (or any non-renameable) decl of the same
//!     name is left untouched — the collision stays (the safe, conservative choice).
//!
//! Blast radius is intentionally tiny: only files that actually contain a renamed decl are
//! walked, so ordinary non-colliding cross-file `pub`/`export` calls are never touched.

const std = @import("std");

const ast = @import("ast.zig");
const loader = @import("loader.zig");
const sema_decl = @import("sema_decl.zig");

const declName = sema_decl.declName;
const declIsPublic = sema_decl.declIsPublic;

// A value-level top-level decl whose name may be mangled without disturbing any ABI: a
// non-exported function WITH a body, or a plain (non-exported, non-extern) global. Anything
// with external linkage (`export`/`extern`, `extern fn`) keeps its exact symbol name.
fn isRenameable(decl: ast.Decl) bool {
    if (decl.is_pub) return false;
    return switch (decl.kind) {
        .fn_decl => |f| !f.exported and !f.is_variadic and f.body != null and f.abi == null,
        .global_decl => |g| !g.exported and !g.is_extern,
        else => false,
    };
}

// Origin-file index of a span offset: the last boundary whose start <= offset. Returns the
// index into `boundaries` (a stable per-file id) or null when no boundary covers the offset.
fn originFileIndex(boundaries: []const loader.FileBoundary, offset: usize) ?usize {
    var idx: ?usize = null;
    for (boundaries, 0..) |entry, i| {
        if (entry.start <= offset) idx = i else break;
    }
    return idx;
}

const NameInfo = struct {
    // Any decl of this name is `pub`/`export`/`extern` OR is not a renameable value decl
    // (a type/trait/etc). If set, the name is never mangled (collision stays sema's job).
    has_non_renameable: bool = false,
    // Renameable file-private decls of this name, by origin-file index.
    files: std.ArrayListUnmanaged(usize) = .empty,
};

// Rewrite file-private colliding top-level names to per-file-unique mangled names, in place.
// No-op (returns `module` untouched) unless at least two files are involved and at least one
// name genuinely collides across files, so single-file / non-colliding code is never changed.
pub fn transform(arena: std.mem.Allocator, module: ast.Module, boundaries: ?[]const loader.FileBoundary) !ast.Module {
    const b = boundaries orelse return module;
    if (b.len < 2) return module;

    // Explicit mode makes every file private-by-default. Legacy mode preserves the original
    // per-file opt-in rule for source compatibility.
    var strict_files = std.AutoHashMap(usize, void).init(arena);
    defer strict_files.deinit();
    if (module.visibility_mode == .explicit_public) {
        for (b, 0..) |_, fi| try strict_files.put(fi, {});
    } else {
        for (module.decls) |decl| {
            if (!decl.is_pub) continue;
            if (originFileIndex(b, decl.span.offset)) |fi| try strict_files.put(fi, {});
        }
    }
    if (strict_files.count() == 0) return module;

    // Bucket every top-level name: is it ever non-renameable, and which files hold a
    // renameable file-private decl of it?
    var names = std.StringHashMap(NameInfo).init(arena);
    defer names.deinit();
    for (module.decls) |decl| {
        if (decl.kind == .impl_trait) continue; // introduces no importable name of its own
        const nm = declName(decl).text;
        const gop = try names.getOrPut(nm);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const fi = originFileIndex(b, decl.span.offset);
        const private_here = fi != null and strict_files.contains(fi.?) and !declIsPublic(decl);
        if (isRenameable(decl) and private_here) {
            try gop.value_ptr.files.append(arena, fi.?);
        } else {
            gop.value_ptr.has_non_renameable = true;
        }
    }

    // A name is mangled iff ALL its decls are renameable file-private AND they span >= 2
    // distinct files. (Two in the SAME file -> same suffix -> sema still catches the dup.)
    // Build per-file rename maps: file index -> (original name -> mangled name).
    var per_file = std.AutoHashMap(usize, *std.StringHashMap([]const u8)).init(arena);
    defer per_file.deinit();
    var any = false;

    var it = names.iterator();
    while (it.next()) |e| {
        const info = e.value_ptr;
        if (info.has_non_renameable) continue;
        if (!spansTwoFiles(info.files.items)) continue;
        for (info.files.items) |fi| {
            const mangled = try std.fmt.allocPrint(arena, "{s}__mcp{d}", .{ e.key_ptr.*, fi });
            const map = try getOrCreateFileMap(arena, &per_file, fi);
            // A same-file duplicate would collide here (same key); keep the first — sema's
            // E_DUPLICATE_DECLARATION still fires on the original names.
            _ = try map.getOrPutValue(e.key_ptr.*, mangled);
            any = true;
        }
    }
    if (!any) return module;

    // Rename the declarations themselves.
    for (module.decls) |*decl| {
        const fi = originFileIndex(b, decl.span.offset) orelse continue;
        const map = per_file.get(fi) orelse continue;
        const new = map.get(declName(decl.*).text) orelse continue;
        setDeclName(decl, new);
    }

    // Rewrite file-local references (scope-aware) in every decl that lives in a renaming file.
    for (module.decls) |*decl| {
        const fi = originFileIndex(b, decl.span.offset) orelse continue;
        const map = per_file.get(fi) orelse continue;
        var w = Walker{ .arena = arena, .map = map };
        try w.walkDecl(decl);
    }

    return module;
}

fn spansTwoFiles(files: []const usize) bool {
    if (files.len < 2) return false;
    for (files[1..]) |f| {
        if (f != files[0]) return true;
    }
    return false;
}

fn getOrCreateFileMap(arena: std.mem.Allocator, per_file: *std.AutoHashMap(usize, *std.StringHashMap([]const u8)), fi: usize) !*std.StringHashMap([]const u8) {
    const gop = try per_file.getOrPut(fi);
    if (!gop.found_existing) {
        const m = try arena.create(std.StringHashMap([]const u8));
        m.* = std.StringHashMap([]const u8).init(arena);
        gop.value_ptr.* = m;
    }
    return gop.value_ptr.*;
}

fn setDeclName(decl: *ast.Decl, new: []const u8) void {
    switch (decl.kind) {
        .fn_decl => |*f| f.name.text = new,
        .global_decl => |*g| g.name.text = new,
        else => {},
    }
}

// --- scope-aware reference rewriter -----------------------------------------
//
// A file-private value name is referenced only within its OWN file (a cross-file use is
// E_PRIVATE_IMPORT), so only this file's decls are walked. A bare `ident` is rewritten iff the
// name is in the rename map AND is not shadowed by an in-scope local (param / let / var / for
// binding / if-let / switch pattern). This mirrors MC's lexical scoping so a local that happens
// to reuse a renamed top-level name keeps referring to the local.

const Walker = struct {
    arena: std.mem.Allocator,
    map: *std.StringHashMap([]const u8),
    shadow: std.ArrayListUnmanaged([]const u8) = .empty,

    fn shadowed(self: *Walker, name: []const u8) bool {
        for (self.shadow.items) |s| {
            if (std.mem.eql(u8, s, name)) return true;
        }
        return false;
    }

    fn push(self: *Walker, name: []const u8) !void {
        try self.shadow.append(self.arena, name);
    }

    fn mark(self: *Walker) usize {
        return self.shadow.items.len;
    }

    fn restore(self: *Walker, m: usize) void {
        self.shadow.shrinkRetainingCapacity(m);
    }

    fn walkDecl(self: *Walker, decl: *ast.Decl) anyerror!void {
        switch (decl.kind) {
            .fn_decl => |*f| {
                const m = self.mark();
                for (f.params) |*p| {
                    try self.walkType(&p.ty);
                    try self.push(p.name.text);
                }
                if (f.return_type) |*rt| try self.walkType(rt);
                if (f.body) |*body| try self.walkBlock(body);
                self.restore(m);
            },
            .global_decl => |*g| {
                if (g.ty) |*t| try self.walkType(t);
                if (g.init) |*e| try self.walkExpr(e);
            },
            else => {},
        }
    }

    fn walkBlock(self: *Walker, block: *ast.Block) anyerror!void {
        const m = self.mark();
        for (block.items) |*stmt| try self.walkStmt(stmt);
        self.restore(m);
    }

    fn walkStmt(self: *Walker, stmt: *ast.Stmt) anyerror!void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |*d| {
                if (d.ty) |*t| try self.walkType(t);
                if (d.init) |*e| try self.walkExpr(e);
                // The bound names shadow for the REST of the enclosing block.
                for (d.names) |n| try self.push(n.text);
            },
            .loop => |*l| {
                if (l.iterable) |*e| try self.walkExpr(e);
                const m = self.mark();
                if (l.kind == .@"for") {
                    if (l.label) |lbl| try self.push(lbl.text);
                }
                try self.walkBlock(&l.body);
                self.restore(m);
            },
            .if_let => |*il| {
                try self.walkExpr(&il.value);
                const m = self.mark();
                self.pushPattern(il.pattern) catch {};
                try self.walkBlock(&il.then_block);
                self.restore(m);
                if (il.else_block) |*eb| try self.walkBlock(eb);
            },
            .@"switch" => |*sw| {
                try self.walkExpr(&sw.subject);
                for (sw.arms) |*arm| {
                    const m = self.mark();
                    for (arm.patterns) |pat| self.pushPattern(pat) catch {};
                    switch (arm.body) {
                        .block => |*bl| try self.walkBlock(bl),
                        .expr => |*e| try self.walkExpr(e),
                    }
                    self.restore(m);
                }
            },
            .unsafe_block, .comptime_block, .block => |*bl| try self.walkBlock(bl),
            .contract_block => |*cb| try self.walkBlock(&cb.block),
            // `asm` inputs are a `[]const` slice (immutable) and reference registers/locals,
            // never a top-level value name we would rewrite — nothing to do.
            .asm_stmt => {},
            .@"return" => |*maybe| {
                if (maybe.*) |*e| try self.walkExpr(e);
            },
            .@"defer" => |*e| try self.walkExpr(e),
            .assert => |*e| try self.walkExpr(e),
            .assignment => |*asn| {
                try self.walkExpr(&asn.target);
                try self.walkExpr(&asn.value);
            },
            .expr => |*e| try self.walkExpr(e),
            .@"break", .@"continue" => {},
        }
    }

    fn pushPattern(self: *Walker, pat: ast.Pattern) !void {
        switch (pat.kind) {
            .bind => |id| try self.push(id.text),
            .tag_bind => |tb| try self.push(tb.binding.text),
            .wildcard, .tag, .literal => {},
        }
    }

    fn walkExpr(self: *Walker, expr: *ast.Expr) anyerror!void {
        switch (expr.kind) {
            .ident => |id| {
                if (self.shadowed(id.text)) return;
                if (self.map.get(id.text)) |new| {
                    expr.kind = .{ .ident = .{ .text = new, .span = id.span } };
                }
            },
            .array_literal => |arr| {
                for (arr) |*e| try self.walkExpr(e);
            },
            .struct_literal => |fields| {
                for (fields) |*f| try self.walkExpr(&f.value);
            },
            .grouped => |e| try self.walkExpr(e),
            .block => |*bl| try self.walkBlock(bl),
            .unary => |*u| try self.walkExpr(u.expr),
            .binary => |*bin| {
                try self.walkExpr(bin.left);
                try self.walkExpr(bin.right);
            },
            .cast => |*c| {
                try self.walkExpr(c.value);
                try self.walkType(c.ty);
            },
            .address_of => |e| try self.walkExpr(e),
            .call => |*c| {
                try self.walkExpr(c.callee);
                for (c.type_args) |*t| try self.walkType(t);
                for (c.args) |*a| try self.walkExpr(a);
            },
            .index => |*ix| {
                try self.walkExpr(ix.base);
                try self.walkExpr(ix.index);
            },
            .slice => |*s| {
                try self.walkExpr(s.base);
                try self.walkExpr(s.start);
                try self.walkExpr(s.end);
            },
            .deref => |e| try self.walkExpr(e),
            .member => |*mem| try self.walkExpr(mem.base),
            .try_expr => |*t| {
                try self.walkExpr(t.operand);
                if (t.mapped) |m| try self.walkExpr(m);
            },
            .await_expr => |e| try self.walkExpr(e),
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
            => {},
        }
    }

    // Only array-length expressions inside a type can reference a (renamed) value name.
    fn walkType(self: *Walker, ty: *ast.TypeExpr) anyerror!void {
        switch (ty.kind) {
            .array => |*arr| {
                try self.walkExpr(&arr.len);
                try self.walkType(arr.child);
            },
            .pointer => |*q| try self.walkType(q.child),
            .raw_many_pointer => |*q| try self.walkType(q.child),
            .slice => |*q| try self.walkType(q.child),
            .qualified => |*q| try self.walkType(q.child),
            .nullable => |child| try self.walkType(child),
            .member => |*m| try self.walkType(m.base),
            .generic => |*g| {
                for (g.args) |*a| try self.walkType(a);
            },
            .fn_pointer => |*f| {
                for (f.params) |*p| try self.walkType(p);
                try self.walkType(f.ret);
            },
            .closure_type => |*f| {
                for (f.params) |*p| try self.walkType(p);
                try self.walkType(f.ret);
            },
            .name, .enum_literal, .dyn_trait => {},
        }
    }
};
