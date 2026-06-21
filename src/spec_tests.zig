const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const hir = @import("hir.zig");
const ir = @import("ir.zig");
const loader = @import("loader.zig");
const lower_c = @import("lower_c.zig");
const lower_llvm = @import("lower_llvm.zig");
const mir = @import("mir.zig");
const monomorphize = @import("monomorphize.zig");
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
    // A fixture whose `check=` only documents that it must COMPILE CLEAN (an accept
    // fixture with no diagnostic to assert). Counted, but not output-verified and not
    // asserted-zero — the fixture's value is that `checkModule` produces no error.
    acceptance,
    future_trap,
    future_lowering,
    unsupported,

    fn label(self: CheckKind) []const u8 {
        return switch (self) {
            .diagnostic => "diagnostic",
            .ir_fact => "IR fact",
            .lower_c => "lower-c",
            .acceptance => "acceptance",
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
    acceptance: usize = 0,
    future_traps: usize = 0,
    future_lowering: usize = 0,
    unsupported: usize = 0,

    fn add(self: *CheckSummary, kind: CheckKind) void {
        switch (kind) {
            .diagnostic => self.diagnostics += 1,
            .ir_fact => self.ir_facts += 1,
            .lower_c => self.lower_c += 1,
            .acceptance => self.acceptance += 1,
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
    try std.testing.expectEqual(CheckKind.lower_c, classifyCheck("packed-bits-no-c-bitfields"));
    try std.testing.expectEqual(CheckKind.lower_c, classifyCheck("overlay-union-byte-storage"));
    try std.testing.expectEqual(CheckKind.lower_c, classifyCheck("floating-reduction-modes"));
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

        // Soundness fixtures that import std/kernel opaque types are import-expanded so the
        // cross-file orphan rule (E_ORPHAN_IMPL) has file boundaries to compare; single-file
        // fixtures (the overwhelming majority) borrow `source` and carry no boundaries.
        var imported = false;
        var spec = try resolveSpecSource(allocator, io, path, source, &imported);
        defer spec.deinit(allocator, imported);

        var reporter = diagnostics.Reporter.init(allocator, path, spec.source);
        defer reporter.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parse_allocator = arena.allocator();

        const module = try parseSpecModule(spec.source, parse_allocator, &reporter);
        defer module.deinit(parse_allocator);

        var checker = sema.Checker.init(&reporter);
        checker.file_boundaries = spec.boundaries;
        checker.checkModule(module);
        if (metadataListContains(metadata.valueFor("phase") orelse "", "verifier")) {
            try mir.verify(allocator, module, &reporter);
        }

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

        var metadata = try parseLeadingMetadata(allocator, source);
        defer metadata.deinit(allocator);

        var expected_errors = try parseExpectedErrors(allocator, source);
        defer expected_errors.deinit(allocator);
        if (expected_errors.items.len == 0) continue;
        found_expectation = true;

        const path = try std.fmt.allocPrint(allocator, "tests/spec/{s}", .{entry.path});
        defer allocator.free(path);

        // Soundness fixtures that import std/kernel opaque types are import-expanded so the
        // cross-file orphan rule (E_ORPHAN_IMPL) has file boundaries to compare; single-file
        // fixtures (the overwhelming majority) borrow `source` and carry no boundaries.
        var imported = false;
        var spec = try resolveSpecSource(allocator, io, path, source, &imported);
        defer spec.deinit(allocator, imported);

        var reporter = diagnostics.Reporter.init(allocator, path, spec.source);
        defer reporter.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parse_allocator = arena.allocator();

        const module = try parseSpecModule(spec.source, parse_allocator, &reporter);
        defer module.deinit(parse_allocator);

        var checker = sema.Checker.init(&reporter);
        checker.file_boundaries = spec.boundaries;
        checker.checkModule(module);
        if (metadataListContains(metadata.valueFor("phase") orelse "", "verifier")) {
            try mir.verify(allocator, module, &reporter);
        }

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

test "tests/spec semantic errors are all explicitly expected" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "tests/spec", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var found_fixture = false;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".mc")) continue;
        found_fixture = true;

        const source = try dir.readFileAlloc(io, entry.path, allocator, .limited(1024 * 1024));
        defer allocator.free(source);

        // Import-using fixtures (the soundness fixtures that pull in std/kernel opaque types)
        // are import-expanded elsewhere; checking them here against inline EXPECT_ERROR comments
        // would also see incidental diagnostics from the imported stdlib. Their declared
        // diagnostic codes are locked by "tests/spec fixtures produce declared semantic error
        // codes" (which IS import-aware), so skip them in this raw, single-file pass.
        if (hasTopLevelImport(source)) continue;

        var expected_errors = try parseExpectedErrors(allocator, source);
        defer expected_errors.deinit(allocator);

        const path = try std.fmt.allocPrint(allocator, "tests/spec/{s}", .{entry.path});
        defer allocator.free(path);

        var reporter = diagnostics.Reporter.init(allocator, path, source);
        defer reporter.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parse_allocator = arena.allocator();

        const module = try parseSpecModule(source, parse_allocator, &reporter);
        defer module.deinit(parse_allocator);

        var checker = sema.Checker.init(&reporter);
        checker.checkModule(module);
        var metadata = try parseLeadingMetadata(allocator, source);
        defer metadata.deinit(allocator);
        if (metadataListContains(metadata.valueFor("phase") orelse "", "verifier")) {
            try mir.verify(allocator, module, &reporter);
        }

        for (reporter.diagnostics.items) |diag| {
            if (diag.severity != .error_ or !isCompilerErrorCodeMessage(diag.message)) continue;
            if (!hasExpectedErrorForDiagnostic(expected_errors.items, diag)) {
                std.debug.print(
                    "{s}:{d}: unexpected diagnostic {s}; every spec diagnostic must have an EXPECT_ERROR comment on the target line\n",
                    .{ path, diag.span.line, diag.message },
                );
                try std.testing.expect(false);
            }
        }
    }

    try std.testing.expect(found_fixture);
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

        const module = try parseSpecModule(source, parse_allocator, &reporter);
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

        const module = try parseSpecModule(source, parse_allocator, &reporter);
        defer module.deinit(parse_allocator);

        var facts: std.ArrayList(u8) = .empty;
        defer facts.deinit(allocator);
        try ir.appendFacts(allocator, module, &facts);

        var checks = std.mem.splitScalar(u8, check_value, ',');
        while (checks.next()) |raw_check| {
            const check = trimCheck(raw_check);
            if (classifyCheck(check) != .ir_fact) continue;
            if (!std.mem.eql(u8, check, "irq-context-verifier") and !hasIrEvidenceForCheck(facts.items, check)) {
                std.debug.print("{s}: expected IR fact evidence for {s}\nFacts:\n{s}", .{ path, check, facts.items });
                try std.testing.expect(false);
            }
            if (std.mem.eql(u8, check, "no-language-trap-edge") or std.mem.eql(u8, check, "contract_region")) {
                var module_ir = try ir.buildModuleIr(allocator, module);
                defer module_ir.deinit();
                if (!hasLowerIrEvidenceForCheck(module_ir, check)) {
                    std.debug.print("{s}: expected lower-ir artifact evidence for {s}\n", .{ path, check });
                    try std.testing.expect(false);
                }
            }
            if (std.mem.eql(u8, check, "no-language-trap-edge") or std.mem.eql(u8, check, "irq-context-verifier")) {
                var hir_facts: std.ArrayList(u8) = .empty;
                defer hir_facts.deinit(allocator);
                if (std.mem.eql(u8, check, "no-language-trap-edge")) {
                    try hir.appendVerificationFacts(allocator, module, &hir_facts);
                    if (!hasHirVerifierEvidenceForCheck(hir_facts.items, check)) {
                        std.debug.print("{s}: expected HIR verifier evidence for {s}\nHIR verifier:\n{s}", .{ path, check, hir_facts.items });
                        try std.testing.expect(false);
                    }
                }
                var mir_facts: std.ArrayList(u8) = .empty;
                defer mir_facts.deinit(allocator);
                try mir.appendVerificationFacts(allocator, module, &mir_facts);
                if (!hasMirVerifierEvidenceForCheck(mir_facts.items, check)) {
                    std.debug.print("{s}: expected MIR verifier evidence for {s}\nMIR verifier:\n{s}", .{ path, check, mir_facts.items });
                    try std.testing.expect(false);
                }
            }
            if (std.mem.eql(u8, check, "contract_region")) {
                var typed_mir = try mir.build(allocator, module);
                defer typed_mir.deinit();
                if (!hasMirEvidenceForCheck(typed_mir, check)) {
                    std.debug.print("{s}: expected MIR artifact evidence for {s}\n", .{ path, check });
                    try std.testing.expect(false);
                }
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

        const module = try parseSpecModule(source, parse_allocator, &reporter);
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

// The "both backends" claim for `?*dyn Trait` is asserted by the fixture comment but the
// lower-c marker test only exercises C. This emits the nullable-dyn fixture through BOTH
// backends and asserts each succeeds AND carries the data-word niche evidence — so a future
// edit that un-wires either backend (the original Findings 1–2 failure mode) goes red.
test "nullable trait object fixture lowers on both backends with the data-word niche" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = "tests/spec/traits_dyn_nullable.mc";
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
    var reporter = diagnostics.Reporter.init(a, path, source);

    // C backend: none = the zero fat pointer, niche test on `.data`, dispatch via vtable.
    {
        const module = try parseSpecModule(source, a, &reporter);
        var out: std.ArrayList(u8) = .empty;
        try lower_c.appendC(a, module, &out);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "(mc_dyn_CharDevice){0}") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, ".data != NULL") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "vtable->putc") != null);
    }
    // LLVM backend: must emit (not UnsupportedLlvmEmission), with the fat-pointer niche.
    {
        const module = try parseSpecModule(source, a, &reporter);
        var out: std.ArrayList(u8) = .empty;
        try lower_llvm.appendLlvm(a, module, &out);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "{ ptr, ptr }") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "extractvalue") != null);
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
    if (isAcceptanceCheck(check)) return .acceptance;
    if (isFutureTrapCheck(check)) return .future_trap;
    if (isFutureLoweringCheck(check)) return .future_lowering;
    return .unsupported;
}

