const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const ir = @import("ir.zig");
const lower_c = @import("lower_c.zig");
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
    lower_c,
    future_trap,
    future_lowering,
    unsupported,

    fn label(self: CheckKind) []const u8 {
        return switch (self) {
            .diagnostic => "diagnostic",
            .ir_fact => "IR fact",
            .lower_c => "lower-c",
            .future_trap => "future trap",
            .future_lowering => "future lowering",
            .unsupported => "unsupported",
        };
    }
};

const CheckSummary = struct {
    diagnostics: usize = 0,
    ir_facts: usize = 0,
    lower_c: usize = 0,
    future_traps: usize = 0,
    future_lowering: usize = 0,
    unsupported: usize = 0,

    fn add(self: *CheckSummary, kind: CheckKind) void {
        switch (kind) {
            .diagnostic => self.diagnostics += 1,
            .ir_fact => self.ir_facts += 1,
            .lower_c => self.lower_c += 1,
            .future_trap => self.future_traps += 1,
            .future_lowering => self.future_lowering += 1,
            .unsupported => self.unsupported += 1,
        }
    }
};

const ExpectedError = struct {
    code: []const u8,
    comment_line: usize,
    target_line: usize,
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
    try std.testing.expectEqual(CheckKind.lower_c, classifyCheck("checked-arithmetic-lowering"));
    try std.testing.expectEqual(CheckKind.lower_c, classifyCheck("mmio-width-preserved"));
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

    if (summary.future_traps > 0 or summary.future_lowering > 0 or summary.unsupported > 0) {
        std.debug.print(
            "SPEC check summary: {d} diagnostic, {d} IR fact, {d} lower-c, {d} future trap, {d} future lowering, {d} unsupported\n",
            .{ summary.diagnostics, summary.ir_facts, summary.lower_c, summary.future_traps, summary.future_lowering, summary.unsupported },
        );
    }
    try std.testing.expect(summary.diagnostics > 0);
    try std.testing.expect(summary.ir_facts > 0);
    try std.testing.expect(summary.lower_c > 0);
    try std.testing.expectEqual(@as(usize, 0), summary.future_traps);
    try std.testing.expectEqual(@as(usize, 0), summary.future_lowering);
    try std.testing.expectEqual(@as(usize, 0), summary.unsupported);
}

test "tests/spec phase and expectation metadata values are supported" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/spec", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var all_supported = true;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".mc")) continue;

        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);

        var metadata = try parseLeadingMetadata(allocator, source);
        defer metadata.deinit(allocator);

        const path = try std.fmt.allocPrint(allocator, "tests/spec/{s}", .{entry.path});
        defer allocator.free(path);

        if (metadata.valueFor("phase")) |phase_value| {
            if (!allMetadataValuesSupported(path, "phase", phase_value, isSupportedPhase)) all_supported = false;
        }
        if (metadata.valueFor("expect")) |expect_value| {
            if (!allMetadataValuesSupported(path, "expect", expect_value, isSupportedExpectation)) all_supported = false;
        }
    }

    try std.testing.expect(all_supported);
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

test "tests/spec inline EXPECT_ERROR comments match diagnostic lines" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/spec", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var found_expectation = false;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".mc")) continue;

        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);

        var expected_errors = try parseExpectedErrors(allocator, source);
        defer expected_errors.deinit(allocator);
        if (expected_errors.items.len == 0) continue;
        found_expectation = true;

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

        for (expected_errors.items) |expected| {
            if (!hasDiagnosticCodeOnLine(reporter, expected.code, expected.target_line)) {
                std.debug.print(
                    "{s}:{d}: expected {s} on line {d}\n",
                    .{ path, expected.comment_line, expected.code, expected.target_line },
                );
                try std.testing.expect(false);
            }
        }
        for (reporter.diagnostics.items) |diag| {
            if (diag.severity != .error_ or !isCompilerErrorCodeMessage(diag.message)) continue;
            if (!hasExpectedErrorForDiagnostic(expected_errors.items, diag)) {
                std.debug.print(
                    "{s}:{d}: unexpected diagnostic {s}; add an EXPECT_ERROR comment on the target line\n",
                    .{ path, diag.span.line, diag.message },
                );
                try std.testing.expect(false);
            }
        }
    }

    try std.testing.expect(found_expectation);
}

