//! Function-body fallback census.
//!
//! The C/LLVM backends admit a function body through the verified-MIR fast path
//! (`emitSimpleMirFunction`) when they recognize its shape, and otherwise fall
//! back to rendering the transitional AST body artifact
//! (`FunctionBodyFallbackArtifact.syntax: ast.Block`). Closing the P0 goal
//! ("codegen no longer ingests an AST body") means shrinking that fallback to
//! zero. Today the shapes are attacked one at a time, blindly — there is no
//! frequency-ranked worklist of what still falls back.
//!
//! This census fills that gap. It hooks the *real* admission decision in
//! `emitFunctionDefinitions` (no re-run, so zero drift): for every non-extern
//! function each backend emits, it records whether the function took the fast
//! path, the AST body fallback, or hit `UnsupportedEmission`, together with a
//! compact MIR *shape descriptor* (block count, entry terminator, return value
//! kind, trap/cleanup flags, and the set of MIR instruction kinds present).
//! `tools/toolchain/fallback-census-report.py` aggregates the records into a
//! ranked table so the remaining fallbacks can be attacked head-of-distribution
//! first instead of by guesswork.
//!
//! Gating mirrors `lower_cov`: the recorder is armed from `main` with the
//! `MC_FALLBACK_CENSUS` env var (its value is the output path). When unset,
//! every `record` call is a single cheap branch and a normally-built `mcc` pays
//! nothing. The corpus driver gives each `mcc` invocation a unique output path
//! and concatenates the files afterward, so no append/locking is needed here.

const std = @import("std");
const builtin = @import("builtin");
const mir = @import("mir.zig");

pub const Backend = enum { c, llvm };

/// How a function's body entered (or failed to enter) code emission.
pub const Status = enum {
    /// Emitted from verified MIR by the fast path — no AST body needed.
    admitted,
    /// Fast path declined; body rendered from the transitional AST fallback.
    fallback,
    /// Fast path declined and there is no AST fallback — `UnsupportedEmission`.
    unsupported,
};

var enabled: bool = false;
var armed: bool = false;
var out_path_buf: [4096]u8 = undefined;
var out_path_len: usize = 0;
var io: ?std.Io = null;
// JSONL accumulator. One compile is single-threaded through codegen (C then
// LLVM in turn), so a plain global with no locking is safe, matching lower_cov.
var buf: std.ArrayList(u8) = .empty;

/// Arm the recorder from `main`: hand it the process `std.Io` (Zig 0.16 file
/// writes need it) and the `MC_FALLBACK_CENSUS` value (output path, or
/// null/empty to stay disabled). Idempotent.
pub fn init(value: std.Io, out_path: ?[]const u8) void {
    armed = true;
    io = value;
    const val = out_path orelse return;
    if (val.len == 0 or val.len > out_path_buf.len) return;
    @memcpy(out_path_buf[0..val.len], val);
    out_path_len = val.len;
    enabled = true;
}

/// Record one function's admission outcome. No-op unless armed. Best-effort:
/// any allocation failure is swallowed so the census never changes `mcc`'s
/// behavior or exit status.
pub fn record(backend: Backend, status: Status, module: ?[]const u8, fn_mir: mir.Function) void {
    if (builtin.is_test and !armed) {
        init(std.testing.io, std.process.Environ.getPosix(std.testing.environ, "MC_FALLBACK_CENSUS"));
    }
    if (!enabled) return;
    const a = std.heap.page_allocator;
    writeRecordJson(&buf, a, backend, status, module, fn_mir) catch return;
    buf.append(a, '\n') catch return;
}

/// Write the accumulated JSONL to the `MC_FALLBACK_CENSUS` path (truncating).
/// Called on every `mcc` exit path. An empty file is still written when armed so
/// the driver can distinguish "ran, nothing fell back" from "invocation failed".
pub fn dump() void {
    if (!enabled) return;
    const the_io = io orelse return;
    const path = out_path_buf[0..out_path_len];
    const file = std.Io.Dir.cwd().createFile(the_io, path, .{ .truncate = true }) catch return;
    defer file.close(the_io);
    file.writeStreamingAll(the_io, buf.items) catch return;
}

/// Test-only: reset the accumulator between in-process cases.
pub fn resetForTest() void {
    buf.clearRetainingCapacity();
}