fn trimCheck(check: []const u8) []const u8 {
    return std.mem.trim(u8, check, " \t\r");
}

fn metadataListContains(value: []const u8, needle: []const u8) bool {
    var entries = std.mem.splitScalar(u8, value, ',');
    while (entries.next()) |raw_entry| {
        if (std.mem.eql(u8, trimCheck(raw_entry), needle)) return true;
    }
    return false;
}

fn isDiagnosticCode(check: []const u8) bool {
    return std.mem.startsWith(u8, check, "E_");
}

fn isAcceptanceCheck(check: []const u8) bool {
    const names = [_][]const u8{
        "traits-tier1-accept",
        "traits-tier1-irq-accept",
        "traits-tier2-dyn-accept",
        "traits-tier2-nullable-dyn",
    };
    return matchesAny(check, &names);
}

fn isIrFactCheck(check: []const u8) bool {
    const names = [_][]const u8{
        "IntegerOverflow",
        "DivideByZero",
        "InvalidShift",
        "contract_region",
        "no-language-trap-edge",
        "irq-context-verifier",
        "trap-lowering",
        "bitwise-no-trap",
        "mmio-ir-width-preserved",
        "mmio-ir-ordering-preserved",
        "race-ir-semantics",
        "race-ir-no-ub",
        "arithmetic-domain-no-trap",
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
        "packed-bits-no-c-bitfields",
        "overlay-union-byte-storage",
        "arithmetic-domain-lowering",
        "atomics-lowering",
        "dma-cache-core",
        "dma-ordering-composition",
        "irq-off-capability",
        "opaque-asm-lowering",
        "bitcast-lowering",
        "floating-reduction-modes",
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

fn parseSpecModule(source: []const u8, allocator: std.mem.Allocator, reporter: *diagnostics.Reporter) !ast.Module {
    var p = parser.Parser.init(source, reporter);
    const module = try p.parseModule(allocator);
    return try monomorphize.transformReport(allocator, module, reporter);
}

// A spec fixture's effective source, plus the import-flattened file boundaries needed to
// enforce the cross-file orphan rule (sema). Most fixtures are single-file: `source` is then
// the raw text and `boundaries` is empty. A fixture that begins with `import "..."` (e.g. the
// soundness fixtures that pull in std/kernel opaque types) is expanded through the loader, with
// `rel_path` made absolute first so the loader's ancestor walk reaches the repo root — matching
// how the real kernel/std build resolves rooted imports.
const SpecSource = struct {
    source: []const u8,
    boundaries: []const loader.FileBoundary,

    fn deinit(self: *SpecSource, allocator: std.mem.Allocator, imported: bool) void {
        if (!imported) return;
        allocator.free(self.source);
        for (self.boundaries) |b| allocator.free(b.path);
        allocator.free(self.boundaries);
    }
};

fn hasTopLevelImport(source: []const u8) bool {
    // A coarse, false-positive-tolerant probe: a line whose first token is `import`. The loader
    // re-lexes precisely; this only decides whether to invoke it at all.
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "import") and (t.len == 6 or t[6] == ' ' or t[6] == '\t' or t[6] == '"')) return true;
    }
    return false;
}

