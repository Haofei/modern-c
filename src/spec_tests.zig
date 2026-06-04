const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const ir = @import("ir.zig");
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

const CheckKind = enum {
    diagnostic,
    ir_fact,
    future_trap,
    future_lowering,
    unsupported,

    fn label(self: CheckKind) []const u8 {
        return switch (self) {
            .diagnostic => "diagnostic",
            .ir_fact => "IR fact",
            .future_trap => "future trap",
            .future_lowering => "future lowering",
            .unsupported => "unsupported",
        };
    }
};

const CheckSummary = struct {
    diagnostics: usize = 0,
    ir_facts: usize = 0,
    future_traps: usize = 0,
    future_lowering: usize = 0,
    unsupported: usize = 0,

    fn add(self: *CheckSummary, kind: CheckKind) void {
        switch (kind) {
            .diagnostic => self.diagnostics += 1,
            .ir_fact => self.ir_facts += 1,
            .future_trap => self.future_traps += 1,
            .future_lowering => self.future_lowering += 1,
            .unsupported => self.unsupported += 1,
        }
    }
};

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

test "classify SPEC check entries" {
    try std.testing.expectEqual(CheckKind.diagnostic, classifyCheck("E_C_VOID_DEREF"));
    try std.testing.expectEqual(CheckKind.ir_fact, classifyCheck("IntegerOverflow"));
    try std.testing.expectEqual(CheckKind.ir_fact, classifyCheck("DivideByZero"));
    try std.testing.expectEqual(CheckKind.future_lowering, classifyCheck("checked-arithmetic-lowering"));
    try std.testing.expectEqual(CheckKind.future_lowering, classifyCheck("mmio-width-preserved"));
    try std.testing.expectEqual(CheckKind.unsupported, classifyCheck("needs-new-harness-mode"));
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

test "tests/spec check entries are classified" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/spec", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var summary = CheckSummary{};

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".mc")) continue;

        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);

        var metadata = try parseLeadingMetadata(allocator, source);
        defer metadata.deinit(allocator);

        const check_value = metadata.valueFor("check") orelse continue;
        const path = try std.fmt.allocPrint(allocator, "tests/spec/{s}", .{entry.path});
        defer allocator.free(path);

        var checks = std.mem.splitScalar(u8, check_value, ',');
        while (checks.next()) |raw_check| {
            const check = trimCheck(raw_check);
            if (check.len == 0) continue;

            const kind = classifyCheck(check);
            summary.add(kind);
            if (kind == .unsupported) {
                std.debug.print("{s}: unsupported SPEC check '{s}' skipped by harness\n", .{ path, check });
            }
        }
    }

    if (summary.unsupported > 0) {
        std.debug.print(
            "SPEC check summary: {d} diagnostic, {d} IR fact, {d} future trap, {d} future lowering, {d} unsupported\n",
            .{ summary.diagnostics, summary.ir_facts, summary.future_traps, summary.future_lowering, summary.unsupported },
        );
    }
    try std.testing.expect(summary.diagnostics > 0);
    try std.testing.expect(summary.ir_facts > 0);
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
        if (!hasExpectedDiagnosticCode(check_value)) continue;

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
            const code = trimCheck(raw_check);
            if (classifyCheck(code) != .diagnostic) continue;
            if (!hasDiagnosticCode(reporter, code)) {
                std.debug.print("{s}: expected diagnostic code {s}\n", .{ path, code });
                try std.testing.expect(false);
            }
        }
    }
}

test "tests/spec fixtures produce declared IR inspection facts" {
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
        if (!hasExpectedIrFactCheck(check_value)) continue;

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

        var facts: std.ArrayList(u8) = .empty;
        defer facts.deinit(allocator);
        try ir.appendFacts(allocator, module, &facts);

        var checks = std.mem.splitScalar(u8, check_value, ',');
        while (checks.next()) |raw_check| {
            const check = trimCheck(raw_check);
            if (classifyCheck(check) != .ir_fact) continue;
            if (!hasIrEvidenceForCheck(facts.items, check)) {
                std.debug.print("{s}: expected IR fact evidence for {s}\nFacts:\n{s}", .{ path, check, facts.items });
                try std.testing.expect(false);
            }
        }
    }
}

fn hasExpectedDiagnosticCode(check_value: []const u8) bool {
    var checks = std.mem.splitScalar(u8, check_value, ',');
    while (checks.next()) |raw_check| {
        if (classifyCheck(trimCheck(raw_check)) == .diagnostic) return true;
    }
    return false;
}

fn hasExpectedIrFactCheck(check_value: []const u8) bool {
    var checks = std.mem.splitScalar(u8, check_value, ',');
    while (checks.next()) |raw_check| {
        if (classifyCheck(trimCheck(raw_check)) == .ir_fact) return true;
    }
    return false;
}

fn classifyCheck(check: []const u8) CheckKind {
    if (isDiagnosticCode(check)) return .diagnostic;
    if (isIrFactCheck(check)) return .ir_fact;
    if (isFutureTrapCheck(check)) return .future_trap;
    if (isFutureLoweringCheck(check)) return .future_lowering;
    return .unsupported;
}

fn trimCheck(check: []const u8) []const u8 {
    return std.mem.trim(u8, check, " \t\r");
}

fn isDiagnosticCode(check: []const u8) bool {
    return std.mem.startsWith(u8, check, "E_");
}

fn isIrFactCheck(check: []const u8) bool {
    const names = [_][]const u8{
        "IntegerOverflow",
        "DivideByZero",
        "contract_region",
        "no-language-trap-edge",
    };
    return matchesAny(check, &names);
}

fn isFutureTrapCheck(check: []const u8) bool {
    const names = [_][]const u8{};
    return matchesAny(check, &names);
}

fn isFutureLoweringCheck(check: []const u8) bool {
    const names = [_][]const u8{
        "checked-arithmetic-lowering",
        "metadata-contained",
        "race-tolerant-lowering",
        "no-happens-before",
        "no-c-data-race-ub",
        "mmio-width-preserved",
        "mmio-ordering-preserved",
    };
    return matchesAny(check, &names);
}

fn matchesAny(check: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, check, name)) return true;
    }
    return false;
}

fn hasDiagnosticCode(reporter: diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.startsWith(u8, diag.message, code) and diag.message.len > code.len and diag.message[code.len] == ':') return true;
    }
    return false;
}

fn hasIrEvidenceForCheck(facts: []const u8, check: []const u8) bool {
    if (std.mem.eql(u8, check, "IntegerOverflow")) {
        return containsAll(facts, &.{
            "fact checked_arithmetic_trap",
            " op=add ",
            " op=sub ",
            " op=mul ",
            " op=div ",
            " op=mod ",
        });
    }
    if (std.mem.eql(u8, check, "DivideByZero")) {
        return containsAll(facts, &.{
            "fact checked_arithmetic_trap",
            " op=div ",
        });
    }
    if (std.mem.eql(u8, check, "contract_region")) {
        return containsAll(facts, &.{
            "fact unsafe_contract_begin",
            " contract=no_overflow ",
            "fact unsafe_contract_end",
            "fact unchecked_call",
            " unsafe_contract_depth=1 ",
        });
    }
    if (std.mem.eql(u8, check, "no-language-trap-edge")) {
        return containsAll(facts, &.{
            "fact checked_arithmetic_trap fn=reject_checked_add",
            " no_lang_trap=true ",
            "fact no_lang_trap_index",
            "fact no_lang_trap_assert",
            "fact no_lang_trap_unreachable",
        });
    }
    return false;
}

fn containsAll(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) == null) return false;
    }
    return true;
}
