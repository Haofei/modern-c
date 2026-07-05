const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const lower_c = @import("lower_c.zig");
const mir = @import("mir.zig");
const parser = @import("parser.zig");
const test_support = @import("test_support.zig");

fn appendCTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try lower_c.appendC(std.testing.allocator, parsed.module, output);
}

fn appendCheckedCTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    try lower_c.appendC(std.testing.allocator, parsed.module, output);
}

fn expectUnsupportedCheckedCEmission(source_name: []const u8, source: []const u8) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, lower_c.appendC(std.testing.allocator, parsed.module, &output));
}

fn hasTestDiagnosticCode(reporter: diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.startsWith(u8, diag.message, code) and diag.message.len > code.len and diag.message[code.len] == ':') return true;
    }
    return false;
}

test "lower-c inspection markers for lowering-sensitive spec behavior" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn exercise(uart: MmioPtr<Uart16550>, ch: u8, a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let y = unchecked.add(a, b);
        \\    }
        \\    shared_counter = ch;
        \\    let x = shared_counter;
        \\    uart.thr.write(ch, .release);
        \\    let status = uart.lsr.read(.acquire);
        \\    return a + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "lower_c.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendInspection(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower checked_arith") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "op=add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower contract_scope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "metadata_begin=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "metadata_end=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower ordinary_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "access=store") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "access=load") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "lower mmio_access") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value_type=UartLsr") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "register_width=8 emitted_width=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=release") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ordering=acquire") != null);
}

test "lower-c emits support helpers used by evidence" {
    const source =
        \\fn noop() -> void {}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_IntegerOverflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_DivideByZero") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidShift") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_NullUnwrap") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_check_index_usize") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_UNSIGNED(u32, uint32_t, UINT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_UNSIGNED(u64, uint64_t, UINT64_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_SIGNED(i32, int32_t, INT32_MIN, INT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_NEG_SIGNED(i32, int32_t, INT32_MIN)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_NEG_SIGNED(isize, intptr_t, INTPTR_MIN)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(NAME, TYPE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(bool, bool)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(u32, uint32_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(i32, int32_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_RACE_SCALAR(usize, uintptr_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_write_u64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_thread_fence(__ATOMIC_RELEASE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_thread_fence(__ATOMIC_ACQUIRE)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__atomic_signal_fence") == null);
}

test "lower-c emits cstr as immutable C string pointer" {
    const source =
        \\extern "C" fn strlen(s: cstr) -> usize;
        \\extern "C" fn identity(s: cstr) -> cstr;
        \\
        \\export fn use_cstr() -> usize {
        \\    let s: cstr = "abc";
        \\    return strlen(s);
        \\}
        \\
        \\export fn return_cstr() -> cstr {
        \\    return identity("xyz");
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("cstr_c.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t strlen(char const * s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * identity(char const * s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * s = ((char const *)\"abc\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * return_cstr(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = ((char const *)\"xyz\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return identity(mc_tmp") != null);
}

test "lower-c reuses prebuilt verified MIR without changing output" {
    const source =
        \\fn add_one(value: u32) -> u32 {
        \\    return value + 1;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_prebuilt_mir.mc", source);
    defer parsed.deinit();

    var rebuilt_output: std.ArrayList(u8) = .empty;
    defer rebuilt_output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithSourcePath(std.testing.allocator, parsed.module, &rebuilt_output, .kernel, "c_prebuilt_mir.mc", .{ .optimize = true }, false);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "c_prebuilt_mir.mc", source);
    defer reporter.deinit();
    var module_mir = try mir.buildOpt(std.testing.allocator, parsed.module, .{ .optimize = true });
    defer module_mir.deinit();
    try mir.verifyBuiltMir(module_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);

    var prebuilt_output: std.ArrayList(u8) = .empty;
    defer prebuilt_output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMir(std.testing.allocator, parsed.module, &module_mir, &prebuilt_output, .kernel, "c_prebuilt_mir.mc", .{ .optimize = true }, false, &reporter);

    try std.testing.expectEqualSlices(u8, rebuilt_output.items, prebuilt_output.items);
}

test "lower-c path-aware C emission writes source line hints" {
    const source =
        \\global count: u32 = 1;
        \\
        \\fn add_one(x: u32) -> u32 {
        \\    let y: u32 = x + 1;
        \\    return y;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "debug_map.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithSourcePath(std.testing.allocator, module, &output, .kernel, "debug\"map\\case.mc", .{}, false);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "#line 1 \"debug\\\"map\\\\case.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#line 3 \"debug\\\"map\\\\case.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#line 4 \"debug\\\"map\\\\case.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#line 5 \"debug\\\"map\\\\case.mc\"") != null);
}

test "lower-c source map records source spans and generated C lines" {
    const source =
        \\global count: u32 = 1;
        \\
        \\fn add_one(x: u32) -> u32 {
        \\    let y: u32 = x + 1;
        \\    return y;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "debug_map.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCSourceMap(std.testing.allocator, module, &output, .kernel, "debug_map.mc", "debug_map.c");

    try std.testing.expect(std.mem.indexOf(u8, output.items, "# mcmap v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "source_module=\"debug_map\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "symbol_kind=\"free_fn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "source_qualname=\"add_one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "backend_name=\"add_one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "origin=\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "symbol_kind=\"assoc_const\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"global\" symbol=\"count\" source_line=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"global_initializer_expr\" symbol=\"count\" source_line=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"function\" symbol=\"add_one\" source_line=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"let_decl\" symbol=\"add_one\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"initializer_expr\" symbol=\"add_one\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"expr_ident\" symbol=\"add_one\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"expr_int_literal\" symbol=\"add_one\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"return\" symbol=\"add_one\" source_line=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"return_expr\" symbol=\"add_one\" source_line=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "generated_c_line=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "source_path=\"debug_map.mc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "generated_c_path=\"debug_map.c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typed_ast_node=\"ast:function:add_one@3:4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typed_ast_node=\"ast:global_initializer_expr:count@1:21\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typed_ast_node=\"ast:initializer_expr:add_one@4:18\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typed_ast_node=\"ast:return_expr:add_one@5:12\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mir_block=\"mir:add_one:block:") != null);
}

test "lower-c source map records defer cleanup spans" {
    const source =
        \\extern fn close_resource() -> void;
        \\
        \\fn cleanup(flag: bool) -> void {
        \\    defer close_resource();
        \\    defer {
        \\        close_resource();
        \\    };
        \\    while flag {
        \\        defer close_resource();
        \\        break;
        \\    }
        \\    return;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "debug_map_defer.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCSourceMap(std.testing.allocator, module, &output, .kernel, "debug_map_defer.mc", "debug_map_defer.c");

    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer\" symbol=\"cleanup\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer_expr\" symbol=\"cleanup\" source_line=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer\" symbol=\"cleanup\" source_line=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"expr\" symbol=\"cleanup\" source_line=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer\" symbol=\"cleanup\" source_line=9") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "entry kind=\"defer_expr\" symbol=\"cleanup\" source_line=9") != null);
    var defer_lines = std.mem.splitScalar(u8, output.items, '\n');
    while (defer_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "generated_c_line=0") == null) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "symbol_kind=\"extern_fn\"") != null or
            std.mem.indexOf(u8, line, "symbol_kind=\"type\"") != null);
    }
}

test "lower-c f32 literal expressions compute in float, not double" {
    const source =
        \\export fn harness() -> u64 {
        \\    var c: f32 = (1.7 * 2.3);
        \\    return bitcast<u32>(c) as u64;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "f32.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "1.7f") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "2.3f") != null);
}

test "lower-c tuples desugar to one nominal struct with numeric field access" {
    const source =
        \\fn make() -> (u32, u64) { return (7, 100); }
        \\export fn harness() -> u64 {
        \\    var t: (u32, u64) = make();
        \\    return (t.0 as u64) + t.1;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "tup.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.count(u8, output.items, "typedef struct __tuple2_u32_u64 __tuple2_u32_u64;") == 1);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "t._0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "t._1") != null);
}