// Resolve a spec fixture to its effective source. `raw` is the fixture's own bytes; `rel_path`
// is its repo-relative path (`tests/spec/<name>.mc`). `imported_out` is set true when the loader
// was used (so the caller frees with the same flag). The returned `source`/`boundaries` are
// loader-owned when imported, else borrow `raw`.
fn resolveSpecSource(
    allocator: std.mem.Allocator,
    io: std.Io,
    rel_path: []const u8,
    raw: []const u8,
    imported_out: *bool,
) !SpecSource {
    if (!hasTopLevelImport(raw)) {
        imported_out.* = false;
        return .{ .source = raw, .boundaries = &.{} };
    }
    imported_out.* = true;
    const abs = try std.fs.path.resolve(allocator, &.{rel_path});
    defer allocator.free(abs);
    var boundaries: std.ArrayList(loader.FileBoundary) = .empty;
    errdefer {
        for (boundaries.items) |b| allocator.free(b.path);
        boundaries.deinit(allocator);
    }
    const combined = try loader.loadCombinedSourceWithBoundaries(allocator, io, abs, raw, &boundaries, null);
    return .{ .source = combined, .boundaries = try boundaries.toOwnedSlice(allocator) };
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
            "fact ordinary_access fn=possibly_racing_field_store object=shared_pair.value access=store race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_field_load object=shared_pair.value access=load race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact racing_load_semantics fn=possibly_racing_field_load object=shared_pair.value result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_array_store object=shared_values[] access=store race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_array_load object=shared_values[] access=load race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact racing_load_semantics fn=possibly_racing_array_load object=shared_values[] result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact non_atomic_rmw fn=racing_increment_is_not_atomic object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false",
        });
    }
    if (std.mem.eql(u8, check, "race-ir-no-ub")) {
        return containsAll(facts, &.{
            "fact ordinary_access fn=possibly_racing_store object=shared_counter access=store race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_load object=shared_counter access=load race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_field_store object=shared_pair.value access=store race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_field_load object=shared_pair.value access=load race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_array_store object=shared_values[] access=store race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact ordinary_access fn=possibly_racing_array_load object=shared_values[] access=load race_class=possibly_shared creates_happens_before=false assumes_no_race=false optimizer_license_ub=false",
            "fact non_atomic_rmw fn=racing_increment_is_not_atomic object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false",
        });
    }
    if (std.mem.eql(u8, check, "arithmetic-domain-no-trap")) {
        return containsAll(facts, &.{
            "fact arithmetic_domain_no_trap fn=wrap_add domain=wrap op=add language_trap=false overflow_trap=false",
            "fact arithmetic_domain_no_trap fn=wrap_bitwise domain=wrap op=bit_and language_trap=false overflow_trap=false",
            "fact arithmetic_domain_no_trap fn=sat_add domain=sat op=add language_trap=false overflow_trap=false",
            "fact arithmetic_domain_no_trap fn=sat_mul domain=sat op=mul language_trap=false overflow_trap=false",
        }) and
            std.mem.indexOf(u8, facts, "fact checked_arithmetic_trap fn=wrap_add") == null and
            std.mem.indexOf(u8, facts, "fact checked_arithmetic_trap fn=sat_add") == null;
    }
    return false;
}

fn hasLowerIrEvidenceForCheck(module_ir: ir.ModuleIr, check: []const u8) bool {
    if (std.mem.eql(u8, check, "no-language-trap-edge")) {
        return lowerIrFunctionHasTrap(module_ir, "reject_checked_add", .IntegerOverflow, .checked_arithmetic) and
            lowerIrFunctionHasTrap(module_ir, "reject_bounds_check", .Bounds, .index) and
            lowerIrFunctionHasTrap(module_ir, "reject_assert", .Assert, .assert_stmt) and
            lowerIrFunctionHasTrap(module_ir, "reject_reachable_unreachable", .Unreachable, .unreachable_expr) and
            lowerIrFunctionHasTrap(module_ir, "reject_explicit_trap", .Assert, .trap_call) and
            lowerIrFunctionHasTrap(module_ir, "reject_nullable_try", .Unknown, .unwrap) and
            lowerIrFunctionHasTrap(module_ir, "reject_unwrap_call", .Unknown, .unwrap) and
            lowerIrFunctionHasTrap(module_ir, "reject_right_shift", .InvalidShift, .checked_shift) and
            lowerIrFunctionHasNoTrapsAndSafeOp(module_ir, "allow_wrapping_add", "wrapping.add") and
            lowerIrFunctionHasNoTrapsAndSafeOp(module_ir, "allow_saturating_add", "saturating.add") and
            lowerIrFunctionHasNoTrapsAndSafeOp(module_ir, "allow_boot_asm", "opaque_volatile_asm");
    }
    if (std.mem.eql(u8, check, "contract_region")) {
        return lowerIrFunctionHasContractRegion(module_ir, "allow_unchecked_add_inside_contract", "no_overflow", "unchecked.add") and
            lowerIrFunctionHasPostContractTrapWithoutMetadata(module_ir, "allow_unchecked_add_inside_contract", "no_overflow", .IntegerOverflow, .checked_arithmetic) and
            lowerIrFunctionHasContractRegion(module_ir, "noalias_contract_region", "noalias", "compiler.assume_noalias_unchecked");
    }
    return false;
}

