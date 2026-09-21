//! Table-driven MIR *verification-fact* fixtures.
//!
//! `tests/mir_verify/<name>.mc` is an MC source fixture; its sibling
//! `<name>.expect` states what the verifier must find in it. This is the
//! corpus the `appendVerificationFactsFrom*` golden strings in `mir_tests.zig`
//! became: each of those tests parsed a program, asserted a list of
//! `mir verify fn=... pass=... finding=...` substrings, and separately
//! asserted which `E_*` diagnostics the verifier reported for the same
//! program. Both halves are one fixture here.
//!
//! The text a rule matches is therefore the two halves concatenated:
//!
//! ```text
//! mir verify fn=... pass=... finding=... ...     one line per verification fact
//! mir diagnostic <message>                       one line per reported diagnostic
//! ```
//!
//! Keeping the diagnostics in the same text is what lets a whole test move.
//! The facts say what the verifier *found*; the diagnostics say what it
//! *reported*. They are not the same assertion -- a finding that stops being
//! reported is a real regression -- so a fixture that asserted both still
//! asserts both, and `= n` / `>= n` carry the exact counts the Zig tests used.
//!
//! The `.expect` grammar and the directory walk are shared with the MIR dump
//! corpus; see `fixture_expect.zig`.

const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const fixture_expect = @import("fixture_expect.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const test_support = @import("test_support.zig");

const fixture_dir = "tests/mir_verify";

/// The verifier's findings and its diagnostics over one fixture.
fn appendVerifierReport(
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    mode: fixture_expect.Mode,
    out: *std.ArrayList(u8),
) !void {
    var reporter = diagnostics.Reporter.init(allocator, name, source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed: ?test_support.ParsedModule = null;
    defer if (parsed) |*p| p.deinit();

    const decls = switch (mode) {
        .raw => blk: {
            var p = parser.Parser.init(source, &reporter);
            const module = try p.parseModule(arena.allocator());
            try std.testing.expect(!reporter.has_errors);
            break :blk module.decls;
        },
        .resolved, .checked => blk: {
            parsed = if (mode == .checked)
                try test_support.parseCheckedModule(name, source)
            else
                try test_support.parseModule(name, source);
            break :blk parsed.?.decls();
        },
    };

    try mir.appendVerificationFactsFromDecls(allocator, decls, out);

    // One build, verified once: a fixture's diagnostic counts are exact, so
    // verifying twice into the same reporter would double every one of them.
    var built = try mir.buildFromDecls(allocator, decls);
    defer built.deinit();
    try mir.verifyBuiltMir(built, &reporter);
    for (reporter.diagnostics.items) |diagnostic| {
        try out.print(allocator, "mir diagnostic {s}\n", .{diagnostic.message});
    }
}

test "MIR verification-fact fixtures match their expected findings" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, fixture_dir, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    try fixture_expect.collect(allocator, io, dir, &names);

    // Anti-vacuity: an empty or mislaid fixture directory is a failure, not a
    // silently passing gate. The floor is the size of the corpus the in-Zig
    // golden strings became, less room to retire one.
    try std.testing.expect(names.items.len >= 25);

    var ok = true;
    for (names.items) |expect_path| {
        const base = expect_path[0 .. expect_path.len - ".expect".len];
        const source_path = try std.fmt.allocPrint(allocator, "{s}.mc", .{base});
        defer allocator.free(source_path);

        const expect_text = try dir.readFileAlloc(io, expect_path, allocator, .limited(1 * 1024 * 1024));
        defer allocator.free(expect_text);
        const source = dir.readFileAlloc(io, source_path, allocator, .limited(1 * 1024 * 1024)) catch {
            std.debug.print("mir verify fixture: {s}/{s} has no sibling {s}\n", .{ fixture_dir, expect_path, source_path });
            ok = false;
            continue;
        };
        defer allocator.free(source);

        var expectations = try fixture_expect.parse(allocator, expect_text);
        defer expectations.deinit(allocator);

        var report: std.ArrayList(u8) = .empty;
        defer report.deinit(allocator);
        try appendVerifierReport(allocator, source_path, source, expectations.mode, &report);

        if (!fixture_expect.check(source_path, report.items, expectations.rules.items)) ok = false;
    }

    try std.testing.expect(ok);
}
