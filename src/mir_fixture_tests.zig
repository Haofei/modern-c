//! Table-driven MIR dump fixtures.
//!
//! `tests/mir/<name>.mc` is an MC source fixture; `tests/mir/<name>.expect`
//! states what its MIR dump must and must not contain. One test walks the
//! directory, so adding a case is adding two files rather than another
//! in-Zig golden string, and a representation change is one fixture edit
//! instead of a rewrite of the unit suite.
//!
//! The `.expect` grammar, and the walk that applies it, live in
//! `fixture_expect.zig`, which the MIR *verification-fact* corpus
//! (`tests/mir_verify/`, see `mir_verify_fixture_tests.zig`) shares. The two
//! corpora differ only in which dump they take of the fixture.

const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const fixture_expect = @import("fixture_expect.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const test_support = @import("test_support.zig");

const fixture_dir = "tests/mir";

/// Build the MIR dump for one fixture at the stage its `.expect` names.
fn appendFixtureDump(
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    mode: fixture_expect.Mode,
    out: *std.ArrayList(u8),
) !void {
    switch (mode) {
        .raw => {
            var reporter = diagnostics.Reporter.init(allocator, name, source);
            defer reporter.deinit();
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var p = parser.Parser.init(source, &reporter);
            const module = try p.parseModule(arena.allocator());
            defer module.deinit(arena.allocator());
            try std.testing.expect(!reporter.has_errors);
            try mir.appendDumpFromDecls(allocator, module.decls, out);
        },
        .resolved, .checked => {
            var parsed = if (mode == .checked)
                try test_support.parseCheckedModule(name, source)
            else
                try test_support.parseModule(name, source);
            defer parsed.deinit();
            try mir.appendDumpFromDecls(allocator, parsed.decls(), out);
        },
    }
}

test "MIR dump fixtures match their expected rows" {
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
    // silently passing gate.
    try std.testing.expect(names.items.len >= 20);

    var ok = true;
    for (names.items) |expect_path| {
        const base = expect_path[0 .. expect_path.len - ".expect".len];
        const source_path = try std.fmt.allocPrint(allocator, "{s}.mc", .{base});
        defer allocator.free(source_path);

        const expect_text = try dir.readFileAlloc(io, expect_path, allocator, .limited(1 * 1024 * 1024));
        defer allocator.free(expect_text);
        const source = dir.readFileAlloc(io, source_path, allocator, .limited(1 * 1024 * 1024)) catch {
            std.debug.print("mir fixture: {s}/{s} has no sibling {s}\n", .{ fixture_dir, expect_path, source_path });
            ok = false;
            continue;
        };
        defer allocator.free(source);

        var expectations = try fixture_expect.parse(allocator, expect_text);
        defer expectations.deinit(allocator);

        var dump: std.ArrayList(u8) = .empty;
        defer dump.deinit(allocator);
        try appendFixtureDump(allocator, source_path, source, expectations.mode, &dump);

        if (!fixture_expect.check(source_path, dump.items, expectations.rules.items)) ok = false;
    }

    try std.testing.expect(ok);
}