test "tests/spec inline run trap expectations are reached by arithmetic evaluator" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/spec", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var found_expectation = false;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".mc")) continue;

        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);

        var expectations = try eval.parseRunTrapExpectations(allocator, source);
        defer eval.freeRunTrapExpectations(allocator, &expectations);
        if (expectations.items.len == 0) continue;
        found_expectation = true;

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

        for (expectations.items) |expectation| {
            const actual = try eval.runTrapExpectation(allocator, module, expectation.function_name, expectation.args);
            if (actual == null or actual.? != expectation.trap) {
                std.debug.print(
                    "{s}:{d}: expected run {s}(...) to trap .{s}, got {s}\n",
                    .{ path, expectation.line, expectation.function_name, @tagName(expectation.trap), if (actual) |trap| @tagName(trap) else "no trap" },
                );
                try std.testing.expect(false);
            }
        }
    }

    try std.testing.expect(found_expectation);
}

test "parse inline EXPECT_ERROR comments to target lines" {
    const source =
        \\fn before() -> void {
        \\    // EXPECT_ERROR: E_BEFORE
        \\    fail_before();
        \\    fail_trailing(); // EXPECT_ERROR: E_TRAILING
        \\}
    ;

    var expected = try parseExpectedErrors(std.testing.allocator, source);
    defer expected.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), expected.items.len);
    try std.testing.expectEqualStrings("E_BEFORE", expected.items[0].code);
    try std.testing.expectEqual(@as(usize, 2), expected.items[0].comment_line);
    try std.testing.expectEqual(@as(usize, 3), expected.items[0].target_line);
    try std.testing.expectEqualStrings("E_TRAILING", expected.items[1].code);
    try std.testing.expectEqual(@as(usize, 4), expected.items[1].comment_line);
    try std.testing.expectEqual(@as(usize, 4), expected.items[1].target_line);
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

test "tests/spec fixtures produce declared lower-c inspection markers" {
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
        if (!hasExpectedLowerCCheck(check_value)) continue;

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

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        try lower_c.appendInspection(allocator, module, &output);

        var checks = std.mem.splitScalar(u8, check_value, ',');
        while (checks.next()) |raw_check| {
            const check = trimCheck(raw_check);
            if (classifyCheck(check) != .lower_c) continue;
            if (!hasLowerCEvidenceForCheck(output.items, check)) {
                std.debug.print("{s}: expected lower-c evidence for {s}\nLowering:\n{s}", .{ path, check, output.items });
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

fn hasExpectedLowerCCheck(check_value: []const u8) bool {
    var checks = std.mem.splitScalar(u8, check_value, ',');
    while (checks.next()) |raw_check| {
        if (classifyCheck(trimCheck(raw_check)) == .lower_c) return true;
    }
    return false;
}

fn classifyCheck(check: []const u8) CheckKind {
    if (isDiagnosticCode(check)) return .diagnostic;
    if (isIrFactCheck(check)) return .ir_fact;
    if (isLowerCCheck(check)) return .lower_c;
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
        "InvalidShift",
        "contract_region",
        "no-language-trap-edge",
        "trap-lowering",
        "bitwise-no-trap",
        "mmio-ir-width-preserved",
        "mmio-ir-ordering-preserved",
        "race-ir-semantics",
        "race-ir-no-ub",
    };
    return matchesAny(check, &names);
}

fn isLowerCCheck(check: []const u8) bool {
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

fn isFutureTrapCheck(check: []const u8) bool {
    const names = [_][]const u8{};
    return matchesAny(check, &names);
}

fn isFutureLoweringCheck(check: []const u8) bool {
    const names = [_][]const u8{};
    return matchesAny(check, &names);
}

fn matchesAny(check: []const u8, names: []const []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, check, name)) return true;
    }
    return false;
}

fn allMetadataValuesSupported(path: []const u8, key: []const u8, value: []const u8, supported: fn ([]const u8) bool) bool {
    var ok = true;
    var entries = std.mem.splitScalar(u8, value, ',');
    while (entries.next()) |raw_entry| {
        const entry = trimCheck(raw_entry);
        if (entry.len == 0 or supported(entry)) continue;
        std.debug.print("{s}: unsupported SPEC {s} value '{s}'\n", .{ path, key, entry });
        ok = false;
    }
    return ok;
}

fn isSupportedPhase(phase: []const u8) bool {
    const names = [_][]const u8{
        "parse",
        "sema",
        "verifier",
        "mir",
        "lower-ir",
        "lower-c",
        "run",
    };
    return matchesAny(phase, &names);
}