fn hasHirVerifierEvidenceForCheck(facts: []const u8, check: []const u8) bool {
    if (std.mem.eql(u8, check, "no-language-trap-edge")) {
        return containsAll(facts, &.{
            "hir verify fn=reject_checked_add finding=trap_edge detail=IntegerOverflow no_lang_trap=true",
            "hir verify fn=reject_bounds_check finding=trap_edge detail=Bounds no_lang_trap=true",
            "hir verify fn=reject_assert finding=trap_edge detail=Assert no_lang_trap=true",
            "hir verify fn=reject_reachable_unreachable finding=trap_edge detail=Unreachable no_lang_trap=true",
            "hir verify fn=reject_explicit_trap finding=trap_edge detail=ExplicitTrap no_lang_trap=true",
            "hir verify fn=reject_nullable_try finding=trap_edge detail=Unwrap no_lang_trap=true",
            "hir verify fn=reject_unwrap_call finding=trap_edge detail=Unwrap no_lang_trap=true",
            "hir verify fn=reject_right_shift finding=trap_edge detail=InvalidShift no_lang_trap=true",
            "hir verify fn=reject_checked_negation finding=trap_edge detail=IntegerOverflow no_lang_trap=true",
            "hir verify fn=reject_call_trapping_fn finding=trap_edge detail=CallMayTrap no_lang_trap=true",
        }) and
            std.mem.indexOf(u8, facts, "hir verify fn=allow_wrapping_add finding=trap_edge") == null and
            std.mem.indexOf(u8, facts, "hir verify fn=allow_wrapping_neg finding=trap_edge") == null and
            std.mem.indexOf(u8, facts, "hir verify fn=allow_saturating_add finding=trap_edge") == null and
            std.mem.indexOf(u8, facts, "hir verify fn=allow_call_no_lang_trap_fn finding=trap_edge") == null and
            std.mem.indexOf(u8, facts, "hir verify fn=allow_boot_asm finding=trap_edge") == null;
    }
    return false;
}

fn hasMirVerifierEvidenceForCheck(facts: []const u8, check: []const u8) bool {
    if (std.mem.eql(u8, check, "no-language-trap-edge")) {
        return containsAll(facts, &.{
            "mir verify fn=reject_checked_add pass=trap finding=trap_edge detail=IntegerOverflow source=checked_arithmetic no_lang_trap=true",
            "mir verify fn=reject_bounds_check pass=trap finding=trap_edge detail=Bounds source=bounds_check no_lang_trap=true",
            "mir verify fn=reject_assert pass=trap finding=trap_edge detail=Assert source=assert_stmt no_lang_trap=true",
            "mir verify fn=reject_reachable_unreachable pass=trap finding=trap_edge detail=Unreachable source=unreachable_expr no_lang_trap=true",
            "mir verify fn=reject_explicit_trap pass=trap finding=trap_edge detail=ExplicitTrap source=explicit_trap no_lang_trap=true",
            "mir verify fn=reject_nullable_try pass=trap finding=trap_edge detail=Unwrap source=unwrap no_lang_trap=true",
            "mir verify fn=reject_unwrap_call pass=trap finding=trap_edge detail=Unwrap source=unwrap no_lang_trap=true",
            "mir verify fn=reject_right_shift pass=trap finding=trap_edge detail=InvalidShift source=checked_shift no_lang_trap=true",
            "mir verify fn=reject_checked_negation pass=trap finding=trap_edge detail=IntegerOverflow source=checked_arithmetic no_lang_trap=true",
            "mir verify fn=reject_call_trapping_fn pass=trap finding=trap_edge detail=CallMayTrap source=call no_lang_trap=true",
        }) and
            std.mem.indexOf(u8, facts, "mir verify fn=allow_wrapping_add pass=trap finding=trap_edge") == null and
            std.mem.indexOf(u8, facts, "mir verify fn=allow_wrapping_neg pass=trap finding=trap_edge") == null and
            std.mem.indexOf(u8, facts, "mir verify fn=allow_saturating_add pass=trap finding=trap_edge") == null and
            std.mem.indexOf(u8, facts, "mir verify fn=allow_call_no_lang_trap_fn pass=trap finding=trap_edge") == null and
            std.mem.indexOf(u8, facts, "mir verify fn=allow_boot_asm pass=trap finding=trap_edge") == null;
    }
    if (std.mem.eql(u8, check, "irq-context-verifier")) {
        return containsAll(facts, &.{
            "mir verify fn=reject_plain_call pass=context finding=irq_call detail=ordinary_work",
            "mir verify fn=reject_indirect_call pass=context finding=irq_call detail=callee",
            "mir verify fn=reject_blocking_calls pass=context finding=irq_blocking detail=lock.acquire",
            "mir verify fn=reject_blocking_calls pass=context finding=irq_blocking detail=heap.alloc",
            "mir verify fn=reject_blocking_calls pass=context finding=irq_blocking detail=device.wait_irq",
            "mir verify fn=reject_blocking_calls pass=context finding=irq_blocking detail=fs.read",
        }) and
            std.mem.indexOf(u8, facts, "mir verify fn=allow_irq_to_irq pass=context finding=irq_call") == null and
            std.mem.indexOf(u8, facts, "mir verify fn=allow_atomic_and_mmio pass=context finding=irq_call") == null;
    }
    return false;
}

fn hasMirEvidenceForCheck(module: mir.Module, check: []const u8) bool {
    if (std.mem.eql(u8, check, "contract_region")) {
        return mirFunctionHasContractRegion(module, "allow_unchecked_add_inside_contract", "no_overflow", "unchecked.add") and
            mirFunctionHasNoOverflowRangeFact(module, "allow_unchecked_add_inside_contract", "sum", "add") and
            mirFunctionHasContractRegion(module, "noalias_contract_region", "noalias", "compiler.assume_noalias_unchecked");
    }
    return false;
}

