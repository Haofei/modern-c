//! C backend inline-asm statement emission.

const std = @import("std");

const ast = @import("ast.zig");
const lower_c_model = @import("lower_c_model.zig");

const LocalInfo = lower_c_model.LocalInfo;

pub const WriteIndentFn = *const fn (ctx: *anyopaque) anyerror!void;
pub const CIdentFn = *const fn (ctx: *anyopaque, name: []const u8) anyerror![]const u8;
pub const EmitExprWithTargetFn = *const fn (ctx: *anyopaque, expr: ast.Expr, locals: ?*std.StringHashMap(LocalInfo), target_ty: ast.TypeExpr) anyerror!void;

pub const EmitContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    stub_asm: bool,
    emit_ctx: *anyopaque,
    write_indent: WriteIndentFn,
    c_ident: CIdentFn,
    emit_expr_with_target: EmitExprWithTargetFn,
};

pub fn emitAsmStmt(ctx: EmitContext, asm_stmt: ast.AsmStmt, locals: ?*std.StringHashMap(LocalInfo)) !void {
    if (asm_stmt.form == .precise) return emitPreciseAsmStmt(ctx, asm_stmt, locals);
    // `--stub-asm` (host-native logic tests): opaque asm is a barrier/operand-less
    // instruction sequence whose effect is irrelevant to the portable logic under test.
    // Emit only a compiler memory barrier (no target instructions) so the host assembler
    // never sees the arch mnemonic, while ordering w.r.t. surrounding memory is preserved.
    if (ctx.stub_asm) {
        try ctx.write_indent(ctx.emit_ctx);
        try ctx.out.appendSlice(ctx.allocator, "__asm__ __volatile__(\"\" ::: \"memory\");\n");
        return;
    }
    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, "#if defined(__GNUC__) || defined(__clang__)\n");
    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, if (asm_stmt.is_volatile) "__asm__ __volatile__(" else "__asm__(");
    try emitAsmTemplate(ctx.allocator, ctx.out, asm_stmt.templates);
    try ctx.out.appendSlice(ctx.allocator, " ::: ");
    if (asm_stmt.clobbers.len == 0) {
        try ctx.out.appendSlice(ctx.allocator, "\"memory\"");
    } else {
        for (asm_stmt.clobbers, 0..) |clobber, index| {
            if (index > 0) try ctx.out.appendSlice(ctx.allocator, ", ");
            try ctx.out.appendSlice(ctx.allocator, clobber);
        }
    }
    try ctx.out.appendSlice(ctx.allocator, ");\n");
    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, "#else\n");
    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, "#error \"inline asm emission requires compiler support\"\n");
    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, "#endif\n");
}

pub fn emitAsmTemplate(allocator: std.mem.Allocator, out: *std.ArrayList(u8), templates: []const []const u8) !void {
    if (templates.len == 0) {
        try out.appendSlice(allocator, "\"\"");
        return;
    }
    for (templates, 0..) |template, index| {
        if (index > 0) try out.appendSlice(allocator, " \"\\n\\t\" ");
        try out.appendSlice(allocator, template);
    }
}

/// Precise asm (§23.2): the compiler trusts the declared inputs, outputs, and
/// clobbers. Lowers to GCC/Clang extended asm with the operands wired in
/// declared order; outputs are numbered first, then inputs.
pub fn emitPreciseAsmStmt(ctx: EmitContext, asm_stmt: ast.AsmStmt, locals: ?*std.StringHashMap(LocalInfo)) !void {
    // `--stub-asm` (host-native logic tests): replace the arch instruction with a neutral
    // stub the host compiler can build — consume each input (so `-Werror` sees it used) and
    // zero each output (so it is defined). The portable logic under test must not depend on
    // the instruction's effect (e.g. a TLB fence is a no-op for single-threaded host logic).
    if (ctx.stub_asm) {
        for (asm_stmt.inputs) |input| {
            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.appendSlice(ctx.allocator, "(void)(");
            try ctx.emit_expr_with_target(ctx.emit_ctx, input.value, locals, input.ty);
            try ctx.out.appendSlice(ctx.allocator, ");\n");
        }
        for (asm_stmt.outputs) |output| {
            try ctx.write_indent(ctx.emit_ctx);
            try ctx.out.print(ctx.allocator, "{s} = 0;\n", .{try ctx.c_ident(ctx.emit_ctx, output.name.text)});
        }
        return;
    }
    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, "#if defined(__GNUC__) || defined(__clang__)\n");

    if (asm_stmt.outputs.len > 0 or asm_stmt.inputs.len > 0) {
        try ctx.write_indent(ctx.emit_ctx);
        try ctx.out.appendSlice(ctx.allocator, "/* MC_PRECISE_ASM");
        for (asm_stmt.outputs) |output| {
            try ctx.out.print(ctx.allocator, " out({s})->{s}", .{ output.reg, output.name.text });
        }
        for (asm_stmt.inputs) |input| {
            try ctx.out.print(ctx.allocator, " in({s})", .{input.reg});
        }
        try ctx.out.appendSlice(ctx.allocator, " */\n");
    }

    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, if (asm_stmt.is_volatile) "__asm__ __volatile__(" else "__asm__(");
    try emitAsmTemplate(ctx.allocator, ctx.out, asm_stmt.templates);
    try ctx.out.appendSlice(ctx.allocator, " : ");
    for (asm_stmt.outputs, 0..) |output, index| {
        if (index > 0) try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.out.print(ctx.allocator, "\"=r\"({s})", .{try ctx.c_ident(ctx.emit_ctx, output.name.text)});
    }
    try ctx.out.appendSlice(ctx.allocator, " : ");
    for (asm_stmt.inputs, 0..) |input, index| {
        if (index > 0) try ctx.out.appendSlice(ctx.allocator, ", ");
        try ctx.out.appendSlice(ctx.allocator, "\"r\"(");
        try ctx.emit_expr_with_target(ctx.emit_ctx, input.value, locals, input.ty);
        try ctx.out.appendSlice(ctx.allocator, ")");
    }
    if (asm_stmt.clobbers.len > 0) {
        try ctx.out.appendSlice(ctx.allocator, " : ");
        for (asm_stmt.clobbers, 0..) |clobber, index| {
            if (index > 0) try ctx.out.appendSlice(ctx.allocator, ", ");
            try ctx.out.appendSlice(ctx.allocator, clobber);
        }
    }
    try ctx.out.appendSlice(ctx.allocator, ");\n");

    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, "#else\n");
    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, "#error \"inline asm emission requires compiler support\"\n");
    try ctx.write_indent(ctx.emit_ctx);
    try ctx.out.appendSlice(ctx.allocator, "#endif\n");
}