/// Test-only: the JSONL accumulated so far.
pub fn bufferForTest() []const u8 {
    return buf.items;
}

fn writeRecordJson(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    backend: Backend,
    status: Status,
    module: ?[]const u8,
    fn_mir: mir.Function,
) !void {
    const shape = mirShape(fn_mir);
    try out.appendSlice(a, "{\"backend\":\"");
    try out.appendSlice(a, @tagName(backend));
    try out.appendSlice(a, "\",\"status\":\"");
    try out.appendSlice(a, @tagName(status));
    try out.appendSlice(a, "\",\"module\":");
    try writeJsonString(out, a, module orelse "");
    try out.appendSlice(a, ",\"fn\":");
    try writeJsonString(out, a, fn_mir.name);
    try out.print(a, ",\"blocks\":{d},\"term\":", .{shape.blocks});
    try writeJsonString(out, a, shape.term);
    try out.appendSlice(a, ",\"ret\":");
    try writeJsonString(out, a, shape.ret);
    try out.print(a, ",\"traps\":{d},\"cleanup\":{s},\"instrs\":", .{ shape.traps, if (shape.cleanup) "true" else "false" });
    try writeInstrSet(out, a, fn_mir);
    try out.appendSlice(a, "}");
}

const Shape = struct {
    blocks: usize,
    term: []const u8,
    ret: []const u8,
    traps: usize,
    cleanup: bool,
};

fn mirShape(fn_mir: mir.Function) Shape {
    return .{
        .blocks = fn_mir.blocks.len,
        .term = if (fn_mir.blocks.len == 0) "none" else fn_mir.blocks[0].terminator.name(),
        .ret = returnKind(fn_mir),
        .traps = fn_mir.trap_edges.len,
        .cleanup = hasCleanup(fn_mir),
    };
}

fn hasCleanup(fn_mir: mir.Function) bool {
    if (fn_mir.ownership_cleanup_plan.actions.len != 0) return true;
    if (fn_mir.ownership_cleanup_plan.cancellations.len != 0) return true;
    for (fn_mir.cleanup_cfg.edges) |edge| if (edge.actions.len != 0) return true;
    return false;
}

/// The normalized `value_id` of the first `return_value` instruction — the axis
/// the return classifiers switch on. Non-keyword ids (a local/param/global
/// name) collapse to "<ident>" so functions group by return *shape*, not by the
/// unique name they happen to return.
fn returnKind(fn_mir: mir.Function) []const u8 {
    for (fn_mir.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.kind != .return_value) continue;
            const value_id = instruction.value_id orelse return "void";
            return normalizeReturnId(value_id);
        }
    }
    return "none";
}

fn normalizeReturnId(value_id: []const u8) []const u8 {
    const keywords = [_][]const u8{
        "void",          "int",   "char",  "bool",  "float",
        "binary",        "unary", "cast",  "null",  "deref",
        "struct_literal", "array_literal", "address_of",
    };
    for (keywords) |kw| {
        if (std.mem.eql(u8, value_id, kw)) return kw;
    }
    return "<ident>";
}

/// The set of MIR instruction kinds present anywhere in the function, in enum
/// order, as a JSON string of comma-separated tag names. This is the finest
/// grouping axis: it names exactly which constructs a fallen-back function
/// contains, which points at the recognizer family to build.
fn writeInstrSet(out: *std.ArrayList(u8), a: std.mem.Allocator, fn_mir: mir.Function) !void {
    const fields = @typeInfo(mir.Instruction.Kind).@"enum".fields;
    var present = [_]bool{false} ** fields.len;
    for (fn_mir.blocks) |block| {
        for (block.instructions) |instruction| {
            present[@intFromEnum(instruction.kind)] = true;
        }
    }
    try out.append(a, '"');
    var first = true;
    inline for (fields, 0..) |field, i| {
        if (present[i]) {
            if (!first) try out.append(a, ',');
            try out.appendSlice(a, field.name);
            first = false;
        }
    }
    try out.append(a, '"');
}

fn writeJsonString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => if (c < 0x20) {
            try out.print(a, "\\u{x:0>4}", .{c});
        } else {
            try out.append(a, c);
        },
    };
    try out.append(a, '"');
}
