//! C backend source-map emission (`emit-map`).
//!
//! This module consumes the already-generated C text and MIR metadata, then
//! writes the mcmap inventory. It deliberately does not import `lower_c.zig`,
//! keeping C codegen and map emission separate.

const std = @import("std");

const artifact_model = @import("artifact_model.zig");
const ast = @import("ast.zig");
const backend = @import("backend.zig");
const source_map_mechanics = @import("source_map_mechanics.zig");
const mir = @import("mir.zig");
const mir_syntax = @import("mir_syntax.zig");

pub fn appendSourceMap(
    allocator: std.mem.Allocator,
    source_map: source_map_mechanics.SourceMapMechanicsView,
    out: *std.ArrayList(u8),
    generated_c: []const u8,
    mir_module: *const mir.Module,
    source_path: []const u8,
    generated_c_path: ?[]const u8,
    opts: backend.LowerOptions,
) !void {
    var line_index = try buildGeneratedLineIndex(allocator, generated_c);
    defer line_index.deinit(allocator);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.appendSlice(allocator, "# columns: kind symbol source_line source_column source_len generated_c_line source_path generated_c_path typed_ast_node mir_block object_symbol source_module source_qualname symbol_kind visibility backend_name origin\n");
    const decls = source_map.declsForRowEnumeration();
    var mapper = SourceMapEmitter{
        .allocator = allocator,
        .out = &payload,
        .source_path = source_path,
        .generated_c_path = generated_c_path orelse "-",
        .line_index = line_index.items,
        .mir_module = mir_module,
        .module_name = moduleNameFromPath(source_path),
    };
    defer mapper.deinit();
    try mapper.collectRowArtifactsFromDecls(decls);
    try mapper.emitCollectedRows();

    var mir_facts_input: std.ArrayList(u8) = .empty;
    defer mir_facts_input.deinit(allocator);
    try appendMirFactsDigestInput(allocator, &mir_facts_input, mir_module);

    const bundle = artifact_model.ArtifactBundle.forSourceMap(generated_c, payload.items, mir_facts_input.items, opts);

    try artifact_model.appendArtifactBundle(allocator, out, bundle, .source_map);
    try out.appendSlice(allocator, payload.items);
}

pub fn appendLineDirective(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    source_path: ?[]const u8,
    span: ast.Span,
) !void {
    const path = source_path orelse return;
    if (span.line == 0) return;
    try out.print(allocator, "#line {d} \"", .{span.line});
    try appendEscapedString(out, allocator, path);
    try out.appendSlice(allocator, "\"\n");
}