test "lower-c module blocks namespace functions and constants" {
    const source =
        \\module Math {
        \\    const PI: u32 = 3;
        \\    fn square(x: u32) -> u32 { return x * x; }
        \\}
        \\export fn harness() -> u64 {
        \\    return (Math.square(4) + Math.PI) as u64;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mod.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__square") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__PI") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__square(4)") != null);
}

test "lower-c impl blocks desugar to mangled free functions" {
    const source =
        \\struct Tensor { v: u32 }
        \\impl Tensor {
        \\    fn get(self: Tensor) -> u32 { return self.v; }
        \\}
        \\export fn harness() -> u64 {
        \\    var t: Tensor = .{ .v = 5 };
        \\    return Tensor.get(t) as u64;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "impl.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Tensor__get") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Tensor__get(t)") != null);
}

test "lower-c tuple destructuring binds each name to temporary fields" {
    const source =
        \\fn make() -> (u32, u64) { return (7, 100); }
        \\export fn harness() -> u64 {
        \\    let (a, b) = make();
        \\    return (a as u64) + b;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "destr.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "__destr0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__destr0._0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__destr0._1") != null);
}

test "lower-c backend_name attribute emits asm label" {
    const source =
        \\#[backend_name("rss_helper_x")]
        \\fn helper(x: u64) -> u64 { return x + 1; }
        \\export fn harness() -> u64 { return helper(7); }
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bn.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.count(u8, output.items, "__asm__(\"rss_helper_x\")") == 1);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "helper(uint64_t x) __asm__(\"rss_helper_x\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "helper(uint64_t x) {") != null);
}

test "lower-c align attribute and naked default emit aligned attributes" {
    const source =
        \\#[align(64)]
        \\export fn dma_buf_fn() -> void { return; }
        \\#[naked]
        \\export fn trap_vector() -> void {
        \\    asm opaque volatile { "ret" }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "align.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "__attribute__((aligned(64)))") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__attribute__((aligned(4)))") != null);
}

test "lower-c closure callees materialize once" {
    const source =
        \\struct Env { tag: u32 }
        \\fn run_impl(e: *mut Env, x: u32) -> u32 { return x + e.tag; }
        \\struct Slot { run: closure(u32) -> u32 }
        \\global g_env: Env;
        \\global g_table: [4]Slot;
        \\
        \\fn call_direct(i: usize, x: u32) -> u32 {
        \\    return g_table[i].run(x);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_closure_callee_once.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    const callee = "g_table.elems[mc_check_index_usize(i, 4)].run";
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, callee)) |index| {
        count += 1;
        search_from = index + callee.len;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".code(mc_tmp") != null);
}

