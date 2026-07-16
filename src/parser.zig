const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const token = @import("token.zig");
const layout = @import("layout.zig");

const max_parse_depth: usize = 256;

pub const Parser = struct {
    lx: lexer.Lexer,
    previous: token.Token,
    current: token.Token,
    reporter: *diagnostics.Reporter,
    allocator: std.mem.Allocator = undefined,
    // Tuples are desugared to synthesized nominal structs at parse time, so the rest of the
    // compiler only ever sees ordinary structs. `synth_decls` holds the generated struct decls
    // (prepended to the module); `tuple_names` dedups them by structural signature so the same
    // tuple shape is one nominal struct everywhere.
    synth_decls: std.ArrayList(ast.Decl) = .empty,
    tuple_names: std.StringHashMap(void) = undefined,
    // Tuple destructuring `let (a, b) = e` expands to several statements (a temp + per-field
    // bindings); the extra statements wait here and are drained into the enclosing block.
    pending_stmts: std.ArrayList(ast.Stmt) = .empty,
    destr_counter: usize = 0,
    // G11: `return switch …` and `var/let x: T = switch …` are desugared at parse time into the
    // existing statement-`switch` (return/assign arms), so the rest of the compiler only ever sees
    // ordinary statement switches. `swexpr_counter` mints the temp for the initializer form.
    swexpr_counter: usize = 0,
    // `impl Type { fn m(…) }` associated functions are desugared to free functions `Type__m`;
    // `impl_methods` maps the call form `Type.m` to the mangled free-function name so that
    // `Type.m(args)` call sites can be rewritten (impl block must precede the call).
    impl_methods: std.StringHashMap([]const u8) = undefined,
    // Names that own a qualified namespace (module/impl), exported on the Module so sema can
    // reserve them against local bindings (prevents a local from shadowing a qualified owner).
    qualified_owners: std.StringHashMap(void) = undefined,
    parse_depth: usize = 0,
    nesting_too_deep_reported: bool = false,
    had_parse_error: bool = false,

    pub fn init(source: []const u8, reporter: *diagnostics.Reporter) Parser {
        var lx = lexer.Lexer.init(source, reporter);
        const first = lx.next();
        return .{
            .lx = lx,
            .previous = first,
            .current = first,
            .reporter = reporter,
        };
    }

    pub fn parseModule(self: *Parser, allocator: std.mem.Allocator) !ast.Module {
        self.allocator = allocator;
        self.tuple_names = std.StringHashMap(void).init(allocator);
        defer self.tuple_names.deinit();
        self.impl_methods = std.StringHashMap([]const u8).init(allocator);
        defer self.impl_methods.deinit();
        self.qualified_owners = std.StringHashMap(void).init(allocator);
        defer self.qualified_owners.deinit();
        var decls: std.ArrayList(ast.Decl) = .empty;
        errdefer decls.deinit(allocator);

        while (self.current.kind != .eof) {
            const start_offset = self.current.span.offset;
            const attrs = self.parseAttrs() catch |err| switch (err) {
                error.ParseFailed => {
                    self.had_parse_error = true;
                    self.synchronizeTopLevel(start_offset);
                    continue;
                },
                else => return err,
            };
            if (self.matchIdentifierText("trait")) {
                decls.append(allocator, self.parseTraitDecl(attrs) catch |err| switch (err) {
                    error.ParseFailed => {
                        self.had_parse_error = true;
                        self.synchronizeTopLevel(start_offset);
                        continue;
                    },
                    else => return err,
                }) catch |err| return err;
                continue;
            }
            if (self.matchIdentifierText("impl")) {
                self.parseImplBlock(&decls, allocator) catch |err| switch (err) {
                    error.ParseFailed => {
                        self.had_parse_error = true;
                        self.synchronizeTopLevel(start_offset);
                        continue;
                    },
                    else => return err,
                };
                continue;
            }
            if (self.matchIdentifierText("module")) {
                self.parseModuleBlock(&decls, allocator) catch |err| switch (err) {
                    error.ParseFailed => {
                        self.had_parse_error = true;
                        self.synchronizeTopLevel(start_offset);
                        continue;
                    },
                    else => return err,
                };
                continue;
            }
            decls.append(allocator, self.parseDecl(attrs) catch |err| switch (err) {
                error.ParseFailed => {
                    self.had_parse_error = true;
                    self.synchronizeTopLevel(start_offset);
                    continue;
                },
                else => return err,
            }) catch |err| return err;
        }

        if (self.had_parse_error) return error.ParseFailed;

        // Prepend synthesized tuple structs so they precede any use.
        const owners = try self.collectOwnerNames(allocator);
        if (self.synth_decls.items.len == 0) return .{ .decls = try decls.toOwnedSlice(allocator), .qualified_owners = owners };
        var all: std.ArrayList(ast.Decl) = .empty;
        errdefer all.deinit(allocator);
        try all.appendSlice(allocator, self.synth_decls.items);
        try all.appendSlice(allocator, decls.items);
        decls.deinit(allocator);
        return .{ .decls = try all.toOwnedSlice(allocator), .qualified_owners = owners };
    }

    // `impl Type { fn m(…) {…} … }` — associated functions desugared to free functions named
    // `Type__m`, appended to the module. `Type.m(args)` calls are rewritten to `Type__m(args)`
    // at the call site (see resolveImplCallee); the impl block must precede such calls.
    fn parseImplBlock(self: *Parser, decls: *std.ArrayList(ast.Decl), allocator: std.mem.Allocator) anyerror!void {
        const start = self.previous.span;
        const first_name = try self.expectName("expected type or trait name after 'impl'");
        // `impl Trait for Type { ... }` — a trait conformance. The first name is the
        // trait, then `for`, then the concrete type. Methods still desugar to `Type__m`
        // free functions (same machinery as an inherent impl); a `impl_trait` record is
        // appended for sema's conformance / coherence / orphan checks.
        var trait_name: ?ast.Ident = null;
        const type_name = if (self.match(.kw_for)) blk: {
            trait_name = first_name;
            break :blk try self.expectName("expected type name after 'impl Trait for'");
        } else first_name;

        try self.expect(.l_brace, "expected '{' after impl type name");
        var conf_methods: std.ArrayList(ast.ImplTraitMethod) = .empty;
        errdefer conf_methods.deinit(allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const member_start = self.current.span.offset;
            self.parseImplMember(decls, allocator, &conf_methods, start, type_name, trait_name) catch |err| switch (err) {
                error.ParseFailed => {
                    self.had_parse_error = true;
                    self.synchronizeImplMember(member_start);
                    continue;
                },
                else => return err,
            };
        }
        try self.expect(.r_brace, "expected '}' to close impl block");
        if (trait_name) |tn| {
            try decls.append(allocator, .{ .span = joinSpan(start, tn.span), .attrs = &[_]ast.Attr{}, .kind = .{ .impl_trait = .{
                .trait_name = tn,
                .type_name = type_name,
                .methods = try conf_methods.toOwnedSlice(allocator),
            } } });
        }
        return;
    }

    fn parseImplMember(
        self: *Parser,
        decls: *std.ArrayList(ast.Decl),
        allocator: std.mem.Allocator,
        conf_methods: *std.ArrayList(ast.ImplTraitMethod),
        start: ast.Span,
        type_name: ast.Ident,
        trait_name: ?ast.Ident,
    ) anyerror!void {
        const m_attrs = try self.parseAttrs();
        const exported = self.match(.kw_export);
        try self.expect(.kw_fn, "expected 'fn' in impl block");
        const trait_rel_name = self.current; // the un-mangled method name
        var fn_decl = try self.finishFnDecl(null, false, exported);
        const self_mode = selfModeOfParams(fn_decl.params);
        try self.registerQualified(type_name.text, fn_decl.name.text);
        const mangled = try self.mangleQualified(type_name.text, fn_decl.name.text);
        if (trait_name != null) {
            try conf_methods.append(allocator, .{
                .name = .{ .text = trait_rel_name.lexeme, .span = trait_rel_name.span },
                .mangled = mangled,
                .self_mode = self_mode,
                .attrs = m_attrs,
                // Carry the impl method's full signature so conformance can check
                // FULL-signature equality (arity + each param type + return type)
                // against the trait method, not just name + self-mode.
                .params = fn_decl.params,
                .return_type = fn_decl.return_type,
            });
        }
        fn_decl.name = .{ .text = mangled, .span = fn_decl.name.span };
        try decls.append(allocator, .{ .span = joinSpan(start, fn_decl.name.span), .attrs = m_attrs, .kind = .{ .fn_decl = fn_decl } });
    }

    // `trait Name { fn sig(self: *Self, ...) -> R; ... }` — method signatures only.
    fn parseTraitDecl(self: *Parser, attrs: []ast.Attr) anyerror!ast.Decl {
        const start = self.previous.span;
        const name = try self.expectName("expected trait name after 'trait'");
        try self.expect(.l_brace, "expected '{' after trait name");
        var methods: std.ArrayList(ast.TraitMethodSig) = .empty;
        errdefer methods.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const member_start = self.current.span.offset;
            self.parseTraitMember(&methods) catch |err| switch (err) {
                error.ParseFailed => {
                    self.had_parse_error = true;
                    self.synchronizeTraitMember(member_start);
                    continue;
                },
                else => return err,
            };
        }
        try self.expect(.r_brace, "expected '}' to close trait body");
        return .{ .span = joinSpan(start, name.span), .attrs = attrs, .kind = .{ .trait_decl = .{
            .name = name,
            .methods = try methods.toOwnedSlice(self.allocator),
        } } };
    }

    fn parseTraitMember(self: *Parser, methods: *std.ArrayList(ast.TraitMethodSig)) anyerror!void {
        const m_attrs = try self.parseAttrs();
        try self.expect(.kw_fn, "expected 'fn' in trait body");
        const m_name = try self.expectName("expected trait method name");
        try self.expect(.l_paren, "expected '(' after trait method name");
        var params: std.ArrayList(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);
        if (self.current.kind != .r_paren) {
            while (true) {
                const is_comptime = self.match(.kw_comptime);
                const is_move = self.matchIdentifierText("move");
                const param_name = try self.expectName("expected trait method parameter name");
                if (is_move and std.mem.eql(u8, param_name.text, "self")) {
                    // `move self` — recorded as a by-value self for object-safety later;
                    // for Tier 1 conformance it is its own self-mode.
                    try params.append(self.allocator, .{ .name = param_name, .ty = selfTypeExpr(param_name.span), .is_comptime = false });
                } else {
                    try self.expect(.colon, "expected ':' after trait method parameter name");
                    const ty = try self.parseType();
                    try params.append(self.allocator, .{ .name = param_name, .ty = ty, .is_comptime = is_comptime });
                }
                if (!self.match(.comma) or self.current.kind == .r_paren) break;
            }
        }
        try self.expect(.r_paren, "expected ')' after trait method parameters");
        const return_type = if (self.match(.arrow)) try self.parseType() else null;
        try self.expect(.semicolon, "expected ';' after trait method signature (no body)");
        const self_mode = selfModeOfParams(params.items);
        try methods.append(self.allocator, .{
            .name = m_name,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .self_mode = self_mode,
            .attrs = m_attrs,
        });
    }

    // If `base` is a bare identifier `Owner` and `Owner.name` is a registered qualified symbol
    // (impl associated function, module function, or module constant), return an identifier
    // expression for the mangled free symbol `Owner__name`.
    fn resolveQualified(self: *Parser, base: ast.Expr, name: ast.Ident) !?ast.Expr {
        const owner = switch (base.kind) {
            .ident => |id| id,
            else => return null,
        };
        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ owner.text, name.text });
        const mangled = self.impl_methods.get(key) orelse return null;
        const span = joinSpan(base.span, name.span);
        return ast.Expr{ .span = span, .kind = .{ .ident = .{ .text = mangled, .span = span } } };
    }

    // `module Name { fn f(…) {…}  global g: T = …; … }` — a namespace. Each function and global
    // is desugared to a mangled top-level declaration `Name__f` / `Name__g`, and `Name.f` /
    // `Name.g` access sites resolve to it (qualified symbol identity; see resolveQualified).
    fn parseModuleBlock(self: *Parser, decls: *std.ArrayList(ast.Decl), allocator: std.mem.Allocator) anyerror!void {
        const start = self.previous.span;
        const mod_name = try self.expectName("expected module name after 'module'");
        try self.expect(.l_brace, "expected '{' after module name");
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const member_start = self.current.span.offset;
            self.parseModuleMember(decls, allocator, start, mod_name) catch |err| switch (err) {
                error.ParseFailed => {
                    self.had_parse_error = true;
                    self.synchronizeModuleMember(member_start);
                    continue;
                },
                else => return err,
            };
        }
        try self.expect(.r_brace, "expected '}' to close module block");
    }

    fn parseModuleMember(self: *Parser, decls: *std.ArrayList(ast.Decl), allocator: std.mem.Allocator, start: ast.Span, mod_name: ast.Ident) anyerror!void {
        const exported = self.match(.kw_export);
        if (self.match(.kw_fn)) {
            var fn_decl = try self.finishFnDecl(null, false, exported);
            try self.registerQualified(mod_name.text, fn_decl.name.text);
            fn_decl.name = .{ .text = try self.mangleQualified(mod_name.text, fn_decl.name.text), .span = fn_decl.name.span };
            try decls.append(allocator, .{ .span = joinSpan(start, fn_decl.name.span), .attrs = &[_]ast.Attr{}, .kind = .{ .fn_decl = fn_decl } });
        } else if (self.matchIdentifierText("global") or self.current.kind == .kw_const) {
            const is_const = self.match(.kw_const);
            const g_name = try self.expectName("expected global name");
            const ty = if (self.match(.colon)) try self.parseType() else null;
            const initializer = if (self.match(.equal)) try self.parseExpr(0) else null;
            _ = try self.expectTok(.semicolon, "expected ';' after module global");
            try self.registerQualified(mod_name.text, g_name.text);
            const mangled = try self.mangleQualified(mod_name.text, g_name.text);
            try decls.append(allocator, .{ .span = joinSpan(start, g_name.span), .attrs = &[_]ast.Attr{}, .kind = .{ .global_decl = .{ .name = .{ .text = mangled, .span = g_name.span }, .ty = ty, .init = initializer, .is_const = is_const } } });
        } else {
            return self.fail("expected 'fn', 'global', or 'const' in module block");
        }
    }

    fn mangleQualified(self: *Parser, owner: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ owner, name });
    }

    // A `Self` type expression (used to record a `move self` parameter's type).
    fn selfTypeExpr(span: ast.Span) ast.TypeExpr {
        return .{ .span = span, .kind = .{ .name = .{ .text = "Self", .span = span } } };
    }

    // Classify the `self`-mode of a (trait/impl) method from its first parameter, when
    // that parameter is named `self`. `*Self` / `*mut Self` / `Self` / move-self.
    fn selfModeOfParams(params: []const ast.Param) ast.SelfMode {
        if (params.len == 0) return .none;
        const first = params[0];
        if (!std.mem.eql(u8, first.name.text, "self")) return .none;
        return switch (first.ty.kind) {
            .pointer => |p| switch (p.mutability) {
                .mut => .by_mut_ptr,
                else => .by_ptr,
            },
            else => .by_value, // `self: Self` and the synthesized `move self`
        };
    }

    fn registerQualified(self: *Parser, owner: []const u8, name: []const u8) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ owner, name });
        try self.impl_methods.put(key, try self.mangleQualified(owner, name));
        try self.qualified_owners.put(owner, {});
    }

    fn collectOwnerNames(self: *Parser, allocator: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(allocator);
        var it = self.qualified_owners.keyIterator();
        while (it.next()) |k| try list.append(allocator, k.*);
        return list.toOwnedSlice(allocator);
    }

    // ---- tuple desugaring (tuples -> synthesized nominal structs) ----
    fn synthTupleStruct(self: *Parser, elems: []ast.TypeExpr, span: ast.Span) !ast.Ident {
        const name = try self.tupleStructName(elems);
        const name_ident = ast.Ident{ .text = name, .span = span };
        if (self.tuple_names.contains(name)) return name_ident;
        try self.tuple_names.put(name, {});
        const fields = try self.allocator.alloc(ast.Field, elems.len);
        for (elems, 0..) |elem, i| {
            const fname = try std.fmt.allocPrint(self.allocator, "_{d}", .{i});
            fields[i] = .{ .name = .{ .text = fname, .span = span }, .ty = elem, .offset = null };
        }
        try self.synth_decls.append(self.allocator, .{
            .span = span,
            .attrs = &[_]ast.Attr{},
            .kind = .{ .struct_decl = .{ .name = name_ident, .abi = null, .fields = fields, .type_params = &[_]ast.Ident{}, .is_move = false } },
        });
        return name_ident;
    }

    fn tupleStructName(self: *Parser, elems: []ast.TypeExpr) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, try std.fmt.allocPrint(self.allocator, "__tuple{d}", .{elems.len}));
        for (elems) |elem| {
            try buf.append(self.allocator, '_');
            try self.appendTypeSignature(&buf, elem);
        }
        return buf.toOwnedSlice(self.allocator);
    }

    fn appendTypeSignature(self: *Parser, buf: *std.ArrayList(u8), ty: ast.TypeExpr) anyerror!void {
        const a = self.allocator;
        switch (ty.kind) {
            .name => |id| try buf.appendSlice(a, id.text),
            .enum_literal => |id| {
                try buf.appendSlice(a, "el");
                try buf.appendSlice(a, id.text);
            },
            .nullable => |c| {
                try buf.appendSlice(a, "opt");
                try self.appendTypeSignature(buf, c.*);
            },
            .pointer => |p| {
                try buf.appendSlice(a, "ptr");
                try self.appendMutSig(buf, p.mutability);
                try self.appendTypeSignature(buf, p.child.*);
            },
            .raw_many_pointer => |p| {
                try buf.appendSlice(a, "mptr");
                try self.appendMutSig(buf, p.mutability);
                try self.appendTypeSignature(buf, p.child.*);
            },
            .slice => |p| {
                try buf.appendSlice(a, "slice");
                try self.appendMutSig(buf, p.mutability);
                try self.appendTypeSignature(buf, p.child.*);
            },
            .qualified => |q| {
                try self.appendMutSig(buf, q.mutability);
                try self.appendTypeSignature(buf, q.child.*);
            },
            .array => |arr| {
                try buf.appendSlice(a, "arr");
                switch (arr.len.kind) {
                    .int_literal => |lit| try buf.appendSlice(a, lit),
                    else => try buf.appendSlice(a, "n"),
                }
                try buf.append(a, '_');
                try self.appendTypeSignature(buf, arr.child.*);
            },
            .generic => |g| {
                try buf.appendSlice(a, g.base.text);
                for (g.args) |arg| {
                    try buf.append(a, '_');
                    try self.appendTypeSignature(buf, arg);
                }
            },
            .member => |m| {
                try self.appendTypeSignature(buf, m.base.*);
                try buf.append(a, '_');
                try buf.appendSlice(a, m.field.text);
            },
            .fn_pointer, .closure_type => try buf.appendSlice(a, "fn"),
            .dyn_trait => |d| {
                try buf.appendSlice(a, "dyn");
                try buf.appendSlice(a, d.trait_name.text);
            },
        }
    }

    fn appendMutSig(self: *Parser, buf: *std.ArrayList(u8), mutability: ast.Mutability) !void {
        try buf.appendSlice(self.allocator, switch (mutability) {
            .none => "",
            .mut => "m",
            .@"const" => "c",
        });
    }

    fn parseDecl(self: *Parser, attrs: []ast.Attr) anyerror!ast.Decl {
        // `pub` (opt-in module visibility) precedes the declaration's leading keyword,
        // after any `#[...]` attributes. It stamps the parsed declaration; the rest of the
        // grammar is unchanged.
        const is_pub = self.match(.kw_pub);
        var decl = try self.parseDeclBody(attrs);
        decl.is_pub = is_pub;
        return decl;
    }

    fn parseDeclBody(self: *Parser, attrs: []ast.Attr) anyerror!ast.Decl {
        const start = if (attrs.len > 0) attrs[0].span else self.current.span;

        // `move` is a contextual qualifier (section 18.1) on a struct declaration
        // making it a linear resource type. At top level a leading `move` is
        // unambiguous — declarations otherwise start with a keyword.
        // `opaque` is a contextual qualifier on a (non-extern) struct declaration
        // (field privacy): `opaque struct …` / `opaque move struct …`. Like `move`
        // it is unambiguous at top level.
        const is_opaque = self.matchIdentifierText("opaque");
        const is_move = self.matchIdentifierText("move");
        if (is_move and self.current.kind != .kw_extern and self.current.kind != .kw_struct) {
            return self.fail("'move' applies only to struct declarations");
        }
        if (is_opaque and self.current.kind != .kw_struct) {
            return self.fail("'opaque' applies only to a (non-extern) struct declaration");
        }

        if (self.match(.kw_extern)) {
            const abi = if (self.current.kind == .string_literal) blk: {
                const text = self.current.lexeme;
                self.advance();
                break :blk text;
            } else null;
            if (self.matchIdentifierText("mmio")) {
                try self.expect(.kw_struct, "expected 'struct' after extern mmio");
                var struct_decl = try self.finishStructDecl("mmio");
                struct_decl.is_move = is_move;
                return .{ .span = joinSpan(start, struct_decl.name.span), .attrs = attrs, .kind = .{ .struct_decl = struct_decl } };
            }
            if (self.match(.kw_fn)) {
                if (is_move) return self.fail("'move' applies only to struct declarations");
                const fn_decl = try self.finishFnDecl(abi, false, false);
                return .{ .span = joinSpan(start, self.previousSpan(fn_decl.name.span)), .attrs = attrs, .kind = .{ .extern_fn = fn_decl } };
            }
            if (self.match(.kw_struct)) {
                var struct_decl = try self.finishStructDecl(abi);
                struct_decl.is_move = is_move;
                return .{ .span = joinSpan(start, struct_decl.name.span), .attrs = attrs, .kind = .{ .struct_decl = struct_decl } };
            }
            if (self.matchIdentifierText("global")) {
                if (is_move) return self.fail("'move' applies only to struct declarations");
                const name = try self.expectName("expected global name");
                try self.expect(.colon, "expected ':' in extern global declaration");
                const ty = try self.parseType();
                const semi = try self.expectTok(.semicolon, "expected ';' after extern global declaration");
                return .{ .span = joinSpan(start, semi.span), .attrs = attrs, .kind = .{ .global_decl = .{ .name = name, .ty = ty, .init = null, .is_extern = true } } };
            }
            return self.fail("expected extern fn, extern struct, or extern global");
        }

        if (self.match(.kw_open)) {
            try self.expect(.kw_enum, "expected 'enum' after open");
            const enum_decl = try self.finishEnumDecl(true);
            return .{ .span = joinSpan(start, enum_decl.name.span), .attrs = attrs, .kind = .{ .enum_decl = enum_decl } };
        }

        const exported = self.match(.kw_export);
        // `async fn …` — a stackless async function (Phase D). `async` is contextual (matched
        // as identifier text) so it never reserves the word elsewhere; it must be followed by
        // `fn`. The pre-sema transform rewrites the resulting `is_async` fn into a state machine.
        const is_async = self.matchIdentifierText("async");
        const is_const = self.match(.kw_const);
        if (self.match(.kw_fn)) {
            if (is_async and is_const) return self.fail("'const fn' cannot be 'async'");
            var fn_decl = try self.finishFnDecl(null, is_const, exported);
            fn_decl.is_async = is_async;
            const end = if (fn_decl.body) |body| body.span else fn_decl.name.span;
            return .{ .span = joinSpan(start, end), .attrs = attrs, .kind = .{ .fn_decl = fn_decl } };
        }
        if (is_async) return self.fail("'async' applies only to a function declaration");

        // `const NAME: T = <comptime constant>;` — a named compile-time constant
        // (section 22). A const declaration that is not `const fn` is this form.
        if (is_const) {
            const name = try self.expectName("expected const name");
            try self.expect(.colon, "expected ':' in const declaration");
            const ty = try self.parseType();
            try self.expect(.equal, "expected '=' in const declaration");
            const initializer = try self.parseExpr(0);
            const semi = try self.expectTok(.semicolon, "expected ';' after const declaration");
            return .{ .span = joinSpan(start, semi.span), .attrs = attrs, .kind = .{ .global_decl = .{ .name = name, .ty = ty, .init = initializer, .is_const = true } } };
        }

        if (self.match(.kw_type)) {
            const name = try self.expectName("expected type alias name");
            try self.expect(.equal, "expected '=' in type alias");
            const ty = try self.parseType();
            const semi = try self.expectTok(.semicolon, "expected ';' after type alias");
            return .{ .span = joinSpan(start, semi.span), .attrs = attrs, .kind = .{ .type_alias = .{ .name = name, .ty = ty } } };
        }

        if (self.match(.kw_packed)) {
            if (self.matchIdentifierText("bits")) {
                const packed_bits = try self.finishPackedBitsDecl();
                return .{ .span = joinSpan(start, packed_bits.name.span), .attrs = attrs, .kind = .{ .packed_bits_decl = packed_bits } };
            }
        }

        if (self.match(.kw_overlay)) {
            try self.expect(.kw_union, "expected 'union' after overlay");
            const overlay_union = try self.finishOverlayUnionDecl();
            return .{ .span = joinSpan(start, overlay_union.name.span), .attrs = attrs, .kind = .{ .overlay_union_decl = overlay_union } };
        }

        if (self.match(.kw_struct)) {
            var struct_decl = try self.finishStructDecl(null);
            struct_decl.is_move = is_move;
            struct_decl.is_opaque = is_opaque;
            // `#[c_union]` — compiler-internal addressable union laid out as a real C `union`
            // (see ast.StructDecl.is_c_union). Recognized as a struct attribute so the async
            // state-machine lowering (and its focused test) can request union layout.
            struct_decl.is_c_union = attrsHaveNamed(attrs, "c_union");
            return .{ .span = joinSpan(start, struct_decl.name.span), .attrs = attrs, .kind = .{ .struct_decl = struct_decl } };
        }

        if (self.match(.kw_union)) {
            const union_decl = try self.finishUnionDecl();
            return .{ .span = joinSpan(start, union_decl.name.span), .attrs = attrs, .kind = .{ .union_decl = union_decl } };
        }

        if (self.matchIdentifierText("global")) {
            const name = try self.expectName("expected global name");
            const ty = if (self.match(.colon)) try self.parseType() else null;
            const initializer = if (self.match(.equal)) try self.parseExpr(0) else null;
            const semi = try self.expectTok(.semicolon, "expected ';' after global declaration");
            return .{ .span = joinSpan(start, semi.span), .attrs = attrs, .kind = .{ .global_decl = .{ .name = name, .ty = ty, .init = initializer, .exported = exported } } };
        }

        if (self.match(.kw_enum)) {
            const enum_decl = try self.finishEnumDecl(false);
            return .{ .span = joinSpan(start, enum_decl.name.span), .attrs = attrs, .kind = .{ .enum_decl = enum_decl } };
        }

        return self.fail("expected top-level fn, type, or extern declaration");
    }

    fn finishFnDecl(self: *Parser, abi: ?[]const u8, is_const: bool, exported: bool) anyerror!ast.FnDecl {
        const name = try self.expectName("expected function name");
        try self.expect(.l_paren, "expected '(' after function name");

        var params: std.ArrayList(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);
        var is_variadic = false;
        if (self.current.kind != .r_paren) {
            while (true) {
                // C-ABI variadic marker `...` — only valid as the final entry, after at
                // least one named parameter (the named arg `va.start` anchors on).
                if (self.current.kind == .dot_dot_dot) {
                    _ = self.advance();
                    is_variadic = true;
                    break;
                }
                const is_comptime = self.match(.kw_comptime);
                const param_name = try self.expectName("expected parameter name");
                try self.expect(.colon, "expected ':' after parameter name");
                const ty = try self.parseType();
                try params.append(self.allocator, .{ .name = param_name, .ty = ty, .is_comptime = is_comptime });
                if (!self.match(.comma) or self.current.kind == .r_paren) break;
            }
        }
        if (is_variadic and params.items.len == 0) {
            return self.fail("a variadic function needs at least one named parameter before `...`");
        }
        try self.expect(.r_paren, "expected ')' after parameters");

        const return_type = if (self.match(.arrow)) try self.parseType() else null;
        // `where T: TraitA, U: TraitB` — bounds on the function's comptime type
        // parameters (Tier 1 trait bounds). Optional; precedes the body.
        const bounds = try self.parseWhereClause();
        const body = if (self.current.kind == .l_brace) try self.parseBlock() else blk: {
            try self.expect(.semicolon, "expected function body or ';'");
            break :blk null;
        };

        return .{
            .name = name,
            .abi = abi,
            .params = try params.toOwnedSlice(self.allocator),
            .return_type = return_type,
            .body = body,
            .is_const = is_const,
            .exported = exported,
            .is_variadic = is_variadic,
            .bounds = bounds,
        };
    }

    // `where T: TraitA, U: TraitB` (Tier 1). Returns an empty slice when absent.
    fn parseWhereClause(self: *Parser) anyerror![]ast.TraitBound {
        if (!self.matchIdentifierText("where")) return &.{};
        var bounds: std.ArrayList(ast.TraitBound) = .empty;
        errdefer bounds.deinit(self.allocator);
        while (true) {
            const tp = try self.expectName("expected type parameter name in 'where' clause");
            try self.expect(.colon, "expected ':' after type parameter in 'where' clause");
            const trait_name = try self.expectName("expected trait name in 'where' clause");
            try bounds.append(self.allocator, .{ .type_param = tp, .trait_name = trait_name });
            if (!self.match(.comma)) break;
        }
        return bounds.toOwnedSlice(self.allocator);
    }

    fn finishStructDecl(self: *Parser, abi: ?[]const u8) anyerror!ast.StructDecl {
        const name = try self.expectName("expected struct name");
        const type_params = try self.parseTypeParamList();
        const fields = try self.finishFieldList("expected '{' after struct name", "expected '}' after struct fields");
        return .{ .name = name, .abi = abi, .fields = fields, .type_params = type_params };
    }

    // Parse an optional `@offset(N)` annotation after a (MMIO) field's type.
    fn parseFieldOffset(self: *Parser) anyerror!?u64 {
        if (!self.match(.at)) return null;
        const kw = try self.expectName("expected 'offset' after '@'");
        if (!std.mem.eql(u8, kw.text, "offset")) return self.fail("only '@offset(N)' is supported on fields");
        try self.expect(.l_paren, "expected '(' after @offset");
        const tok = self.current;
        if (tok.kind != .integer_literal) return self.fail("expected an integer offset");
        self.advance();
        try self.expect(.r_paren, "expected ')' after @offset value");
        return parseIntLiteralValue(tok.lexeme) orelse return self.fail("invalid @offset value");
    }

    // Parse an integer literal lexeme (decimal / `0x` / `0b`, with `_` digit
    // separators) to its value.
    fn parseIntLiteralValue(lexeme: []const u8) ?u64 {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (lexeme) |ch| {
            if (ch == '_') continue;
            if (n >= buf.len) return null;
            buf[n] = ch;
            n += 1;
        }
        const cleaned = buf[0..n];
        if (cleaned.len > 2 and cleaned[0] == '0' and (cleaned[1] == 'x' or cleaned[1] == 'X')) {
            return std.fmt.parseInt(u64, cleaned[2..], 16) catch null;
        }
        if (cleaned.len > 2 and cleaned[0] == '0' and (cleaned[1] == 'b' or cleaned[1] == 'B')) {
            return std.fmt.parseInt(u64, cleaned[2..], 2) catch null;
        }
        return std.fmt.parseInt(u64, cleaned, 10) catch null;
    }

    // Parse an optional `<T, U, …>` type-parameter list after a generic
    // declaration name. Returns an empty slice when absent.
    fn parseTypeParamList(self: *Parser) anyerror![]ast.Ident {
        if (!self.match(.less)) return &.{};
        var params: std.ArrayList(ast.Ident) = .empty;
        errdefer params.deinit(self.allocator);
        if (self.current.kind != .greater) {
            while (true) {
                try params.append(self.allocator, try self.expectName("expected type parameter name"));
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(.greater, "expected '>' after type parameters");
        return params.toOwnedSlice(self.allocator);
    }

    fn finishPackedBitsDecl(self: *Parser) anyerror!ast.PackedBitsDecl {
        const name = try self.expectName("expected packed bits name");
        try self.expect(.colon, "expected ':' before packed bits representation type");
        const repr = try self.parseType();
        const fields = try self.finishFieldList("expected '{' after packed bits representation type", "expected '}' after packed bits fields");
        return .{ .name = name, .repr = repr, .fields = fields };
    }

    fn finishOverlayUnionDecl(self: *Parser) anyerror!ast.OverlayUnionDecl {
        const name = try self.expectName("expected overlay union name");
        const fields = try self.finishFieldList("expected '{' after overlay union name", "expected '}' after overlay union fields");
        return .{ .name = name, .fields = fields };
    }

    fn finishUnionDecl(self: *Parser) anyerror!ast.UnionDecl {
        const name = try self.expectName("expected union name");
        // Optional `<T, …>` type-parameter list for a generic tagged union
        // (mirrors `struct Name<T>`); case payload types may reference these.
        const type_params = try self.parseTypeParamList();
        try self.expect(.l_brace, "expected '{' after union name");
        var cases: std.ArrayList(ast.UnionCase) = .empty;
        errdefer cases.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const case_name = try self.expectSymbol("expected union case name");
            const ty = if (self.match(.colon)) try self.parseType() else null;
            _ = self.match(.comma) or self.match(.semicolon);
            try cases.append(self.allocator, .{ .name = case_name, .ty = ty });
        }
        try self.expect(.r_brace, "expected '}' after union cases");
        return .{ .name = name, .cases = try cases.toOwnedSlice(self.allocator), .type_params = type_params };
    }

    fn finishFieldList(self: *Parser, open_message: []const u8, close_message: []const u8) anyerror![]ast.Field {
        try self.expect(.l_brace, open_message);
        var fields: std.ArrayList(ast.Field) = .empty;
        errdefer fields.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const field_start = self.current.span.offset;
            self.parseField(&fields) catch |err| switch (err) {
                error.ParseFailed => {
                    self.had_parse_error = true;
                    self.synchronizeField(field_start);
                    continue;
                },
                else => return err,
            };
        }
        try self.expect(.r_brace, close_message);
        return fields.toOwnedSlice(self.allocator);
    }

    fn parseField(self: *Parser, fields: *std.ArrayList(ast.Field)) anyerror!void {
        const field_name = try self.expectName("expected field name");
        try self.expect(.colon, "expected ':' after field name");
        const ty = try self.parseType();
        const offset = try self.parseFieldOffset();
        _ = self.match(.comma) or self.match(.semicolon);
        try fields.append(self.allocator, .{ .name = field_name, .ty = ty, .offset = offset });
    }

    fn finishEnumDecl(self: *Parser, is_open: bool) anyerror!ast.EnumDecl {
        const name = try self.expectName("expected enum name");
        const repr = if (self.match(.colon)) try self.parseType() else null;
        try self.expect(.l_brace, "expected '{' after enum name");
        var cases: std.ArrayList(ast.EnumCase) = .empty;
        errdefer cases.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const case_name = try self.expectSymbol("expected enum case name");
            const value = if (self.match(.equal)) try self.parseExpr(0) else null;
            _ = self.match(.comma) or self.match(.semicolon);
            try cases.append(self.allocator, .{ .name = case_name, .value = value });
        }
        try self.expect(.r_brace, "expected '}' after enum cases");
        return .{ .name = name, .repr = repr, .cases = try cases.toOwnedSlice(self.allocator), .is_open = is_open };
    }

    fn parseAttrs(self: *Parser) anyerror![]ast.Attr {
        var attrs: std.ArrayList(ast.Attr) = .empty;
        errdefer attrs.deinit(self.allocator);
        while (self.match(.hash)) {
            try attrs.append(self.allocator, try self.parseAttr());
        }
        return attrs.toOwnedSlice(self.allocator);
    }

    fn parseAttr(self: *Parser) anyerror!ast.Attr {
        const start = self.lxTokenBeforeCurrent();
        try self.expect(.l_bracket, "expected '[' after '#'");
        const name = try self.expectName("expected attribute name");
        if (std.mem.eql(u8, name.text, "unsafe_contract")) {
            try self.expect(.l_paren, "expected '(' after unsafe_contract");
            const contract_name = try self.expectSymbol("expected contract name");
            var args: std.ArrayList(ast.Expr) = .empty;
            errdefer args.deinit(self.allocator);
            while (self.match(.comma) and self.current.kind != .r_paren) {
                try args.append(self.allocator, try self.parseExpr(0));
            }
            try self.expect(.r_paren, "expected ')' after unsafe contract");
            const end = try self.expectTok(.r_bracket, "expected ']' after attribute");
            return .{
                .span = joinSpan(start, end.span),
                .kind = .{ .unsafe_contract = .{ .name = contract_name, .args = try args.toOwnedSlice(self.allocator) } },
            };
        }
        if (std.mem.eql(u8, name.text, "backend_name") or std.mem.eql(u8, name.text, "origin") or std.mem.eql(u8, name.text, "section")) {
            const which = name.text;
            try self.expect(.l_paren, "expected '(' after attribute name");
            if (self.current.kind != .string_literal) return self.fail("expected a string argument");
            const raw = self.current.lexeme;
            self.advance();
            try self.expect(.r_paren, "expected ')' after attribute argument");
            const end = try self.expectTok(.r_bracket, "expected ']' after attribute");
            const value = stripStringQuotes(raw);
            return .{
                .span = joinSpan(start, end.span),
                .kind = if (std.mem.eql(u8, which, "origin")) .{ .origin = value } else if (std.mem.eql(u8, which, "section")) .{ .section = value } else .{ .backend_name = value },
            };
        }
        if (std.mem.eql(u8, name.text, "align")) {
            try self.expect(.l_paren, "expected '(' after align");
            if (self.current.kind != .integer_literal) return self.fail("expected an integer argument to align");
            const raw = self.current.lexeme;
            self.advance();
            try self.expect(.r_paren, "expected ')' after align argument");
            const end = try self.expectTok(.r_bracket, "expected ']' after attribute");
            const n = std.fmt.parseInt(u32, raw, 0) catch return self.fail("align argument is not a valid integer");
            if (n == 0 or (n & (n - 1)) != 0) return self.fail("align argument must be a non-zero power of two");
            return .{
                .span = joinSpan(start, end.span),
                .kind = .{ .@"align" = n },
            };
        }
        const end = try self.expectTok(.r_bracket, "expected ']' after attribute");
        return .{
            .span = joinSpan(start, end.span),
            .kind = if (std.mem.eql(u8, name.text, "no_lang_trap")) .no_lang_trap else if (std.mem.eql(u8, name.text, "naked")) .naked else if (std.mem.eql(u8, name.text, "noinline")) .@"noinline" else if (std.mem.eql(u8, name.text, "weak")) .weak else .{ .named = name },
        };
    }

    fn attrsHaveNamed(attrs: []ast.Attr, wanted: []const u8) bool {
        for (attrs) |attr| {
            switch (attr.kind) {
                .named => |named| if (std.mem.eql(u8, named.text, wanted)) return true,
                else => {},
            }
        }
        return false;
    }

    fn stripStringQuotes(lexeme: []const u8) []const u8 {
        if (lexeme.len >= 2 and lexeme[0] == '"' and lexeme[lexeme.len - 1] == '"') {
            return lexeme[1 .. lexeme.len - 1];
        }
        return lexeme;
    }

    fn parseBlock(self: *Parser) anyerror!ast.Block {
        try self.enterParseDepth();
        defer self.leaveParseDepth();
        const start = try self.expectTok(.l_brace, "expected block");
        var items: std.ArrayList(ast.Stmt) = .empty;
        errdefer items.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const start_offset = self.current.span.offset;
            const stmt = self.parseStmt() catch |err| switch (err) {
                error.ParseFailed => {
                    self.had_parse_error = true;
                    self.pending_stmts.clearRetainingCapacity();
                    self.synchronizeStatement(start_offset);
                    continue;
                },
                else => return err,
            };
            try items.append(self.allocator, stmt);
            // Drain statements synthesized by tuple destructuring into this block.
            if (self.pending_stmts.items.len > 0) {
                try items.appendSlice(self.allocator, self.pending_stmts.items);
                self.pending_stmts.clearRetainingCapacity();
            }
        }
        const end = try self.expectTok(.r_brace, "expected '}' after block");
        return .{ .span = joinSpan(start.span, end.span), .items = try items.toOwnedSlice(self.allocator) };
    }

    fn parseStmt(self: *Parser) anyerror!ast.Stmt {
        const attrs = try self.parseAttrs();
        if (attrs.len > 0) {
            if (attrs.len == 1 and std.meta.activeTag(attrs[0].kind) == .unsafe_contract) {
                const block = try self.parseBlock();
                return .{ .span = joinSpan(attrs[0].span, block.span), .kind = .{ .contract_block = .{ .attr = attrs[0], .block = block } } };
            }
            return self.fail("statement attributes currently require unsafe_contract block");
        }

        if (self.match(.kw_let)) return self.parseLocal(true);
        if (self.match(.kw_var)) return self.parseLocal(false);
        // G7: labeled loop `outer: while ...` / `outer: for ...`. Only an
        // `IDENT :` immediately followed by a loop keyword is a loop label; any
        // other `ident :` is left for its existing meaning.
        if (self.current.kind == .identifier) {
            var lx = self.lx;
            if (lx.next().kind == .colon) {
                const after = lx.next().kind;
                if (after == .kw_for or after == .kw_while) {
                    const loop_label = ident(self.current);
                    self.advance(); // label ident
                    self.advance(); // ':'
                    if (self.match(.kw_for)) return self.parseFor(loop_label);
                    _ = self.match(.kw_while);
                    return self.parseWhile(loop_label);
                }
            }
        }
        if (self.match(.kw_for)) return self.parseFor(null);
        if (self.match(.kw_while)) return self.parseWhile(null);
        if (self.current.kind == .kw_if) return self.parseIfLet();
        if (self.current.kind == .kw_switch) return self.parseSwitch();
        if (self.match(.kw_unsafe)) {
            const block = try self.parseBlock();
            return .{ .span = block.span, .kind = .{ .unsafe_block = block } };
        }
        if (self.match(.kw_comptime)) {
            const block = try self.parseBlock();
            return .{ .span = block.span, .kind = .{ .comptime_block = block } };
        }
        if (self.match(.kw_asm)) return self.parseAsmStmt();
        if (self.current.kind == .l_brace) {
            const block = try self.parseBlock();
            return .{ .span = block.span, .kind = .{ .block = block } };
        }
        if (self.match(.kw_return)) {
            const start = self.lxTokenBeforeCurrent();
            if (self.current.kind == .kw_switch) { // G11: `return switch e {…}` -> switch with return arms
                const sw = try self.parseSwitchNode();
                try self.rewriteSwitchArms(sw.node.arms, .ret);
                _ = self.match(.semicolon);
                return .{ .span = joinSpan(start, sw.span), .kind = .{ .@"switch" = sw.node } };
            }
            const value = if (self.current.kind != .semicolon) try self.parseExpr(0) else null;
            const end = try self.expectTok(.semicolon, "expected ';' after return");
            return .{ .span = joinSpan(start, end.span), .kind = .{ .@"return" = value } };
        }
        if (self.match(.kw_break)) {
            const start = self.lxTokenBeforeCurrent();
            const target = try self.parseOptionalLoopLabel();
            const end = try self.expectTok(.semicolon, "expected ';' after break");
            return .{ .span = joinSpan(start, end.span), .kind = .{ .@"break" = target } };
        }
        if (self.match(.kw_continue)) {
            const start = self.lxTokenBeforeCurrent();
            const target = try self.parseOptionalLoopLabel();
            const end = try self.expectTok(.semicolon, "expected ';' after continue");
            return .{ .span = joinSpan(start, end.span), .kind = .{ .@"continue" = target } };
        }
        if (self.match(.kw_defer)) {
            const expr = try self.parseExpr(0);
            const end = try self.expectTok(.semicolon, "expected ';' after defer");
            return .{ .span = joinSpan(expr.span, end.span), .kind = .{ .@"defer" = expr } };
        }
        if (self.match(.kw_assert)) {
            const start = self.lxTokenBeforeCurrent();
            try self.expect(.l_paren, "expected '(' after assert");
            const expr = try self.parseExpr(0);
            try self.expect(.r_paren, "expected ')' after assert expression");
            const end = try self.expectTok(.semicolon, "expected ';' after assert");
            return .{ .span = joinSpan(start, end.span), .kind = .{ .assert = expr } };
        }

        const start = self.current.span;
        const target_or_expr = try self.parseExpr(0);
        if (self.match(.equal)) {
            const value = try self.parseExpr(0);
            const end = try self.expectTok(.semicolon, "expected ';' after assignment");
            return .{ .span = joinSpan(start, end.span), .kind = .{ .assignment = .{ .target = target_or_expr, .value = value } } };
        }
        const end = try self.expectTok(.semicolon, "expected ';' after expression");
        return .{ .span = joinSpan(start, end.span), .kind = .{ .expr = target_or_expr } };
    }

    fn parseAsmStmt(self: *Parser) anyerror!ast.Stmt {
        const start = self.lxTokenBeforeCurrent();
        var form: ast.AsmForm = .@"opaque";
        var is_volatile = false;
        while (self.current.kind != .l_brace and self.current.kind != .eof) {
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "opaque")) form = .@"opaque";
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "precise")) form = .precise;
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "volatile")) is_volatile = true;
            self.advance();
        }
        try self.expect(.l_brace, "expected '{' after asm modifiers");

        var templates: std.ArrayList([]const u8) = .empty;
        errdefer templates.deinit(self.allocator);
        var clobbers: std.ArrayList([]const u8) = .empty;
        errdefer clobbers.deinit(self.allocator);
        var outputs: std.ArrayList(ast.AsmOutput) = .empty;
        errdefer outputs.deinit(self.allocator);
        var inputs: std.ArrayList(ast.AsmInput) = .empty;
        errdefer inputs.deinit(self.allocator);

        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            if (self.match(.string_literal)) {
                try templates.append(self.allocator, self.previousLexeme());
                continue;
            }
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "clobber")) {
                self.advance();
                try self.expect(.l_paren, "expected '(' after clobber");
                const clobber = try self.expectTok(.string_literal, "expected clobber string");
                try clobbers.append(self.allocator, clobber.lexeme);
                try self.expect(.r_paren, "expected ')' after clobber");
                _ = self.match(.comma) or self.match(.semicolon);
                continue;
            }
            // Precise-asm output: `out("reg") name: T`.
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "out")) {
                self.advance();
                try self.expect(.l_paren, "expected '(' after out");
                const reg = try self.expectTok(.string_literal, "expected register constraint string");
                try self.expect(.r_paren, "expected ')' after out register");
                const name = try self.expectName("expected output binding name");
                try self.expect(.colon, "expected ':' before output operand type");
                const ty = try self.parseType();
                try outputs.append(self.allocator, .{ .reg = reg.lexeme, .name = name, .ty = ty });
                _ = self.match(.comma) or self.match(.semicolon);
                continue;
            }
            // Precise-asm input: `in("reg") expr: T`.
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "in")) {
                self.advance();
                try self.expect(.l_paren, "expected '(' after in");
                const reg = try self.expectTok(.string_literal, "expected register constraint string");
                try self.expect(.r_paren, "expected ')' after in register");
                const value = try self.parseExpr(0);
                try self.expect(.colon, "expected ':' before input operand type");
                const ty = try self.parseType();
                try inputs.append(self.allocator, .{ .reg = reg.lexeme, .value = value, .ty = ty });
                _ = self.match(.comma) or self.match(.semicolon);
                continue;
            }
            self.advance();
        }
        const end = try self.expectTok(.r_brace, "expected '}' after asm block");
        return .{ .span = joinSpan(start, end.span), .kind = .{ .asm_stmt = .{
            .form = form,
            .is_volatile = is_volatile,
            .templates = try templates.toOwnedSlice(self.allocator),
            .clobbers = try clobbers.toOwnedSlice(self.allocator),
            .outputs = try outputs.toOwnedSlice(self.allocator),
            .inputs = try inputs.toOwnedSlice(self.allocator),
        } } };
    }

    // G7: parse an optional `:IDENT` loop-label target after `break`/`continue`.
    fn parseOptionalLoopLabel(self: *Parser) anyerror!?ast.Ident {
        if (!self.match(.colon)) return null;
        return try self.expectName("expected loop label name after ':'");
    }

    fn parseFor(self: *Parser, loop_label: ?ast.Ident) anyerror!ast.Stmt {
        const start = self.lxTokenBeforeCurrent();
        const label = try self.expectName("expected loop binding after for");
        try self.expectIdentifierText("in", "expected 'in' after for binding");
        const iterable = try self.parseExpr(0);
        const body = try self.parseBlock();
        return .{
            .span = joinSpan(start, body.span),
            .kind = .{ .loop = .{
                .kind = .@"for",
                .label = label,
                .loop_label = loop_label,
                .iterable = iterable,
                .body = body,
            } },
        };
    }

    fn parseWhile(self: *Parser, loop_label: ?ast.Ident) anyerror!ast.Stmt {
        const start = self.lxTokenBeforeCurrent();
        const condition = try self.parseExpr(0);
        const body = try self.parseBlock();
        return .{
            .span = joinSpan(start, body.span),
            .kind = .{ .loop = .{
                .kind = .@"while",
                .label = null,
                .loop_label = loop_label,
                .iterable = condition,
                .body = body,
            } },
        };
    }

    // `let (a, b) = e;` -> `let __destrN = e; let a = __destrN._0; let b = __destrN._1;`.
    // The returned statement is the temp binding; the per-field bindings are queued and drained
    // into the enclosing block by parseBlock. Field types are inferred from the member access.
    fn parseTupleDestructure(self: *Parser, is_let: bool, start: ast.Span) anyerror!ast.Stmt {
        try self.expect(.l_paren, "expected '(' for tuple destructuring");
        var names: std.ArrayList(ast.Ident) = .empty;
        errdefer names.deinit(self.allocator);
        try names.append(self.allocator, try self.expectName("expected binding name"));
        while (self.match(.comma)) {
            if (self.current.kind == .r_paren) break;
            try names.append(self.allocator, try self.expectName("expected binding name"));
        }
        if (names.items.len < 2) return self.fail("tuple destructuring requires at least two bindings");
        try self.expect(.r_paren, "expected ')' after tuple destructuring pattern");
        try self.expect(.equal, "expected '=' in tuple destructuring");
        const init_expr = try self.parseExpr(0);
        const end = try self.expectTok(.semicolon, "expected ';' after destructuring");
        const span = joinSpan(start, end.span);

        const tmp_name = try std.fmt.allocPrint(self.allocator, "__destr{d}", .{self.destr_counter});
        self.destr_counter += 1;
        const tmp_ident = ast.Ident{ .text = tmp_name, .span = span };

        for (names.items, 0..) |nm, i| {
            // Each synthesized projection needs its own source point. Typed MIR
            // keys expression-result facts by span, so using the whole
            // destructuring statement for every `_N` projection lets fields
            // cross-match during backend admission.
            const base = try ast.makePtr(self.allocator, ast.Expr{ .span = nm.span, .kind = .{ .ident = tmp_ident } });
            const fname = try std.fmt.allocPrint(self.allocator, "_{d}", .{i});
            const member = ast.Expr{ .span = nm.span, .kind = .{ .member = .{ .base = base, .name = .{ .text = fname, .span = nm.span } } } };
            const name_slice = try self.allocator.alloc(ast.Ident, 1);
            name_slice[0] = nm;
            const local = ast.LocalDecl{ .names = name_slice, .ty = null, .init = member };
            try self.pending_stmts.append(self.allocator, .{ .span = nm.span, .kind = if (is_let) .{ .let_decl = local } else .{ .var_decl = local } });
        }
        names.deinit(self.allocator);

        const tmp_slice = try self.allocator.alloc(ast.Ident, 1);
        tmp_slice[0] = tmp_ident;
        return .{ .span = span, .kind = .{ .let_decl = .{ .names = tmp_slice, .ty = null, .init = init_expr } } };
    }

    fn parseLocal(self: *Parser, is_let: bool) anyerror!ast.Stmt {
        const start = self.current.span;
        if (self.current.kind == .l_paren) return self.parseTupleDestructure(is_let, start);
        var names: std.ArrayList(ast.Ident) = .empty;
        errdefer names.deinit(self.allocator);
        try names.append(self.allocator, try self.expectName("expected local name"));
        while (self.match(.comma)) {
            if (self.current.kind == .colon or self.current.kind == .equal) break;
            try names.append(self.allocator, try self.expectName("expected local name"));
        }
        const ty = if (self.match(.colon)) try self.parseType() else null;
        var initializer: ?ast.Expr = null;
        if (self.match(.equal)) {
            if (self.current.kind == .kw_switch) { // G11: `var/let x: T = switch e {…}`
                if (names.items.len != 1) return self.fail("expression-switch initializer requires a single binding");
                const ty_val = ty orelse return self.fail("expression-switch initializer requires a type annotation");
                const only = names.items[0];
                names.deinit(self.allocator);
                names = .empty; // neutralize the errdefer: desugarSwitchInit may fail on malformed input
                return self.desugarSwitchInit(is_let, start, only, ty_val);
            }
            initializer = try self.parseExpr(0);
        }
        const end = try self.expectTok(.semicolon, "expected ';' after local declaration");
        const local = ast.LocalDecl{ .names = try names.toOwnedSlice(self.allocator), .ty = ty, .init = initializer };
        return .{ .span = joinSpan(start, end.span), .kind = if (is_let) .{ .let_decl = local } else .{ .var_decl = local } };
    }

    fn parseIfLet(self: *Parser) anyerror!ast.Stmt {
        try self.enterParseDepth();
        defer self.leaveParseDepth();
        const start = try self.expectTok(.kw_if, "expected if");
        if (self.match(.kw_let)) {
            const pattern = try self.parsePattern();
            try self.expect(.equal, "expected '=' in if let");
            const value = try self.parseExpr(0);
            const then_block = try self.parseBlock();
            const else_block = if (self.match(.kw_else)) try self.parseBlock() else null;
            const end = if (else_block) |b| b.span else then_block.span;
            return .{ .span = joinSpan(start.span, end), .kind = .{ .if_let = .{ .pattern = pattern, .value = value, .then_block = then_block, .else_block = else_block } } };
        }
        // Boolean `if cond { … } [else { … }]` (and `else if`). Desugars to a
        // `switch` on the bool, reusing all its checking and CFG lowering.
        const cond = try self.parseExpr(0);
        const then_block = try self.parseBlock();
        var else_block: ?ast.Block = null;
        if (self.match(.kw_else)) {
            if (self.current.kind == .kw_if) {
                // `else if` — wrap the nested if statement in a block.
                const nested = try self.parseIfLet();
                var items = try self.allocator.alloc(ast.Stmt, 1);
                items[0] = nested;
                else_block = .{ .span = nested.span, .items = items };
            } else {
                else_block = try self.parseBlock();
            }
        }
        const end = if (else_block) |b| b.span else then_block.span;
        return try self.desugarBoolIf(joinSpan(start.span, end), cond, then_block, else_block);
    }

    fn boolPattern(self: *Parser, value: bool, span: ast.Span) ast.Pattern {
        _ = self;
        return .{ .span = span, .kind = .{ .literal = .{ .span = span, .kind = .{ .bool_literal = value } } } };
    }

    fn desugarBoolIf(self: *Parser, span: ast.Span, cond: ast.Expr, then_block: ast.Block, else_block: ?ast.Block) anyerror!ast.Stmt {
        const false_body: ast.Block = else_block orelse .{ .span = span, .items = &.{} };
        var arms = try self.allocator.alloc(ast.SwitchArm, 2);
        const true_pats = try self.allocator.alloc(ast.Pattern, 1);
        true_pats[0] = self.boolPattern(true, cond.span);
        const false_pats = try self.allocator.alloc(ast.Pattern, 1);
        false_pats[0] = self.boolPattern(false, cond.span);
        arms[0] = .{ .patterns = true_pats, .body = .{ .block = then_block } };
        arms[1] = .{ .patterns = false_pats, .body = .{ .block = false_body } };
        return .{ .span = span, .kind = .{ .@"switch" = .{ .subject = cond, .arms = arms } } };
    }

    const SwitchParse = struct { node: ast.Switch, span: ast.Span };

    fn parseSwitchNode(self: *Parser) anyerror!SwitchParse {
        const start = try self.expectTok(.kw_switch, "expected switch");
        const subject = try self.parseExpr(0);
        try self.expect(.l_brace, "expected '{' after switch subject");
        var arms: std.ArrayList(ast.SwitchArm) = .empty;
        errdefer arms.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            var patterns: std.ArrayList(ast.Pattern) = .empty;
            errdefer patterns.deinit(self.allocator);
            while (true) {
                try patterns.append(self.allocator, try self.parsePattern());
                if (!self.match(.comma) or self.current.kind == .fat_arrow) break;
            }
            try self.expect(.fat_arrow, "expected '=>' after switch pattern");
            const body: ast.SwitchBody = if (self.current.kind == .l_brace) .{ .block = try self.parseBlock() } else .{ .expr = try self.parseExpr(0) };
            _ = self.match(.comma) or self.match(.semicolon);
            try arms.append(self.allocator, .{ .patterns = try patterns.toOwnedSlice(self.allocator), .body = body });
        }
        const end = try self.expectTok(.r_brace, "expected '}' after switch");
        return .{ .node = .{ .subject = subject, .arms = try arms.toOwnedSlice(self.allocator) }, .span = joinSpan(start.span, end.span) };
    }

    fn parseSwitch(self: *Parser) anyerror!ast.Stmt {
        const sw = try self.parseSwitchNode();
        return .{ .span = sw.span, .kind = .{ .@"switch" = sw.node } };
    }

    // G11 expression-switch sugar: rewrite each arm's value expression into a one-statement block
    // — `return <expr>;` (return form) or `<target> = <expr>;` (initializer form) — so the result
    // is an ordinary statement-`switch`. Arms must be value expressions, not blocks.
    const ArmRewrite = union(enum) { ret, assign: ast.Ident };

    fn rewriteSwitchArms(self: *Parser, arms: []ast.SwitchArm, mode: ArmRewrite) anyerror!void {
        for (arms) |*arm| {
            const e = switch (arm.body) {
                .expr => |ex| ex,
                .block => return self.fail("expression-switch arms must be value expressions, not blocks"),
            };
            const items = try self.allocator.alloc(ast.Stmt, 1);
            items[0] = switch (mode) {
                .ret => .{ .span = e.span, .kind = .{ .@"return" = e } },
                .assign => |target| .{ .span = e.span, .kind = .{ .assignment = .{
                    .target = .{ .span = target.span, .kind = .{ .ident = target } },
                    .value = e,
                } } },
            };
            arm.body = .{ .block = .{ .span = e.span, .items = items } };
        }
    }

    // G11: `var/let x: T = switch e {…}` -> `var __swvalN: T = uninit; switch e { … __swvalN = v; }
    // let/var x: T = __swvalN;`. The temp decl is returned; the switch and the user binding are
    // queued in pending_stmts (drained right after by parseBlock), preserving evaluation order and
    // the original binding's mutability.
    fn desugarSwitchInit(self: *Parser, is_let: bool, start: ast.Span, name: ast.Ident, ty: ast.TypeExpr) anyerror!ast.Stmt {
        const sw = try self.parseSwitchNode();
        _ = self.match(.semicolon);
        const span = joinSpan(start, sw.span);
        const tmp_text = try std.fmt.allocPrint(self.allocator, "__swval{d}", .{self.swexpr_counter});
        self.swexpr_counter += 1;
        const tmp_ident = ast.Ident{ .text = tmp_text, .span = span };
        try self.rewriteSwitchArms(sw.node.arms, .{ .assign = tmp_ident });
        try self.pending_stmts.append(self.allocator, .{ .span = span, .kind = .{ .@"switch" = sw.node } });
        const name_slice = try self.allocator.alloc(ast.Ident, 1);
        name_slice[0] = name;
        const bind_local = ast.LocalDecl{ .names = name_slice, .ty = ty, .init = ast.Expr{ .span = span, .kind = .{ .ident = tmp_ident } } };
        try self.pending_stmts.append(self.allocator, .{ .span = span, .kind = if (is_let) .{ .let_decl = bind_local } else .{ .var_decl = bind_local } });
        const tmp_slice = try self.allocator.alloc(ast.Ident, 1);
        tmp_slice[0] = tmp_ident;
        const tmp_local = ast.LocalDecl{ .names = tmp_slice, .ty = ty, .init = ast.Expr{ .span = span, .kind = .uninit_literal } };
        return .{ .span = span, .kind = .{ .var_decl = tmp_local } };
    }

    fn parsePattern(self: *Parser) anyerror!ast.Pattern {
        if (self.match(.underscore)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .wildcard };
        if (self.match(.dot)) {
            const dot = self.lxTokenBeforeCurrent();
            const name = try self.expectSymbol("expected enum case");
            return .{ .span = joinSpan(dot, name.span), .kind = .{ .tag = name } };
        }
        if (self.isSymbol(self.current.kind)) {
            const tok = self.current;
            self.advance();
            const name = ident(tok);
            if (self.match(.l_paren)) {
                const binding = try self.expectName("expected binding name");
                try self.expect(.r_paren, "expected ')' after pattern binding");
                return .{ .span = joinSpan(tok.span, binding.span), .kind = .{ .tag_bind = .{ .tag = name, .binding = binding } } };
            }
            return .{ .span = tok.span, .kind = .{ .bind = name } };
        }
        if (self.current.kind == .minus or self.current.kind == .integer_literal or self.current.kind == .char_literal or self.current.kind == .string_literal or self.current.kind == .kw_true or self.current.kind == .kw_false) {
            const expr = try self.parseExpr(0);
            return .{ .span = expr.span, .kind = .{ .literal = expr } };
        }
        return self.fail("expected pattern");
    }

    fn parseType(self: *Parser) anyerror!ast.TypeExpr {
        try self.enterParseDepth();
        defer self.leaveParseDepth();
        const start = self.current.span;
        if (self.match(.dot)) {
            const dot = self.lxTokenBeforeCurrent();
            const name = try self.expectSymbol("expected enum literal type argument");
            return .{ .span = joinSpan(dot, name.span), .kind = .{ .enum_literal = name } };
        }
        if (self.match(.question)) {
            const child = try ast.makePtr(self.allocator, try self.parseType());
            return .{ .span = joinSpan(start, child.span), .kind = .{ .nullable = child } };
        }
        if (self.current.kind == .kw_mut or self.current.kind == .kw_const) {
            const mutability = self.parseMutability();
            const child = try ast.makePtr(self.allocator, try self.parseType());
            return .{ .span = joinSpan(start, child.span), .kind = .{ .qualified = .{ .mutability = mutability, .child = child } } };
        }
        if (self.match(.star)) {
            const mutability = self.parseMutability();
            // `*dyn Trait` / `*mut dyn Trait` — a trait-object fat pointer (Tier 2).
            // The `dyn Trait` pointee is not an ordinary type; the whole `*dyn`
            // folds into a single `dyn_trait` node.
            if (self.matchIdentifierText("dyn")) {
                const trait_name = try self.expectName("expected trait name after 'dyn'");
                return .{ .span = joinSpan(start, trait_name.span), .kind = .{ .dyn_trait = .{ .mutability = mutability, .trait_name = trait_name } } };
            }
            const child = try ast.makePtr(self.allocator, try self.parseType());
            return .{ .span = joinSpan(start, child.span), .kind = .{ .pointer = .{ .mutability = mutability, .child = child } } };
        }
        if (self.match(.l_bracket)) {
            if (self.match(.star)) {
                try self.expect(.r_bracket, "expected ']' after raw many pointer marker");
                const mutability = self.parseMutability();
                const child = try ast.makePtr(self.allocator, try self.parseType());
                return .{ .span = joinSpan(start, child.span), .kind = .{ .raw_many_pointer = .{ .mutability = mutability, .child = child } } };
            }
            if (self.match(.r_bracket)) {
                const mutability = self.parseMutability();
                const child = try ast.makePtr(self.allocator, try self.parseType());
                return .{ .span = joinSpan(start, child.span), .kind = .{ .slice = .{ .mutability = mutability, .child = child } } };
            }
            const len = try self.parseExpr(0);
            try self.expect(.r_bracket, "expected ']' after array length");
            const child = try ast.makePtr(self.allocator, try self.parseType());
            return .{ .span = joinSpan(start, child.span), .kind = .{ .array = .{ .len = len, .child = child } } };
        }

        // A tuple type `(T0, T1, …)` desugars to a synthesized nominal struct. `(T)` is just a
        // parenthesized type (T), not a 1-tuple.
        if (self.match(.l_paren)) {
            var elems: std.ArrayList(ast.TypeExpr) = .empty;
            errdefer elems.deinit(self.allocator);
            if (self.current.kind != .r_paren) {
                while (true) {
                    try elems.append(self.allocator, try self.parseType());
                    if (!self.match(.comma)) break;
                }
            }
            const end = try self.expectTok(.r_paren, "expected ')' to close tuple type");
            const elem_slice = try elems.toOwnedSlice(self.allocator);
            if (elem_slice.len == 1) return elem_slice[0];
            // A tuple has at least two element types; `()` is not a unit/void type (use `void`).
            if (elem_slice.len == 0) return self.fail("tuple type requires at least two element types");
            const tuple_span = joinSpan(start, end.span);
            const name = try self.synthTupleStruct(elem_slice, tuple_span);
            return .{ .span = tuple_span, .kind = .{ .name = name } };
        }

        // A function-pointer type: `fn(P0, P1) -> R`.
        if (self.match(.kw_fn)) {
            try self.expect(.l_paren, "expected '(' after 'fn' in function-pointer type");
            var params: std.ArrayList(ast.TypeExpr) = .empty;
            errdefer params.deinit(self.allocator);
            if (self.current.kind != .r_paren) {
                while (true) {
                    try params.append(self.allocator, try self.parseType());
                    if (!self.match(.comma)) break;
                }
            }
            try self.expect(.r_paren, "expected ')' after function-pointer parameter types");
            try self.expect(.arrow, "expected '->' after function-pointer parameters");
            const ret = try ast.makePtr(self.allocator, try self.parseType());
            return .{ .span = joinSpan(start, ret.span), .kind = .{ .fn_pointer = .{ .params = try params.toOwnedSlice(self.allocator), .ret = ret } } };
        }

        // A closure type: `closure(P0, P1) -> R` (a capturing function value).
        if (self.match(.kw_closure)) {
            try self.expect(.l_paren, "expected '(' after 'closure' in closure type");
            var params: std.ArrayList(ast.TypeExpr) = .empty;
            errdefer params.deinit(self.allocator);
            if (self.current.kind != .r_paren) {
                while (true) {
                    try params.append(self.allocator, try self.parseType());
                    if (!self.match(.comma)) break;
                }
            }
            try self.expect(.r_paren, "expected ')' after closure parameter types");
            try self.expect(.arrow, "expected '->' after closure parameters");
            const ret = try ast.makePtr(self.allocator, try self.parseType());
            return .{ .span = joinSpan(start, ret.span), .kind = .{ .closure_type = .{ .params = try params.toOwnedSlice(self.allocator), .ret = ret } } };
        }

        // `type` is the meta-type of a `comptime T: type` type parameter
        // (section 22 type parameters / user-defined generics).
        if (self.match(.kw_type)) {
            const tok = self.previous;
            return .{ .span = tok.span, .kind = .{ .name = .{ .text = "type", .span = tok.span } } };
        }

        const base = try self.expectSymbol("expected type name");
        var ty = ast.TypeExpr{ .span = base.span, .kind = .{ .name = base } };
        if (self.match(.less)) {
            var args: std.ArrayList(ast.TypeExpr) = .empty;
            errdefer args.deinit(self.allocator);
            if (self.current.kind != .greater) {
                while (true) {
                    // A const-generic argument (`Foo<T, 8>`): an integer literal carried
                    // as a name; the monomorphizer substitutes it as a value into `[N]T`.
                    if (self.current.kind == .integer_literal) {
                        const tok = self.current;
                        self.advance();
                        try args.append(self.allocator, .{ .span = tok.span, .kind = .{ .name = .{ .text = tok.lexeme, .span = tok.span } } });
                    } else {
                        try args.append(self.allocator, try self.parseType());
                    }
                    if (!self.match(.comma)) break;
                }
            }
            const end = try self.consumeGenericClose("expected '>' after type arguments");
            ty = .{ .span = joinSpan(base.span, end.span), .kind = .{ .generic = .{ .base = base, .args = try args.toOwnedSlice(self.allocator) } } };
        }
        var member_depth: usize = 1;
        while (self.match(.dot)) {
            const field = try self.expectSymbol("expected type member");
            try self.reserveParseWrapperDepth(&member_depth);
            const base_ptr = try ast.makePtr(self.allocator, ty);
            ty = .{ .span = joinSpan(base_ptr.span, field.span), .kind = .{ .member = .{ .base = base_ptr, .field = field } } };
        }
        return ty;
    }

    fn parseMutability(self: *Parser) ast.Mutability {
        if (self.match(.kw_mut)) return .mut;
        if (self.match(.kw_const)) return .@"const";
        return .none;
    }

    fn parseExpr(self: *Parser, min_bp: u8) anyerror!ast.Expr {
        try self.enterParseDepth();
        defer self.leaveParseDepth();
        var lhs = try self.parsePrefix();
        var expr_depth: usize = 1;
        while (true) {
            lhs = try self.parsePostfix(lhs);
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "as")) {
                self.advance();
                const ty = try ast.makePtr(self.allocator, try self.parseType());
                try self.reserveParseWrapperDepth(&expr_depth);
                const value = try ast.makePtr(self.allocator, lhs);
                lhs = .{ .span = joinSpan(value.span, ty.span), .kind = .{ .cast = .{ .value = value, .ty = ty } } };
                continue;
            }
            const op = infix(self.current.kind) orelse break;
            if (op.left_bp < min_bp) break;
            self.advance();
            const rhs = try self.parseExpr(op.right_bp);
            try self.reserveParseWrapperDepth(&expr_depth);
            const left = try ast.makePtr(self.allocator, lhs);
            const right = try ast.makePtr(self.allocator, rhs);
            lhs = .{ .span = joinSpan(left.span, right.span), .kind = .{ .binary = .{ .op = op.op, .left = left, .right = right } } };
        }
        return lhs;
    }

    fn parsePrefix(self: *Parser) anyerror!ast.Expr {
        if (self.match(.minus)) return self.unary(.neg);
        if (self.match(.tilde)) return self.unary(.bit_not);
        if (self.match(.bang)) return self.unary(.logical_not);
        if (self.match(.star)) {
            const start = self.lxTokenBeforeCurrent();
            const value = try ast.makePtr(self.allocator, try self.parseExpr(prefix_operand_bp));
            return .{ .span = joinSpan(start, value.span), .kind = .{ .deref = value } };
        }
        if (self.match(.amp)) {
            const start = self.lxTokenBeforeCurrent();
            const value = try ast.makePtr(self.allocator, try self.parseExpr(prefix_operand_bp));
            return .{ .span = joinSpan(start, value.span), .kind = .{ .address_of = value } };
        }
        // `await EXPR` — a suspend point inside an `async fn` (Phase D). `await` is contextual
        // (matched as identifier text). It binds as a unary prefix; the pre-sema async transform
        // rewrites it into a child-future poll/take_result. Outside an `async fn` it is rejected
        // by the transform.
        if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "await")) {
            const start = self.current.span;
            self.advance();
            const value = try ast.makePtr(self.allocator, try self.parseExpr(prefix_operand_bp));
            return .{ .span = joinSpan(start, value.span), .kind = .{ .await_expr = value } };
        }
        return self.parsePrimary();
    }

    fn unary(self: *Parser, op: ast.UnaryOp) anyerror!ast.Expr {
        const start = self.lxTokenBeforeCurrent();
        const value = try ast.makePtr(self.allocator, try self.parseExpr(prefix_operand_bp));
        return .{ .span = joinSpan(start, value.span), .kind = .{ .unary = .{ .op = op, .expr = value } } };
    }

    fn parsePrimary(self: *Parser) anyerror!ast.Expr {
        if (self.isSymbol(self.current.kind)) {
            const tok = self.current;
            self.advance();
            return .{ .span = tok.span, .kind = .{ .ident = ident(tok) } };
        }
        if (self.match(.integer_literal)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .int_literal = self.previousLexeme() } };
        if (self.match(.float_literal)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .float_literal = self.previousLexeme() } };
        if (self.match(.string_literal)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .string_literal = self.previousLexeme() } };
        if (self.match(.char_literal)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .char_literal = self.previousLexeme() } };
        if (self.match(.kw_true)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .bool_literal = true } };
        if (self.match(.kw_false)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .bool_literal = false } };
        if (self.match(.kw_null)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .null_literal };
        if (self.match(.kw_uninit)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .uninit_literal };
        if (self.match(.kw_unreachable)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .unreachable_expr };
        if (self.match(.dot)) {
            const dot = self.lxTokenBeforeCurrent();
            if (self.match(.l_brace)) {
                if (self.startsStructLiteralField()) {
                    var fields: std.ArrayList(ast.StructLiteralField) = .empty;
                    errdefer fields.deinit(self.allocator);
                    while (true) {
                        _ = try self.expectTok(.dot, "expected '.' before struct literal field name");
                        const field_name = try self.expectSymbol("expected struct literal field name");
                        try self.expect(.equal, "expected '=' after struct literal field name");
                        const value = try self.parseExpr(0);
                        try fields.append(self.allocator, .{ .name = field_name, .value = value });
                        if (!self.match(.comma) or self.current.kind == .r_brace) break;
                    }
                    const end = try self.expectTok(.r_brace, "expected '}' after struct literal");
                    return .{ .span = joinSpan(dot, end.span), .kind = .{ .struct_literal = try fields.toOwnedSlice(self.allocator) } };
                }
                var items: std.ArrayList(ast.Expr) = .empty;
                errdefer items.deinit(self.allocator);
                if (self.current.kind != .r_brace) {
                    while (true) {
                        try items.append(self.allocator, try self.parseExpr(0));
                        if (!self.match(.comma) or self.current.kind == .r_brace) break;
                    }
                }
                const end = try self.expectTok(.r_brace, "expected '}' after array literal");
                return .{ .span = joinSpan(dot, end.span), .kind = .{ .array_literal = try items.toOwnedSlice(self.allocator) } };
            }
            const name = try self.expectSymbol("expected enum literal name");
            return .{ .span = joinSpan(dot, name.span), .kind = .{ .enum_literal = name } };
        }
        if (self.match(.l_paren)) {
            const start = self.lxTokenBeforeCurrent();
            if (self.match(.r_paren)) return .{ .span = joinSpan(start, self.lxTokenBeforeCurrent()), .kind = .void_literal };
            const first = try self.parseExpr(0);
            // A tuple literal `(e0, e1, …)` desugars to a struct literal `.{ ._0 = e0, … }`,
            // matching the synthesized tuple struct. A comma (≥2 elements) is the discriminator;
            // `(e)` stays a grouped expression.
            if (self.match(.comma)) {
                var fields: std.ArrayList(ast.StructLiteralField) = .empty;
                errdefer fields.deinit(self.allocator);
                try fields.append(self.allocator, .{ .name = .{ .text = "_0", .span = first.span }, .value = first });
                var idx: usize = 1;
                while (true) {
                    const value = try self.parseExpr(0);
                    const fname = try std.fmt.allocPrint(self.allocator, "_{d}", .{idx});
                    try fields.append(self.allocator, .{ .name = .{ .text = fname, .span = value.span }, .value = value });
                    idx += 1;
                    if (!self.match(.comma)) break;
                }
                const end = try self.expectTok(.r_paren, "expected ')' to close tuple literal");
                return .{ .span = joinSpan(start, end.span), .kind = .{ .struct_literal = try fields.toOwnedSlice(self.allocator) } };
            }
            const inner = try ast.makePtr(self.allocator, first);
            const end = try self.expectTok(.r_paren, "expected ')' after expression");
            // C-style cast: `(ScalarType)(expr)`. A scalar builtin type name can never be a value
            // or callable, so a parenthesized scalar-type name immediately applied to a
            // parenthesized operand is unambiguously a cast (the dual of `expr as ScalarType`).
            if (self.current.kind == .l_paren) {
                if (scalarTypeNameIdent(first)) |type_name| {
                    self.advance();
                    const operand = try self.parseExpr(0);
                    const close = try self.expectTok(.r_paren, "expected ')' after cast operand");
                    const value = try ast.makePtr(self.allocator, operand);
                    const ty = try ast.makePtr(self.allocator, ast.TypeExpr{
                        .span = first.span,
                        .kind = .{ .name = .{ .text = type_name, .span = first.span } },
                    });
                    return .{ .span = joinSpan(start, close.span), .kind = .{ .cast = .{ .value = value, .ty = ty } } };
                }
            }
            return .{ .span = joinSpan(start, end.span), .kind = .{ .grouped = inner } };
        }
        if (self.current.kind == .l_brace) {
            const block = try self.parseBlock();
            return .{ .span = block.span, .kind = .{ .block = block } };
        }
        return self.fail("expected expression");
    }

    fn parsePostfix(self: *Parser, input: ast.Expr) anyerror!ast.Expr {
        var expr = input;
        var wrapper_depth: usize = 1;
        while (true) {
            if (self.current.kind == .less and self.lessStartsGenericCall()) {
                self.advance();
                const type_args = try self.finishTypeArgsAfterLess();
                try self.expect(.l_paren, "expected '(' after generic call type arguments");
                try self.reserveParseWrapperDepth(&wrapper_depth);
                expr = try self.finishCall(expr, type_args);
                continue;
            }
            if (self.match(.l_paren)) {
                try self.reserveParseWrapperDepth(&wrapper_depth);
                expr = try self.finishCall(expr, &.{});
                continue;
            }
            if (self.match(.l_bracket)) {
                const first = try self.parseExpr(0);
                if (self.match(.dot_dot)) {
                    const end_expr = try ast.makePtr(self.allocator, try self.parseExpr(0));
                    const close = try self.expectTok(.r_bracket, "expected ']' after slice range");
                    try self.reserveParseWrapperDepth(&wrapper_depth);
                    const base = try ast.makePtr(self.allocator, expr);
                    const start_expr = try ast.makePtr(self.allocator, first);
                    expr = .{ .span = joinSpan(base.span, close.span), .kind = .{ .slice = .{ .base = base, .start = start_expr, .end = end_expr } } };
                    continue;
                }
                const idx = try ast.makePtr(self.allocator, first);
                const end = try self.expectTok(.r_bracket, "expected ']' after index");
                try self.reserveParseWrapperDepth(&wrapper_depth);
                const base = try ast.makePtr(self.allocator, expr);
                expr = .{ .span = joinSpan(base.span, end.span), .kind = .{ .index = .{ .base = base, .index = idx } } };
                continue;
            }
            if (self.match(.dot)) {
                if (self.match(.star)) {
                    try self.reserveParseWrapperDepth(&wrapper_depth);
                    const base = try ast.makePtr(self.allocator, expr);
                    expr = .{ .span = joinSpan(base.span, self.lxTokenBeforeCurrent()), .kind = .{ .deref = base } };
                    continue;
                }
                // Numeric tuple access `t.0` -> the synthesized field `_0`.
                if (self.current.kind == .integer_literal) {
                    const idx_tok = self.current;
                    self.advance();
                    const fname = try std.fmt.allocPrint(self.allocator, "_{s}", .{idx_tok.lexeme});
                    try self.reserveParseWrapperDepth(&wrapper_depth);
                    const base = try ast.makePtr(self.allocator, expr);
                    expr = .{ .span = joinSpan(base.span, idx_tok.span), .kind = .{ .member = .{ .base = base, .name = .{ .text = fname, .span = idx_tok.span } } } };
                    continue;
                }
                const name = try self.expectSymbol("expected member name");
                // Qualified symbol access `Owner.name` (impl associated function / module
                // function / module constant) -> the mangled free symbol `Owner__name`.
                if (try self.resolveQualified(expr, name)) |resolved| {
                    expr = resolved;
                    continue;
                }
                try self.reserveParseWrapperDepth(&wrapper_depth);
                const base = try ast.makePtr(self.allocator, expr);
                expr = .{ .span = joinSpan(base.span, name.span), .kind = .{ .member = .{ .base = base, .name = name } } };
                continue;
            }
            if (self.match(.question)) {
                try self.reserveParseWrapperDepth(&wrapper_depth);
                const inner = try ast.makePtr(self.allocator, expr);
                // `EXPR? else MAPPED`: on error, propagate `err(MAPPED)` (in the enclosing
                // function's error type) instead of the original error.
                var mapped: ?*ast.Expr = null;
                if (self.match(.kw_else)) {
                    mapped = try ast.makePtr(self.allocator, try self.parsePrimary());
                }
                expr = .{ .span = joinSpan(inner.span, self.lxTokenBeforeCurrent()), .kind = .{ .try_expr = .{ .operand = inner, .mapped = mapped } } };
                continue;
            }
            break;
        }
        return expr;
    }

    fn lessStartsGenericCall(self: *Parser) bool {
        if (self.current.kind != .less) return false;
        var lx = self.lx;
        var depth: usize = 0;
        var saw_type_token = false;

        while (true) {
            const tok = lx.next();
            switch (tok.kind) {
                .eof, .semicolon, .l_brace, .r_brace, .fat_arrow, .equal => return false,
                .less => {
                    depth += 1;
                    saw_type_token = false;
                },
                .greater => {
                    if (depth == 0) {
                        return saw_type_token and lx.next().kind == .l_paren;
                    }
                    depth -= 1;
                    saw_type_token = true;
                },
                .shift_right => {
                    // `>>` closes two levels (a nested generic's `>` plus the outer).
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) return saw_type_token and lx.next().kind == .l_paren;
                    saw_type_token = true;
                },
                .comma => {
                    if (!saw_type_token) return false;
                    saw_type_token = false;
                },
                .l_paren => return false,
                else => saw_type_token = true,
            }
        }
    }

    fn finishTypeArgsAfterLess(self: *Parser) anyerror![]ast.TypeExpr {
        var args: std.ArrayList(ast.TypeExpr) = .empty;
        errdefer args.deinit(self.allocator);
        if (self.current.kind != .greater) {
            while (true) {
                if (self.match(.integer_literal)) {
                    const span = self.lxTokenBeforeCurrent();
                    try args.append(self.allocator, .{ .span = span, .kind = .{ .name = .{ .text = self.previousLexeme(), .span = span } } });
                } else {
                    try args.append(self.allocator, try self.parseType());
                }
                if (!self.match(.comma)) break;
            }
        }
        _ = try self.consumeGenericClose("expected '>' after type arguments");
        return args.toOwnedSlice(self.allocator);
    }

    fn finishCall(self: *Parser, callee_expr: ast.Expr, type_args: []ast.TypeExpr) anyerror!ast.Expr {
        if (type_args.len == 0 and self.isReflectionBuiltinCallee(callee_expr) and self.startsTypeExpr(self.current.kind)) {
            return self.finishReflectionSpecCall(callee_expr);
        }
        var args: std.ArrayList(ast.Expr) = .empty;
        errdefer args.deinit(self.allocator);
        if (self.current.kind != .r_paren) {
            while (true) {
                try args.append(self.allocator, try self.parseExpr(0));
                if (!self.match(.comma) or self.current.kind == .r_paren) break;
            }
        }
        const end = try self.expectTok(.r_paren, "expected ')' after call");
        const callee = try ast.makePtr(self.allocator, callee_expr);
        return .{ .span = joinSpan(callee.span, end.span), .kind = .{ .call = .{ .callee = callee, .type_args = type_args, .args = try args.toOwnedSlice(self.allocator) } } };
    }

    fn finishReflectionSpecCall(self: *Parser, callee_expr: ast.Expr) anyerror!ast.Expr {
        var type_args: std.ArrayList(ast.TypeExpr) = .empty;
        errdefer type_args.deinit(self.allocator);
        try type_args.append(self.allocator, try self.parseType());

        var args: std.ArrayList(ast.Expr) = .empty;
        errdefer args.deinit(self.allocator);
        if (self.match(.comma) and self.current.kind != .r_paren) {
            while (true) {
                try args.append(self.allocator, try self.parseExpr(0));
                if (!self.match(.comma) or self.current.kind == .r_paren) break;
            }
        }
        const end = try self.expectTok(.r_paren, "expected ')' after reflection call");
        const callee = try ast.makePtr(self.allocator, callee_expr);
        return .{ .span = joinSpan(callee.span, end.span), .kind = .{ .call = .{ .callee = callee, .type_args = try type_args.toOwnedSlice(self.allocator), .args = try args.toOwnedSlice(self.allocator) } } };
    }

    fn isReflectionBuiltinCallee(self: *Parser, expr: ast.Expr) bool {
        return switch (expr.kind) {
            .ident => |name| std.mem.eql(u8, name.text, "size_of") or
                std.mem.eql(u8, name.text, "sizeof") or
                std.mem.eql(u8, name.text, "alignof") or
                std.mem.eql(u8, name.text, "field_offset") or
                std.mem.eql(u8, name.text, "field_type") or
                std.mem.eql(u8, name.text, "bit_offset") or
                std.mem.eql(u8, name.text, "repr_of"),
            .grouped => |inner| return self.isReflectionBuiltinCallee(inner.*),
            else => false,
        };
    }

    fn startsTypeExpr(_: *Parser, kind: token.Kind) bool {
        return switch (kind) {
            .identifier,
            .kw_bool,
            .kw_never,
            .kw_void,
            .kw_wrap,
            .kw_sat,
            .kw_serial,
            .kw_atomic,
            .dot,
            .question,
            .kw_mut,
            .kw_const,
            .star,
            .l_bracket,
            => true,
            else => false,
        };
    }

    // Contextual keywords (language gap G24): words that carry keyword meaning only in a
    // specific syntactic position but are otherwise ordinary identifiers. Freeing them here
    // lets self-hosted code use common names (`ok`, `err`, `type`, `use`, `open`, `sat`,
    // `wrap`) as locals/params/fields/fn names without ambiguity:
    //   - `ok`/`err`   : only meaningful as text (Result constructor `ok(v)`/pattern `ok(v)=>`),
    //                    resolved downstream by lexeme, never by token kind.
    //   - `sat`/`wrap` : arithmetic-domain type constructors, also resolved by lexeme in a type
    //                    position; the token kind is irrelevant to a name position.
    //   - `open`       : keyword only as the top-level `open enum` lead-in (a decl-leading
    //                    position expectName never reaches).
    //   - `type`       : keyword only as the top-level `type X = …` alias lead-in and as the
    //                    `comptime T: type` metatype (both matched via `self.match(.kw_type)`
    //                    before any name position is consulted).
    //   - `use`        : reserved but otherwise unused, so free in every non-leading position.
    fn isContextualNameKeyword(_: *Parser, kind: token.Kind) bool {
        return switch (kind) {
            .kw_ok, .kw_err, .kw_type, .kw_use, .kw_open, .kw_sat, .kw_wrap => true,
            else => false,
        };
    }

    fn expectName(self: *Parser, message: []const u8) anyerror!ast.Ident {
        if (self.current.kind != .identifier and !self.isContextualNameKeyword(self.current.kind)) return self.fail(message);
        const out = ident(self.current);
        self.advance();
        return out;
    }

    fn expectSymbol(self: *Parser, message: []const u8) anyerror!ast.Ident {
        if (!self.isSymbol(self.current.kind)) return self.fail(message);
        const out = ident(self.current);
        self.advance();
        return out;
    }

    fn expectIdentifierText(self: *Parser, text: []const u8, message: []const u8) anyerror!void {
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, text)) return self.fail(message);
        self.advance();
    }

    fn expect(self: *Parser, kind: token.Kind, message: []const u8) anyerror!void {
        _ = try self.expectTok(kind, message);
    }

    fn expectTok(self: *Parser, kind: token.Kind, message: []const u8) anyerror!token.Token {
        if (self.current.kind != kind) return self.fail(message);
        const tok = self.current;
        self.advance();
        return tok;
    }

    // Close a generic/type-argument list, splitting a `>>` (shift_right) token into two
    // `>` so nested generics like `Foo<Bar<T>>` parse. Consumes one `>`; on a `>>`,
    // leaves a synthetic `>` as the current token for the enclosing list to consume.
    fn consumeGenericClose(self: *Parser, message: []const u8) anyerror!token.Token {
        if (self.current.kind == .greater) {
            const tok = self.current;
            self.advance();
            return tok;
        }
        if (self.current.kind == .shift_right) {
            const tok = token.Token{ .kind = .greater, .lexeme = ">", .span = self.current.span };
            self.current = token.Token{ .kind = .greater, .lexeme = ">", .span = self.current.span };
            return tok;
        }
        return self.fail(message);
    }

    fn match(self: *Parser, kind: token.Kind) bool {
        if (self.current.kind != kind) return false;
        self.advance();
        return true;
    }

    fn matchIdentifierText(self: *Parser, text: []const u8) bool {
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.current.lexeme, text)) return false;
        self.advance();
        return true;
    }

    fn advance(self: *Parser) void {
        self.previous = self.current;
        self.current = self.lx.next();
    }

    fn synchronizeTopLevel(self: *Parser, start_offset: usize) void {
        if (self.current.kind != .eof and self.current.span.offset == start_offset) self.advance();
        var depth: usize = 0;
        while (self.current.kind != .eof) {
            if (depth == 0) {
                if (self.isTopLevelStart()) return;
                if (self.current.kind == .semicolon or self.current.kind == .r_brace) {
                    self.advance();
                    return;
                }
            }
            self.updateSyncDepth(&depth);
            self.advance();
        }
    }

    fn synchronizeStatement(self: *Parser, start_offset: usize) void {
        if (self.current.kind != .eof and self.current.kind != .r_brace and self.current.span.offset == start_offset) self.advance();
        var depth: usize = 0;
        while (self.current.kind != .eof and self.current.kind != .r_brace) {
            if (depth == 0) {
                if (self.current.kind == .semicolon) {
                    self.advance();
                    return;
                }
                if (self.isStatementStart()) return;
            }
            self.updateSyncDepth(&depth);
            self.advance();
        }
    }

    const DeclBodyRecovery = enum { module_member, impl_member, trait_member, field };

    fn synchronizeModuleMember(self: *Parser, start_offset: usize) void {
        self.synchronizeDeclBody(start_offset, .module_member);
    }

    fn synchronizeImplMember(self: *Parser, start_offset: usize) void {
        self.synchronizeDeclBody(start_offset, .impl_member);
    }

    fn synchronizeTraitMember(self: *Parser, start_offset: usize) void {
        self.synchronizeDeclBody(start_offset, .trait_member);
    }

    fn synchronizeField(self: *Parser, start_offset: usize) void {
        self.synchronizeDeclBody(start_offset, .field);
    }

    fn synchronizeDeclBody(self: *Parser, start_offset: usize, recovery: DeclBodyRecovery) void {
        if (self.current.kind != .eof and self.current.kind != .r_brace and self.current.span.offset == start_offset) self.advance();
        var depth: usize = 0;
        while (self.current.kind != .eof and self.current.kind != .r_brace) {
            if (depth == 0) {
                if (self.current.kind == .semicolon or self.current.kind == .comma) {
                    self.advance();
                    return;
                }
                if (self.isDeclBodyStart(recovery)) return;
            }
            self.updateSyncDepth(&depth);
            self.advance();
        }
    }

    fn updateSyncDepth(self: *Parser, depth: *usize) void {
        switch (self.current.kind) {
            .l_paren, .l_brace, .l_bracket => depth.* += 1,
            .r_paren, .r_brace, .r_bracket => {
                if (depth.* > 0) depth.* -= 1;
            },
            else => {},
        }
    }

    fn isTopLevelStart(self: *Parser) bool {
        return switch (self.current.kind) {
            .hash,
            .kw_pub,
            .kw_export,
            .kw_extern,
            .kw_open,
            .kw_const,
            .kw_fn,
            .kw_type,
            .kw_packed,
            .kw_overlay,
            .kw_struct,
            .kw_union,
            .kw_enum,
            => true,
            .identifier => std.mem.eql(u8, self.current.lexeme, "trait") or
                std.mem.eql(u8, self.current.lexeme, "impl") or
                std.mem.eql(u8, self.current.lexeme, "module") or
                std.mem.eql(u8, self.current.lexeme, "global") or
                std.mem.eql(u8, self.current.lexeme, "async") or
                std.mem.eql(u8, self.current.lexeme, "opaque") or
                std.mem.eql(u8, self.current.lexeme, "move"),
            else => false,
        };
    }

    fn isDeclBodyStart(self: *Parser, recovery: DeclBodyRecovery) bool {
        return switch (recovery) {
            .module_member => switch (self.current.kind) {
                .kw_export, .kw_fn, .kw_const => true,
                .identifier => std.mem.eql(u8, self.current.lexeme, "global"),
                else => false,
            },
            .impl_member => switch (self.current.kind) {
                .hash, .kw_export, .kw_fn => true,
                else => false,
            },
            .trait_member => switch (self.current.kind) {
                .hash, .kw_fn => true,
                else => false,
            },
            .field => self.current.kind == .identifier or self.isContextualNameKeyword(self.current.kind),
        };
    }

    fn isStatementStart(self: *Parser) bool {
        return switch (self.current.kind) {
            .hash,
            .kw_let,
            .kw_var,
            .kw_for,
            .kw_while,
            .kw_if,
            .kw_switch,
            .kw_unsafe,
            .kw_comptime,
            .kw_asm,
            .l_brace,
            .kw_return,
            .kw_break,
            .kw_continue,
            .kw_defer,
            .kw_assert,
            => true,
            .identifier => self.isLabeledLoopStart(),
            else => false,
        };
    }

    fn isLabeledLoopStart(self: *Parser) bool {
        if (self.current.kind != .identifier) return false;
        var lx = self.lx;
        if (lx.next().kind != .colon) return false;
        const after = lx.next().kind;
        return after == .kw_for or after == .kw_while;
    }

    fn startsStructLiteralField(self: *Parser) bool {
        if (self.current.kind != .dot) return false;
        var lx = self.lx;
        const name = lx.next();
        if (!self.isSymbol(name.kind)) return false;
        return lx.next().kind == .equal;
    }

    fn isSymbol(_: *Parser, kind: token.Kind) bool {
        return switch (kind) {
            .identifier, .kw_ok, .kw_err, .kw_open, .kw_type, .kw_use, .kw_never, .kw_void, .kw_bool, .kw_wrap, .kw_sat, .kw_serial, .kw_atomic, .kw_sizeof, .kw_alignof => true,
            else => false,
        };
    }

    fn fail(self: *Parser, message: []const u8) anyerror {
        self.reporter.err(self.current.span, "{s}: {s}", .{ parseDiagnosticCode(message), message });
        return error.ParseFailed;
    }

    fn parseDiagnosticCode(message: []const u8) []const u8 {
        if (std.mem.eql(u8, message, "expected expression")) return "E_PARSE_EXPECTED_EXPRESSION";
        if (std.mem.eql(u8, message, "expected parameter name")) return "E_PARSE_EXPECTED_PARAMETER_NAME";
        return "E_PARSE";
    }

    fn enterParseDepth(self: *Parser) anyerror!void {
        if (self.parse_depth >= max_parse_depth) {
            return self.failNestingTooDeep();
        }
        self.parse_depth += 1;
    }

    fn leaveParseDepth(self: *Parser) void {
        self.parse_depth -= 1;
    }

    fn reserveParseWrapperDepth(self: *Parser, depth: *usize) anyerror!void {
        if (depth.* >= max_parse_depth) return self.failNestingTooDeep();
        depth.* += 1;
    }

    fn failNestingTooDeep(self: *Parser) anyerror {
        if (!self.nesting_too_deep_reported) {
            self.nesting_too_deep_reported = true;
            self.reporter.err(self.current.span, "E_NESTING_TOO_DEEP: nesting too deep", .{});
        }
        return error.ParseFailed;
    }

    fn previousSpan(self: *Parser, fallback: diagnostics.Span) diagnostics.Span {
        _ = self;
        return fallback;
    }

    fn lxTokenBeforeCurrent(self: *Parser) diagnostics.Span {
        return self.previous.span;
    }

    fn previousLexeme(self: *Parser) []const u8 {
        return self.previous.lexeme;
    }
};

