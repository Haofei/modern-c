const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const token = @import("token.zig");

pub const Parser = struct {
    lx: lexer.Lexer,
    previous: token.Token,
    current: token.Token,
    reporter: *diagnostics.Reporter,
    allocator: std.mem.Allocator = undefined,

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
        var decls: std.ArrayList(ast.Decl) = .empty;
        errdefer decls.deinit(allocator);

        while (self.current.kind != .eof) {
            const attrs = try self.parseAttrs();
            try decls.append(allocator, try self.parseDecl(attrs));
        }

        return .{ .decls = try decls.toOwnedSlice(allocator) };
    }

    fn parseDecl(self: *Parser, attrs: []ast.Attr) anyerror!ast.Decl {
        const start = if (attrs.len > 0) attrs[0].span else self.current.span;

        // `move` is a contextual qualifier (section 18.1) on a struct declaration
        // making it a linear resource type. At top level a leading `move` is
        // unambiguous — declarations otherwise start with a keyword.
        const is_move = self.matchIdentifierText("move");
        if (is_move and self.current.kind != .kw_extern and self.current.kind != .kw_struct) {
            return self.fail("'move' applies only to struct declarations");
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
            return self.fail("expected extern fn or extern struct");
        }

        if (self.match(.kw_open)) {
            try self.expect(.kw_enum, "expected 'enum' after open");
            const enum_decl = try self.finishEnumDecl(true);
            return .{ .span = joinSpan(start, enum_decl.name.span), .attrs = attrs, .kind = .{ .enum_decl = enum_decl } };
        }

        const exported = self.match(.kw_export);
        const is_const = self.match(.kw_const);
        if (self.match(.kw_fn)) {
            const fn_decl = try self.finishFnDecl(null, is_const, exported);
            const end = if (fn_decl.body) |body| body.span else fn_decl.name.span;
            return .{ .span = joinSpan(start, end), .attrs = attrs, .kind = .{ .fn_decl = fn_decl } };
        }

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
            return .{ .span = joinSpan(start, semi.span), .attrs = attrs, .kind = .{ .global_decl = .{ .name = name, .ty = ty, .init = initializer } } };
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
        if (self.current.kind != .r_paren) {
            while (true) {
                const is_comptime = self.match(.kw_comptime);
                const param_name = try self.expectName("expected parameter name");
                try self.expect(.colon, "expected ':' after parameter name");
                const ty = try self.parseType();
                try params.append(self.allocator, .{ .name = param_name, .ty = ty, .is_comptime = is_comptime });
                if (!self.match(.comma) or self.current.kind == .r_paren) break;
            }
        }
        try self.expect(.r_paren, "expected ')' after parameters");

        const return_type = if (self.match(.arrow)) try self.parseType() else null;
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
        };
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
        return .{ .name = name, .cases = try cases.toOwnedSlice(self.allocator) };
    }

    fn finishFieldList(self: *Parser, open_message: []const u8, close_message: []const u8) anyerror![]ast.Field {
        try self.expect(.l_brace, open_message);
        var fields: std.ArrayList(ast.Field) = .empty;
        errdefer fields.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const field_name = try self.expectName("expected field name");
            try self.expect(.colon, "expected ':' after field name");
            const ty = try self.parseType();
            const offset = try self.parseFieldOffset();
            _ = self.match(.comma) or self.match(.semicolon);
            try fields.append(self.allocator, .{ .name = field_name, .ty = ty, .offset = offset });
        }
        try self.expect(.r_brace, close_message);
        return fields.toOwnedSlice(self.allocator);
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
        const end = try self.expectTok(.r_bracket, "expected ']' after attribute");
        return .{
            .span = joinSpan(start, end.span),
            .kind = if (std.mem.eql(u8, name.text, "no_lang_trap")) .no_lang_trap else .{ .named = name },
        };
    }

    fn parseBlock(self: *Parser) anyerror!ast.Block {
        const start = try self.expectTok(.l_brace, "expected block");
        var items: std.ArrayList(ast.Stmt) = .empty;
        errdefer items.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            try items.append(self.allocator, try self.parseStmt());
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
        if (self.match(.kw_for)) return self.parseFor();
        if (self.match(.kw_while)) return self.parseWhile();
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
            const value = if (self.current.kind != .semicolon) try self.parseExpr(0) else null;
            const end = try self.expectTok(.semicolon, "expected ';' after return");
            return .{ .span = joinSpan(start, end.span), .kind = .{ .@"return" = value } };
        }
        if (self.match(.kw_break)) {
            const start = self.lxTokenBeforeCurrent();
            const end = try self.expectTok(.semicolon, "expected ';' after break");
            return .{ .span = joinSpan(start, end.span), .kind = .@"break" };
        }
        if (self.match(.kw_continue)) {
            const start = self.lxTokenBeforeCurrent();
            const end = try self.expectTok(.semicolon, "expected ';' after continue");
            return .{ .span = joinSpan(start, end.span), .kind = .@"continue" };
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

    fn parseFor(self: *Parser) anyerror!ast.Stmt {
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
                .iterable = iterable,
                .body = body,
            } },
        };
    }

    fn parseWhile(self: *Parser) anyerror!ast.Stmt {
        const start = self.lxTokenBeforeCurrent();
        const condition = try self.parseExpr(0);
        const body = try self.parseBlock();
        return .{
            .span = joinSpan(start, body.span),
            .kind = .{ .loop = .{
                .kind = .@"while",
                .label = null,
                .iterable = condition,
                .body = body,
            } },
        };
    }

    fn parseLocal(self: *Parser, is_let: bool) anyerror!ast.Stmt {
        const start = self.current.span;
        var names: std.ArrayList(ast.Ident) = .empty;
        errdefer names.deinit(self.allocator);
        try names.append(self.allocator, try self.expectName("expected local name"));
        while (self.match(.comma)) {
            if (self.current.kind == .colon or self.current.kind == .equal) break;
            try names.append(self.allocator, try self.expectName("expected local name"));
        }
        const ty = if (self.match(.colon)) try self.parseType() else null;
        const initializer = if (self.match(.equal)) try self.parseExpr(0) else null;
        const end = try self.expectTok(.semicolon, "expected ';' after local declaration");
        const local = ast.LocalDecl{ .names = try names.toOwnedSlice(self.allocator), .ty = ty, .init = initializer };
        return .{ .span = joinSpan(start, end.span), .kind = if (is_let) .{ .let_decl = local } else .{ .var_decl = local } };
    }

    fn parseIfLet(self: *Parser) anyerror!ast.Stmt {
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

    fn parseSwitch(self: *Parser) anyerror!ast.Stmt {
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
        return .{ .span = joinSpan(start.span, end.span), .kind = .{ .@"switch" = .{ .subject = subject, .arms = try arms.toOwnedSlice(self.allocator) } } };
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
        while (self.match(.dot)) {
            const field = try self.expectSymbol("expected type member");
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
        var lhs = try self.parsePrefix();
        while (true) {
            lhs = try self.parsePostfix(lhs);
            if (self.current.kind == .identifier and std.mem.eql(u8, self.current.lexeme, "as")) {
                self.advance();
                const ty = try ast.makePtr(self.allocator, try self.parseType());
                const value = try ast.makePtr(self.allocator, lhs);
                lhs = .{ .span = joinSpan(value.span, ty.span), .kind = .{ .cast = .{ .value = value, .ty = ty } } };
                continue;
            }
            const op = infix(self.current.kind) orelse break;
            if (op.left_bp < min_bp) break;
            self.advance();
            const rhs = try self.parseExpr(op.right_bp);
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
            const inner = try ast.makePtr(self.allocator, try self.parseExpr(0));
            const end = try self.expectTok(.r_paren, "expected ')' after expression");
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
        while (true) {
            if (self.current.kind == .less and self.lessStartsGenericCall()) {
                self.advance();
                const type_args = try self.finishTypeArgsAfterLess();
                try self.expect(.l_paren, "expected '(' after generic call type arguments");
                expr = try self.finishCall(expr, type_args);
                continue;
            }
            if (self.match(.l_paren)) {
                expr = try self.finishCall(expr, &.{});
                continue;
            }
            if (self.match(.l_bracket)) {
                const first = try self.parseExpr(0);
                if (self.match(.dot_dot)) {
                    const end_expr = try ast.makePtr(self.allocator, try self.parseExpr(0));
                    const close = try self.expectTok(.r_bracket, "expected ']' after slice range");
                    const base = try ast.makePtr(self.allocator, expr);
                    const start_expr = try ast.makePtr(self.allocator, first);
                    expr = .{ .span = joinSpan(base.span, close.span), .kind = .{ .slice = .{ .base = base, .start = start_expr, .end = end_expr } } };
                    continue;
                }
                const idx = try ast.makePtr(self.allocator, first);
                const end = try self.expectTok(.r_bracket, "expected ']' after index");
                const base = try ast.makePtr(self.allocator, expr);
                expr = .{ .span = joinSpan(base.span, end.span), .kind = .{ .index = .{ .base = base, .index = idx } } };
                continue;
            }
            if (self.match(.dot)) {
                if (self.match(.star)) {
                    const base = try ast.makePtr(self.allocator, expr);
                    expr = .{ .span = joinSpan(base.span, self.lxTokenBeforeCurrent()), .kind = .{ .deref = base } };
                    continue;
                }
                const name = try self.expectSymbol("expected member name");
                const base = try ast.makePtr(self.allocator, expr);
                expr = .{ .span = joinSpan(base.span, name.span), .kind = .{ .member = .{ .base = base, .name = name } } };
                continue;
            }
            if (self.match(.question)) {
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

    fn expectName(self: *Parser, message: []const u8) anyerror!ast.Ident {
        if (self.current.kind != .identifier) return self.fail(message);
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

    fn startsStructLiteralField(self: *Parser) bool {
        if (self.current.kind != .dot) return false;
        var lx = self.lx;
        const name = lx.next();
        if (!self.isSymbol(name.kind)) return false;
        return lx.next().kind == .equal;
    }

    fn isSymbol(_: *Parser, kind: token.Kind) bool {
        return switch (kind) {
            .identifier, .kw_ok, .kw_err, .kw_open, .kw_never, .kw_void, .kw_bool, .kw_wrap, .kw_sat, .kw_serial, .kw_atomic, .kw_sizeof, .kw_alignof => true,
            else => false,
        };
    }

    fn fail(self: *Parser, message: []const u8) anyerror {
        self.reporter.err(self.current.span, "{s}", .{message});
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

fn joinSpan(first: diagnostics.Span, last: diagnostics.Span) diagnostics.Span {
    const first_end = first.offset + first.len;
    const last_end = last.offset + last.len;
    const end = if (last_end > first_end) last_end else first_end;
    return .{ .offset = first.offset, .len = end - first.offset, .line = first.line, .column = first.column };
}

test "parser covers MC declaration and statement examples" {
    const source =
        \\extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
        \\global shared_counter: u32 = 0;
        \\extern struct Timespec { sec: i64, nsec: i64, }
        \\type LoadResult = Result<Module, LoadError>;
        \\type RawUart = [*]mut Uart16550;
        \\#[no_lang_trap]
        \\fn boot_entry() -> never { return trap(.Unreachable); }
        \\fn exercise(pa: PAddr, maybe: ?*mut Node, status: Status) -> u32 {
        \\    var sum: u32 = 0;
        \\    unsafe { let uart = mmio.map<Uart16550>(phys(0x1000_0000))?; raw.store<u64>(pa.residue(), uart.raw_lsr.read(.acquire)); }
        \\    if let p = maybe { sum = p.value + 1; }
        \\    switch status { .ready => 1, ok(v) => v + sum, _ => 0, }
        \\    #[unsafe_contract(no_overflow)] { sum = unchecked.add(sum, 1); }
        \\    return (sum & 0xff_u32) << 1;
        \\}
    ;
    var reporter = diagnostics.Reporter{
        .allocator = std.testing.allocator,
        .path = "parser_cases.mc",
        .source = source,
        .diagnostics = .empty,
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(source, &reporter);
    const module = try p.parseModule(allocator);
    defer module.deinit(allocator);
    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 7), module.decls.len);
    try std.testing.expectEqual(std.meta.Tag(ast.Decl.Kind).global_decl, std.meta.activeTag(module.decls[1].kind));
    try std.testing.expect(module.decls[1].kind.global_decl.ty != null);
    try std.testing.expect(module.decls[1].kind.global_decl.init != null);
}

test "parser accepts qualified generic type arguments" {
    const source = "fn read_user(buf: UserPtr<const u8>) -> void {}\n";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "qualified_type.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(source, &reporter);
    const module = try p.parseModule(allocator);
    defer module.deinit(allocator);

    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), module.decls.len);

    const fn_decl = module.decls[0].kind.fn_decl;
    try std.testing.expectEqual(@as(usize, 1), fn_decl.params.len);

    const param_ty = fn_decl.params[0].ty.kind.generic;
    try std.testing.expectEqualStrings("UserPtr", param_ty.base.text);
    try std.testing.expectEqual(@as(usize, 1), param_ty.args.len);

    const qualifier = param_ty.args[0].kind.qualified;
    try std.testing.expectEqual(ast.Mutability.@"const", qualifier.mutability);
    try std.testing.expectEqualStrings("u8", qualifier.child.kind.name.text);
}

test "parser distinguishes relational operators from generic calls" {
    const source =
        \\fn compare(a: u32, b: u32) -> bool { return a < b; }
        \\fn compare_equal(a: u32, b: u32) -> bool { return a >= b; }
        \\fn generic_then_compare(a: u32, b: u32, limit: u32) -> bool { return min<u32>(a, b) < limit; }
        \\fn compare_then_generic(a: u32, b: u32, limit: u32) -> bool { return limit > max<u32>(a, b); }
        \\fn call_generic(pa: PAddr, value: u64) -> void { raw.store<u64>(pa, value); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "relational_vs_generic.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var p = Parser.init(source, &reporter);
    const module = try p.parseModule(allocator);
    defer module.deinit(allocator);

    try std.testing.expect(!reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 5), module.decls.len);

    const lt = module.decls[0].kind.fn_decl.body.?.items[0].kind.@"return".?.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.lt, lt.op);

    const ge = module.decls[1].kind.fn_decl.body.?.items[0].kind.@"return".?.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.ge, ge.op);

    const generic_lt = module.decls[2].kind.fn_decl.body.?.items[0].kind.@"return".?.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.lt, generic_lt.op);
    try std.testing.expectEqual(@as(usize, 1), generic_lt.left.kind.call.type_args.len);

    const gt_generic = module.decls[3].kind.fn_decl.body.?.items[0].kind.@"return".?.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.gt, gt_generic.op);
    try std.testing.expectEqual(@as(usize, 1), gt_generic.right.kind.call.type_args.len);

    const call = module.decls[4].kind.fn_decl.body.?.items[0].kind.expr.kind.call;
    try std.testing.expectEqual(@as(usize, 1), call.type_args.len);
}

test "return statement span covers the whole statement" {
    const source = "fn f() -> u32 { return 1; }\n";
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "ret.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());

    const ret = module.decls[0].kind.fn_decl.body.?.items[0];
    try std.testing.expect(std.meta.activeTag(ret.kind) == .@"return");
    // The span runs from the `return` keyword through the terminating `;`,
    // not just the `;`.
    try std.testing.expectEqualStrings("return", source[ret.span.offset .. ret.span.offset + 6]);
    try std.testing.expectEqual(@as(u8, ';'), source[ret.span.offset + ret.span.len - 1]);
}

test "parser requires in after for binding" {
    const good_source = "fn good(xs: []const u32) -> void { for x in xs { } }\n";
    var good_reporter = diagnostics.Reporter.init(std.testing.allocator, "for_good.mc", good_source);
    defer good_reporter.deinit();

    var good_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer good_arena.deinit();

    var good_parser = Parser.init(good_source, &good_reporter);
    const good_module = try good_parser.parseModule(good_arena.allocator());
    defer good_module.deinit(good_arena.allocator());
    try std.testing.expect(!good_reporter.has_errors);

    const bad_source = "fn bad(xs: []const u32) -> void { for x over xs { } }\n";
    var bad_reporter = diagnostics.Reporter.init(std.testing.allocator, "for_bad.mc", bad_source);
    defer bad_reporter.deinit();

    var bad_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer bad_arena.deinit();

    var bad_parser = Parser.init(bad_source, &bad_reporter);
    try std.testing.expectError(error.ParseFailed, bad_parser.parseModule(bad_arena.allocator()));
    try std.testing.expect(bad_reporter.has_errors);
    try std.testing.expectEqualStrings("expected 'in' after for binding", bad_reporter.diagnostics.items[0].message);
}
