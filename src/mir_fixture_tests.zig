//! Table-driven MIR dump fixtures.
//!
//! `tests/mir/<name>.mc` is an MC source fixture; `tests/mir/<name>.expect`
//! states what its MIR dump must and must not contain. One test walks the
//! directory, so adding a case is adding two files rather than another
//! in-Zig golden string, and a representation change is one fixture edit
//! instead of a rewrite of the unit suite.
//!
//! `.expect` grammar, one rule per line:
//!
//! ```text
//! # free-form comment
//! mode: raw | resolved | checked     how far the front end runs (default raw)
//! + "needle"                         the dump must contain this substring
//! - "needle"                         the dump must not contain it
//! = 4 "needle"                       it must occur exactly four times
//! ```
//!
//! The needle is everything between the first and last `"` on the line, so a
//! trailing space inside a needle survives a whitespace-trimming editor.
//! `mode` selects the pipeline the dump is taken from:
//!
//! - `raw`: parse only, the shape `parser.Parser.parseModule` produces.
//! - `resolved`: parse plus qualified-name resolution.
//! - `checked`: `resolved` plus a full `sema` pass over the declarations.
//!
//! The mode matters because the MIR builder reads what the front end left
//! behind, so a fixture must name the stage its expectations were taken at.

const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const test_support = @import("test_support.zig");

const fixture_dir = "tests/mir";

const Mode = enum { raw, resolved, checked };

const Rule = union(enum) {
    present: []const u8,
    absent: []const u8,
    count: struct { n: usize, needle: []const u8 },
};

const Expectations = struct {
    mode: Mode,
    rules: std.ArrayList(Rule),

    fn deinit(self: *Expectations, allocator: std.mem.Allocator) void {
        self.rules.deinit(allocator);
    }
};

/// The text between the first and last `"` of a rule line.
fn quoted(line: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, line, '"') orelse return null;
    if (close <= open) return null;
    return line[open + 1 .. close];
}

fn parseExpectations(allocator: std.mem.Allocator, text: []const u8) !Expectations {
    var result = Expectations{ .mode = .raw, .rules = .empty };
    errdefer result.rules.deinit(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "mode:")) {
            const value = std.mem.trim(u8, line["mode:".len..], " ");
            result.mode = std.meta.stringToEnum(Mode, value) orelse return error.UnknownFixtureMode;
            continue;
        }
        switch (line[0]) {
            '+' => try result.rules.append(allocator, .{ .present = quoted(line) orelse return error.MalformedFixtureRule }),
            '-' => try result.rules.append(allocator, .{ .absent = quoted(line) orelse return error.MalformedFixtureRule }),
            '=' => {
                const needle = quoted(line) orelse return error.MalformedFixtureRule;
                const digits = std.mem.trim(u8, line[1..std.mem.indexOfScalar(u8, line, '"').?], " ");
                const n = std.fmt.parseUnsigned(usize, digits, 10) catch return error.MalformedFixtureRule;
                try result.rules.append(allocator, .{ .count = .{ .n = n, .needle = needle } });
            },
            else => return error.MalformedFixtureRule,
        }
    }
    if (result.rules.items.len == 0) return error.EmptyFixtureExpectations;
    return result;
}

/// Build the MIR dump for one fixture at the stage its `.expect` names.
fn appendFixtureDump(
    allocator: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    mode: Mode,
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

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".expect")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.path));
    }

    // Anti-vacuity: an empty or mislaid fixture directory is a failure, not a
    // silently passing gate.
    try std.testing.expect(names.items.len >= 20);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

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

        var expectations = try parseExpectations(allocator, expect_text);
        defer expectations.deinit(allocator);

        var dump: std.ArrayList(u8) = .empty;
        defer dump.deinit(allocator);
        try appendFixtureDump(allocator, source_path, source, expectations.mode, &dump);

        for (expectations.rules.items) |rule| {
            const failed = switch (rule) {
                .present => |needle| std.mem.indexOf(u8, dump.items, needle) == null,
                .absent => |needle| std.mem.indexOf(u8, dump.items, needle) != null,
                .count => |c| std.mem.count(u8, dump.items, c.needle) != c.n,
            };
            if (!failed) continue;
            ok = false;
            switch (rule) {
                .present => |needle| std.debug.print("mir fixture {s}: missing \"{s}\"\n", .{ source_path, needle }),
                .absent => |needle| std.debug.print("mir fixture {s}: unexpected \"{s}\"\n", .{ source_path, needle }),
                .count => |c| std.debug.print(
                    "mir fixture {s}: \"{s}\" occurs {d} times, expected {d}\n",
                    .{ source_path, c.needle, std.mem.count(u8, dump.items, c.needle), c.n },
                ),
            }
        }
    }

    try std.testing.expect(ok);
}