fn isSupportedExpectation(expectation: []const u8) bool {
    const names = [_][]const u8{
        "pass",
        "compile_error",
        "trap",
        "reject",
        "inspect",
    };
    return matchesAny(expectation, &names);
}

fn hasDiagnosticCode(reporter: diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.startsWith(u8, diag.message, code) and diag.message.len > code.len and diag.message[code.len] == ':') return true;
    }
    return false;
}

fn hasDiagnosticCodeOnLine(reporter: diagnostics.Reporter, code: []const u8, line: usize) bool {
    for (reporter.diagnostics.items) |diag| {
        if (diag.severity == .error_ and diag.span.line == line and isDiagnosticCodeMessage(diag.message, code)) return true;
    }
    return false;
}

fn isDiagnosticCodeMessage(message: []const u8, code: []const u8) bool {
    return std.mem.startsWith(u8, message, code) and message.len > code.len and message[code.len] == ':';
}

fn isCompilerErrorCodeMessage(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "E_") and std.mem.indexOfScalar(u8, message, ':') != null;
}

fn hasExpectedErrorForDiagnostic(expected_errors: []ExpectedError, diag: diagnostics.Diagnostic) bool {
    for (expected_errors) |expected| {
        if (expected.target_line == diag.span.line and isDiagnosticCodeMessage(diag.message, expected.code)) return true;
    }
    return false;
}

