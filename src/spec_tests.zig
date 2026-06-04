const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");

pub const MetadataRecord = struct {
    key: []const u8,
    value: []const u8,
    line: usize,
};

pub const FixtureMetadata = struct {
    records: std.ArrayList(MetadataRecord),

    pub fn init() FixtureMetadata {
        return .{ .records = .empty };
    }

    pub fn deinit(self: *FixtureMetadata, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
    }

    pub fn hasKey(self: FixtureMetadata, key: []const u8) bool {
        for (self.records.items) |record| {
            if (std.mem.eql(u8, record.key, key)) return true;
        }
        return false;
    }

    pub fn valueFor(self: FixtureMetadata, key: []const u8) ?[]const u8 {
        for (self.records.items) |record| {
            if (std.mem.eql(u8, record.key, key)) return record.value;
        }
        return null;
    }
};

const RequiredKey = enum {
    section,
    phase,
    expect,
    check,

    fn text(self: RequiredKey) []const u8 {
        return @tagName(self);
    }
};

const required_keys = [_]RequiredKey{ .section, .phase, .expect, .check };

pub fn parseLeadingMetadata(allocator: std.mem.Allocator, source: []const u8) !FixtureMetadata {
    var metadata = FixtureMetadata.init();
    errdefer metadata.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (line_it.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trim(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, "//")) break;

        const comment = std.mem.trim(u8, trimmed[2..], " \t");
        if (!std.mem.startsWith(u8, comment, "SPEC:")) break;

        const payload = std.mem.trim(u8, comment["SPEC:".len..], " \t");
        const eq_index = std.mem.indexOfScalar(u8, payload, '=') orelse return error.InvalidSpecMetadata;
        const key = std.mem.trim(u8, payload[0..eq_index], " \t");
        const value = std.mem.trim(u8, payload[eq_index + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) return error.InvalidSpecMetadata;

        try metadata.records.append(allocator, .{
            .key = key,
            .value = value,
            .line = line_no,
        });
    }

    return metadata;
}

fn reportMissingMetadata(path: []const u8, metadata: FixtureMetadata) bool {
    var ok = true;
    for (required_keys) |required| {
        const key = required.text();
        if (!metadata.hasKey(key)) {
            std.debug.print("{s}: missing leading // SPEC: {s}=... metadata\n", .{ path, key });
            ok = false;
        }
    }
    return ok;
}

test "parse leading SPEC metadata records" {
    const source =
        \\// SPEC: section=5.1,G
        \\// SPEC: phase=sema,lower-c
        \\// SPEC: expect=pass
        \\// SPEC: check=some-check
        \\
        \\fn main() -> void {}
    ;

    var metadata = try parseLeadingMetadata(std.testing.allocator, source);
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), metadata.records.items.len);
    try std.testing.expectEqualStrings("section", metadata.records.items[0].key);
    try std.testing.expectEqualStrings("5.1,G", metadata.records.items[0].value);
    try std.testing.expect(metadata.hasKey("phase"));
    try std.testing.expect(metadata.hasKey("expect"));
    try std.testing.expect(metadata.hasKey("check"));
}

test "tests/spec fixtures declare required SPEC metadata" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/spec", .{ .iterate = true });
    defer dir.close(io);

    var found_fixture = false;
    var all_have_metadata = true;

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".mc")) continue;

        found_fixture = true;
        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);

        var metadata = parseLeadingMetadata(allocator, source) catch |err| {
            std.debug.print("tests/spec/{s}: invalid leading // SPEC: metadata: {s}\n", .{ entry.path, @errorName(err) });
            all_have_metadata = false;
            continue;
        };
        defer metadata.deinit(allocator);

        const path = try std.fmt.allocPrint(allocator, "tests/spec/{s}", .{entry.path});
        defer allocator.free(path);
        if (!reportMissingMetadata(path, metadata)) all_have_metadata = false;
    }

    try std.testing.expect(found_fixture);
    try std.testing.expect(all_have_metadata);
}

test "tests/spec fixtures produce declared semantic error codes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/spec", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".mc")) continue;

        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);

        var metadata = try parseLeadingMetadata(allocator, source);
        defer metadata.deinit(allocator);

        const check_value = metadata.valueFor("check") orelse continue;
        if (!hasExpectedSemanticCode(check_value)) continue;

        const path = try std.fmt.allocPrint(allocator, "tests/spec/{s}", .{entry.path});
        defer allocator.free(path);

        var reporter = diagnostics.Reporter.init(allocator, path, source);
        defer reporter.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parse_allocator = arena.allocator();

        var p = parser.Parser.init(source, &reporter);
        const module = try p.parseModule(parse_allocator);
        defer module.deinit(parse_allocator);

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(module);

        var checks = std.mem.splitScalar(u8, check_value, ',');
        while (checks.next()) |raw_check| {
            const code = std.mem.trim(u8, raw_check, " \t\r");
            if (!isSemanticCode(code)) continue;
            if (!hasDiagnosticCode(reporter, code)) {
                std.debug.print("{s}: expected diagnostic code {s}\n", .{ path, code });
                try std.testing.expect(false);
            }
        }
    }
}

fn hasExpectedSemanticCode(check_value: []const u8) bool {
    var checks = std.mem.splitScalar(u8, check_value, ',');
    while (checks.next()) |raw_check| {
        if (isSemanticCode(std.mem.trim(u8, raw_check, " \t\r"))) return true;
    }
    return false;
}

fn isSemanticCode(check: []const u8) bool {
    return std.mem.startsWith(u8, check, "E_");
}

fn hasDiagnosticCode(reporter: diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.startsWith(u8, diag.message, code) and diag.message.len > code.len and diag.message[code.len] == ':') return true;
    }
    return false;
}
