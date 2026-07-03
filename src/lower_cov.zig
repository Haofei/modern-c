//! Lowering-coverage instrumentation (hardening item V3.2).
//!
//! This module provides a *function-level* coverage tracker for the split C and LLVM
//! backend modules (`lower_c*.zig`, `lower_llvm*.zig`). The Zig toolchain in the dev image ships
//! `llvm-cov`/`llvm-profdata` but Zig 0.16's self-hosted compiler exposes no
//! `-fprofile-instr-generate`/source-coverage flag for *its own* output, and `kcov`
//! is not installed — so true line/branch coverage of the `mcc` binary is not
//! available. Instead, `tools/toolchain/lowering-coverage.sh` injects a
//! `lower_cov.hit("<fn>")` probe at the top of every function in those backend
//! files, builds that instrumented `mcc`, and runs it over the differential corpus.
//! The set of probed-but-never-fired functions is the list of UNCOVERED lowering
//! branches.
//!
//! Fidelity: FUNCTION-level (a function counts as "covered" if it was entered at
//! least once). This is coarser than branch coverage, but it is exactly the
//! granularity that surfaces "this whole lowering family is never exercised by the
//! corpus" — which is the class the overlay-read miscompile lived in.
//!
//! The probe is gated on the `MC_LOWER_COV` environment variable (the value is the
//! output file path). When unset, `hit` is a single cheap branch and the tracker is
//! never armed, so a normally-built `mcc` pays nothing.

const std = @import("std");

// Fixed-capacity, allocation-free recorder. We store the (static, comptime) name
// pointers as they fire and de-duplicate at dump time. 1<<20 slots is far more than
// the number of lowering calls a single compile makes, and overflow simply stops
// recording (the dump still reflects everything seen up to the cap).
const cap = 1 << 20;

var enabled: bool = false;
var armed: bool = false;
var out_path_buf: [4096]u8 = undefined;
var out_path_len: usize = 0;
var names: [cap][]const u8 = undefined;
var count: usize = 0;
var io: ?std.Io = null;

/// Arm the tracker from `main`: hand it the process `std.Io` (file writes in Zig 0.16
/// need it) and the `MC_LOWER_COV` value (the output path, or null/empty to stay
/// disabled). Reading the env in `main` avoids depending on a `getenv` that this
/// Zig's std no longer exposes. Idempotent.
pub fn init(value: std.Io, out_path: ?[]const u8) void {
    armed = true;
    io = value;
    const val = out_path orelse return;
    if (val.len == 0 or val.len > out_path_buf.len) return;
    @memcpy(out_path_buf[0..val.len], val);
    out_path_len = val.len;
    enabled = true;
}

/// Record that lowering function `name` was entered. `name` must be a comptime
/// string literal (stable pointer) so the de-dup at dump time can compare by bytes.
pub fn hit(name: []const u8) void {
    if (!enabled) return;
    if (count >= cap) return;
    names[count] = name;
    count += 1;
}

/// Write the unique set of fired function names to the file named by `MC_LOWER_COV`,
/// one per line (truncating). The corpus driver gives each `mcc` invocation a unique
/// `MC_LOWER_COV` path and concatenates them afterward, so no append/locking is
/// needed here. Best-effort: any error is swallowed so instrumentation never changes
/// `mcc`'s exit status.
pub fn dump() void {
    if (!enabled) return;
    if (count == 0) return;
    const the_io = io orelse return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.page_allocator);
    var seen = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen.deinit();
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const n = names[i];
        if (seen.contains(n)) continue;
        seen.put(n, {}) catch {};
        buf.appendSlice(std.heap.page_allocator, n) catch return;
        buf.append(std.heap.page_allocator, '\n') catch return;
    }

    const path = out_path_buf[0..out_path_len];
    const file = std.Io.Dir.cwd().createFile(the_io, path, .{ .truncate = true }) catch return;
    defer file.close(the_io);
    file.writeStreamingAll(the_io, buf.items) catch return;
}
