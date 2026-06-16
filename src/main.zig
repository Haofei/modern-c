const std = @import("std");

const ast = @import("ast.zig");
const backend = @import("backend.zig");
const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const fmt = @import("fmt.zig");
const hir = @import("hir.zig");
const ir = @import("ir.zig");
const lexer = @import("lexer.zig");
const loader = @import("loader.zig");
const lower_c = @import("lower_c.zig");
const lower_llvm = @import("lower_llvm.zig");
const mir = @import("mir.zig");
const monomorphize = @import("monomorphize.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");
const spec_tests = @import("spec_tests.zig");
const symbols = @import("symbols.zig");

const usage =
    \\usage:
    \\  mcc lex <file.mc>
    \\  mcc check <file.mc>
    \\  mcc run-trap <file.mc>
    \\  mcc facts <file.mc>
    \\  mcc lower-hir <file.mc>
    \\  mcc verify-hir <file.mc>
    \\  mcc lower-mir <file.mc>
    \\  mcc verify <file.mc>
    \\  mcc lower-ir <file.mc>
    \\  mcc lower-c <file.mc>
    \\  mcc emit-c <file.mc> [--profile=kernel|hosted]
    \\  mcc emit-map <file.mc> [--profile=kernel|hosted]
    \\  mcc emit-llvm <file.mc>
    \\  mcc emit-layout <file.mc> --structs=A,B,C
    \\  mcc fmt <file.mc> [--check]
    \\  mcc symbols <file.mc>
    \\
;

// Generated artifacts (lowered HIR/IR/C, facts, verification reports) go to
// stdout so they can be redirected with `>`; diagnostics and logs stay on stderr.
var stdout_io: std.Io = undefined;

fn writeStdout(bytes: []const u8) !void {
    std.Io.File.stdout().writeStreamingAll(stdout_io, bytes) catch |err| switch (err) {
        error.BrokenPipe => return,
        else => return err,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    stdout_io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    _ = args.next();
    const command = args.next() orelse return failUsage();
    const path = args.next() orelse return failUsage();
    // Optional flags follow the path. `emit-c` and `emit-map` accept:
    // `--profile=kernel` (default) or `--profile=hosted`.
    var profile: lower_c.Profile = .kernel;
    var saw_profile_flag = false;
    var optimize = false;
    var check_fmt = false;
    // `emit-layout --structs=A,B,C`: the comma-separated structs whose MC layout is asserted.
    var structs_flag: ?[]const u8 = null;
    while (args.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "--structs=")) {
            structs_flag = flag["--structs=".len..];
        } else if (std.mem.startsWith(u8, flag, "--profile=")) {
            saw_profile_flag = true;
            const value = flag["--profile=".len..];
            if (std.mem.eql(u8, value, "kernel")) {
                profile = .kernel;
            } else if (std.mem.eql(u8, value, "hosted")) {
                profile = .hosted;
            } else {
                return failUsage();
            }
        } else if (std.mem.eql(u8, flag, "--optimize")) {
            optimize = true;
        } else if (std.mem.eql(u8, flag, "--check")) {
            check_fmt = true;
        } else {
            return failUsage();
        }
    }
    // `--profile` is consumed only by the C artifact commands; `--optimize` (the fact-gated
    // MIR optimizer, annex E) by the MIR-level and code-emitting commands; `--check` only by
    // `fmt`. A flag on any other command is an error.
    const is_c_artifact_command = std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-map");
    const accepts_optimize = std.mem.eql(u8, command, "verify") or std.mem.eql(u8, command, "lower-mir") or
        std.mem.eql(u8, command, "emit-c") or std.mem.eql(u8, command, "emit-llvm");
    const is_emit_layout = std.mem.eql(u8, command, "emit-layout");
    if (saw_profile_flag and !is_c_artifact_command) return failUsage();
    if (optimize and !accepts_optimize) return failUsage();
    if (check_fmt and !std.mem.eql(u8, command, "fmt")) return failUsage();
    // `--structs=` is consumed only by `emit-layout`, and `emit-layout` requires it.
    if (structs_flag != null and !is_emit_layout) return failUsage();
    if (is_emit_layout and structs_flag == null) return failUsage();

    const root_source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(root_source);

    // `fmt` operates on the raw file (not the import-flattened source) and is token-preserving;
    // it bypasses the parse/sema pipeline entirely.
    if (std.mem.eql(u8, command, "fmt")) {
        try runFmt(allocator, path, root_source, check_fmt);
        return;
    }

    // Resolve `import "path";` declarations by textual inclusion (section 22 /
    // module system). With no imports this is the original source plus a
    // trailing newline, so single-file behavior is unchanged.
    const source = try loader.loadCombinedSource(allocator, init.io, path, root_source);
    defer allocator.free(source);

    if (std.mem.eql(u8, command, "lex")) {
        try runLex(allocator, path, source);
    } else if (std.mem.eql(u8, command, "symbols")) {
        try runSymbols(allocator, path, source);
    } else if (std.mem.eql(u8, command, "check")) {
        try runCheck(allocator, path, source);
    } else if (std.mem.eql(u8, command, "run-trap")) {
        try runTrap(allocator, path, source);
    } else if (std.mem.eql(u8, command, "facts")) {
        try runFacts(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-hir")) {
        try runLowerHir(allocator, path, source);
    } else if (std.mem.eql(u8, command, "verify-hir")) {
        try runVerifyHir(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-mir")) {
        try runLowerMir(allocator, path, source, optimize);
    } else if (std.mem.eql(u8, command, "verify")) {
        try runVerify(allocator, path, source, optimize);
    } else if (std.mem.eql(u8, command, "lower-ir")) {
        try runLowerIr(allocator, path, source);
    } else if (std.mem.eql(u8, command, "lower-c")) {
        try runLowerC(allocator, path, source);
    } else if (std.mem.eql(u8, command, "emit-c")) {
        try runEmitC(allocator, path, source, profile, optimize);
    } else if (std.mem.eql(u8, command, "emit-map")) {
        try runEmitMap(allocator, path, source, profile);
    } else if (std.mem.eql(u8, command, "emit-llvm")) {
        try runEmitLlvm(allocator, path, source, optimize);
    } else if (is_emit_layout) {
        try runEmitLayout(allocator, path, source, structs_flag.?);
    } else {
        return failUsage();
    }
}

fn runLowerHir(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerHirFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try hir.appendDump(allocator, module, &output);
    try writeStdout(output.items);
}

fn runVerifyHir(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.VerifyHirFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try hir.appendVerificationFacts(allocator, module, &output);
    try writeStdout(output.items);
}

fn runLowerMir(allocator: std.mem.Allocator, path: []const u8, source: []const u8, optimize: bool) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerMirFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try mir.appendDumpOpt(allocator, module, &output, .{ .optimize = optimize });
    try writeStdout(output.items);
}