const Infix = struct {
    left_bp: u8,
    right_bp: u8,
    op: ast.BinaryOp,
};

// Prefix operators (`-`, `~`, `!`, deref `*`, addr-of `&`) must bind tighter than every
// binary operator so that `-a + b` parses as `(-a) + b`, matching C. The highest binary
// `left_bp` is 19 (`* / %`), so any value above 20 keeps binary ops from binding into the
// operand while still allowing postfix `.`/`[]`/`()` (handled in parseExpr, not by binding power).
const prefix_operand_bp: u8 = 21;

fn infix(kind: token.Kind) ?Infix {
    return switch (kind) {
        .pipe_pipe => .{ .left_bp = 1, .right_bp = 2, .op = .logical_or },
        .amp_amp => .{ .left_bp = 3, .right_bp = 4, .op = .logical_and },
        .equal_equal => .{ .left_bp = 5, .right_bp = 6, .op = .eq },
        .bang_equal => .{ .left_bp = 5, .right_bp = 6, .op = .ne },
        .less => .{ .left_bp = 7, .right_bp = 8, .op = .lt },
        .less_equal => .{ .left_bp = 7, .right_bp = 8, .op = .le },
        .greater => .{ .left_bp = 7, .right_bp = 8, .op = .gt },
        .greater_equal => .{ .left_bp = 7, .right_bp = 8, .op = .ge },
        .pipe => .{ .left_bp = 9, .right_bp = 10, .op = .bit_or },
        .caret => .{ .left_bp = 11, .right_bp = 12, .op = .bit_xor },
        .amp => .{ .left_bp = 13, .right_bp = 14, .op = .bit_and },
        .shift_left => .{ .left_bp = 15, .right_bp = 16, .op = .shl },
        .shift_right => .{ .left_bp = 15, .right_bp = 16, .op = .shr },
        .plus => .{ .left_bp = 17, .right_bp = 18, .op = .add },
        .minus => .{ .left_bp = 17, .right_bp = 18, .op = .sub },
        .star => .{ .left_bp = 19, .right_bp = 20, .op = .mul },
        .slash => .{ .left_bp = 19, .right_bp = 20, .op = .div },
        .percent => .{ .left_bp = 19, .right_bp = 20, .op = .mod },
        else => null,
    };
}

fn ident(tok: token.Token) ast.Ident {
    return .{ .text = tok.lexeme, .span = tok.span };
}

// The name of a bare scalar-builtin-type ident expression (`f32`, `usize`, `i32`, …), or null.
// Used to recognize the C-style cast `(ScalarType)(expr)`: such a name is never a value, so the
// form is unambiguous. `PAddr`/`VAddr`/`DmaAddr` are excluded — those are real value types whose
// parenthesized name could be a grouped value, not a cast.
fn scalarTypeNameIdent(expr: ast.Expr) ?[]const u8 {
    const name = switch (expr.kind) {
        .ident => |id| id.text,
        else => return null,
    };
    if (std.mem.eql(u8, name, "PAddr") or std.mem.eql(u8, name, "VAddr") or std.mem.eql(u8, name, "DmaAddr")) return null;
    return if (layout.scalarLayout(name) != null) name else null;
}

fn joinSpan(first: diagnostics.Span, last: diagnostics.Span) diagnostics.Span {
    const first_end = first.offset + first.len;
    const last_end = last.offset + last.len;
    const end = if (last_end > first_end) last_end else first_end;
    return .{ .offset = first.offset, .len = end - first.offset, .line = first.line, .column = first.column };
}