fn mirFunctionHasContractRegion(module: mir.Module, name: []const u8, contract: []const u8, callee: []const u8) bool {
    const function = mirFunctionByName(module, name) orelse return false;
    var region_id: ?usize = null;
    for (function.contract_regions) |region| {
        if (std.mem.eql(u8, region.kind, contract) and region.end_line > region.begin_line) {
            region_id = region.id;
            break;
        }
    }
    const expected_region_id = region_id orelse return false;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.kind == .unchecked_assume and
                std.mem.eql(u8, instruction.detail, callee) and
                instruction.contract_region_id != null and
                instruction.contract_region_id.? == expected_region_id)
            {
                return true;
            }
        }
    }
    return false;
}

fn mirFunctionHasNoOverflowRangeFact(module: mir.Module, name: []const u8, target: []const u8, op: []const u8) bool {
    const function = mirFunctionByName(module, name) orelse return false;
    for (function.range_facts) |fact| {
        if (std.mem.eql(u8, fact.target, target) and
            std.mem.eql(u8, fact.op, op) and
            fact.region_id != 0)
        {
            return true;
        }
    }
    return false;
}

fn mirFunctionByName(module: mir.Module, name: []const u8) ?mir.Function {
    for (module.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
}

fn lowerIrFunctionHasTrap(module_ir: ir.ModuleIr, name: []const u8, kind: ir.TrapKind, source: ir.TrapSource) bool {
    const function = lowerIrFunctionByName(module_ir, name) orelse return false;
    if (!function.no_lang_trap) return false;
    for (function.trap_edges) |edge| {
        if (edge.kind == kind and edge.source == source and edge.no_lang_trap) return true;
    }
    return false;
}

fn lowerIrFunctionHasNoTrapsAndSafeOp(module_ir: ir.ModuleIr, name: []const u8, op_kind: []const u8) bool {
    const function = lowerIrFunctionByName(module_ir, name) orelse return false;
    if (!function.no_lang_trap or function.trap_edges.len != 0) return false;
    for (function.safe_no_trap_ops) |op| {
        if (std.mem.eql(u8, op.kind, op_kind)) return true;
    }
    return false;
}

fn lowerIrFunctionHasContractRegion(module_ir: ir.ModuleIr, name: []const u8, contract: []const u8, callee: []const u8) bool {
    const function = lowerIrFunctionByName(module_ir, name) orelse return false;
    var region_id: ?usize = null;
    var begin_line: usize = 0;
    var end_line: usize = 0;
    for (function.contract_regions) |region| {
        if (std.mem.eql(u8, region.contract, contract) and region.unchecked_calls > 0 and !region.metadata_attached_after_region) {
            region_id = region.id;
            begin_line = region.begin_line;
            end_line = region.end_line;
            if (region.end_line <= region.begin_line) return false;
            break;
        }
    }
    const expected_region_id = region_id orelse return false;
    for (function.unchecked_calls) |call| {
        if (std.mem.eql(u8, call.callee, callee) and call.contract_region_id != null and call.contract_region_id.? == expected_region_id) {
            return call.line >= begin_line and call.line <= end_line;
        }
    }
    return false;
}

fn lowerIrFunctionHasPostContractTrapWithoutMetadata(module_ir: ir.ModuleIr, name: []const u8, contract: []const u8, kind: ir.TrapKind, source: ir.TrapSource) bool {
    const function = lowerIrFunctionByName(module_ir, name) orelse return false;
    var contract_end: ?usize = null;
    for (function.contract_regions) |region| {
        if (std.mem.eql(u8, region.contract, contract) and !region.metadata_attached_after_region) {
            contract_end = region.end_line;
            break;
        }
    }
    const end_line = contract_end orelse return false;
    for (function.trap_edges) |edge| {
        if (edge.kind == kind and edge.source == source and edge.line > end_line) return true;
    }
    return false;
}

fn lowerIrFunctionByName(module_ir: ir.ModuleIr, name: []const u8) ?ir.FunctionIr {
    for (module_ir.functions) |function| {
        if (std.mem.eql(u8, function.name, name)) return function;
    }
    return null;
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
            "lower ordinary_access fn=possibly_racing_store object=shared_counter access=store race_class=possibly_shared strategy=race_helper helper=mc_race_store_u32 type=u32 width_bits=32 helper_required=true helper_available=true c_plain_access=false",
            "lower race_backend fn=possibly_racing_store object=shared_counter access=store action=emit_helper helper=mc_race_store_u32 type=u32 width_bits=32 expr=mc_race_store_u32(&shared_counter, value) c_plain_access=false reject_if_helper_missing=true",
            "lower ordinary_access fn=possibly_racing_load object=shared_counter access=load race_class=possibly_shared strategy=race_helper helper=mc_race_load_u32 type=u32 width_bits=32 helper_required=true helper_available=true c_plain_access=false",
            "lower race_backend fn=possibly_racing_load object=shared_counter access=load action=emit_helper helper=mc_race_load_u32 type=u32 width_bits=32 expr=mc_race_load_u32(&shared_counter) c_plain_access=false reject_if_helper_missing=true",
            "lower ordinary_access fn=possibly_racing_field_store object=shared_pair.value access=store race_class=possibly_shared strategy=race_helper helper=mc_race_store_u32 type=u32 width_bits=32 helper_required=true helper_available=true c_plain_access=false",
            "lower race_backend fn=possibly_racing_field_store object=shared_pair.value access=store action=emit_helper helper=mc_race_store_u32 type=u32 width_bits=32 expr=mc_race_store_u32(&shared_pair.value, value) c_plain_access=false reject_if_helper_missing=true",
            "lower ordinary_access fn=possibly_racing_field_load object=shared_pair.value access=load race_class=possibly_shared strategy=race_helper helper=mc_race_load_u32 type=u32 width_bits=32 helper_required=true helper_available=true c_plain_access=false",
            "lower race_backend fn=possibly_racing_field_load object=shared_pair.value access=load action=emit_helper helper=mc_race_load_u32 type=u32 width_bits=32 expr=mc_race_load_u32(&shared_pair.value) c_plain_access=false reject_if_helper_missing=true",
            "lower ordinary_access fn=possibly_racing_array_store object=shared_values[] access=store race_class=possibly_shared strategy=race_helper helper=mc_race_store_u32 type=u32 width_bits=32 helper_required=true helper_available=true c_plain_access=false",
            "lower race_backend fn=possibly_racing_array_store object=shared_values[] access=store action=emit_helper helper=mc_race_store_u32 type=u32 width_bits=32 expr=mc_race_store_u32(&shared_values[], value) c_plain_access=false reject_if_helper_missing=true",
            "lower ordinary_access fn=possibly_racing_array_load object=shared_values[] access=load race_class=possibly_shared strategy=race_helper helper=mc_race_load_u32 type=u32 width_bits=32 helper_required=true helper_available=true c_plain_access=false",
            "lower race_backend fn=possibly_racing_array_load object=shared_values[] access=load action=emit_helper helper=mc_race_load_u32 type=u32 width_bits=32 expr=mc_race_load_u32(&shared_values[]) c_plain_access=false reject_if_helper_missing=true",
            "lower non_atomic_rmw fn=racing_increment_is_not_atomic object=shared_counter bug_if_concurrent=true optimizer_license_ub=false atomic=false c_data_race_ub_dependency=false",
        });
    }
    if (std.mem.eql(u8, check, "no-happens-before")) {
        return containsAll(output, &.{
            "lower race_semantics fn=possibly_racing_load object=shared_counter creates_happens_before=false assumes_no_race=false",
            "lower racing_load_semantics fn=possibly_racing_load object=shared_counter result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false",
            "lower race_semantics fn=possibly_racing_field_load object=shared_pair.value creates_happens_before=false assumes_no_race=false",
            "lower racing_load_semantics fn=possibly_racing_field_load object=shared_pair.value result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false",
            "lower race_semantics fn=possibly_racing_array_load object=shared_values[] creates_happens_before=false assumes_no_race=false",
            "lower racing_load_semantics fn=possibly_racing_array_load object=shared_values[] result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false",
        });
    }
    if (std.mem.eql(u8, check, "no-c-data-race-ub")) {
        return containsAll(output, &.{
            "lower c_ub fn=possibly_racing_store object=shared_counter c_data_race_ub_dependency=false",
            "lower c_ub fn=possibly_racing_load object=shared_counter c_data_race_ub_dependency=false",
            "lower c_ub fn=possibly_racing_field_store object=shared_pair.value c_data_race_ub_dependency=false",
            "lower c_ub fn=possibly_racing_field_load object=shared_pair.value c_data_race_ub_dependency=false",
            "lower c_ub fn=possibly_racing_array_store object=shared_values[] c_data_race_ub_dependency=false",
            "lower c_ub fn=possibly_racing_array_load object=shared_values[] c_data_race_ub_dependency=false",
            "lower racing_load_semantics fn=possibly_racing_load object=shared_counter result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false",
            "lower racing_load_semantics fn=possibly_racing_field_load object=shared_pair.value result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false",
            "lower racing_load_semantics fn=possibly_racing_array_load object=shared_values[] result=target_defined may_tear=true creates_happens_before=false assumes_no_race=false c_data_race_ub_dependency=false",
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
            "lower mmio_backend fn=putc op=write register=Uart16550.thr helper=mc_mmio_write_u8 value_type=u8 width_bits=8 volatile=true address_space=mmio",
            "lower mmio_backend fn=read_status op=read register=Uart16550.lsr helper=mc_mmio_read_u8 value_type=UartLsr width_bits=8 volatile=true address_space=mmio",
        });
    }
    if (std.mem.eql(u8, check, "mmio-ordering-preserved")) {
        return containsAll(output, &.{
            "lower mmio_order fn=putc op=write register=Uart16550.thr ordering=release",
            "prevents_before_after=true",
            "lower mmio_barrier fn=putc register=Uart16550.thr ordering=release placement=before helper=mc_barrier_release_before prevents_reorder=true",
            "lower mmio_order fn=read_status op=read register=Uart16550.lsr ordering=acquire",
            "prevents_after_before=true",
            "lower mmio_barrier fn=read_status register=Uart16550.lsr ordering=acquire placement=after helper=mc_barrier_acquire_after prevents_reorder=true",
            "lower mmio_sequence fn=ordered_device_sequence edge=ordinary_before_release before=raw.store barrier=Uart16550.thr.write ordering=release prevents_reorder=true",
            "lower mmio_sequence fn=ordered_device_sequence edge=ordinary_after_acquire barrier=Uart16550.lsr.read ordering=acquire after=raw.store prevents_reorder=true",
        });
    }
    if (std.mem.eql(u8, check, "packed-bits-no-c-bitfields")) {
        return containsAll(output, &.{
            "lower packed_bits name=UartLsr",
            "strategy=mask_shift",
            "c_bitfields=false",
            "semantic_source=mc_bits",
        });
    }
    if (std.mem.eql(u8, check, "overlay-union-byte-storage")) {
        return containsAll(output, &.{
            "lower overlay_union name=Word",
            "strategy=byte_storage",
            "c_union=false",
            "semantic_source=mc_bytes",
        });
    }
    if (std.mem.eql(u8, check, "arithmetic-domain-lowering")) {
        return containsAll(output, &.{
            "lower arithmetic_domain fn=wrap_add domain=wrap op=add strategy=plain_unsigned language_trap=false overflow_trap=false emits_checked_overflow_helper=false",
            "lower arithmetic_domain fn=wrap_bitwise domain=wrap op=bit_and strategy=plain_unsigned language_trap=false overflow_trap=false emits_checked_overflow_helper=false",
            "lower arithmetic_domain fn=sat_add domain=sat op=add strategy=saturating_helper language_trap=false overflow_trap=false emits_checked_overflow_helper=false",
            "lower arithmetic_domain fn=sat_mul domain=sat op=mul strategy=saturating_helper language_trap=false overflow_trap=false emits_checked_overflow_helper=false",
        }) and
            std.mem.indexOf(u8, output, "lower checked_arith fn=wrap_add") == null and
            std.mem.indexOf(u8, output, "lower checked_arith fn=sat_add") == null;
    }
    if (std.mem.eql(u8, check, "atomics-lowering")) {
        return containsAll(output, &.{
            "lower atomic_access fn=atomic_load_acquire op=load object=flag type=bool ordering=acquire c_order=__ATOMIC_ACQUIRE builtin=__atomic_load_n volatile=false ordinary_access=false creates_happens_before=true",
            "lower atomic_backend fn=atomic_load_acquire op=load object=flag c_expr=__atomic_load_n(&flag, ...) c_plain_access=false volatile=false",
            "lower atomic_access fn=atomic_store_release op=store object=flag type=bool ordering=release c_order=__ATOMIC_RELEASE builtin=__atomic_store_n volatile=false ordinary_access=false creates_happens_before=true",
            "lower atomic_backend fn=atomic_store_release op=store object=flag c_expr=__atomic_store_n(&flag, ...) c_plain_access=false volatile=false",
            "lower atomic_access fn=atomic_fetch_add_acq_rel op=fetch_add object=ticks type=u64 ordering=acq_rel c_order=__ATOMIC_ACQ_REL builtin=__atomic_fetch_add volatile=false ordinary_access=false creates_happens_before=true",
            "lower atomic_backend fn=atomic_fetch_add_acq_rel op=fetch_add object=ticks c_expr=__atomic_fetch_add(&ticks, ...) c_plain_access=false volatile=false",
        });
    }
    if (std.mem.eql(u8, check, "dma-cache-core")) {
        return containsAll(output, &.{
            "lower dma_access fn=accept_dma_addr op=dma_addr object=buf payload=Packet mode=noncoherent result=DmaAddr address_class=dma_addr not_paddr=true not_vaddr=true",
            "lower dma_cache fn=accept_noncoherent_cache_cycle op=clean object=buf payload=Packet mode=noncoherent helper=mc_dma_cache_clean required_for_noncoherent=true",
            "lower dma_cache fn=accept_noncoherent_cache_cycle op=invalidate object=buf payload=Packet mode=noncoherent helper=mc_dma_cache_invalidate required_for_noncoherent=true",
            "lower dma_access fn=accept_noncoherent_cache_cycle op=as_slice object=buf payload=Packet mode=noncoherent result=slice temporal_cache_proven=false core_guarantee=address_class_only",
            "lower dma_access fn=accept_core_allows_unproven_slice op=as_slice object=buf payload=Packet mode=noncoherent result=slice temporal_cache_proven=false core_guarantee=address_class_only",
            "lower dma_access fn=accept_coherent_slice op=as_slice object=buf payload=Packet mode=coherent result=slice temporal_cache_proven=false core_guarantee=address_class_only",
        });
    }
    if (std.mem.eql(u8, check, "dma-ordering-composition")) {
        return containsAll(output, &.{
            // section 18 cache barriers carry their section 17 composition role.
            "lower dma_cache_order fn=program_noncoherent_dma op=clean object=buf role=before_device_handoff barrier=true composes_with=section17_mmio_release",
            "lower dma_cache_order fn=program_noncoherent_dma op=invalidate object=buf role=before_cpu_read barrier=true composes_with=section17_mmio_acquire",
            // a DMA-descriptor handoff is an MMIO write of a dma_addr; it joins the section 17 ordering set.
            "lower dma_descriptor fn=program_noncoherent_dma register=DmaEngine.desc_addr object=buf value=dma_addr ordering=release handoff=true composes_with=section17_mmio participants=ordinary,atomic,dma_descriptor,mmio",
            // clean-for-device may not move after the .release descriptor write.
            "lower mmio_sequence fn=program_noncoherent_dma edge=cache_clean_before_release before=cache.clean barrier=DmaEngine.desc_addr.write ordering=release prevents_reorder=true",
        });
    }
    if (std.mem.eql(u8, check, "irq-off-capability")) {
        return containsAll(output, &.{
            "lower irq_off fn=read_device param=cs capability=interrupts_disabled c_type=uint8_t witness=true",
        });
    }
    if (std.mem.eql(u8, check, "opaque-asm-lowering")) {
        return containsAll(output, &.{
            "lower asm fn=accept_opaque_asm form=opaque volatile=true conservative=true memory_clobber=true optimizer_assumptions=false c_backend=gcc_clang_asm",
            "lower asm fn=accept_opaque_asm_default_memory form=opaque volatile=true conservative=true memory_clobber=true optimizer_assumptions=false c_backend=gcc_clang_asm",
        });
    }
    if (std.mem.eql(u8, check, "bitcast-lowering")) {
        return containsAll(output, &.{
            "lower bitcast fn=bitcast_u32_from_i32 source=i32 target=u32 strategy=memcpy helper=mc_bitcast_memcpy strict_aliasing_cast=false",
            "lower bitcast fn=bitcast_i32_from_u32 source=u32 target=i32 strategy=memcpy helper=mc_bitcast_memcpy strict_aliasing_cast=false",
        });
    }
    if (std.mem.eql(u8, check, "floating-reduction-modes")) {
        return containsAll(output, &.{
            "lower float_reduce fn=sum_left_f64 op=sum_left type=f64 c_type=double strict_left_fold=true reassociate=false vectorize=false target_dependent=false",
            "lower float_reduce fn=sum_fast_f32 op=sum_fast type=f32 c_type=float strict_left_fold=false reassociate=true vectorize=true target_dependent=true",
        });
    }
    return false;
}