fn runVerify(allocator: std.mem.Allocator, path: []const u8, source: []const u8, optimize: bool) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.VerifyFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.optimize = optimize;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.VerifyFailed;
    }

    try mir.verifyOpt(allocator, module, &diag, .{ .optimize = optimize });
    if (diag.has_errors) {
        diag.render();
        return error.VerifyFailed;
    }
}

fn failUsage() !void {
    std.debug.print("{s}", .{usage});
    return error.InvalidArgs;
}

// `mcc fmt <file>` prints the canonically-formatted source to stdout. `mcc fmt --check <file>`
// prints nothing and exits nonzero if the file is not already formatted (for CI / editors).
fn runFmt(allocator: std.mem.Allocator, path: []const u8, source: []const u8, check: bool) !void {
    const formatted = try fmt.format(allocator, source);
    defer allocator.free(formatted);
    if (check) {
        if (!std.mem.eql(u8, formatted, source)) {
            std.debug.print("{s}: not formatted (run `mcc fmt` to fix)\n", .{path});
            return error.FmtCheckFailed;
        }
        return;
    }
    try writeStdout(formatted);
}

// `mcc symbols <file>` prints a JSON symbol index (defs + refs with spans) for the language
// server. Best-effort: it needs only a parse (not sema), and on a hard parse failure it still
// prints a valid empty index so the client always gets parseable JSON.
fn runSymbols(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = parseModuleOrReport(source, parse_allocator, &diag) catch {
        try writeStdout("{\"defs\":[],\"refs\":[]}\n");
        return;
    };
    defer module.deinit(parse_allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try symbols.emitJson(allocator, module, &output);
    try writeStdout(output.items);
}

fn runLex(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var lx = lexer.Lexer.init(source, &diag);
    while (true) {
        const tok = lx.next();
        std.debug.print("{s}:{d}:{d}: {s}", .{
            path,
            tok.span.line,
            tok.span.column,
            @tagName(tok.kind),
        });
        if (tok.lexeme.len != 0) {
            std.debug.print(" `{s}`", .{tok.lexeme});
        }
        std.debug.print("\n", .{});
        if (tok.kind == .eof) break;
    }

    if (diag.has_errors) {
        diag.render();
        return error.LexFailed;
    }
}

fn runCheck(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.CheckFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.CheckFailed;
    }

    std.debug.print("parsed {d} top-level declarations\n", .{module.decls.len});
}

fn runFacts(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.FactsFailed;
    }

    var facts: std.ArrayList(u8) = .empty;
    defer facts.deinit(allocator);
    try ir.appendFacts(allocator, module, &facts);
    try writeStdout(facts.items);
}

fn runLowerIr(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerIrFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try ir.appendLowerIr(allocator, module, &output);
    try writeStdout(output.items);
}