test "lower-c casts bool closure-call switch subjects" {
    const source =
        \\fn classify(pred: closure(u32) -> bool, x: u32) -> u32 {
        \\    switch pred(x) {
        \\        true => { return 1; },
        \\        false => { return 0; },
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_closure_bool_switch.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch ((int)(({ mc_closure_bool_u32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".code(mc_tmp") != null);
}

test "lower-c emits simple MMIO register access" {
    const source =
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\    lsr: Reg<u8, .read>,
        \\}
        \\
        \\fn putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
        \\    uart.thr.write(ch, .release);
        \\}
        \\
        \\fn read_lsr(uart: MmioPtr<Uart16550>) -> u8 {
        \\    return uart.lsr.read(.acquire);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Uart16550 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t volatile thr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t volatile lsr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void putc(Uart16550 volatile * uart, uint8_t ch)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp0 = ch;\n    mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_lsr(Uart16550 volatile * uart)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp1 = (uint8_t)mc_mmio_read_u8(&uart->lsr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp1;") != null);
}

test "lower-c emits wider MMIO register access" {
    const source =
        \\extern mmio struct Device {
        \\    lo: Reg<u16, .read>,
        \\    hi: Reg<u32, .write>,
        \\    wide: Reg<u64, .read_write>,
        \\}
        \\
        \\fn read_lo(dev: MmioPtr<Device>) -> u16 {
        \\    return dev.lo.read(.relaxed);
        \\}
        \\
        \\fn write_hi(dev: MmioPtr<Device>, value: u32) -> void {
        \\    dev.hi.write(value, .release);
        \\}
        \\
        \\fn read_wide(dev: MmioPtr<Device>) -> u64 {
        \\    return dev.wide.read(.acquire);
        \\}
        \\
        \\fn write_wide(dev: MmioPtr<Device>, value: u64) -> void {
        \\    dev.wide.write(value, .relaxed);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_wide_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t volatile lo;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t volatile hi;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t volatile wide;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (uint16_t)mc_mmio_read_u16(&dev->lo);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = value;\n    mc_barrier_release_before();\n    mc_mmio_write_u32(&dev->hi, mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t mc_tmp1 = (uint64_t)mc_mmio_read_u64(&dev->wide);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t mc_tmp2 = value;\n    mc_mmio_write_u64(&dev->wide, mc_tmp2);") != null);
}

test "lower-c sequences MMIO write value before release barrier" {
    const source =
        \\extern mmio struct Uart16550 {
        \\    thr: Reg<u8, .write>,
        \\}
        \\
        \\extern fn next_byte() -> u8;
        \\extern fn box_byte(value: u8) -> u8;
        \\
        \\fn putc_computed(uart: MmioPtr<Uart16550>) -> void {
        \\    uart.thr.write(box_byte(next_byte()), .release);
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_write_order.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp0 = next_byte();\n    uint8_t mc_tmp1 = box_byte(mc_tmp0);\n    mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before();\n    mc_mmio_write_u8(&uart->thr, box_byte(next_byte()))") == null);
}

test "lower-c sequences raw store address and value operands" {
    const source =
        \\extern fn next_addr() -> PAddr;
        \\extern fn next_byte() -> u8;
        \\extern fn box_byte(value: u8) -> u8;
        \\
        \\fn store_computed() -> void {
        \\    unsafe {
        \\        raw.store<u8>(next_addr(), box_byte(next_byte()));
        \\    }
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_raw_store_order.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp0 = next_addr();\n        uint8_t mc_tmp1 = next_byte();\n        uint8_t mc_tmp2 = box_byte(mc_tmp1);\n        mc_raw_store_u8(mc_tmp0, mc_tmp2);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_raw_store_u8(next_addr(), box_byte(next_byte()))") == null);
}

test "lower-c emits MMIO read local initializers" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    stat: Reg<u16, .read>,
        \\    flags: RegBits<u8, Status, .read>,
        \\}
        \\
        \\fn read_local(dev: MmioPtr<Device>) -> u16 {
        \\    let value: u16 = dev.stat.read(.acquire);
        \\    return value;
        \\}
        \\
        \\fn read_bits_local(dev: MmioPtr<Device>) -> Status {
        \\    let status: Status = dev.flags.read(.relaxed);
        \\    return status;
        \\}
        \\
        \\fn read_inferred_bits_local(dev: MmioPtr<Device>) -> bool {
        \\    let status = dev.flags.read(.acquire);
        \\    return status.ready;
        \\}
        \\
        \\fn assign_status(dev: MmioPtr<Device>) -> Status {
        \\    var status: Status = dev.flags.read(.relaxed);
        \\    status = dev.flags.read(.acquire);
        \\    return status;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_mmio_read_local_init.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t value = (uint16_t)mc_mmio_read_u16(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status status = (Status)mc_mmio_read_u8(&dev->flags);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status status = (Status)mc_mmio_read_u8(&dev->flags);\n    mc_barrier_acquire_after();\n    return ((status & UINT8_C(1)) != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp0 = (Status)mc_mmio_read_u8(&dev->flags);\n    mc_barrier_acquire_after();\n    status = mc_tmp0;\n    return status;") != null);
}

test "lower-c emits packed bits MMIO reads and field masks" {
    const source =
        \\packed bits UartLsr: u8 {
        \\    data_ready: bool,
        \\    tx_empty: bool,
        \\}
        \\
        \\global status: UartLsr = 0;
        \\
        \\extern mmio struct Uart16550 {
        \\    lsr: RegBits<u8, UartLsr, .read>,
        \\}
        \\
        \\fn read_status(uart: MmioPtr<Uart16550>) -> UartLsr {
        \\    return uart.lsr.read(.acquire);
        \\}
        \\
        \\fn ready(status: UartLsr) -> bool {
        \\    return status.tx_empty;
        \\}
        \\
        \\fn set_ready(status: UartLsr, flag: bool) -> UartLsr {
        \\    status.tx_empty = flag;
        \\    return status;
        \\}
        \\
        \\fn set_global_ready(flag: bool) -> void {
        \\    status.tx_empty = flag;
        \\}
    ;

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "emit_c_packed_bits_mmio.mc", source);
    defer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendC(std.testing.allocator, module, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t UartLsr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static UartLsr read_status(Uart16550 volatile * uart)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "UartLsr mc_tmp0 = (UartLsr)mc_mmio_read_u8(&uart->lsr);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool ready(UartLsr status)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((status & UINT8_C(2)) != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static UartLsr set_ready(UartLsr status, bool flag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "status = (UartLsr)((status & (UartLsr)~UINT8_C(2)) | (flag ? UINT8_C(2) : (UartLsr)0));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void set_global_ready(bool flag)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "UartLsr mc_tmp1 = (UartLsr)mc_race_load_u8(&status);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_tmp1 = (UartLsr)((mc_tmp1 & (UartLsr)~UINT8_C(2)) | (flag ? UINT8_C(2) : (UartLsr)0));") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u8(&status, (uint8_t)mc_tmp1);") != null);
}

test "lower-c emits C ABI for simple Result types" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume_result(result: Result<u32, Error>) -> void;
        \\
        \\fn pass_result(result: Result<u32, Error>) -> Result<u32, Error> {
        \\    return result;
        \\}
        \\
        \\fn call_consume(result: Result<u32, Error>) -> void {
        \\    consume_result(result);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_abi.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_result_u32_Error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "bool is_ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} payload;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error make_result(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "void consume_result(mc_result_u32_Error result);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_result_u32_Error pass_result(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return result;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = result;\n    consume_result(mc_tmp0);") != null);
}

test "lower-c emits C ABI for tagged unions" {
    const source =
        \\union Token {
        \\    int: i64,
        \\    eof,
        \\}
        \\
        \\fn pass_token(token: Token) -> Token {
        \\    return token;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_tagged_union_abi.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef enum TokenTag {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag_int = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag_eof = 1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} TokenTag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Token {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "TokenTag tag;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} payload;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} Token;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Token pass_token(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return token;") != null);
}

test "lower-c emits tagged union switch narrowing" {
    const source =
        \\union Token {
        \\    int: i64,
        \\    eof,
        \\    space,
        \\}
        \\
        \\fn token_value(token: Token) -> i64 {
        \\    switch token {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
        \\
        \\fn token_kind(token: Token) -> u32 {
        \\    switch token {
        \\        .int => { return 1; },
        \\        .eof, .space => { return 0; },
        \\    }
        \\}
        \\
        \\extern fn make_token() -> Token;
        \\
        \\fn token_call_value() -> i64 {
        \\    switch make_token() {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
        \\
        \\fn token_local_value() -> i64 {
        \\    let token = make_token();
        \\    switch token {
        \\        int(v) => { return v; },
        \\        .eof => { return 0; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_tagged_union_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_value(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = token.payload.int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return v;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (token.tag == TokenTag_eof) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t token_kind(Token token)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (token.tag == TokenTag_eof || token.tag == TokenTag_space) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_call_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token mc_tmp0 = make_token();\n    if (mc_tmp0.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = mc_tmp0.payload.int_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else if (mc_tmp0.tag == TokenTag_eof) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static int64_t token_local_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token token = make_token();\n    if (token.tag == TokenTag_int) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "int64_t v = token.payload.int_;") != null);
}

test "lower-c emits tagged union constructors" {
    const source =
        \\union Token {
        \\    number: i64,
        \\    eof,
        \\}
        \\
        \\fn id(token: Token) -> Token {
        \\    return token;
        \\}
        \\
        \\fn make_number() -> Token {
        \\    return number(7);
        \\}
        \\
        \\fn make_eof() -> Token {
        \\    return eof();
        \\}
        \\
        \\fn call_id() -> Token {
        \\    return id(number(7));
        \\}
        \\
        \\fn local_number() -> Token {
        \\    let token: Token = number(9);
        \\    return token;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_tagged_union_constructors.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Token){ .tag = TokenTag_number, .payload.number = 7 });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Token){ .tag = TokenTag_eof });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token mc_tmp0 = ((Token){ .tag = TokenTag_number, .payload.number = 7 });\n    return id(mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Token token = ((Token){ .tag = TokenTag_number, .payload.number = 9 });") != null);
}

test "lower-c emits Result ok and err constructors" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn consume_result(result: Result<u32, Error>) -> void;
        \\
        \\fn make_ok(value: u32) -> Result<u32, Error> {
        \\    return ok(value);
        \\}
        \\
        \\fn make_err() -> Result<u32, Error> {
        \\    return err(.denied);
        \\}
        \\
        \\fn send_ok() -> void {
        \\    consume_result(ok(7));
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_constructors.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = true, .payload.ok = value });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = Error_denied });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = ((mc_result_u32_Error){ .is_ok = true, .payload.ok = 7 });\n    consume_result(mc_tmp0);") != null);
}

test "lower-c emits Result try in local initializers" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn add_one() -> Result<u32, Error> {
        \\    let value: u32 = make_result()?;
        \\    return ok(value + 1);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_try.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = mc_tmp0.payload.err });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = true, .payload.ok = mc_checked_add_u32(value, 1) });") != null);
}

test "lower-c emits Result try in return statements" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn unwrap_param(result: Result<u32, Error>) -> u32 {
        \\    return result?;
        \\}
        \\
        \\fn unwrap_call() -> u32 {
        \\    return make_result()?;
        \\}
        \\
        \\fn unwrap_grouped_call() -> u32 {
        \\    return (make_result())?;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_try_return.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = result;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp1 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp2 = (make_result());") != null);
}

test "lower-c emits Result try in return call arguments" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume(value: u32) -> u32;
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\extern fn box_value(value: u32) -> u32;
        \\
        \\fn arg_try() -> u32 {
        \\    return consume(make_result()?);
        \\}
        \\
        \\fn two_arg_try() -> u32 {
        \\    return combine(make_result()?, make_result()?);
        \\}
        \\
        \\fn nested_arg_try() -> u32 {
        \\    return consume(box_value(make_result()?));
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_try_call_args.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t arg_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return combine(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "box_value(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume(mc_tmp") != null);
}

test "lower-c emits nullable try in return statements" {
    const source =
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn make_nullable_mut_pointer() -> ?*mut u8;
        \\
        \\fn unwrap_param(maybe: ?*const u8) -> *const u8 {
        \\    return maybe?;
        \\}
        \\
        \\fn unwrap_call() -> *const u8 {
        \\    return make_nullable_pointer()?;
        \\}
        \\
        \\fn unwrap_grouped_call() -> *mut u8 {
        \\    return (make_nullable_mut_pointer())?;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nullable_try_return.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp0 = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_tmp0 == NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp2 = (make_nullable_mut_pointer());") != null);
}

test "lower-c emits nullable try in return call arguments" {
    const source =
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn consume_ptr(ptr: *const u8) -> u32;
        \\extern fn choose(left: *const u8, right: *const u8) -> u32;
        \\extern fn ptr_id(ptr: *const u8) -> *const u8;
        \\
        \\fn arg_try(maybe: ?*const u8) -> u32 {
        \\    return consume_ptr(maybe?);
        \\}
        \\
        \\fn direct_arg_try() -> u32 {
        \\    return consume_ptr(make_nullable_pointer()?);
        \\}
        \\
        \\fn two_arg_try(maybe: ?*const u8) -> u32 {
        \\    return choose(maybe?, make_nullable_pointer()?);
        \\}
        \\
        \\fn nested_arg_try() -> u32 {
        \\    return consume_ptr(ptr_id(make_nullable_pointer()?));
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nullable_try_call_args.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t arg_try(uint8_t const * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp0 = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_tmp0 == NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return choose(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ptr_id(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return consume_ptr(mc_tmp") != null);
}

test "lower-c emits try in local initializer call arguments" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn box_value(value: u32) -> u32;
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn ptr_id(ptr: *const u8) -> *const u8;
        \\
        \\fn local_result_try() -> Result<u32, Error> {
        \\    let value: u32 = box_value(make_result()?);
        \\    return ok(value);
        \\}
        \\
        \\fn local_nullable_try() -> *const u8 {
        \\    let ptr: *const u8 = ptr_id(make_nullable_pointer()?);
        \\    return ptr;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_try_local_initializer.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_result_u32_Error local_result_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((mc_result_u32_Error){ .is_ok = false, .payload.err = mc_tmp0.payload.err });") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = box_value(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t const * local_nullable_try(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr = ptr_id(mc_tmp") != null);
}

test "lower-c emits try in assignment and expression statements" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\global shared_value: u32 = 0;
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\extern fn consume(value: u32) -> void;
        \\extern fn make_nullable_pointer() -> ?*const u8;
        \\extern fn consume_ptr(ptr: *const u8) -> void;
        \\
        \\fn assign_result_try() -> Result<u32, Error> {
        \\    var value: u32 = 0;
        \\    value = make_result()?;
        \\    shared_value = make_result()?;
        \\    return ok(value);
        \\}
        \\
        \\fn expr_result_try() -> Result<u32, Error> {
        \\    make_result()?;
        \\    consume(make_result()?);
        \\    return ok(1);
        \\}
        \\
        \\fn assign_nullable_try() -> *const u8 {
        \\    var ptr: *const u8 = make_nullable_pointer()?;
        \\    ptr = make_nullable_pointer()?;
        \\    return ptr;
        \\}
        \\
        \\fn expr_nullable_try() -> void {
        \\    make_nullable_pointer()?;
        \\    consume_ptr(make_nullable_pointer()?);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_try_assignment_expr_stmt.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp1 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&shared_value, (uint32_t)mc_tmp1.payload.ok);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp2 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!mc_tmp2.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp3 = make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ptr = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_ptr(mc_tmp") != null);
}

test "lower-c emits simple functions and race-safe globals" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn add(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\
        \\fn store(x: u32) -> void {
        \\    shared_counter = x;
        \\}
        \\
        \\fn load() -> u32 {
        \\    return shared_counter;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_functions.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "static MC_UNUSED uint32_t shared_counter = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t add(uint32_t a, uint32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&shared_counter, (uint32_t)x);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((uint32_t)mc_race_load_u32(&shared_counter));") != null);
}

test "lower-c emits while loops and loop control" {
    const source =
        \\fn loop_once(flag: bool) -> u32 {
        \\    var out: u32 = 0;
        \\    while flag {
        \\        {
        \\            out = out + 1;
        \\        }
        \\        break;
        \\    }
        \\    while flag {
        \\        continue;
        \\    }
        \\    return out;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_loops.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "while (flag) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "out = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "goto mc_break_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "goto mc_continue_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return out;") != null);
}

test "lower-c hoists MMIO reads in while conditions" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    ctrl: Reg<u16, .write>,
        \\    stat: RegBits<u8, Status, .read>,
        \\    raw: Reg<u16, .read>,
        \\}
        \\
        \\extern fn pause() -> void;
        \\
        \\fn poll_and_write(dev: MmioPtr<Device>, value: u16) -> void {
        \\    while !dev.stat.read(.acquire).ready {
        \\        pause();
        \\    }
        \\    dev.ctrl.write(value, .release);
        \\}
        \\
        \\fn wait_raw(dev: MmioPtr<Device>) -> void {
        \\    while dev.raw.read(.relaxed) == 0 {
        \\        pause();
        \\    }
        \\}
        \\
        \\fn require_ready(dev: MmioPtr<Device>) -> void {
        \\    assert(dev.stat.read(.acquire).ready);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_while_condition.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "while (true) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp0 = (Status)mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(!(((mc_tmp0 & UINT8_C(1)) != 0)))) break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "pause();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t mc_tmp1 = value;\n    mc_barrier_release_before();\n    mc_mmio_write_u16(&dev->ctrl, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t mc_tmp2 = (uint16_t)mc_mmio_read_u16(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!((mc_tmp2 == 0))) break;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Status mc_tmp3 = (Status)mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(((mc_tmp3 & UINT8_C(1)) != 0))) mc_trap_Assert();") != null);
}

test "lower-c hoists MMIO reads in return and expression statements" {
    const source =
        \\packed bits Status: u8 {
        \\    ready: bool,
        \\}
        \\
        \\extern mmio struct Device {
        \\    stat: RegBits<u8, Status, .read>,
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\extern fn observe(status: Status) -> void;
        \\
        \\fn observe_status(dev: MmioPtr<Device>) -> void {
        \\    observe(dev.stat.read(.acquire));
        \\}
        \\
        \\fn read_plus(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    return dev.raw.read(.relaxed) + extra;
        \\}
        \\
        \\fn read_side_effect(dev: MmioPtr<Device>) -> void {
        \\    dev.raw.read(.acquire);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_exprs.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u8(&dev->stat);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "observe(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();\n    (void)mc_tmp") != null);
}

test "lower-c hoists MMIO reads in local initializer and assignment expressions" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn local_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    let x: u32 = dev.raw.read(.relaxed) + extra;
        \\    return x;
        \\}
        \\
        \\fn assign_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    var x: u32 = 0;
        \\    x = dev.raw.read(.acquire) + extra;
        \\    return x;
        \\}
        \\
        \\fn local_untyped_nested(dev: MmioPtr<Device>, extra: u32) -> u32 {
        \\    let x = dev.raw.read(.relaxed) + extra;
        \\    return x;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_nested_init_assignment.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_mmio_read_u32(&dev->raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after();") != null);
}

test "lower-c hoists MMIO reads in switch subjects" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn switch_relaxed(dev: MmioPtr<Device>) -> u32 {
        \\    switch dev.raw.read(.relaxed) {
        \\        0 => { return 1; },
        \\        _ => { return 2; },
        \\    }
        \\}
        \\
        \\fn switch_acquire(dev: MmioPtr<Device>) -> u32 {
        \\    switch dev.raw.read(.acquire) {
        \\        0 => { return 1; },
        \\        _ => { return 2; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_switch_subject.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n    switch (mc_tmp0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp1 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n    mc_barrier_acquire_after();\n    switch (mc_tmp1) {") != null);
}

test "lower-c hoists MMIO reads in switch arm expressions" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\
        \\fn switch_arm_expr(dev: MmioPtr<Device>, n: u32) -> void {
        \\    switch n {
        \\        0 => dev.raw.read(.acquire),
        \\        _ => dev.raw.read(.relaxed),
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_mmio_read_switch_arm_expr.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n            mc_barrier_acquire_after();\n            (void)mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp1 = (uint32_t)mc_mmio_read_u32(&dev->raw);\n            (void)mc_tmp1;") != null);
}

test "lower-c emits array and slice for loops" {
    const source =
        \\extern fn make_slice() -> []const u32;
        \\extern fn make_array() -> [4]u32;
        \\
        \\fn sum_slice(xs: []const u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_array(xs: [4]u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_call_slice() -> u32 {
        \\    var sum: u32 = 0;
        \\    for x in make_slice() {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn first_call_array() -> u32 {
        \\    for x in make_array() {
        \\        return x;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn sum_inferred_slice() -> u32 {
        \\    let xs = make_slice();
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn sum_inferred_array() -> u32 {
        \\    let xs = make_array();
        \\    var sum: u32 = 0;
        \\    for x in xs {
        \\        sum = sum + x;
        \\    }
        \\    return sum;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_for_loops.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t sum_slice(mc_slice_const_u32 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "for (uintptr_t mc_i0 = 0; mc_i0 < xs.len; mc_i0 += 1) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = xs.ptr[mc_i0];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_array_u32_4 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t sum_array(mc_array_u32_4 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " < 4; mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = xs.elems[mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".len; mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".ptr[mc_i") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 xs = make_array();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "sum = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return sum;") != null);
}

test "lower-c emits fixed array indexing with bounds checks" {
    const source =
        \\fn pick_u8(xs: [4]u8, i: usize) -> u8 {
        \\    return xs[i];
        \\}
        \\
        \\fn pick_u32(xs: [4]u32, i: usize) -> u32 {
        \\    return xs[i];
        \\}
        \\
        \\#[no_lang_trap]
        \\fn pick_const(xs: [4]u8) -> u8 {
        \\    return xs.const_get<2>();
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_arrays.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u8_4 xs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_array_u32_4 xs") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.elems[mc_check_index_usize(i, 4)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.elems[2];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_check_index_usize(2, 4)") == null);
}

test "lower-c emits slice typedefs and indexing" {
    const source =
        \\extern fn make_u8_slice() -> []const u8;
        \\extern fn make_u32_slice() -> []const u32;
        \\
        \\fn read_slice(xs: []const u8, i: usize) -> u8 {
        \\    return xs[i];
        \\}
        \\
        \\fn read_literal(xs: []const u8) -> u8 {
        \\    return xs[0];
        \\}
        \\
        \\fn write_slice(xs: []mut u32, i: usize, value: u32) -> void {
        \\    xs[i] = value;
        \\}
        \\
        \\fn same_slice(xs: []const u8) -> []const u8 {
        \\    return xs;
        \\}
        \\
        \\fn read_direct_literal() -> u8 {
        \\    return make_u8_slice()[0];
        \\}
        \\
        \\fn read_direct_index(i: usize) -> u32 {
        \\    return make_u32_slice()[i];
        \\}
        \\
        \\fn read_inferred_slice(i: usize) -> u32 {
        \\    let xs = make_u32_slice();
        \\    return xs[i];
        \\}
        \\
        \\fn local_direct_literal() -> u8 {
        \\    let x: u8 = make_u8_slice()[0];
        \\    return x;
        \\}
        \\
        \\fn local_direct_index(i: usize) -> u32 {
        \\    let x: u32 = make_u32_slice()[i];
        \\    return x;
        \\}
        \\
        \\fn const_slice_from_array_range(n: usize) -> u8 {
        \\    var buf: [4]u8 = uninit;
        \\    buf[0] = 7;
        \\    let xs: []const u8 = buf[0..n];
        \\    return xs[0];
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_slices.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_const_u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_mut_u8 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_const_u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t const * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_slice_mut_u32 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t len;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 make_u8_slice(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 make_u32_slice(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_slice(mc_slice_const_u8 xs, uintptr_t i)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.ptr[mc_check_index_usize(i, xs.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return xs.ptr[mc_check_index_usize(0, xs.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void write_slice(mc_slice_mut_u32 xs, uintptr_t i, uint32_t value)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "xs.ptr[mc_check_index_usize(i, xs.len)] = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_slice_const_u8 same_slice(mc_slice_const_u8 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 mc_tmp0 = make_u8_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp1 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp2 = mc_tmp0.ptr[mc_check_index_usize(mc_tmp1, mc_tmp0.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 mc_tmp3 = make_u32_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp4 = i;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp5 = mc_tmp3.ptr[mc_check_index_usize(mc_tmp4, mc_tmp3.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp5;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 xs = make_u32_slice();\n    return xs.ptr[mc_check_index_usize(i, xs.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 mc_tmp6 = make_u8_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp7 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t mc_tmp8 = mc_tmp6.ptr[mc_check_index_usize(mc_tmp7, mc_tmp6.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t x = mc_tmp8;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u32 mc_tmp9 = make_u32_slice();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t mc_tmp10 = i;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp11 = mc_tmp9.ptr[mc_check_index_usize(mc_tmp10, mc_tmp9.len)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = mc_tmp11;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_const_u8 xs = ({ mc_slice_mut_u8 mc_scv") != null);
}

test "lower-c emits checked u32 arithmetic helpers" {
    const source =
        \\fn checked_ops(a: u32, b: u32, n: u32) -> u32 {
        \\    var out: u32 = a - b;
        \\    out = out * b;
        \\    out = out / b;
        \\    out = out % b;
        \\    out = out << n;
        \\    return out >> n;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_checked_ops.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_sub_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mul_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_div_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mod_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_shl_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_shr_u32(") != null);
}

test "lower-c emits integer switch arms" {
    const source =
        \\fn classify(n: u32) -> u32 {
        \\    switch n {
        \\        0 => {
        \\            let x: u32 = 10;
        \\            return x;
        \\        },
        \\        1, 2 => { return 20; },
        \\        _ => { return 30; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (n) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 10;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 30;") != null);
}

test "lower-c emits closed enum switch arms" {
    const source =
        \\enum Irq: u8 {
        \\    timer = 32,
        \\    keyboard = 33,
        \\}
        \\
        \\fn classify_irq(irq: Irq) -> u32 {
        \\    switch irq {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
        \\
        \\extern fn read_irq() -> Irq;
        \\
        \\fn classify_read_irq() -> u32 {
        \\    switch read_irq() {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
        \\
        \\fn classify_local_irq() -> u32 {
        \\    let irq = read_irq();
        \\    switch irq {
        \\        .timer => { return 1; },
        \\        .keyboard => { return 2; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_enum_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t Irq;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq_timer = 32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq_keyboard = 33") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_irq(Irq irq)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (irq) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case Irq_timer:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case Irq_keyboard:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_read_irq(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq mc_tmp0 = read_irq();\n    switch (mc_tmp0) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t classify_local_irq(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Irq irq = read_irq();\n    switch (irq) {") != null);
}

test "lower-c casts indexed bool switch subjects and marks ignored locals unused" {
    const source =
        \\extern fn tick() -> u64;
        \\extern fn tick2(a: u64, b: u64) -> u64;
        \\
        \\fn ignore_call() -> void {
        \\    let _ignore: u64 = tick();
        \\    let _seq_ignore: u64 = tick2(1, 2);
        \\}
        \\
        \\fn classify(flags: [2]bool, i: usize) -> u32 {
        \\    switch flags[i] {
        \\        true => { return 1; },
        \\        false => { return 0; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_bool_switch_unused.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED uint64_t _ignore = tick();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED uint64_t _seq_ignore = tick2(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch ((int)(flags.elems[mc_check_index_usize(i, 2)])) {") != null);
}

test "lower-c emits target-typed enum literals" {
    const source =
        \\enum Mode: u8 {
        \\    read = 1,
        \\    write = 2,
        \\}
        \\
        \\extern fn sink(mode: Mode) -> u32;
        \\
        \\fn default_mode() -> Mode {
        \\    return .read;
        \\}
        \\
        \\fn local_mode() -> Mode {
        \\    let mode: Mode = .write;
        \\    return mode;
        \\}
        \\
        \\fn pass_mode() -> u32 {
        \\    return sink(.read);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_enum_literals.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t Mode;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode_read = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode_write = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t sink(Mode mode);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return Mode_read;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode mode = Mode_write;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode mc_tmp0 = Mode_read;\n    return sink(mc_tmp0);") != null);
}

test "lower-c emits optional pointer if-let" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\
        \\fn unwrap_or(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
        \\    if let p = maybe {
        \\        return p;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
        \\
        \\fn read_const(maybe: ?*const u8) -> u8 {
        \\    if let p = maybe {
        \\        return p.*;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
        \\fn unwrap_call_or_zero() -> u32 {
        \\    if let p = maybe_ptr() {
        \\        return ptr_value(p);
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn unwrap_local_or_zero() -> u32 {
        \\    let maybe = maybe_ptr();
        \\    if let p = maybe {
        \\        return ptr_value(p);
        \\    }
        \\    return 0;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_if_let.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t * unwrap_or(uint8_t * maybe, uint8_t * fallback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_const(uint8_t const * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t const * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return *p;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return fallback;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp0 = maybe_ptr();\n    if (mc_tmp0 != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t unwrap_local_or_zero(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * maybe = maybe_ptr();\n    if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
}

test "lower-c emits nullable switch binding" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\
        \\fn nullable_switch(maybe: ?*mut u8) -> u32 {
        \\    switch maybe {
        \\        p => { return ptr_value(p); },
        \\        _ => { return 0; },
        \\    }
        \\}
        \\
        \\fn nullable_call_switch() -> u32 {
        \\    switch maybe_ptr() {
        \\        p => { return ptr_value(p); },
        \\        _ => { return 0; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_nullable_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t nullable_switch(uint8_t * maybe)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (maybe != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp0 = p;\n        return ptr_value(mc_tmp0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else {\n        return 0;\n    }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp1 = maybe_ptr();\n    if (mc_tmp1 != NULL) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * p = mc_tmp1;") != null);
}

test "lower-c emits Result if-let narrowing" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn unwrap_or_zero(result: Result<u32, Error>) -> u32 {
        \\    if let ok(v) = result {
        \\        return v;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
        \\fn has_err(result: Result<u32, Error>) -> bool {
        \\    if let err(e) = result {
        \\        return e != 0;
        \\    }
        \\    return false;
        \\}
        \\
        \\fn unwrap_call_or_zero() -> u32 {
        \\    if let ok(v) = make_result() {
        \\        return v;
        \\    }
        \\    return 0;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_if_let.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t unwrap_or_zero(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return v;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool has_err(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = result.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (e != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();\n    if (mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = mc_tmp0.payload.ok;") != null);
}

test "lower-c emits Result switch narrowing" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\
        \\fn result_nonzero(result: Result<u32, Error>) -> bool {
        \\    switch result {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\extern fn make_result() -> Result<u32, Error>;
        \\
        \\fn result_call_nonzero() -> bool {
        \\    switch make_result() {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\fn result_local_nonzero() -> bool {
        \\    let result = make_result();
        \\    switch result {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
        \\
        \\fn result_payloadless_switch() -> u32 {
        \\    let result = make_result();
        \\    switch result {
        \\        .ok => { return 1; },
        \\        .err => { return 0; },
        \\    }
        \\}
        \\
        \\fn result_multi_payloadless_switch() -> u32 {
        \\    let result = make_result();
        \\    switch result {
        \\        .ok, .err => { return 1; },
        \\    }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_result_switch.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_result_u32_Error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool result_nonzero(mc_result_u32_Error result)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (v != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "else {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = result.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return (e != 0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error mc_tmp0 = make_result();\n    if (mc_tmp0.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = mc_tmp0.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Error e = mc_tmp0.payload.err;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static bool result_local_nonzero(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t v = result.payload.ok;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t result_payloadless_switch(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok) {\n        return 1;\n    }\n    else {\n        return 0;\n    }") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t result_multi_payloadless_switch(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_result_u32_Error result = make_result();\n    if (result.is_ok || !result.is_ok) {\n        return 1;\n    }") != null);
}

test "lower-c checked conversion evaluates a side-effecting operand once" {
    const source =
        \\extern fn src() -> u64;
        \\fn narrow() -> u8 {
        \\    return u8.trap_from(src());
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_conv_once.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "= (src());") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "src()"));
}

test "lower-c emits extern structs and member access" {
    const source =
        \\extern struct Packet {
        \\    value: u32,
        \\    ptr: *mut u8,
        \\    next: ?*mut Packet,
        \\}
        \\
        \\fn make_packet() -> Packet;
        \\extern fn make_ptr() -> *mut u8;
        \\
        \\fn id_packet_ptr(p: *mut Packet) -> *mut Packet {
        \\    return p;
        \\}
        \\
        \\fn maybe_packet(maybe: ?*mut Packet, fallback: *mut Packet) -> *mut Packet {
        \\    if let p = maybe {
        \\        return p;
        \\    } else {
        \\        return fallback;
        \\    }
        \\}
        \\
        \\fn cast_packet_ptr(raw: *mut u8) -> *mut Packet {
        \\    return raw as *mut Packet;
        \\}
        \\
        \\fn read_value(packet: Packet) -> u32 {
        \\    return packet.value;
        \\}
        \\
        \\fn write_value(packet: Packet, value: u32) -> void {
        \\    packet.value = value;
        \\}
        \\
        \\fn read_ptr(packet: Packet) -> *mut u8 {
        \\    return packet.ptr;
        \\}
        \\
        \\fn read_direct() -> u32 {
        \\    return make_packet().value;
        \\}
        \\
        \\fn inferred_pointer_return() -> *mut u8 {
        \\    let p = make_ptr();
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_structs.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Packet {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "struct Packet * next;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Packet make_packet(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * id_packet_ptr(Packet * p)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * maybe_packet(Packet * maybe, Packet * fallback)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Packet * p = maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Packet * cast_packet_ptr(uint8_t * raw)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return ((Packet *)raw);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t read_value(Packet packet)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return packet.value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "packet.value = value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return packet.ptr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return make_packet().value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * make_ptr(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t * inferred_pointer_return(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t * mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = make_ptr();\n    if (mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " == NULL) mc_trap_InvalidRepresentation();\n    uint8_t * p = mc_tmp") != null);
}

test "lower-c sanitizes C header names used as fields" {
    const source =
        \\extern struct Packet {
        \\    offsetof: u32,
        \\    uint32_t: u32,
        \\}
        \\
        \\fn sum(packet: Packet) -> u32 {
        \\    return packet.offsetof + packet.uint32_t;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_field_reserved_names.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t offsetof_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t uint32_t_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = packet.offsetof_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = packet.uint32_t_;") != null);
}

test "lower-c emits overlay unions as byte storage" {
    const source =
        \\overlay union Word {
        \\    u: u32,
        \\    bytes: [4]u8,
        \\}
        \\
        \\fn pass_word(word: Word) -> Word { return word; }
        \\fn read_u(word: Word) -> u32 { return word.u; }
        \\fn read_b0(word: Word) -> u8 { return word.bytes[0]; }
        \\fn write_u(word: Word, value: u32) -> Word {
        \\    word.u = value;
        \\    return word;
        \\}
        \\fn write_b0(word: Word, value: u8) -> Word {
        \\    word.bytes[0] = value;
        \\    return word;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_overlay_union.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Word {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "alignas(4) unsigned char storage[4];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "} Word;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static Word pass_word(Word word)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return word;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t read_u(Word word)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "memcpy(&mc_tmp0, word.storage, 4);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_tmp0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return word.storage[mc_check_index_usize(0, 4)];") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "memcpy(word.storage, &mc_tmp1, 4);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "word.storage[mc_check_index_usize(0, 4)] = value;") != null);
}

test "lower-c emits assert trap" {
    const source =
        \\fn require_flag(flag: bool) -> void { assert(flag); }
        \\fn require_expr(a: u32, b: u32) -> void { assert(a == b || a != 0); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_assert.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(flag)) mc_trap_Assert();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(((a == b) || (a != 0)))) mc_trap_Assert();") != null);
}

test "lower-c emits lexical defer cleanup before return" {
    const source =
        \\extern fn close_a() -> void;
        \\extern fn close_b() -> void;
        \\fn accept_lexical_cleanup() -> void {
        \\    defer close_a();
        \\    defer close_b();
        \\    return;
        \\}
        \\fn accept_block_cleanup() -> void {
        \\    defer { close_a(); };
        \\    return;
        \\}
        \\fn accept_cleanup_before_break(flag: bool) -> void {
        \\    while flag { defer close_a(); break; }
        \\}
        \\fn accept_cleanup_before_continue(flag: bool) -> void {
        \\    while flag { defer close_a(); continue; }
        \\}
        \\fn accept_cleanup_on_fallthrough() -> void { defer close_a(); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_defer.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "void close_a(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "void close_b(void);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_lexical_cleanup(void) {\n    close_b();\n    close_a();\n    return;\n}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_block_cleanup(void) {\n    {\n        close_a();\n    }\n    return;\n}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_before_break(bool flag) {\n    while (flag) {\n        close_a();\n        goto mc_break_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_before_continue(bool flag) {\n    while (flag) {\n        close_a();\n        goto mc_continue_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void accept_cleanup_on_fallthrough(void) {\n    close_a();\n}") != null);
}

test "lower-c emits unsafe blocks as scoped blocks" {
    const source =
        \\fn accept_unsafe_block() -> u32 {
        \\    var x: u32 = 1;
        \\    unsafe { x = x + 1; }
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_unsafe_block.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_unsafe_block(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;\n    {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
}

test "lower-c emits opaque volatile asm" {
    const source =
        \\fn asm_in_unsafe() -> void {
        \\    unsafe {
        \\        asm opaque volatile { "pause" clobber("memory") }
        \\    }
        \\}
        \\fn boot_asm() -> void {
        \\    unsafe { asm opaque volatile { "cli" "hlt" } }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_asm.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void asm_in_unsafe(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"pause\" ::: \"memory\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"cli\" \"\\n\\t\" \"hlt\" ::: \"memory\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#error \"inline asm emission requires compiler support\"") != null);
}

test "lower-c emits precise asm with operands" {
    const source =
        \\fn find_first_set(mask: u64) -> u64 {
        \\    var idx: u64 = 0;
        \\    #[unsafe_contract(precise_asm)]
        \\    {
        \\        unsafe {
        \\            asm precise volatile {
        \\                "bsf %1, %0"
        \\                out("rax") idx: u64,
        \\                in("rbx") mask: u64,
        \\                clobber("cc")
        \\            }
        \\        }
        \\    }
        \\    return idx;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_precise_asm.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"bsf %1, %0\" : \"=r\"(idx) : \"r\"(mask) : \"cc\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_PRECISE_ASM out(\"rax\")->idx in(\"rbx\") */") != null);
}

test "lower-c emits reduce.sum_checked" {
    const source =
        \\fn sum(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_reduce.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__int128 mc_acc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "> (__int128)(UINT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "(mc_result_u32_Overflow){ .is_ok = true, .payload.ok = (uint32_t)mc_acc") != null);
}

test "lower-c emits distinct floating reduction modes" {
    const source =
        \\fn sum_left(xs: []const f64) -> f64 {
        \\    return reduce.sum_left<f64>(xs);
        \\}
        \\fn sum_fast(xs: []const f32) -> f32 {
        \\    return reduce.sum_fast<f32>(xs);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_float_reduce.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "MC_SUM_FAST"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#pragma clang fp reassociate(on)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "#pragma clang loop vectorize(enable) interleave(enable)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "double mc_acc") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "float mc_acc") != null);
}

test "lower-c omits pure comptime blocks from C runtime output" {
    const source =
        \\fn accept_pure_comptime_block() -> u32 {
        \\    comptime {
        \\        let x: u32 = 1;
        \\        assert(true);
        \\    }
        \\    return 1;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_comptime_block.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_pure_comptime_block(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(true))") == null);
}

test "lower-c emits explicit traps and unreachable" {
    const source =
        \\fn trap_as_value() -> u32 { return trap(.Bounds); }
        \\fn unreachable_as_value() -> u32 { return unreachable; }
        \\fn never_returns_by_trap() -> never { return trap(.Assert); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_traps.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t trap_as_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void never_returns_by_trap(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert();") != null);
}

test "lower-c rejects non-static global initializers instead of zeroing" {
    const source =
        \\fn source() -> u32 { return 1; }
        \\global value: u32 = source();
    ;
    var parsed = try test_support.parseModule("emit_c_reject_global_init.mc", source);
    defer parsed.deinit();
    parsed.check();
    try std.testing.expect(hasTestDiagnosticCode(parsed.reporter, "E_GLOBAL_INITIALIZER_NOT_STATIC"));
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, lower_c.appendC(std.testing.allocator, parsed.module, &output));
}

test "lower-c rejects two MMIO reads in one short-circuit operand" {
    const source =
        \\extern mmio struct ProbeMmio {
        \\    magic: Reg<u32, .read>      @offset(0x000),
        \\    device_id: Reg<u32, .read>  @offset(0x008),
        \\}
        \\fn both(a: u32, b: u32) -> bool { return a == b; }
        \\fn probe(slot: MmioPtr<ProbeMmio>) -> bool {
        \\    return both(slot.magic.read(.acquire), slot.device_id.read(.acquire)) && true;
        \\}
    ;
    try expectUnsupportedCheckedCEmission("emit_c_reject_mmio_seq.mc", source);
}

test "lower-c keeps a single MMIO read per short-circuit operand" {
    const source =
        \\extern mmio struct ProbeMmio {
        \\    magic: Reg<u32, .read>      @offset(0x000),
        \\    device_id: Reg<u32, .read>  @offset(0x008),
        \\}
        \\fn probe(slot: MmioPtr<ProbeMmio>) -> bool {
        \\    return slot.magic.read(.acquire) == 1 && slot.device_id.read(.acquire) == 2;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_single_mmio_seq.mc", source, &output);
    const magic_read = std.mem.indexOf(u8, output.items, "slot->magic") orelse return error.TestUnexpectedResult;
    const amp = std.mem.indexOfPos(u8, output.items, magic_read, "&&") orelse return error.TestUnexpectedResult;
    const devid_read = std.mem.indexOf(u8, output.items, "slot->device_id") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, output.items, magic_read + 1, "slot->magic") == null);
    try std.testing.expect(std.mem.indexOfPos(u8, output.items, devid_read + 1, "slot->device_id") == null);
    try std.testing.expect(magic_read < amp);
    try std.testing.expect(amp < devid_read);
}

test "lower-c uses type-directed helpers for fixed-width checked arithmetic" {
    const source =
        \\fn add_i32(a: i32, b: i32) -> i32 { return a + b; }
        \\fn div_i32(a: i32, b: i32) -> i32 { return a / b; }
        \\fn mul_u64(a: u64, b: u64) -> u64 { return a * b; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_fixed_width_arith.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_DEFINE_CHECKED_SIGNED(i32, int32_t, INT32_MIN, INT32_MAX)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_i32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_div_i32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_mul_u64(") != null);
}

test "lower-c sequences return call arguments left to right" {
    const source =
        \\extern fn next_value() -> u32;
        \\extern fn box_value(value: u32) -> u32;
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\extern fn consume(left: u32, right: u32) -> void;
        \\global ordered_global: u32 = 0;
        \\fn ordered_two_args() -> u32 { return combine(next_value(), next_value()); }
        \\fn ordered_local_init() -> u32 { let value = combine(next_value(), next_value()); return value; }
        \\fn ordered_typed_local_init() -> u32 { let value: u32 = combine(next_value(), next_value()); return value; }
        \\fn ordered_expr_stmt() -> void { consume(next_value(), next_value()); }
        \\fn ordered_nested_return() -> u32 { return combine(box_value(next_value()), next_value()); }
        \\fn ordered_nested_local_init() -> u32 { let value = combine(box_value(next_value()), next_value()); return value; }
        \\fn ordered_nested_expr_stmt() -> void { consume(box_value(next_value()), next_value()); }
        \\fn ordered_assignment() -> u32 { var value: u32 = 0; value = combine(next_value(), next_value()); return value; }
        \\fn ordered_nested_assignment() -> u32 { var value: u32 = 0; value = combine(box_value(next_value()), next_value()); return value; }
        \\fn ordered_global_assignment() -> void { ordered_global = combine(next_value(), next_value()); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_eval_order.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp0 = next_value();\n    uint32_t mc_tmp1 = next_value();\n    return combine(mc_tmp0, mc_tmp1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp2 = next_value();\n    uint32_t mc_tmp3 = next_value();\n    uint32_t value = combine(mc_tmp2, mc_tmp3);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp4 = next_value();\n    uint32_t mc_tmp5 = next_value();\n    uint32_t value = combine(mc_tmp4, mc_tmp5);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp6 = next_value();\n    uint32_t mc_tmp7 = next_value();\n    consume(mc_tmp6, mc_tmp7);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp8 = next_value();\n    uint32_t mc_tmp9 = box_value(mc_tmp8);\n    uint32_t mc_tmp10 = next_value();\n    return combine(mc_tmp9, mc_tmp10);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp11 = next_value();\n    uint32_t mc_tmp12 = box_value(mc_tmp11);\n    uint32_t mc_tmp13 = next_value();\n    uint32_t value = combine(mc_tmp12, mc_tmp13);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp14 = next_value();\n    uint32_t mc_tmp15 = box_value(mc_tmp14);\n    uint32_t mc_tmp16 = next_value();\n    consume(mc_tmp15, mc_tmp16);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp17 = next_value();\n    uint32_t mc_tmp18 = next_value();\n    uint32_t mc_tmp19 = combine(mc_tmp17, mc_tmp18);\n    value = mc_tmp19;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp20 = next_value();\n    uint32_t mc_tmp21 = box_value(mc_tmp20);\n    uint32_t mc_tmp22 = next_value();\n    uint32_t mc_tmp23 = combine(mc_tmp21, mc_tmp22);\n    value = mc_tmp23;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t mc_tmp24 = next_value();\n    uint32_t mc_tmp25 = next_value();\n    uint32_t mc_tmp26 = combine(mc_tmp24, mc_tmp25);\n    mc_race_store_u32(&ordered_global, (uint32_t)mc_tmp26);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value = combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "box_value(next_value())") == null);
}

test "lower-c emits unsafe contract blocks as scoped blocks" {
    const source =
        \\extern fn next_value() -> u32;
        \\extern fn consume_value(value: u32) -> void;
        \\extern fn consume_values(values: [1]u32) -> void;
        \\
        \\struct Counter {
        \\    next: u32,
        \\}
        \\
        \\fn consume_counter(counter: Counter) -> void {
        \\    return;
        \\}
        \\
        \\fn accept_plain_contract_scope() -> u32 {
        \\    var x: u32 = 1;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        x = x + 1;
        \\    }
        \\    return x;
        \\}
        \\
        \\fn accept_unchecked_contract_add(a: u32, b: u32) -> u32 {
        \\    var x: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        x = unchecked.add(a, b);
        \\    }
        \\    return x;
        \\}
        \\
        \\fn accept_unchecked_contract_return_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_return_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(next_value(), next_value()) as u32;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let value: u32 = unchecked.add(next_value(), next_value());
        \\        return value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let cast_value: u32 = unchecked.add(next_value(), next_value()) as u32;
        \\        return cast_value;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_inferred_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let inferred = unchecked.add(next_value(), next_value());
        \\        return inferred;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_inferred_local_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let cast_inferred = unchecked.add(next_value(), next_value()) as u32;
        \\        return cast_inferred;
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_assignment_order() -> u32 {
        \\    var value: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        value = unchecked.add(next_value(), next_value());
        \\    }
        \\    return value;
        \\}
        \\
        \\fn accept_unchecked_contract_cast_assignment_order() -> u32 {
        \\    var cast_assigned: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        cast_assigned = unchecked.add(next_value(), next_value()) as u32;
        \\    }
        \\    return cast_assigned;
        \\}
        \\
        \\fn accept_unchecked_contract_arg_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.add(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_arg_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.add(next_value(), next_value()) as u32);
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_arg_sub_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.sub(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_arg_mul_order() -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_value(unchecked.mul(next_value(), next_value()));
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_sub_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.sub(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_mul_order() -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.mul(next_value(), next_value());
        \\    }
        \\    return 0;
        \\}
        \\
        \\fn accept_unchecked_contract_nested_binary_order(a: u32, b: u32, c: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b)) + c;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_return(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_array_return(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_return(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_cast_struct_return(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) as u32 };
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_local(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let values: [1]u32 = .{ unchecked.sub(a, b) };
        \\        return values;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_local(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let counter: Counter = .{ .next = unchecked.add(a, b) };
        \\        return counter;
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_arg(a: u32, b: u32) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_values(.{ unchecked.add(a, b) });
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_struct_arg(a: u32, b: u32) -> void {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        consume_counter(.{ .next = unchecked.mul(a, b) });
        \\    }
        \\}
        \\
        \\fn accept_unchecked_contract_array_assignment(a: u32, b: u32) -> [1]u32 {
        \\    var values: [1]u32 = .{0};
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        values = .{ unchecked.sub(a, b) };
        \\    }
        \\    return values;
        \\}
        \\
        \\fn accept_unchecked_contract_struct_assignment(a: u32, b: u32) -> Counter {
        \\    var counter: Counter = .{ .next = 0 };
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        counter = .{ .next = unchecked.add(a, b) };
        \\    }
        \\    return counter;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_contract_block.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_plain_contract_scope(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;\n    /* MC_CONTRACT_BEGIN no_overflow */\n    {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_unchecked_contract_add(uint32_t a, uint32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=x op=add */") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=value op=add */"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=inferred op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_value op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_inferred op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=cast_assigned op=add */") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=add */"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=sub */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=call_arg op=mul */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=binary_operand op=add */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=value op=sub */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* MC_MIR_RANGE no_overflow target=value op=mul */") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=aggregate_element op=add */"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=aggregate_element op=sub */"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=next op=mul */"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "/* MC_MIR_RANGE no_overflow target=next op=add */"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_values(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_counter(mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = (mc_tmp") != null);
}