fn appendMirFactsDigestInput(allocator: std.mem.Allocator, out: *std.ArrayList(u8), module: *const mir.Module) !void {
    try out.appendSlice(allocator, "mcmap-mir-facts-v1\n");
    try out.print(allocator, "module symbols={d} functions={d} aggregate_return_summaries={d} aggregate_return_pointer_facts={d}\n", .{
        module.symbol_identities.len,
        module.functions.len,
        module.aggregate_return_summaries.len,
        module.aggregate_return_pointer_facts.len,
    });
    for (module.symbol_identities) |identity| {
        try out.print(allocator, "symbol_identity id={} spelling={s}\n", .{ typedIndexOrMax(identity.id), identity.spelling });
    }
    for (module.aggregate_return_summaries) |fact| {
        try out.print(allocator, "aggregate_return_summary callee={s} ", .{fact.callee});
        try appendSourcePointForDigest(allocator, out, fact.source);
    }
    for (module.aggregate_return_pointer_facts) |fact| {
        try out.print(allocator, "aggregate_return_pointer callee={s} field={s} provenance={s} pointer_kind={s} mutability={s} child={s} ", .{
            fact.callee,
            fact.field_path,
            @tagName(fact.provenance),
            @tagName(fact.pointer_shape.kind),
            @tagName(fact.pointer_shape.mutability),
            fact.pointer_shape.child,
        });
        try appendSourcePointForDigest(allocator, out, fact.source);
    }
    for (module.functions) |function| {
        try out.print(allocator, "function name={s} symbol_id={} return={s} no_lang_trap={} irq_context={} extern={} c_abi={} params={} blocks={} trap_edges={} contracts={} ranges={} bounds={} integers={} const_get={} call_targets={} target_types={} pointer_provenance={} representations={} elided_bounds={}\n", .{
            function.name,
            typedIndexOrMax(function.typed_symbol_id),
            function.return_ty.name(),
            function.no_lang_trap,
            function.irq_context,
            function.is_extern,
            function.c_abi,
            function.param_count,
            function.blocks.len,
            function.trap_edges.len,
            function.contract_regions.len,
            function.range_facts.len,
            function.bounds_facts.len,
            function.integer_facts.len,
            function.const_get_facts.len,
            function.call_target_facts.len,
            function.target_type_facts.len,
            function.pointer_provenance_facts.len,
            function.representation_facts.len,
            function.elided_bounds.len,
        });
        for (function.type_identities) |identity| {
            try out.print(allocator, "type_identity fn={s} id={} spelling={s}\n", .{ function.name, typedIndexOrMax(identity.id), identity.spelling });
        }
        for (function.span_identities) |identity| {
            try out.print(allocator, "span_identity fn={s} id={} ", .{ function.name, typedIndexOrMax(identity.id) });
            try appendSourcePointForDigest(allocator, out, identity.source);
        }
        for (function.value_identities) |identity| {
            try out.print(allocator, "value_identity fn={s} id={} spelling={s}\n", .{ function.name, typedIndexOrMax(identity.id), identity.spelling });
        }
        for (function.target_owner_identities) |identity| {
            try out.print(allocator, "target_owner_identity fn={s} id={} spelling={s}\n", .{ function.name, typedIndexOrMax(identity.id), identity.spelling });
        }
        for (function.blocks) |block| {
            try out.print(allocator, "block fn={s} id={} typed_id={} kind={s} terminator={s} successors=", .{ function.name, block.id, typedIndexOrMax(block.typed_id), block.kind, block.terminator.name() });
            for (block.successors, 0..) |successor, index| {
                if (index != 0) try out.append(allocator, ',');
                try out.print(allocator, "{}", .{successor});
            }
            try out.appendSlice(allocator, " typed_successors=");
            for (block.typed_successors, 0..) |successor, index| {
                if (index != 0) try out.append(allocator, ',');
                try out.print(allocator, "{}", .{typedIndexOrMax(successor)});
            }
            try out.append(allocator, '\n');
            for (block.instructions) |instruction| {
                try out.print(allocator, "instr fn={s} block={} kind={s} result={s} typed_result={} detail={s} target_type={s} aggregate={s} const_index={} target_owner={s} typed_target_owner={} target_index={} value_id={s} typed_value={} typed_span={} line={} column={} offset={} len={}\n", .{
                    function.name,
                    block.id,
                    @tagName(instruction.kind),
                    instruction.result_ty.name(),
                    typedIndexOrMax(instruction.typed_result_ty),
                    instruction.detail,
                    if (instruction.target_ty) |target_ty| mir_syntax.typeText(target_ty) else "none",
                    if (instruction.aggregate_construction) |kind| @tagName(kind) else "none",
                    optionalUsizeOrMax(instruction.const_index),
                    instruction.target_owner orelse "none",
                    optionalTypedIndexOrMax(instruction.typed_target_owner_id),
                    optionalUsizeOrMax(instruction.target_index),
                    instruction.value_id orelse "none",
                    optionalTypedIndexOrMax(instruction.typed_value_id),
                    typedIndexOrMax(instruction.typed_span_id),
                    instruction.line,
                    instruction.column,
                    instruction.source_offset,
                    instruction.source_len,
                });
            }
        }
        for (function.trap_edges) |edge| {
            try out.print(allocator, "trap_edge fn={s} from={} trap={} kind={s} source={s} line={} column={} offset={} len={}\n", .{ function.name, edge.from_block, edge.trap_block, @tagName(edge.kind), @tagName(edge.source), edge.line, edge.column, edge.source_offset, edge.source_len });
        }
        for (function.contract_regions) |region| {
            try out.print(allocator, "contract_region fn={s} id={} kind={s} begin={} end={}\n", .{ function.name, region.id, region.kind, region.begin_line, region.end_line });
        }
        for (function.range_facts) |fact| {
            try out.print(allocator, "range_fact fn={s} region={} target={s} op={s} left={s} right={s} result={s} line={} column={}\n", .{ function.name, fact.region_id, fact.target, fact.op, fact.left, fact.right, fact.result_ty.name(), fact.line, fact.column });
        }
        for (function.bounds_facts) |fact| {
            try out.print(allocator, "bounds_fact fn={s} kind={s} ", .{ function.name, @tagName(fact.kind) });
            try appendSourcePointForDigest(allocator, out, fact.source);
        }
        for (function.integer_facts) |fact| {
            try out.print(allocator, "integer_fact fn={s} literal={s} target={s} ", .{ function.name, fact.literal, fact.target_ty.name() });
            try appendSourcePointForDigest(allocator, out, fact.source);
        }
        for (function.const_get_facts) |fact| {
            try out.print(allocator, "const_get_fact fn={s} index={} ", .{ function.name, fact.index });
            try appendSourcePointForDigest(allocator, out, fact.source);
        }
        for (function.call_target_facts) |fact| {
            try out.print(allocator, "call_target_fact fn={s} kind={s} result={s} ", .{ function.name, @tagName(fact.kind), fact.result_ty.name() });
            try appendSourcePointForDigest(allocator, out, fact.source);
        }
        for (function.target_type_facts) |fact| {
            try out.print(allocator, "target_type_fact fn={s} kind={s} target={s} result={s} typed_result={} typed_span={} aggregate={s} target_owner={s} typed_target_owner={} target_index={} ", .{
                function.name,
                @tagName(fact.kind),
                mir_syntax.typeText(fact.target_ty),
                fact.result_ty.name(),
                typedIndexOrMax(fact.typed_result_ty),
                typedIndexOrMax(fact.typed_span_id),
                if (fact.aggregate_construction) |kind| @tagName(kind) else "none",
                fact.target_owner orelse "none",
                typedIndexOrMax(fact.typed_target_owner_id),
                optionalUsizeOrMax(fact.target_index),
            });
            try appendSourcePointForDigest(allocator, out, fact.source);
        }
        for (function.pointer_provenance_facts) |fact| {
            try out.print(allocator, "pointer_provenance_fact fn={s} subject={s} field={s} element={} storage={s} provenance={s} pointer_kind={s} mutability={s} child={s} invalidation_reason={s} invalidation_policy={s} ", .{
                function.name,
                fact.subject,
                fact.field_path orelse "none",
                optionalUsizeOrMax(fact.element_index),
                fact.storage orelse "none",
                @tagName(fact.provenance),
                @tagName(fact.pointer_shape.kind),
                @tagName(fact.pointer_shape.mutability),
                fact.pointer_shape.child,
                @tagName(fact.invalidation_reason),
                @tagName(fact.invalidation_policy),
            });
            try appendSourcePointForDigest(allocator, out, fact.source);
        }
        for (function.representation_facts) |fact| {
            try out.print(allocator, "representation_fact fn={s} kind={s} detail={s} result={s} typed_result={} value_id={s} typed_value={} typed_span={} ", .{
                function.name,
                @tagName(fact.kind),
                fact.detail,
                fact.result_ty.name(),
                typedIndexOrMax(fact.typed_result_ty),
                fact.value_id,
                typedIndexOrMax(fact.typed_value_id),
                typedIndexOrMax(fact.typed_span_id),
            });
            try appendSourcePointForDigest(allocator, out, fact.source);
        }
        for (function.elided_bounds) |source| {
            try out.print(allocator, "elided_bounds fn={s} ", .{function.name});
            try appendSourcePointForDigest(allocator, out, source);
        }
    }
}