fn runTrap(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.RunTrapFailed;
    }

    var expectations = try eval.parseRunTrapExpectations(allocator, source);
    defer eval.freeRunTrapExpectations(allocator, &expectations);
    if (expectations.items.len == 0) {
        std.debug.print("{s}: no inline run trap expectations found\n", .{path});
        return error.RunTrapFailed;
    }

    for (expectations.items) |expectation| {
        const actual = try eval.runTrapExpectation(allocator, module, expectation.function_name, expectation.args);
        if (actual == null or actual.? != expectation.trap) {
            std.debug.print(
                "{s}:{d}: expected run {s}(...) to trap .{s}, got {s}\n",
                .{ path, expectation.line, expectation.function_name, @tagName(expectation.trap), if (actual) |trap| @tagName(trap) else "no trap" },
            );
            return error.RunTrapFailed;
        }
        std.debug.print(
            "run_trap fn={s} trap={s} reached=true line={d}\n",
            .{ expectation.function_name, @tagName(expectation.trap), expectation.line },
        );
    }
}

fn runLowerC(allocator: std.mem.Allocator, path: []const u8, source: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.LowerCFailed;
    }

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try lower_c.appendInspection(allocator, module, &output);
    try writeStdout(output.items);
}

fn runEmitC(allocator: std.mem.Allocator, path: []const u8, source: []const u8, profile: lower_c.Profile, optimize: bool) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.optimize = optimize;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    try mir.verifyOpt(allocator, module, &diag, .{ .optimize = optimize });
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    const be = backend.byName("c").?;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.lower(allocator, module, &output, .{ .profile = profile, .optimize = optimize, .source_path = path });
    try writeStdout(output.items);
}

fn runEmitMap(allocator: std.mem.Allocator, path: []const u8, source: []const u8, profile: lower_c.Profile) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    try mir.verify(allocator, module, &diag);
    if (diag.has_errors) {
        diag.render();
        return error.EmitCFailed;
    }

    const be = backend.byName("c").?;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.emitMap(allocator, module, &output, profile, path);
    try writeStdout(output.items);
}

fn runEmitLlvm(allocator: std.mem.Allocator, path: []const u8, source: []const u8, optimize: bool) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitLlvmFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.optimize = optimize;
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitLlvmFailed;
    }

    try mir.verifyOpt(allocator, module, &diag, .{ .optimize = optimize });
    if (diag.has_errors) {
        diag.render();
        return error.EmitLlvmFailed;
    }

    const be = backend.byName("llvm").?;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    try be.lower(allocator, module, &output, .{ .profile = .kernel, .optimize = optimize, .source_path = path });
    try writeStdout(output.items);
}

// `emit-layout`: emit a generated C header asserting MC's authoritative layout (sizeof + each
// field offset) for the comma-separated structs in `--structs=`. A C runtime that hand-mirrors
// one of these structs includes the header, so any MC↔C layout drift becomes a compile error.
fn runEmitLayout(allocator: std.mem.Allocator, path: []const u8, source: []const u8, structs_csv: []const u8) !void {
    var diag = diagnostics.Reporter.init(allocator, path, source);
    defer diag.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_allocator = arena.allocator();

    const module = try parseModuleOrReport(source, parse_allocator, &diag);
    defer module.deinit(parse_allocator);

    if (diag.has_errors) {
        diag.render();
        return error.EmitLayoutFailed;
    }

    var checker = sema.Checker.init(&diag);
    checker.checkModule(module);
    if (diag.has_errors) {
        diag.render();
        return error.EmitLayoutFailed;
    }

    // Split `A,B,C` into struct names (arena-allocated so they outlive the loop).
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = std.mem.splitScalar(u8, structs_csv, ',');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        try names.append(allocator, name);
    }
    if (names.items.len == 0) return failUsage();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    lower_c.appendLayoutAsserts(allocator, module, &output, names.items) catch |err| switch (err) {
        error.LayoutStructNotFound => {
            std.debug.print("emit-layout: a struct named in --structs= was not found in {s}\n", .{path});
            return error.EmitLayoutFailed;
        },
        error.LayoutUnresolved => {
            std.debug.print("emit-layout: could not resolve a struct's layout in {s}\n", .{path});
            return error.EmitLayoutFailed;
        },
        else => return err,
    };
    try writeStdout(output.items);
}

fn parseModuleOrReport(source: []const u8, allocator: std.mem.Allocator, diag: *diagnostics.Reporter) !ast.Module {
    var p = parser.Parser.init(source, diag);
    const module = p.parseModule(allocator) catch |err| {
        diag.render();
        return err;
    };
    // Specialize comptime-parameter type-generic functions (section 22). This is
    // a no-op for modules without any such function, so non-generic code is
    // passed through untouched.
    return monomorphize.transform(allocator, module) catch |err| {
        diag.render();
        return err;
    };
}

test {
    _ = diagnostics;
    _ = eval;
    _ = ast;
    _ = backend;
    _ = hir;
    _ = ir;
    _ = lexer;
    _ = loader;
    _ = lower_c;
    _ = lower_llvm;
    _ = mir;
    _ = monomorphize;
    _ = parser;
    _ = sema;
    _ = spec_tests;
}
