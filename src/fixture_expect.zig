//! The `.expect` needle grammar shared by the dump-fixture corpora.
//!
//! A fixture corpus is a directory of `<name>.mc` sources, each with a sibling
//! `<name>.expect` stating what the corpus's dump of that source must and must
//! not contain. One table-driven test per corpus walks the directory, so
//! adding a case is adding two files rather than another in-Zig golden string,
//! and a representation change is one fixture edit instead of a rewrite of the
//! unit suite.
//!
//! The grammar, one rule per line:
//!
//! ```text
//! # free-form comment
//! mode: raw | resolved | checked     how far the front end runs (default raw)
//! + "needle"                         the dump must contain this substring
//! - "needle"                         the dump must not contain it
//! = 4 "needle"                       it must occur exactly four times
//! >= 2 "needle"                      it must occur at least twice
//! ```
//!
//! The needle is everything between the first and last `"` on the line, so a
//! trailing space inside a needle survives a whitespace-trimming editor.
//!
//! `>=` exists because a converted in-Zig assertion sometimes said exactly
//! that -- "at least two of these were reported" -- and rewriting it as an
//! exact count would have made the fixture assert something the test it
//! replaced did not.
//!
//! `mode` selects the pipeline the dump is taken from:
//!
//! - `raw`: parse only, the shape `parser.Parser.parseModule` produces.
//! - `resolved`: parse plus qualified-name resolution.
//! - `checked`: `resolved` plus a full `sema` pass over the declarations.
//!
//! The mode matters because the MIR builder reads what the front end left
//! behind, so a fixture must name the stage its expectations were taken at.

const std = @import("std");

pub const Mode = enum { raw, resolved, checked };

pub const Rule = union(enum) {
    present: []const u8,
    absent: []const u8,
    count: struct { n: usize, needle: []const u8 },
    at_least: struct { n: usize, needle: []const u8 },
};

pub const Expectations = struct {
    mode: Mode,
    rules: std.ArrayList(Rule),

    pub fn deinit(self: *Expectations, allocator: std.mem.Allocator) void {
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

/// The count written between a `=` / `>=` marker and the needle.
fn leadingCount(line: []const u8, marker_len: usize) ?usize {
    const quote = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    if (quote < marker_len) return null;
    const digits = std.mem.trim(u8, line[marker_len..quote], " ");
    return std.fmt.parseUnsigned(usize, digits, 10) catch null;
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Expectations {
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
        if (std.mem.startsWith(u8, line, ">=")) {
            const needle = quoted(line) orelse return error.MalformedFixtureRule;
            const n = leadingCount(line, 2) orelse return error.MalformedFixtureRule;
            try result.rules.append(allocator, .{ .at_least = .{ .n = n, .needle = needle } });
            continue;
        }
        switch (line[0]) {
            '+' => try result.rules.append(allocator, .{ .present = quoted(line) orelse return error.MalformedFixtureRule }),
            '-' => try result.rules.append(allocator, .{ .absent = quoted(line) orelse return error.MalformedFixtureRule }),
            '=' => {
                const needle = quoted(line) orelse return error.MalformedFixtureRule;
                const n = leadingCount(line, 1) orelse return error.MalformedFixtureRule;
                try result.rules.append(allocator, .{ .count = .{ .n = n, .needle = needle } });
            },
            else => return error.MalformedFixtureRule,
        }
    }
    if (result.rules.items.len == 0) return error.EmptyFixtureExpectations;
    return result;
}

/// Check one fixture's dump against its rules, printing every failure.
/// Returns false if any rule failed, so a corpus walk reports all of them in
/// one run instead of stopping at the first.
pub fn check(source_path: []const u8, dump: []const u8, rules: []const Rule) bool {
    var ok = true;
    for (rules) |rule| {
        const failed = switch (rule) {
            .present => |needle| std.mem.indexOf(u8, dump, needle) == null,
            .absent => |needle| std.mem.indexOf(u8, dump, needle) != null,
            .count => |c| std.mem.count(u8, dump, c.needle) != c.n,
            .at_least => |c| std.mem.count(u8, dump, c.needle) < c.n,
        };
        if (!failed) continue;
        ok = false;
        switch (rule) {
            .present => |needle| std.debug.print("fixture {s}: missing \"{s}\"\n", .{ source_path, needle }),
            .absent => |needle| std.debug.print("fixture {s}: unexpected \"{s}\"\n", .{ source_path, needle }),
            .count => |c| std.debug.print(
                "fixture {s}: \"{s}\" occurs {d} times, expected {d}\n",
                .{ source_path, c.needle, std.mem.count(u8, dump, c.needle), c.n },
            ),
            .at_least => |c| std.debug.print(
                "fixture {s}: \"{s}\" occurs {d} times, expected at least {d}\n",
                .{ source_path, c.needle, std.mem.count(u8, dump, c.needle), c.n },
            ),
        }
    }
    return ok;
}

/// Collect the `<name>.expect` paths under `dir`, sorted, so a corpus walk is
/// deterministic. The caller owns each returned path.
pub fn collect(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    names: *std.ArrayList([]const u8),
) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".expect")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

test "the grammar reads every rule form" {
    const allocator = std.testing.allocator;
    var expectations = try parse(allocator,
        \\# a comment
        \\mode: checked
        \\+ "present"
        \\- "absent"
        \\= 2 "twice"
        \\>= 3 "thrice"
    );
    defer expectations.deinit(allocator);

    try std.testing.expectEqual(Mode.checked, expectations.mode);
    try std.testing.expectEqual(@as(usize, 4), expectations.rules.items.len);
    try std.testing.expect(check("t", "present twice twice thrice thrice thrice thrice", expectations.rules.items));
    try std.testing.expect(!check("t", "present absent twice twice thrice thrice thrice", expectations.rules.items));
}

test "an empty or malformed expectation file is a failure, not a pass" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.EmptyFixtureExpectations, parse(allocator, "# nothing here\n"));
    try std.testing.expectError(error.MalformedFixtureRule, parse(allocator, "? \"what\"\n"));
    try std.testing.expectError(error.MalformedFixtureRule, parse(allocator, "= x \"how many\"\n"));
    try std.testing.expectError(error.MalformedFixtureRule, parse(allocator, ">= \"how many\"\n"));
    try std.testing.expectError(error.UnknownFixtureMode, parse(allocator, "mode: sideways\n+ \"a\"\n"));
}