fn appendSourcePointForDigest(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source: mir.SourcePoint) !void {
    try out.print(allocator, "line={} column={} offset={} len={}\n", .{ source.line, source.column, source.offset, source.len });
}

fn typedIndexOrMax(index: anytype) usize {
    return if (index.isValid()) index.index() else std.math.maxInt(usize);
}

fn optionalTypedIndexOrMax(index: anytype) usize {
    return if (index) |value| typedIndexOrMax(value) else std.math.maxInt(usize);
}

fn optionalUsizeOrMax(value: ?usize) usize {
    return value orelse std.math.maxInt(usize);
}

// The source module name a symbol belongs to: the file basename without directory or
// extension (MC is one module per file). Provenance tooling keys on this; RSS namespace
// isolation can later override it per symbol once a richer module model exists.
fn moduleNameFromPath(source_path: []const u8) []const u8 {
    if (source_path.len == 0) return "-";
    var name = source_path;
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name = name[slash + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (dot > 0) name = name[0..dot];
    }
    return if (name.len == 0) "-" else name;
}

// The declared name of a type-level declaration, for inventory rows.
fn declTypeName(kind: ast.Decl.Kind) ?ast.Ident {
    return switch (kind) {
        .struct_decl => |d| d.name,
        .enum_decl => |d| d.name,
        .union_decl => |d| d.name,
        .packed_bits_decl => |d| d.name,
        .overlay_union_decl => |d| d.name,
        .opaque_decl => |name| name,
        .type_alias => |d| d.name,
        else => null,
    };
}