// ----- spec section coverage gate -----
//
// Turns the per-fixture `// SPEC: section=` metadata into an actual conformance gate: every
// normative section of docs/spec that is meant to be exercised by a semantic/diagnostic
// fixture must be referenced by at least one tests/spec fixture. Sections covered by other
// suites (codegen sweeps, tests/llvm, the runtime tools/ suites) or that are prose are listed
// in `coverage_exempt` with a note — so adding a section to the spec forces either a fixture
// or an explicit, reviewed exemption. (This would have caught §7 Indexing falling through.)
const coverage_exempt = [_][]const u8{
    // Umbrella parent (its normative children 1.1/1.2/1.3 carry the fixtures).
    "1",
    // §9.1 closures (`closure(...)` type + `bind`) are exercised by the runtime/LLVM suites
    // (tests/llvm/void_indirect_calls.mc, the std alloc/arena tests), not a semantic fixture.
    "9.1",
    // Rationale / final-contract prose — nothing to execute.
    "26", "26.1", "26.2", "26.3", "27",
    // §29 tuples — desugar to structs; the type/literal/access/destructure/lowering rules are
    // exercised by the lower_c.zig unit tests (tuple desugaring + destructuring) and both-backend
    // run checks. The n>=2 arity rule is a parse-time error (not a sema diagnostic fixture).
    "29", "29.1", "29.2",
    // §28 driver-library profile — exercised by the runtime suite (sync-test, stack-test,
    // ring/endian/time/barrier tests under tools/), not by semantic fixtures.
    "28",  "28.1", "28.2", "28.3", "28.4", "28.5", "28.6", "28.7",
    // Implementation & conformance annex (Part II). Verifier passes (D.*) are exercised by the
    // section fixtures whose rules they enforce; MIR/lowering (E.*, I.*) by the C-emit sweep and
    // the llvm sweeps; the LLVM and debug backends (M, N) by tests/llvm; the rest is prose.
    "A",  "A.1", "B", "C", "C.1", "C.2", "C.3",
    "D",  "D.1", "D.2", "D.3", "D.4", "D.5", "D.6", "D.7",
    // E.4 fact-gated optimizer is exercised by the dedicated `opt-test` (not a sema fixture).
    "E",  "E.1", "E.2", "E.3", "E.4", "F", "G", "H",
    "I",  "I.1", "I.2", "I.3", "I.4", "I.5", "I.6", "I.7", "I.8",
    "I.9", "I.10", "I.11", "I.12", "I.13", "I.14", "I.15",
    // N.1 (editor tooling — formatter + language server) is exercised by `fmt-test` and
    // `lsp-test`, not by a semantic fixture.
    "J", "K", "L", "L.1", "L.2", "L.3", "M", "N", "N.1", "O",
};

