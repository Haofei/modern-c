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

        if (self.match(.kw_extern)) {
            const abi = if (self.current.kind == .string_literal) blk: {
                const text = self.current.lexeme;
                self.advance();
                break :blk text;
            } else null;
            if (self.matchIdentifierText("mmio")) {
                try self.expect(.kw_struct, "expected 'struct' after extern mmio");
                const struct_decl = try self.finishStructDecl("mmio");
                return .{ .span = joinSpan(start, struct_decl.name.span), .attrs = attrs, .kind = .{ .extern_struct = struct_decl } };
            }
            if (self.match(.kw_fn)) {
                const fn_decl = try self.finishFnDecl(abi, false);
                return .{ .span = joinSpan(start, self.previousSpan(fn_decl.name.span)), .attrs = attrs, .kind = .{ .extern_fn = fn_decl } };
            }
            if (self.match(.kw_struct)) {
                const struct_decl = try self.finishStructDecl(abi);
                return .{ .span = joinSpan(start, struct_decl.name.span), .attrs = attrs, .kind = .{ .extern_struct = struct_decl } };
            }
            return self.fail("expected extern fn or extern struct");
        }

        _ = self.match(.kw_export);
        const is_const = self.match(.kw_const);
        if (self.match(.kw_fn)) {
            const fn_decl = try self.finishFnDecl(null, is_const);
            const end = if (fn_decl.body) |body| body.span else fn_decl.name.span;
            return .{ .span = joinSpan(start, end), .attrs = attrs, .kind = .{ .fn_decl = fn_decl } };
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
                const name = try self.expectName("expected packed bits name");
                try self.skipOptionalTypeAndBody();
                return .{ .span = joinSpan(start, name.span), .attrs = attrs, .kind = .{ .opaque_decl = name } };
            }
        }

        if (self.matchIdentifierText("global")) {
            const name = try self.expectName("expected global name");
            const ty = if (self.match(.colon)) try self.parseType() else null;
            const initializer = if (self.match(.equal)) try self.parseExpr(0) else null;
            const semi = try self.expectTok(.semicolon, "expected ';' after global declaration");
            return .{ .span = joinSpan(start, semi.span), .attrs = attrs, .kind = .{ .global_decl = .{ .name = name, .ty = ty, .init = initializer } } };
        }

        return self.fail("expected top-level fn, type, or extern declaration");
    }

    fn skipOptionalTypeAndBody(self: *Parser) anyerror!void {
        while (self.current.kind != .l_brace and self.current.kind != .semicolon and self.current.kind != .eof) self.advance();
        if (self.match(.semicolon)) return;
        if (self.current.kind == .l_brace) {
            var depth: usize = 0;
            while (self.current.kind != .eof) {
                if (self.match(.l_brace)) {
                    depth += 1;
                    continue;
                }
                if (self.match(.r_brace)) {
                    depth -= 1;
                    if (depth == 0) return;
                    continue;
                }
                self.advance();
            }
        }
    }

    fn finishFnDecl(self: *Parser, abi: ?[]const u8, is_const: bool) anyerror!ast.FnDecl {
        const name = try self.expectName("expected function name");
        try self.expect(.l_paren, "expected '(' after function name");

        var params: std.ArrayList(ast.Param) = .empty;
        errdefer params.deinit(self.allocator);
        if (self.current.kind != .r_paren) {
            while (true) {
                const param_name = try self.expectName("expected parameter name");
                try self.expect(.colon, "expected ':' after parameter name");
                const ty = try self.parseType();
                try params.append(self.allocator, .{ .name = param_name, .ty = ty });
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
        };
    }

    fn finishStructDecl(self: *Parser, abi: ?[]const u8) anyerror!ast.StructDecl {
        const name = try self.expectName("expected struct name");
        try self.expect(.l_brace, "expected '{' after struct name");
        var fields: std.ArrayList(ast.Field) = .empty;
        errdefer fields.deinit(self.allocator);
        while (self.current.kind != .r_brace and self.current.kind != .eof) {
            const field_name = try self.expectName("expected field name");
            try self.expect(.colon, "expected ':' after field name");
            const ty = try self.parseType();
            _ = self.match(.comma) or self.match(.semicolon);
            try fields.append(self.allocator, .{ .name = field_name, .ty = ty });
        }
        try self.expect(.r_brace, "expected '}' after struct fields");
        return .{ .name = name, .abi = abi, .fields = try fields.toOwnedSlice(self.allocator) };
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
        if (self.match(.kw_asm)) return self.parseAsmStmt();
        if (self.current.kind == .l_brace) {
            const block = try self.parseBlock();
            return .{ .span = block.span, .kind = .{ .block = block } };
        }
        if (self.match(.kw_return)) {
            const value = if (self.current.kind != .semicolon) try self.parseExpr(0) else null;
            const end = try self.expectTok(.semicolon, "expected ';' after return");
            return .{ .span = end.span, .kind = .{ .@"return" = value } };
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
        while (self.current.kind != .l_brace and self.current.kind != .eof) self.advance();
        var depth: usize = 0;
        while (self.current.kind != .eof) {
            if (self.match(.l_brace)) {
                depth += 1;
                continue;
            }
            if (self.match(.r_brace)) {
                depth -= 1;
                if (depth == 0) break;
                continue;
            }
            self.advance();
        }
        return .{ .span = joinSpan(start, self.lxTokenBeforeCurrent()), .kind = .asm_stmt };
    }

    fn parseFor(self: *Parser) anyerror!ast.Stmt {
        const start = self.lxTokenBeforeCurrent();
        const label = try self.expectName("expected loop binding after for");
        try self.expect(.identifier, "expected 'in' after for binding");
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
        try self.expect(.kw_let, "expected let after if");
        const pattern = try self.parsePattern();
        try self.expect(.equal, "expected '=' in if let");
        const value = try self.parseExpr(0);
        const then_block = try self.parseBlock();
        const else_block = if (self.match(.kw_else)) try self.parseBlock() else null;
        const end = if (else_block) |b| b.span else then_block.span;
        return .{ .span = joinSpan(start.span, end), .kind = .{ .if_let = .{ .pattern = pattern, .value = value, .then_block = then_block, .else_block = else_block } } };
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
        if (self.current.kind == .integer_literal or self.current.kind == .string_literal or self.current.kind == .kw_true or self.current.kind == .kw_false) {
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

        const base = try self.expectSymbol("expected type name");
        var ty = ast.TypeExpr{ .span = base.span, .kind = .{ .name = base } };
        if (self.match(.less)) {
            var args: std.ArrayList(ast.TypeExpr) = .empty;
            errdefer args.deinit(self.allocator);
            if (self.current.kind != .greater) {
                while (true) {
                    try args.append(self.allocator, try self.parseType());
                    if (!self.match(.comma)) break;
                }
            }
            const end = try self.expectTok(.greater, "expected '>' after type arguments");
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
            const value = try ast.makePtr(self.allocator, try self.parseExpr(14));
            return .{ .span = joinSpan(start, value.span), .kind = .{ .deref = value } };
        }
        if (self.match(.amp)) {
            const start = self.lxTokenBeforeCurrent();
            const value = try ast.makePtr(self.allocator, try self.parseExpr(14));
            return .{ .span = joinSpan(start, value.span), .kind = .{ .address_of = value } };
        }
        return self.parsePrimary();
    }

    fn unary(self: *Parser, op: ast.UnaryOp) anyerror!ast.Expr {
        const start = self.lxTokenBeforeCurrent();
        const value = try ast.makePtr(self.allocator, try self.parseExpr(14));
        return .{ .span = joinSpan(start, value.span), .kind = .{ .unary = .{ .op = op, .expr = value } } };
    }

    fn parsePrimary(self: *Parser) anyerror!ast.Expr {
        if (self.isSymbol(self.current.kind)) {
            const tok = self.current;
            self.advance();
            return .{ .span = tok.span, .kind = .{ .ident = ident(tok) } };
        }
        if (self.match(.integer_literal)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .int_literal = self.previousLexeme() } };
        if (self.match(.string_literal)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .string_literal = self.previousLexeme() } };
        if (self.match(.char_literal)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .char_literal = self.previousLexeme() } };
        if (self.match(.kw_true)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .bool_literal = true } };
        if (self.match(.kw_false)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .{ .bool_literal = false } };
        if (self.match(.kw_null)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .null_literal };
        if (self.match(.kw_uninit)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .uninit_literal };
        if (self.match(.kw_unreachable)) return .{ .span = self.lxTokenBeforeCurrent(), .kind = .unreachable_expr };
        if (self.match(.dot)) {
            const dot = self.lxTokenBeforeCurrent();
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
            if (self.match(.less)) {
                const type_args = try self.finishTypeArgsAfterLess();
                if (!self.match(.l_paren)) return self.fail("generic expression must be a call in this parser slice");
                expr = try self.finishCall(expr, type_args);
                continue;
            }
            if (self.match(.l_paren)) {
                expr = try self.finishCall(expr, &.{});
                continue;
            }
            if (self.match(.l_bracket)) {
                const idx = try ast.makePtr(self.allocator, try self.parseExpr(0));
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
                expr = .{ .span = joinSpan(inner.span, self.lxTokenBeforeCurrent()), .kind = .{ .try_expr = inner } };
                continue;
            }
            break;
        }
        return expr;
    }

    fn finishTypeArgsAfterLess(self: *Parser) anyerror![]ast.TypeExpr {
        var args: std.ArrayList(ast.TypeExpr) = .empty;
        errdefer args.deinit(self.allocator);
        if (self.current.kind != .greater) {
            while (true) {
                try args.append(self.allocator, try self.parseType());
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(.greater, "expected '>' after type arguments");
        return args.toOwnedSlice(self.allocator);
    }

    fn finishCall(self: *Parser, callee_expr: ast.Expr, type_args: []ast.TypeExpr) anyerror!ast.Expr {
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

    fn expect(self: *Parser, kind: token.Kind, message: []const u8) anyerror!void {
        _ = try self.expectTok(kind, message);
    }

    fn expectTok(self: *Parser, kind: token.Kind, message: []const u8) anyerror!token.Token {
        if (self.current.kind != kind) return self.fail(message);
        const tok = self.current;
        self.advance();
        return tok;
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