fn hasIrEvidenceForCheck(facts: []const u8, check: []const u8) bool {
    if (std.mem.eql(u8, check, "IntegerOverflow")) {
        return containsAll(facts, &.{
            "fact checked_arithmetic_trap",
            " trap=IntegerOverflow ",
            " op=add ",
            " op=sub ",
            " op=mul ",
            " op=div ",
            " op=mod ",
            " op=neg ",
        });
    }
    if (std.mem.eql(u8, check, "DivideByZero")) {
        return containsAll(facts, &.{
            "fact checked_arithmetic_trap",
            " op=div ",
            " trap=DivideByZero ",
        });
    }
    if (std.mem.eql(u8, check, "InvalidShift")) {
        return containsAll(facts, &.{
            "fact checked_shift_trap",
            " op=shl ",
            " op=shr ",
            " trap=InvalidShift ",
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
            "fact no_lang_trap_explicit_trap",
            " kind=Assert ",
            "fact no_lang_trap_unwrap",
            " form=postfix_question ",
            " form=call ",
            " callee=unwrap ",
            "fact checked_shift_trap fn=reject_right_shift",
            " op=shr ",
            " no_lang_trap=true ",
            "fact no_lang_trap_safe_call fn=allow_wrapping_add callee=wrapping.add language_trap=false",
            "fact no_lang_trap_asm fn=allow_boot_asm opaque=true volatile=true language_trap=false target_fault_possible=true",
        });
    }
    if (std.mem.eql(u8, check, "trap-lowering")) {
        return containsAll(facts, &.{
            "fact trap_edge fn=trap_as_value kind=Bounds source=trap_call no_lang_trap=false",
            "fact trap_edge fn=unreachable_as_value kind=Unreachable source=unreachable no_lang_trap=false",
            "fact trap_edge fn=never_returns_by_trap kind=Assert source=trap_call no_lang_trap=false",
        });
    }
    if (std.mem.eql(u8, check, "bitwise-no-trap")) {
        return containsAll(facts, &.{
            "fact bitwise_no_trap fn=accept_unsigned_and op=bit_and language_trap=false overflow_trap=false",
            "fact bitwise_no_trap fn=accept_unsigned_or op=bit_or language_trap=false overflow_trap=false",
            "fact bitwise_no_trap fn=accept_unsigned_xor op=bit_xor language_trap=false overflow_trap=false",
            "fact bitwise_no_trap fn=accept_unsigned_not op=bit_not language_trap=false overflow_trap=false",
        });
    }
    if (std.mem.eql(u8, check, "mmio-ir-width-preserved")) {
        return containsAll(facts, &.{
            "fact mmio_access fn=putc op=write register=Uart16550.thr",
            "access_mode=write",
            "value_type=u8",
            "register_width=8 emitted_width=8",
            "volatile=true",
            "address_space=mmio",
            "fact mmio_access fn=read_status op=read register=Uart16550.lsr",
        });
    }
    if (std.mem.eql(u8, check, "mmio-ir-ordering-preserved")) {
        return containsAll(facts, &.{
            "fact mmio_order fn=putc op=write register=Uart16550.thr ordering=release",
            "barrier_before=true",
            "prevents_before_after=true",
            "fact mmio_order fn=read_status op=read register=Uart16550.lsr ordering=acquire",
            "barrier_after=true",
            "prevents_after_before=true",
            "fact mmio_sequence fn=ordered_device_sequence edge=ordinary_before_release before=raw.store barrier=Uart16550.thr.write ordering=release prevents_reorder=true",
            "fact mmio_sequence fn=ordered_device_sequence edge=ordinary_after_acquire barrier=Uart16550.lsr.read ordering=acquire after=raw.store prevents_reorder=true",
        });
    }
    if (std.mem.eql(u8, check, "race-ir-semantics")) {
        return containsAll(facts, &.{
            "fact ordinary_access fn=possibly_racing_store object=shared_counter access=store race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_load object=shared_counter access=load race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact racing_load_semantics fn=possibly_racing_load object=shared_counter result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact non_atomic_rmw fn=racing_increment_is_not_atomic object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false",
        });
    }
    if (std.mem.eql(u8, check, "race-ir-no-ub")) {
        return containsAll(facts, &.{
            "fact ordinary_access fn=possibly_racing_store object=shared_counter access=store race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_load object=shared_counter access=load race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact non_atomic_rmw fn=racing_increment_is_not_atomic object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false",
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

fn parseExpectedErrors(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(ExpectedError) {
    var out: std.ArrayList(ExpectedError) = .empty;
    errdefer out.deinit(allocator);

    var pending: std.ArrayList(struct { code: []const u8, line: usize }) = .empty;
    defer pending.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 1;
    while (lines.next()) |raw_line| : (line_no += 1) {
        const line = std.mem.trim(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        const comment_start = std.mem.indexOf(u8, line, "//");
        const code_part = if (comment_start) |idx| std.mem.trim(u8, line[0..idx], " \t") else trimmed;
        const comment_part = if (comment_start) |idx| std.mem.trim(u8, line[idx + 2 ..], " \t") else "";

        if (expectedErrorCodeFromComment(comment_part)) |code| {
            if (isCodeLine(code_part)) {
                try out.append(allocator, .{ .code = code, .comment_line = line_no, .target_line = line_no });
                continue;
            }
            try pending.append(allocator, .{ .code = code, .line = line_no });
            continue;
        }

        if (isCodeLine(code_part)) {
            for (pending.items) |item| {
                try out.append(allocator, .{ .code = item.code, .comment_line = item.line, .target_line = line_no });
            }
            pending.clearRetainingCapacity();
        }
    }

    if (pending.items.len > 0) {
        return error.ExpectedErrorWithoutCodeLine;
    }

    return out;
}

fn expectedErrorCode(trimmed_line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, trimmed_line, "//")) return null;
    const comment = std.mem.trim(u8, trimmed_line[2..], " \t");
    return expectedErrorCodeFromComment(comment);
}

fn expectedErrorCodeFromComment(comment: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, comment, "EXPECT_ERROR:")) return null;
    const code = std.mem.trim(u8, comment["EXPECT_ERROR:".len..], " \t\r");
    return if (code.len == 0) null else code;
}

fn isCodeLine(trimmed_line: []const u8) bool {
    return trimmed_line.len != 0 and !std.mem.startsWith(u8, trimmed_line, "//");
}

fn hasLowerCEvidenceForCheck(output: []const u8, check: []const u8) bool {
    if (std.mem.eql(u8, check, "checked-arithmetic-lowering")) {
        return containsAll(output, &.{
            "lower checked_arith fn=add_overflow_u32 op=add",
            "trap=IntegerOverflow",
            "strategy=helper",
            "emits_plain_c_overflow=false",
            "lower checked_arith fn=signed_div_min_overflow op=div type=i32 trap=IntegerOverflow",
            "lower checked_arith fn=signed_rem_min_overflow op=mod type=i32 trap=IntegerOverflow",
            "lower checked_arith fn=signed_neg_min_overflow op=neg type=i32 trap=IntegerOverflow",
            "lower checked_arith fn=left_shift_invalid_count op=shl type=u32 trap=InvalidShift",
            "lower checked_arith fn=left_shift_overflow op=shl type=u32 trap=IntegerOverflow",
            "lower checked_arith fn=right_shift_invalid_count op=shr type=u32 trap=InvalidShift",
        });
    }
    if (std.mem.eql(u8, check, "metadata-contained")) {
        return containsAll(output, &.{
            "lower contract_scope fn=allow_unchecked_add_inside_contract contract=no_overflow region=1 metadata_begin=1 contained=true",
            "lower contract_metadata fn=allow_unchecked_add_inside_contract contract=no_overflow callee=unchecked.add metadata_attached=true contained=true",
            "lower contract_scope fn=allow_unchecked_add_inside_contract contract=no_overflow region=1 metadata_end=1 contained=true",
            "lower metadata_containment fn=allow_unchecked_add_inside_contract contract=no_overflow region=1 metadata_begin=1 metadata_end=1 metadata_attached_after_region=false contained=true",
            "lower post_contract_arith fn=allow_unchecked_add_inside_contract contract=no_overflow op=add metadata_attached=false",
            "lower contract_scope fn=noalias_contract_region contract=noalias region=1 metadata_begin=1 contained=true",
            "lower contract_metadata fn=noalias_contract_region contract=noalias callee=compiler.assume_noalias_unchecked metadata_attached=true contained=true",
            "lower contract_scope fn=noalias_contract_region contract=noalias region=1 metadata_end=1 contained=true",
            "lower metadata_containment fn=noalias_contract_region contract=noalias region=1 metadata_begin=1 metadata_end=1 metadata_attached_after_region=false contained=true",
            "lower post_contract_call fn=noalias_contract_region contract=noalias callee=raw.store metadata_attached=false",
        });
    }
    if (std.mem.eql(u8, check, "race-tolerant-lowering")) {
        return containsAll(output, &.{
            "lower ordinary_access fn=local_non_racing_access object=local access=load race_class=local strategy=plain_c c_plain_access=true",
            "lower ordinary_access fn=local_non_racing_access object=local access=store race_class=local strategy=plain_c c_plain_access=true",
            "lower ordinary_access fn=possibly_racing_store object=shared_counter access=store race_class=possibly_shared strategy=race_helper c_plain_access=false",
            "lower ordinary_access fn=possibly_racing_load object=shared_counter access=load race_class=possibly_shared strategy=race_helper c_plain_access=false",
            "lower non_atomic_rmw fn=racing_increment_is_not_atomic object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false c_data_race_ub_dependency=false",
        });
    }
    if (std.mem.eql(u8, check, "no-happens-before")) {
        return containsAll(output, &.{
            "lower race_semantics fn=possibly_racing_load object=shared_counter creates_happens_before=false assumes_no_race=false",
            "lower racing_load_semantics fn=possibly_racing_load object=shared_counter result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false",
        });
    }
    if (std.mem.eql(u8, check, "no-c-data-race-ub")) {
        return containsAll(output, &.{
            "lower c_ub fn=possibly_racing_store object=shared_counter c_data_race_ub_dependency=false",
            "lower c_ub fn=possibly_racing_load object=shared_counter c_data_race_ub_dependency=false",
            "lower racing_load_semantics fn=possibly_racing_load object=shared_counter result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false",
            "lower non_atomic_rmw fn=racing_increment_is_not_atomic object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false c_data_race_ub_dependency=false",
        });
    }
    if (std.mem.eql(u8, check, "mmio-width-preserved")) {
        return containsAll(output, &.{
            "lower mmio_access fn=putc op=write register=Uart16550.thr",
            "value_type=u8",
            "register_width=8 emitted_width=8",
            "volatile=true",
            "address_space=mmio",
            "lower mmio_access fn=read_status op=read register=Uart16550.lsr",
            "value_type=UartLsr",
        });
    }
    if (std.mem.eql(u8, check, "mmio-ordering-preserved")) {
        return containsAll(output, &.{
            "lower mmio_order fn=putc op=write register=Uart16550.thr ordering=release",
            "prevents_before_after=true",
            "lower mmio_order fn=read_status op=read register=Uart16550.lsr ordering=acquire",
            "prevents_after_before=true",
            "lower mmio_sequence fn=ordered_device_sequence edge=ordinary_before_release before=raw.store barrier=Uart16550.thr.write ordering=release prevents_reorder=true",
            "lower mmio_sequence fn=ordered_device_sequence edge=ordinary_after_acquire barrier=Uart16550.lsr.read ordering=acquire after=raw.store prevents_reorder=true",
        });
    }
    return false;
}