fn coverageIsAllDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// Extract the section id from a spec markdown header line, or null if the line is not a
// numbered/lettered section header. `# 5. Title` -> "5", `## 5.2 Title` -> "5.2",
// `## D.7 Title` -> "D.7". Rejects the document title, Part dividers, and the subtitle.
fn parseSpecSectionId(line: []const u8) ?[]const u8 {
    var h: usize = 0;
    while (h < line.len and line[h] == '#') h += 1;
    if (h == 0 or h > 2) return null;
    if (h >= line.len or line[h] != ' ') return null;
    var start = h;
    while (start < line.len and line[start] == ' ') start += 1;
    const rest = line[start..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    var tok = rest[0..sp];
    if (tok.len > 0 and tok[tok.len - 1] == '.') tok = tok[0 .. tok.len - 1];
    if (tok.len == 0) return null;
    var parts = std.mem.splitScalar(u8, tok, '.');
    var idx: usize = 0;
    while (parts.next()) |part| : (idx += 1) {
        if (idx == 0) {
            const ok = coverageIsAllDigits(part) or (part.len == 1 and part[0] >= 'A' and part[0] <= 'O');
            if (!ok) return null;
        } else if (!coverageIsAllDigits(part)) {
            return null;
        }
    }
    return tok;
}

fn sectionIsExempt(sec: []const u8) bool {
    for (coverage_exempt) |e| {
        if (std.mem.eql(u8, e, sec)) return true;
    }
    return false;
}

// A section counts as covered if a fixture tags it exactly, tags a more specific child (the
// family is exercised), or tags its parent section.
fn sectionIsCovered(sec: []const u8, covered: *const std.StringHashMap(void)) bool {
    if (covered.contains(sec)) return true;
    var it = covered.keyIterator();
    while (it.next()) |k| {
        const key = k.*;
        if (key.len > sec.len + 1 and std.mem.startsWith(u8, key, sec) and key[sec.len] == '.') return true;
    }
    if (std.mem.lastIndexOfScalar(u8, sec, '.')) |dot| {
        if (covered.contains(sec[0..dot])) return true;
    }
    return false;
}

test "spec section coverage: every normative section has a tests/spec fixture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Collect the sections referenced by tests/spec fixtures.
    var covered = std.StringHashMap(void).init(a);
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/spec", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".mc")) continue;
        const source = try dir.readFileAlloc(io, entry.path, a, .limited(1024 * 1024));
        var metadata = parseLeadingMetadata(a, source) catch continue;
        const sec = metadata.valueFor("section") orelse continue;
        var it = std.mem.splitScalar(u8, sec, ',');
        while (it.next()) |raw| {
            const s = std.mem.trim(u8, raw, " \t");
            if (s.len > 0) try covered.put(s, {});
        }
    }

    // Walk the spec's section headers and require coverage of each non-exempt section.
    const spec = try std.Io.Dir.cwd().readFileAlloc(io, "docs/spec/MC_0.7_Final_Design.md", a, .limited(2 * 1024 * 1024));
    var seen = std.StringHashMap(void).init(a);
    var missing: std.ArrayList([]const u8) = .empty;
    var required: usize = 0;
    var covered_required: usize = 0;
    var line_it = std.mem.splitScalar(u8, spec, '\n');
    while (line_it.next()) |raw_line| {
        const id = parseSpecSectionId(std.mem.trim(u8, raw_line, "\r")) orelse continue;
        if (seen.contains(id)) continue;
        try seen.put(id, {});
        if (sectionIsExempt(id)) continue;
        required += 1;
        if (sectionIsCovered(id, &covered)) {
            covered_required += 1;
        } else {
            try missing.append(a, id);
        }
    }

    if (missing.items.len > 0) {
        std.debug.print("spec coverage: {d}/{d} required sections have a tests/spec fixture; missing:\n", .{ covered_required, required });
        for (missing.items) |m| std.debug.print("  section {s} — add a tests/spec fixture or an entry in coverage_exempt\n", .{m});
    }
    try std.testing.expect(required > 0);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);
}
