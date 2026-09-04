//! C backend closure-dispatch helpers.

const std = @import("std");

const lower_c_model = @import("lower_c_model.zig");
const mir = @import("mir.zig");

const BindThunk = lower_c_model.BindThunk;
const FnInfo = lower_c_model.FnInfo;

pub const SignatureCTypeFn = *const fn (ctx: *anyopaque, id: mir.SignatureTypeId) anyerror![]const u8;

/// The canonical executable-MIR path only emits precomputed bind thunks. It
/// does not need the legacy AST expression renderer used by closure bodies.
/// Keep this smaller context separate so ordinary module emission cannot keep
/// that renderer reachable through a callback slot.
pub const BindThunkContext = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    out: *std.ArrayList(u8),
    temp_index: *usize,
    emit_ctx: *anyopaque,
    signature_c_type: SignatureCTypeFn,
};

// Emit each collected scalar-env thunk: `static RET mc_envthunk_f(void *env, P...){
// return f((T)(uintptr_t)env, P...); }`. The first param is genuinely `void *`,
// matching the closure's code-pointer signature exactly.
pub fn emitBindThunks(ctx: BindThunkContext, bind_thunks: *std.StringHashMap(BindThunk)) !void {
    var it = bind_thunks.iterator();
    while (it.next()) |entry| {
        try emitBindThunk(ctx, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn emitBindThunk(ctx: BindThunkContext, thunk_name: []const u8, thunk: BindThunk) !void {
    const info = thunk.info;
    const returns_void = info.return_ty == .void or info.return_ty == .never;
    try emitBindThunkSignature(ctx, thunk_name, info);
    try emitBindThunkBody(ctx, thunk.fname, info, returns_void);
}

fn emitBindThunkSignature(ctx: BindThunkContext, thunk_name: []const u8, info: FnInfo) !void {
    try ctx.out.appendSlice(ctx.allocator, "static MC_UNUSED ");
    try ctx.out.appendSlice(ctx.allocator, try ctx.signature_c_type(ctx.emit_ctx, info.return_type_id));
    try ctx.out.print(ctx.allocator, " {s}(void *mc_env", .{thunk_name});
    for (info.params[1..], 0..) |param, i| {
        try ctx.out.print(ctx.allocator, ", {s} mc_a{d}", .{ try ctx.signature_c_type(ctx.emit_ctx, param.type_id), i });
    }
    try ctx.out.appendSlice(ctx.allocator, ") {\n    ");
}

fn emitBindThunkBody(ctx: BindThunkContext, fn_name: []const u8, info: FnInfo, returns_void: bool) !void {
    if (!returns_void) try ctx.out.appendSlice(ctx.allocator, "return ");
    try ctx.out.print(ctx.allocator, "{s}((", .{fn_name});
    try ctx.out.appendSlice(ctx.allocator, try ctx.signature_c_type(ctx.emit_ctx, info.params[0].type_id));
    try ctx.out.appendSlice(ctx.allocator, ")(uintptr_t)mc_env");
    for (info.params[1..], 0..) |_, i| {
        try ctx.out.print(ctx.allocator, ", mc_a{d}", .{i});
    }
    try ctx.out.appendSlice(ctx.allocator, ");\n}\n\n");
}