// FFI/autogen boundary classification for an inventory row: an explicit `#[origin("...")]`
// override, else `external` for an extern declaration, else `source`.
fn declOrigin(decl: ast.Decl) []const u8 {
    for (decl.attrs) |attr| switch (attr.kind) {
        .origin => |o| return o,
        else => {},
    };
    return if (std.meta.activeTag(decl.kind) == .extern_fn) "external" else "source";
}

// The `#[backend_name("Y")]` override string for a declaration, if present.
fn backendNameOverride(attrs: []const ast.Attr) ?[]const u8 {
    for (attrs) |attr| {
        switch (attr.kind) {
            .backend_name => |name| return name,
            else => {},
        }
    }
    return null;
}

fn declKindName(kind: ast.Decl.Kind) []const u8 {
    return switch (kind) {
        .struct_decl => "struct",
        .enum_decl => "enum",
        .union_decl => "union",
        .packed_bits_decl => "packed_bits",
        .overlay_union_decl => "overlay_union",
        .opaque_decl => "opaque",
        .type_alias => "type_alias",
        else => "decl",
    };
}

const GeneratedLine = struct {
    source_line: usize,
    generated_line: usize,
};

fn buildGeneratedLineIndex(allocator: std.mem.Allocator, generated_c: []const u8) !std.ArrayList(GeneratedLine) {
    var lines: std.ArrayList(GeneratedLine) = .empty;
    errdefer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, generated_c, '\n');
    var generated_line: usize = 1;
    while (it.next()) |raw_line| : (generated_line += 1) {
        const line = std.mem.trim(u8, raw_line, "\r");
        const source_line = cLineDirectiveSourceLine(line) orelse continue;
        try lines.append(allocator, .{
            .source_line = source_line,
            .generated_line = generated_line + 1,
        });
    }
    return lines;
}

fn cLineDirectiveSourceLine(line: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line, "#line ")) return null;
    var index: usize = "#line ".len;
    var value: usize = 0;
    var saw_digit = false;
    while (index < line.len) : (index += 1) {
        const ch = line[index];
        if (ch < '0' or ch > '9') break;
        saw_digit = true;
        value = value * 10 + (ch - '0');
    }
    return if (saw_digit) value else null;
}

const SourceMapEmitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    source_path: []const u8,
    generated_c_path: []const u8,
    line_index: []const GeneratedLine,
    mir_module: *const mir.Module,
    current_function: ?[]const u8 = null,
    module_name: []const u8 = "-",
    // SymbolMeta for the declaration whose rows are currently being emitted; expression
    // rows inherit the owning declaration's identity/provenance.
    symbol_kind: []const u8 = "value",
    visibility: []const u8 = "internal",
    origin: []const u8 = "source",
    decl_row_artifacts: std.ArrayList(ast.Decl) = .empty,

    fn deinit(self: *SourceMapEmitter) void {
        self.decl_row_artifacts.deinit(self.allocator);
    }

    fn collectRowArtifactsFromDecls(self: *SourceMapEmitter, decls: []const ast.Decl) !void {
        for (decls) |decl| {
            try self.decl_row_artifacts.append(self.allocator, decl);
        }
    }

    fn emitCollectedRows(self: *SourceMapEmitter) !void {
        for (self.decl_row_artifacts.items) |decl| {
            self.origin = declOrigin(decl);
            switch (decl.kind) {
                .global_decl => |global| {
                    self.symbol_kind = if (global.is_const) "assoc_const" else "value";
                    self.visibility = "internal";
                    try self.emitEntry("global", global.name.text, global.name.span, global.name.text, "mir:global:init");
                    if (global.init) |init| try self.emitEntry("global_initializer_expr", global.name.text, init.span, global.name.text, "mir:global:init");
                },
                .fn_decl => |fn_decl| if (fn_decl.body) |body| {
                    self.symbol_kind = "free_fn";
                    self.visibility = if (fn_decl.exported) "exported" else "internal";
                    const obj = backendNameOverride(decl.attrs) orelse fn_decl.name.text;
                    try self.emitEntry("function", fn_decl.name.text, fn_decl.name.span, obj, "mir:function:entry");
                    const previous_function = self.current_function;
                    self.current_function = fn_decl.name.text;
                    try self.emitBlock(body);
                    self.current_function = previous_function;
                },
                .extern_fn => |fn_decl| {
                    self.symbol_kind = "extern_fn";
                    self.visibility = "exported";
                    try self.emitEntry("extern_fn", fn_decl.name.text, fn_decl.name.span, fn_decl.name.text, "mir:function:entry");
                },
                else => {
                    // Type-level declarations: emit one inventory row each so the symbol map
                    // is a complete declared-symbol inventory, not just executable code.
                    if (declTypeName(decl.kind)) |name| {
                        self.symbol_kind = if (std.meta.activeTag(decl.kind) == .type_alias) "type_alias" else "type";
                        self.visibility = "internal";
                        try self.emitEntry(declKindName(decl.kind), name.text, name.span, name.text, "-");
                    }
                },
            }
        }
        self.symbol_kind = "value";
        self.visibility = "internal";
    }

    fn emitBlock(self: *SourceMapEmitter, block: ast.Block) !void {
        for (block.items) |stmt| {
            try self.emitStmt(stmt);
            switch (stmt.kind) {
                .block, .unsafe_block => |nested| try self.emitBlock(nested),
                .comptime_block => {},
                .contract_block => |contract| try self.emitBlock(contract.block),
                .loop => |loop| try self.emitBlock(loop.body),
                .if_let => |node| {
                    try self.emitBlock(node.then_block);
                    if (node.else_block) |else_block| try self.emitBlock(else_block);
                },
                .@"switch" => |node| {
                    for (node.arms) |arm| switch (arm.body) {
                        .block => |arm_block| try self.emitBlock(arm_block),
                        .expr => |expr| try self.emitEntry("switch_expr", self.current_function orelse "-", expr.span, self.current_function orelse "-", "mir:switch:expr"),
                    };
                },
                .@"defer" => |expr| switch (expr.kind) {
                    .block => |nested| try self.emitBlock(nested),
                    else => {},
                },
                else => {},
            }
        }
    }

    fn emitStmt(self: *SourceMapEmitter, stmt: ast.Stmt) !void {
        const symbol = self.current_function orelse "-";
        const mir_block = try std.fmt.allocPrint(self.allocator, "mir:{s}:span:{d}:{d}", .{ symbol, stmt.span.line, stmt.span.column });
        defer self.allocator.free(mir_block);
        try self.emitEntry(@tagName(stmt.kind), symbol, stmt.span, symbol, mir_block);
        try self.emitStmtExpressions(stmt);
    }

    fn emitStmtExpressions(self: *SourceMapEmitter, stmt: ast.Stmt) !void {
        switch (stmt.kind) {
            .let_decl, .var_decl => |local| if (local.init) |init| try self.emitExprTree("initializer_expr", init),
            .assignment => |node| {
                try self.emitExprTree("assignment_target_expr", node.target);
                try self.emitExprTree("assignment_value_expr", node.value);
            },
            .@"return" => |maybe_expr| if (maybe_expr) |expr| try self.emitExprTree("return_expr", expr),
            .assert => |expr| try self.emitExprTree("assert_expr", expr),
            .loop => |loop| if (loop.iterable) |expr| try self.emitExprTree(if (loop.kind == .@"while") "while_condition_expr" else "for_iterable_expr", expr),
            .if_let => |node| try self.emitExprTree("if_let_value_expr", node.value),
            .@"switch" => |node| try self.emitExprTree("switch_subject_expr", node.subject),
            .@"defer" => |expr| try self.emitExprTree("defer_expr", expr),
            .asm_stmt => |asm_stmt| {
                for (asm_stmt.inputs) |input| try self.emitExprTree("asm_input_expr", input.value);
            },
            .expr => |expr| try self.emitExprTree("expr", expr),
            else => {},
        }
    }

    fn emitExprTree(self: *SourceMapEmitter, root_kind: []const u8, expr: ast.Expr) anyerror!void {
        try self.emitExprEntry(root_kind, expr.span);
        try self.emitExprChildren(expr);
    }

    fn emitNestedExpr(self: *SourceMapEmitter, expr: ast.Expr) anyerror!void {
        const kind = try std.fmt.allocPrint(self.allocator, "expr_{s}", .{@tagName(expr.kind)});
        defer self.allocator.free(kind);
        try self.emitExprEntry(kind, expr.span);
        try self.emitExprChildren(expr);
    }

    fn emitExprChildren(self: *SourceMapEmitter, expr: ast.Expr) anyerror!void {
        switch (expr.kind) {
            .array_literal => |items| {
                for (items) |item| try self.emitNestedExpr(item);
            },
            .struct_literal => |fields| {
                for (fields) |field| try self.emitNestedExpr(field.value);
            },
            .grouped, .address_of, .deref => |inner| try self.emitNestedExpr(inner.*),
            .block => |block| try self.emitBlock(block),
            .unary => |node| try self.emitNestedExpr(node.expr.*),
            .binary => |node| {
                try self.emitNestedExpr(node.left.*);
                try self.emitNestedExpr(node.right.*);
            },
            .cast => |node| try self.emitNestedExpr(node.value.*),
            .call => |node| {
                try self.emitNestedExpr(node.callee.*);
                for (node.args) |arg| try self.emitNestedExpr(arg);
            },
            .index => |node| {
                try self.emitNestedExpr(node.base.*);
                try self.emitNestedExpr(node.index.*);
            },
            .slice => |node| {
                try self.emitNestedExpr(node.base.*);
                try self.emitNestedExpr(node.start.*);
                try self.emitNestedExpr(node.end.*);
            },
            .member => |node| try self.emitNestedExpr(node.base.*),
            .try_expr => |node| {
                try self.emitNestedExpr(node.operand.*);
                if (node.mapped) |mapped| try self.emitNestedExpr(mapped.*);
            },
            else => {},
        }
    }

    fn emitExprEntry(self: *SourceMapEmitter, kind: []const u8, span: ast.Span) !void {
        const symbol = self.current_function orelse "-";
        const mir_block = try std.fmt.allocPrint(self.allocator, "mir:{s}:expr:{d}:{d}", .{ symbol, span.line, span.column });
        defer self.allocator.free(mir_block);
        try self.emitEntry(kind, symbol, span, symbol, mir_block);
    }

    fn emitEntry(self: *SourceMapEmitter, kind: []const u8, symbol: []const u8, span: ast.Span, object_symbol: []const u8, mir_block: []const u8) !void {
        try self.out.appendSlice(self.allocator, "entry kind=");
        try appendMapString(self.out, self.allocator, kind);
        try self.out.appendSlice(self.allocator, " symbol=");
        try appendMapString(self.out, self.allocator, symbol);
        try self.out.print(self.allocator, " source_line={d} source_column={d} source_len={d} generated_c_line={d} source_path=", .{
            span.line,
            span.column,
            span.len,
            self.generatedLineForSource(span.line),
        });
        try appendMapString(self.out, self.allocator, self.source_path);
        try self.out.appendSlice(self.allocator, " generated_c_path=");
        try appendMapString(self.out, self.allocator, self.generated_c_path);
        try self.out.appendSlice(self.allocator, " typed_ast_node=");
        try self.out.appendSlice(self.allocator, "\"ast:");
        try appendMapStringContents(self.out, self.allocator, kind);
        try self.out.appendSlice(self.allocator, ":");
        try appendMapStringContents(self.out, self.allocator, symbol);
        try self.out.print(self.allocator, "@{d}:{d}\" mir_block=", .{ span.line, span.column });
        if (try self.mirLabelFor(symbol, span)) |mir_label| {
            defer self.allocator.free(mir_label);
            try appendMapString(self.out, self.allocator, mir_label);
        } else {
            try appendMapString(self.out, self.allocator, mir_block);
        }
        try self.out.appendSlice(self.allocator, " object_symbol=");
        try appendMapString(self.out, self.allocator, object_symbol);
        // mcmap v1: SymbolMeta provenance. backend_name defaults to the object symbol until a
        // per-symbol override exists; source_qualname is the symbol name (MC is flat today).
        try self.out.appendSlice(self.allocator, " source_module=");
        try appendMapString(self.out, self.allocator, self.module_name);
        try self.out.appendSlice(self.allocator, " source_qualname=");
        try appendMapString(self.out, self.allocator, symbol);
        try self.out.appendSlice(self.allocator, " symbol_kind=");
        try appendMapString(self.out, self.allocator, self.symbol_kind);
        try self.out.appendSlice(self.allocator, " visibility=");
        try appendMapString(self.out, self.allocator, self.visibility);
        try self.out.appendSlice(self.allocator, " backend_name=");
        try appendMapString(self.out, self.allocator, object_symbol);
        try self.out.appendSlice(self.allocator, " origin=");
        try appendMapString(self.out, self.allocator, self.origin);
        try self.out.appendSlice(self.allocator, "\n");
    }

    fn mirLabelFor(self: *SourceMapEmitter, symbol: []const u8, span: ast.Span) !?[]const u8 {
        const function = self.mirFunctionByName(symbol) orelse return null;
        if (try self.mirLabelForMatch(function, span, true)) |label| return label;
        return try self.mirLabelForMatch(function, span, false);
    }

    fn mirFunctionByName(self: *SourceMapEmitter, name: []const u8) ?mir.Function {
        for (self.mir_module.functions) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }

    fn mirLabelForMatch(self: *SourceMapEmitter, function: mir.Function, span: ast.Span, exact_column: bool) !?[]const u8 {
        for (function.blocks) |block| {
            for (block.instructions, 0..) |instruction, instruction_index| {
                if (instruction.line != span.line) continue;
                if (exact_column and instruction.column != span.column) continue;
                return try std.fmt.allocPrint(
                    self.allocator,
                    "mir:{s}:block:{d}:instr:{d}:{s}",
                    .{ function.name, block.id, instruction_index, @tagName(instruction.kind) },
                );
            }
        }
        return null;
    }

    fn generatedLineForSource(self: *SourceMapEmitter, source_line: usize) usize {
        var index: usize = 0;
        while (index < self.line_index.len) : (index += 1) {
            const entry = self.line_index[index];
            if (entry.source_line == source_line) {
                return entry.generated_line;
            }
        }
        for (self.line_index) |entry| {
            if (entry.source_line == source_line) return entry.generated_line;
        }
        return 0;
    }
};

fn appendMapString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try out.append(allocator, '"');
    try appendEscapedString(out, allocator, text);
    try out.append(allocator, '"');
}

fn appendMapStringContents(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    try appendEscapedString(out, allocator, text);
}

fn appendEscapedString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => if (ch < 0x20 or ch == 0x7f) {
            try out.print(allocator, "\\x{X:0>2}", .{ch});
        } else {
            try out.append(allocator, ch);
        },
    };
}
