const std = @import("std");

const ast = @import("ast.zig");
const backend_mod = @import("backend.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const diagnostics = @import("diagnostics.zig");
const lower_c = @import("lower_c.zig");
const lower_c_expr = @import("lower_c_expr.zig");
const lower_c_runtime = @import("lower_c_runtime.zig");
const lower_c_shape = @import("lower_c_shape.zig");
const lower_llvm = @import("lower_llvm.zig");
const mir = @import("mir.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const parser = @import("parser.zig");
const test_artifact_support = @import("test_artifact_support.zig");
const test_support = @import("test_support.zig");

fn appendLlvmDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, out: *std.ArrayList(u8)) !void {
    var module_mir = try mir.buildOptFromDecls(allocator, decls, .{});
    defer module_mir.deinit();
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(allocator, decls, &module_mir);
    defer artifacts.deinit(allocator);
    try lower_llvm.appendLlvmCheckedMirArtifacts(allocator, artifacts.codegen(), &module_mir, out, "input.mc", .{}, false, .riscv64, false, null);
}

fn appendCDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, out: *std.ArrayList(u8)) !void {
    var module_mir = try mir.buildOptFromDecls(allocator, decls, .{});
    defer module_mir.deinit();
    try appendCProfileWithMirDeclsTest(allocator, decls, &module_mir, out, .kernel, null, .{}, false, null);
}

fn appendCProfileWithSourcePathDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, out: *std.ArrayList(u8), profile: lower_c.Profile, source_path: ?[]const u8, checks: backend_mod.Checks, stub_asm: bool) !void {
    var module_mir = try mir.buildOptFromDecls(allocator, decls, .{ .optimize = checks.optimize });
    defer module_mir.deinit();
    try appendCProfileWithMirDeclsTest(allocator, decls, &module_mir, out, profile, source_path, checks, stub_asm, null);
}

fn appendCProfileWithMirDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, module_mir: *const mir.Module, out: *std.ArrayList(u8), profile: lower_c.Profile, source_path: ?[]const u8, checks: backend_mod.Checks, stub_asm: bool, reporter: ?*diagnostics.Reporter) !void {
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(allocator, decls, module_mir);
    defer artifacts.deinit(allocator);
    try lower_c.appendCProfileWithMirArtifacts(allocator, artifacts.codegen(), module_mir, out, profile, source_path, checks, stub_asm, reporter);
}

test "lower-c emits a verified body without function declaration artifacts" {
    const source =
        \\fn value() -> u32 { return 7; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_declaration_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        .empty,
        &module_mir,
        &output,
        .kernel,
        "c_missing_declaration_facts.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "value(void)");
}

test "lower-c renders scalar const globals from verified MIR facts" {
    const source =
        \\const COUNT: u32 = 1 + 2;
        \\const ENABLED: bool = true;
        \\const NEG_ZERO: f32 = -0.0;
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_scalar_const_global_facts.mc", source, &output);

    try expectContains(output.items, "uint32_t COUNT = 3;");
    try expectContains(output.items, "bool ENABLED = 1;");
    try expectContains(output.items, "float NEG_ZERO = __builtin_bit_cast(float, ((uint32_t)0x80000000U));");
}

test "lower-c derives type aliases from module signature facts" {
    const source =
        \\type Word = u32;
        \\const BASE: Word = 41;
        \\fn next(value: Word) -> Word { return value + BASE; }
    ;
    var parsed = try test_support.parseCheckedModule("c_type_alias_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), module_mir.type_aliases.len);
    const alias_symbol = module_mir.symbol_identities[module_mir.type_aliases[0].symbol_id.index()];
    try std.testing.expectEqualStrings("Word", alias_symbol.spelling);

    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    // The scalar const global, type alias, and function all have syntax-free
    // fact paths, so no ordinary declaration artifact remains.
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_type_alias_facts.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "uint32_t BASE = 41;");
    try expectContains(output.items, "next(uint32_t value)");
}

test "lower-c derives enums from checked module facts" {
    const source =
        \\enum Status: i8 { negative = -1, ready = 'R' }
        \\fn status() -> Status { return .negative; }
    ;
    var parsed = try test_support.parseCheckedModule("c_enum_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), module_mir.enums.len);

    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    // Enum declaration and callable syntax are both absent from codegen
    // artifacts in this fixture.
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_enum_facts.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "typedef int8_t Status;");
    try expectContains(output.items, "Status_negative = -1");
    try expectContains(output.items, "Status_ready = 82");
}

test "lower-c derives packed bits from checked module facts" {
    const source =
        \\packed bits Flags: u8 { ready: bool, busy: bool }
        \\fn flags(value: Flags) -> bool { return value.ready; }
    ;
    var parsed = try test_support.parseCheckedModule("c_packed_bits_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), module_mir.packed_bits.len);

    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_packed_bits_facts.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "typedef uint8_t Flags;");
    try expectContains(output.items, "flags(Flags value)");
}

test "lower-c derives overlay unions from checked module facts" {
    const source =
        \\overlay union Overlay { bytes: [4]u8, word: u32 }
        \\fn read_word(value: Overlay) -> u32 { return value.word; }
    ;
    var parsed = try test_support.parseCheckedModule("c_overlay_union_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), module_mir.overlay_unions.len);

    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_overlay_union_facts.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "typedef struct Overlay {");
    try expectContains(output.items, "alignas(4) unsigned char storage[4];");
}

test "lower-c derives tagged unions from checked module facts" {
    const source =
        \\union Token { number: u32, eof }
        \\fn identity(value: Token) -> Token { return value; }
    ;
    var parsed = try test_support.parseCheckedModule("c_tagged_union_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), module_mir.tagged_unions.len);

    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_tagged_union_facts.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "typedef enum TokenTag");
    try expectContains(output.items, "typedef struct Token {");
}

test "lower-c derives structs from checked module facts" {
    const source =
        \\struct Pair { left: u32, right: u16 }
        \\fn identity(value: Pair) -> Pair { return value; }
    ;
    var parsed = try test_support.parseCheckedModule("c_struct_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), module_mir.structs.len);

    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_struct_facts.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "typedef struct Pair {");
}

test "lower-c scalar const globals do not retain an AST initializer dependency" {
    const source = "const COUNT: u32 = 1 + 2;";
    var parsed = try test_support.parseCheckedModule("c_scalar_const_global_no_ast_init.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_scalar_const_global_no_ast_init.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "uint32_t COUNT = 3;");
}

test "lower-c renders mutable scalar globals from verified initializer plans" {
    const source = "global COUNT: u32 = 1 + 2;";
    var parsed = try test_support.parseCheckedModule("c_mutable_scalar_global_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 1), module_mir.global_initializer_facts.len);
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_mutable_scalar_global_plan.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "uint32_t COUNT = 3;");
}

test "lower-c emits direct scalar global copies from verified initializer plans" {
    const source =
        \\global SEED: u32 = 7;
        \\global COPIED: u32 = SEED;
        \\global GROUPED: u32 = (SEED);
        \\global CASTED: u32 = (SEED as u32);
    ;
    var parsed = try test_support.parseCheckedModule("c_scalar_global_copy_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    // Every initializer in this family is carried by the verified scalar plan;
    // no GlobalArtifact can retain its source AST expression.
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_scalar_global_copy_plan.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "uint32_t SEED = 7;");
    try expectContains(output.items, "uint32_t COPIED = 7;");
    try expectContains(output.items, "uint32_t GROUPED = 7;");
    try expectContains(output.items, "uint32_t CASTED = 7;");
}

test "lower-c renders no-init scalar and array globals from verified zero plans" {
    const source =
        \\global COUNT: u32;
        \\global VALUES: [2]u32;
    ;
    var parsed = try test_support.parseCheckedModule("c_zero_global_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 2), module_mir.global_initializer_facts.len);
    for (module_mir.global_initializer_facts) |fact| switch (fact.plan) {
        .zero => {},
        .scalar => return error.TestUnexpectedResult,
        .aggregate => return error.TestUnexpectedResult,
        .enum_case => return error.TestUnexpectedResult,
        .nullable_null => return error.TestUnexpectedResult,
        .string_bytes => return error.TestUnexpectedResult,
        .global_address => return error.TestUnexpectedResult,
    };
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_zero_global_plan.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "uint32_t COUNT = 0;");
    try expectContains(output.items, "mc_array_u32_2 VALUES = {0};");
}

test "lower-c renders pure array literals from syntax-free aggregate plans" {
    const source = "global VALUES: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };";
    var parsed = try test_support.parseCheckedModule("c_aggregate_global_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_aggregate_global_plan.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "VALUES = { { 1, 2 }, { 3, 4 } };");
}

test "lower-c renders named struct global literals from syntax-free plans" {
    const source =
        \\open enum Mode: u32 { ready = 7 }
        \\struct Config { retries: u32, mode: Mode, label: cstr, source: *const u32 }
        \\global backing: u32 = 9;
        \\global config: Config = .{ .retries = 3, .mode = .ready, .label = "cfg", .source = &backing };
    ;
    var parsed = try test_support.parseCheckedModule("c_named_struct_global_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expect(module_mir.checkedGlobalInitializer(module_mir.checked_globals[1]) != null);
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(std.testing.allocator, artifacts.codegen(), &module_mir, &output, .kernel, "c_named_struct_global_plan.mc", .{}, false, null);
    try expectContains(output.items, "config = { .retries = 3, .mode = Mode_ready, .label = ((char const *)\"cfg\"), .source = &backing };");
}

test "lower-c fails closed when a scalar const-global fact is missing" {
    const source = "const COUNT: u32 = 1 + 2;";
    var parsed = try test_support.parseCheckedModule("c_missing_scalar_const_global_fact.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const saved_facts = module_mir.global_initializer_facts;
    defer module_mir.global_initializer_facts = saved_facts;
    module_mir.global_initializer_facts = &.{};
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidMirGlobalInitializerFacts,
        lower_c.appendCProfileWithMirArtifacts(
            std.testing.allocator,
            artifacts.codegen(),
            &module_mir,
            &output,
            .kernel,
            "c_missing_scalar_const_global_fact.mc",
            .{},
            false,
            null,
        ),
    );
}

test "lower-c fails closed when a scalar const-global fact is stale" {
    const source = "const COUNT: u32 = 1 + 2;";
    var parsed = try test_support.parseCheckedModule("c_stale_scalar_const_global_fact.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const saved = module_mir.global_initializer_facts[0];
    defer module_mir.global_initializer_facts[0] = saved;
    module_mir.global_initializer_facts[0].value_ty = .bool;
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidMirGlobalInitializerFacts,
        lower_c.appendCProfileWithMirArtifacts(
            std.testing.allocator,
            artifacts.codegen(),
            &module_mir,
            &output,
            .kernel,
            "c_stale_scalar_const_global_fact.mc",
            .{},
            false,
            null,
        ),
    );
}
fn appendCSourceMapDeclsTest(allocator: std.mem.Allocator, decls: []ast.Decl, out: *std.ArrayList(u8), profile: lower_c.Profile, source_path: []const u8, generated_c_path: ?[]const u8) !void {
    var generated_c: std.ArrayList(u8) = .empty;
    defer generated_c.deinit(allocator);
    try appendCProfileWithSourcePathDeclsTest(allocator, decls, &generated_c, profile, source_path, .{}, false);

    var typed_mir = try mir.buildFromDecls(allocator, decls);
    defer typed_mir.deinit();

    var artifacts = try test_artifact_support.collectArtifactsFromDecls(allocator, decls, &typed_mir);
    defer artifacts.deinit(allocator);
    try lower_c.appendCSourceMapFromGenerated(allocator, artifacts.source_map_artifacts, out, generated_c.items, &typed_mir, source_path, generated_c_path, .{
        .profile = profile,
        .source_path = source_path,
    });
}

test "lower-c canonical MIR renders scalar closure capture through a thunk" {
    const source =
        \\fn add_scalar(env: u32, x: u32) -> u32 { return env + x; }
        \\fn scalar_bind() -> u32 {
        \\    let cb: closure(u32) -> u32 = bind(10, add_scalar);
        \\    return cb(5);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_scalar_closure.mc", source, &output);

    try expectContains(output.items, "static MC_UNUSED uint32_t mc_envthunk_add_scalar(void *mc_env, uint32_t mc_a0)");
    try expectContains(output.items, "add_scalar((uint32_t)(uintptr_t)mc_env, mc_a0)");
    const body = try cFunctionBody(output.items, "static uint32_t scalar_bind");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, ".code = (uint32_t (*)(void *, uint32_t))mc_envthunk_add_scalar");
    try expectContains(body, ".env = (void *)(uintptr_t)");
}

test "lower-c canonical MIR renders variadic cursor operations" {
    const source =
        \\export fn sum_args(count: i32, ...) -> i64 {
        \\    var ap: va_list = va.start();
        \\    var total: i64 = 0;
        \\    var i: i32 = 0;
        \\    while i < count {
        \\        unsafe { total = total + va.arg<i64>(&ap); }
        \\        i = i + 1;
        \\    }
        \\    va.end(&ap);
        \\    return total;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_varargs.mc", source, &output);

    const body = try cFunctionBody(output.items, "int64_t sum_args(int32_t count, ...)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "__builtin_va_list ap;");
    try expectContains(body, "__builtin_va_start(ap, count);");
    try expectContains(body, "__builtin_va_arg(ap, int64_t)");
    try expectContains(body, "__builtin_va_end(ap);");
}

test "lower-c canonical MIR maps propagated Result errors" {
    const source =
        \\enum LowErr { Failed }
        \\enum HighErr { Other, Mapped }
        \\#[error_from]
        \\fn promote(error_value: LowErr) -> HighErr { return .Mapped; }
        \\fn low() -> Result<u32, LowErr> { return err(.Failed); }
        \\fn converted() -> Result<u32, HighErr> {
        \\    let value: u32 = low()?;
        \\    return ok(value);
        \\}
        \\fn mapped() -> Result<u32, HighErr> {
        \\    let value: u32 = low()? else .Mapped;
        \\    return ok(value);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_try_map_error.mc", source, &output);

    const converted = try cFunctionBody(output.items, "static mc_result_u32_mc_type_name_7_HighErr converted");
    try expectContains(converted, "/* canonical executable MIR */");
    try expectContains(converted, ".payload.err = promote(");

    const mapped = try cFunctionBody(output.items, "static mc_result_u32_mc_type_name_7_HighErr mapped");
    try expectContains(mapped, "/* canonical executable MIR */");
    try expectContains(mapped, "if (!mc_exec_tmp_0.is_ok) {");
    try expectContains(mapped, ".payload.err = mc_exec_tmp_1");
}

test "lower-c canonical MIR renders packed field read-modify-write" {
    const source =
        \\packed bits Flags: u8 { ready: bool, busy: bool }
        \\global shared_flags: Flags = 0;
        \\fn update_local(input: Flags, set: bool) -> Flags {
        \\    var next: Flags = input;
        \\    next.busy = set;
        \\    return next;
        \\}
        \\fn update_global(set: bool) -> void { shared_flags.ready = set; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_packed_field_store.mc", source, &output);

    const local = try cFunctionBody(output.items, "update_local(");
    try expectContains(local, "/* canonical executable MIR */");
    try expectContains(local, "next = (Flags)((next & (uint8_t)~((uint8_t)2))");
    const global = try cFunctionBody(output.items, "update_global(");
    try expectContains(global, "/* canonical executable MIR */");
    try expectContains(global, "mc_race_store_u8(&shared_flags");
    try expectContains(global, "mc_race_load_u8(&shared_flags)");
}

test "lower-c canonical executable MIR preserves function render attributes" {
    const source =
        \\#[section(".text.hot")]
        \\export fn hot_path(x: u32) -> u32 { return x + 1; }
        \\#[noinline]
        \\export fn never_inlined(x: u32) -> u32 { return x + 1; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_function_attrs.mc", source, &output);

    const hot = try cFunctionBody(output.items, "__attribute__((section(\".text.hot\"))) uint32_t hot_path");
    try expectContains(hot, "/* canonical executable MIR */");
    const noinline_body = try cFunctionBody(output.items, "__attribute__((noinline)) uint32_t never_inlined");
    try expectContains(noinline_body, "/* canonical executable MIR */");
}

test "lower-c lexical unsafe and contract call bodies use canonical executable MIR" {
    const source =
        \\extern fn consume(value: u32) -> void;
        \\fn unsafe_call(value: u32) -> void {
        \\    unsafe { consume(value); }
        \\}
        \\fn contract_call(value: u32) -> void {
        \\    #[unsafe_contract(no_overflow)] {
        \\        consume(value);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_lexical_contract_calls.mc", source, &output);

    const unsafe_body = try cFunctionBody(output.items, "static void unsafe_call");
    try expectContains(unsafe_body, "/* canonical executable MIR */");
    try expectContains(unsafe_body, "consume(mc_exec_tmp_0);");

    const contract_body = try cFunctionBody(output.items, "static void contract_call");
    try expectContains(contract_body, "/* canonical executable MIR */");
    try expectContains(contract_body, "consume(mc_exec_tmp_0);");
    try expectNotContains(contract_body, "MC_CONTRACT_");
}

test "lower-c fixed-array signatures and direct calls use canonical executable MIR" {
    const source =
        \\extern fn make_array() -> [2]u32;
        \\extern fn consume_array(values: [2]u32) -> void;
        \\fn return_array() -> [2]u32 { return make_array(); }
        \\fn copy_array(values: [2]u32) -> [2]u32 {
        \\    let copy: [2]u32 = values;
        \\    return copy;
        \\}
        \\fn pass_array() -> void {
        \\    let values = make_array();
        \\    consume_array(values);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_fixed_array_calls.mc", source, &output);

    const returned = try cFunctionBody(output.items, "static mc_array_u32_2 return_array");
    try expectContains(returned, "/* canonical executable MIR */");
    try expectContains(returned, "= make_array();");
    const copied = try cFunctionBody(output.items, "static mc_array_u32_2 copy_array");
    try expectContains(copied, "/* canonical executable MIR */");
    const passed = try cFunctionBody(output.items, "static void pass_array");
    try expectContains(passed, "/* canonical executable MIR */");
    try expectContains(passed, "consume_array(mc_exec_tmp_");
}

test "lower-c fixed-array element addresses use canonical executable MIR" {
    const source =
        \\extern fn consume_pointer(pointer: *mut u8) -> void;
        \\const ELEMENT_COUNT: usize = 4;
        \\global global_buffer: [ELEMENT_COUNT]u8;
        \\fn pass_array_element_address() -> void {
        \\    var buffer: [4]u8 = uninit;
        \\    consume_pointer(&buffer[0]);
        \\}
        \\fn pass_symbolic_global_element_address() -> void {
        \\    consume_pointer(&global_buffer[0]);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_fixed_array_element_address.mc", source, &output);

    const body = try cFunctionBody(output.items, "static void pass_array_element_address(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "mc_check_index_usize(");
    try expectContains(body, "&((buffer).elems[");
    try expectContains(body, "consume_pointer(mc_exec_tmp_");

    const global_body = try cFunctionBody(output.items, "static void pass_symbolic_global_element_address(void)");
    try expectContains(global_body, "/* canonical executable MIR */");
    try expectContains(global_body, "&((global_buffer).elems[mc_check_index_usize(");
    try expectContains(global_body, ", 4)]");
}

test "lower-c callable parameters forward through canonical executable MIR" {
    const source =
        \\extern fn target(sink: fn(u8) -> void, value: u64, shift: i32) -> void;
        \\fn forward(sink: fn(u8) -> void, value: u32) -> void {
        \\    target(sink, value as u64, 28);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_callable_parameter.mc", source, &output);

    const body = try cFunctionBody(output.items, "MC_UNUSED static void forward");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "target(mc_exec_tmp_");
}

test "lower-c callable field stores use verified signatures" {
    const source =
        \\fn add(a: u32, b: u32) -> u32 { return a + b; }
        \\struct BinOp { combine: fn(u32, u32) -> u32 }
        \\global ops: [2]BinOp = .{ .{ .combine = add }, .{ .combine = add } };
        \\fn replace() -> void { ops[1].combine = add; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_callable_field_store.mc", source, &output);

    const body = try cFunctionBody(output.items, "static void replace(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "__atomic_store_n(&((ops).elems[");
    try expectContains(body, "].combine), add, __ATOMIC_RELAXED)");
}

test "lower-c valid slice representation check uses canonical executable MIR" {
    const source =
        \\fn identity_slice(items: []const u32) -> []const u32 {
        \\    return items;
        \\}
        \\fn slice_len(items: []const u32) -> usize {
        \\    return items.len;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_valid_slice.mc", source, &output);
    const body = try cFunctionBody(output.items, "mc_slice_const_u32 identity_slice");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "__auto_type mc_exec_tmp_0 = items;");
    try expectContains(body, "mc_exec_tmp_1.ptr == NULL && mc_exec_tmp_1.len != 0");
    try expectContains(body, "return mc_exec_tmp_1;");
    const len_body = try cFunctionBody(output.items, "uintptr_t slice_len");
    try expectContains(len_body, "/* canonical executable MIR */");
}

test "lower-c value optional construction needs no function body fallback" {
    const source =
        \\struct Point { x: u32, y: u32 }
        \\fn scalar(present: bool, value: u32) -> ?u32 {
        \\    if present { return value; }
        \\    return null;
        \\}
        \\fn point(present: bool) -> ?Point {
        \\    if present {
        \\        let value: Point = .{ .x = 3, .y = 4 };
        \\        return value;
        \\    }
        \\    return null;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_value_optional.mc", source, &output);

    const scalar = try cFunctionBody(output.items, "mc_opt_u32 scalar");
    try expectContains(scalar, "/* canonical executable MIR */");
    try expectContains(scalar, "(mc_opt_u32){ .present = true, .value =");
    try expectContains(scalar, "(mc_opt_u32){ .present = false }");
    const point = try cFunctionBody(output.items, "mc_opt_mc_type_struct_5_Point point");
    try expectContains(point, "/* canonical executable MIR */");
    try expectContains(point, "(mc_opt_mc_type_struct_5_Point){ .present = true, .value =");
    try expectContains(point, "(mc_opt_mc_type_struct_5_Point){ .present = false }");
}

test "lower-c atomic loads use canonical executable MIR" {
    const source =
        \\global relaxed_ticks: atomic<u32> = atomic.init(0);
        \\global seq_ticks: atomic<u32> = atomic.init(0);
        \\fn load_global_relaxed() -> u32 { return relaxed_ticks.load(.relaxed); }
        \\fn load_global_seq_cst() -> u32 { return seq_ticks.load(.seq_cst); }
        \\fn load_pointer_acquire(value: *mut atomic<u32>) -> u32 { return value.load(.acquire); }
        \\fn load_bool_acquire(value: *const atomic<bool>) -> bool { return value.load(.acquire); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_atomic_load.mc", source, &output);

    const relaxed = try cFunctionBody(output.items, "load_global_relaxed(");
    try expectContains(relaxed, "/* canonical executable MIR */");
    try expectContains(relaxed, "__atomic_load_n(&relaxed_ticks, __ATOMIC_RELAXED)");
    const seq_cst = try cFunctionBody(output.items, "load_global_seq_cst(");
    try expectContains(seq_cst, "__atomic_load_n(&seq_ticks, __ATOMIC_SEQ_CST)");

    const pointer = try cFunctionBody(output.items, "load_pointer_acquire(");
    const guard_at = std.mem.indexOf(u8, pointer, "if (value == NULL)") orelse return error.TestUnexpectedResult;
    const load_at = std.mem.indexOf(u8, pointer, "__atomic_load_n(value, __ATOMIC_ACQUIRE)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard_at < load_at);
    try expectNotContains(pointer, "__atomic_load_n(&value");

    const boolean = try cFunctionBody(output.items, "load_bool_acquire(");
    try expectContains(boolean, "__atomic_load_n(value, __ATOMIC_ACQUIRE)");
}

test "lower-c atomic updates use canonical executable MIR" {
    const source =
        \\fn update(delta: u32) -> u32 {
        \\    var value: atomic<u32> = atomic.init(4);
        \\    value.store(delta, .release);
        \\    return value.fetch_add(1, .acq_rel);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_atomic_update.mc", source, &output);

    const body = try cFunctionBody(output.items, "update(");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "uint32_t value = mc_exec_tmp_");
    try expectContains(body, "__atomic_store_n(&value, ((uint32_t)mc_exec_tmp_");
    try expectContains(body, "__ATOMIC_RELEASE)");
    try expectContains(body, "__atomic_fetch_add(&value, ((uint32_t)mc_exec_tmp_");
    try expectContains(body, "__ATOMIC_ACQ_REL)");
}

test "lower-c MMIO scalar accesses use canonical executable MIR" {
    const source =
        \\extern mmio struct Device {
        \\    status: Reg<u32, .read> @offset(8),
        \\    command: Reg<u32, .write> @offset(16),
        \\}
        \\extern fn next_value() -> u32;
        \\fn read_relaxed(device: MmioPtr<Device>) -> u32 { return device.status.read(.relaxed); }
        \\fn read_after_call(device: MmioPtr<Device>) -> u32 { return next_value() + device.status.read(.acquire); }
        \\fn write_release(device: MmioPtr<Device>) -> void { device.command.write(next_value(), .release); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_mmio_scalar.mc", source, &output);

    const read = try cFunctionBody(output.items, "read_relaxed(");
    try expectContains(read, "/* canonical executable MIR */");
    try expectContains(read, "mc_mmio_read_u32(((uint32_t volatile const *)((uintptr_t)device + UINT64_C(8))))");
    try expectNotContains(read, "mc_barrier_acquire_after");
    const ordered_read = try cFunctionBody(output.items, "read_after_call(");
    try expectNeedlesInOrder(ordered_read, &.{ "next_value();", "mc_mmio_read_u32", "mc_barrier_acquire_after();", "mc_checked_add_u32" });
    const write = try cFunctionBody(output.items, "write_release(");
    try expectNeedlesInOrder(write, &.{ "next_value();", "mc_barrier_release_before();", "mc_mmio_write_u32" });
    try expectContains(write, "+ UINT64_C(16)");
}

test "lower-c grouped i128 minimum never reads an inactive AST union arm" {
    const source =
        \\fn grouped_i128_minimum() -> i128 {
        \\    return -(((170141183460469231731687303715884105728)));
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("grouped_i128_minimum.mc", source, &output);
    try expectContains(output.items, "grouped_i128_minimum");
}

test "lower-c function symbol returns lower from MIR without body fallback" {
    const source =
        \\fn tick() -> void {}
        \\fn entry_of() -> fn() -> void { return tick; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_identity_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static mc_fnptr_4_void entry_of(void)");
    try expectContains(body, "return tick;");
}

test "lower-c executable body renders broad CFG calls without AST fallback" {
    const source =
        \\extern fn next_value() -> u32;
        \\extern fn combine_values(left: u32, right: u32) -> u32;
        \\fn executable_cfg(flag: bool, seed: u32) -> u32 {
        \\    var value: u32 = seed;
        \\    while flag {
        \\        value = combine_values(next_value(), seed);
        \\        break;
        \\    }
        \\    return combine_values(value, next_value());
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_executable_cfg.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t executable_cfg(bool flag, uint32_t seed)");
    try expectContains(body, "mc_bb_");
    try expectContains(body, "goto mc_bb_");
    const first_next = std.mem.indexOf(u8, body, "= next_value();") orelse return error.TestUnexpectedResult;
    const first_combine = std.mem.indexOfPos(u8, body, first_next, "= combine_values(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_next < first_combine);

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "executable_cfg.c", .data = output.items });
    const generated_c = try temp.dir.realPathFileAlloc(std.testing.io, "executable_cfg.c", std.testing.allocator);
    defer std.testing.allocator.free(generated_c);
    const clang = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "clang", "-std=c11", "-fsyntax-only", generated_c } });
    defer std.testing.allocator.free(clang.stdout);
    defer std.testing.allocator.free(clang.stderr);
    try std.testing.expect(clang.term == .exited and clang.term.exited == 0);
}

test "lower-c executable MIR owns reflection constants without AST fallback" {
    const source =
        \\extern struct Packet {
        \\    len: u16,
        \\    tag: u8,
        \\}
        \\enum Mode: u8 { normal = 0 }
        \\overlay union Overlay { byte: u8, word: u32 }
        \\#[c_union]
        \\struct CUnion { byte: u8, word: u64 }
        \\fn packet_size() -> usize { return sizeof<Packet>(); }
        \\fn packet_alignment() -> usize { return alignof<Packet>(); }
        \\fn packet_tag_offset() -> usize { return field_offset<Packet>(.tag); }
        \\fn packet_tag_bit_offset() -> usize { return bit_offset<Packet>(.tag); }
        \\fn mode_repr() -> usize { return repr_of<Mode>(); }
        \\fn overlay_size() -> usize { return sizeof<Overlay>(); }
        \\fn overlay_word_offset() -> usize { return field_offset<Overlay>(.word); }
        \\fn c_union_size() -> usize { return sizeof<CUnion>(); }
        \\fn c_union_word_offset() -> usize { return field_offset<CUnion>(.word); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_executable_reflection_constants.mc", source, &output);

    const packet_size = try cFunctionBody(output.items, "static uintptr_t packet_size(void)");
    try expectContains(packet_size, "= 4;");
    try expectContains(packet_size, "return mc_exec_tmp_");
    const packet_alignment = try cFunctionBody(output.items, "static uintptr_t packet_alignment(void)");
    try expectContains(packet_alignment, "= 2;");
    const packet_tag_offset = try cFunctionBody(output.items, "static uintptr_t packet_tag_offset(void)");
    try expectContains(packet_tag_offset, "= 2;");
    const packet_tag_bit_offset = try cFunctionBody(output.items, "static uintptr_t packet_tag_bit_offset(void)");
    try expectContains(packet_tag_bit_offset, "= 16;");
    const mode_repr = try cFunctionBody(output.items, "static uintptr_t mode_repr(void)");
    try expectContains(mode_repr, "= 1;");
    const overlay_size = try cFunctionBody(output.items, "static uintptr_t overlay_size(void)");
    try expectContains(overlay_size, "= 4;");
    const overlay_word_offset = try cFunctionBody(output.items, "static uintptr_t overlay_word_offset(void)");
    try expectContains(overlay_word_offset, "= 0;");
    const c_union_size = try cFunctionBody(output.items, "static uintptr_t c_union_size(void)");
    try expectContains(c_union_size, "= 8;");
    const c_union_word_offset = try cFunctionBody(output.items, "static uintptr_t c_union_word_offset(void)");
    try expectContains(c_union_word_offset, "= 0;");
}

test "lower-c emits slice length returns from MIR without body fallback" {
    const source =
        \\fn const_slice_len(values: []const u8) -> usize {
        \\    return values.len;
        \\}
        \\fn mutable_slice_len(values: []mut u32) -> usize {
        \\    return values.len;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_slice_length_return.mc", source, &output);

    const const_body = try cFunctionBody(output.items, "static uintptr_t const_slice_len(mc_slice_const_u8 values)");
    try expectContains(const_body, ".ptr == NULL && ");
    try expectContains(const_body, ".len != 0");
    try expectContains(const_body, ".len;");
    try expectContains(const_body, "return mc_exec_tmp_");
    const mutable_body = try cFunctionBody(output.items, "static uintptr_t mutable_slice_len(mc_slice_mut_u32 values)");
    try expectContains(mutable_body, ".ptr == NULL && ");
    try expectContains(mutable_body, ".len != 0");
    try expectContains(mutable_body, ".len;");
    try expectContains(mutable_body, "return mc_exec_tmp_");
}

test "lower-c emits assertion expression trees from MIR without body fallback" {
    const source =
        \\extern fn next_value() -> u32;
        \\fn require_complex(a: u32, b: u32, flag: bool) -> void {
        \\    assert(flag == (a == b));
        \\}
        \\fn assert_ordered_comparison() -> void {
        \\    assert(next_value() == next_value());
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_assert_expression_tree.mc", source, &output);

    const complex = try cFunctionBody(output.items, "static void require_complex(uint32_t a, uint32_t b, bool flag)");
    try expectContains(complex, "/* canonical executable MIR */");
    try expectContains(complex, "if (!(mc_exec_tmp_");
    try expectContains(complex, ")) goto mc_bb_");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, complex, "mc_trap_Assert();"));
    const ordered = try cFunctionBody(output.items, "static void assert_ordered_comparison(void)");
    try expectContains(ordered, "/* canonical executable MIR */");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, ordered, "next_value()"));
    const call = " = next_value();";
    const first = std.mem.indexOf(u8, ordered, call) orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, ordered, first + call.len, call) orelse return error.TestUnexpectedResult;
    try std.testing.expect(first < second);
    try expectContains(ordered, "if (!(mc_exec_tmp_");
    try expectContains(ordered, ")) goto mc_bb_");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ordered, "mc_trap_Assert();"));
}

test "MIR executable body admits pure logical assertion tree" {
    const source =
        \\fn require_complex(a: u32, b: u32, flag: bool) -> void {
        \\    assert(flag && (a == b || a != 0));
        \\}
    ;
    var parsed = try test_support.parseModule("mir_assert_plan_require_complex.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = &module_mir.functions[0];
    try std.testing.expect(function.executable_body.complete);
    try mir_executable_body.verify(function);
}

test "lower-c omits nullable pointer null globals from AST artifacts" {
    const source =
        \\type MaybeByte = ?*mut u8;
        \\const DEFAULT: MaybeByte = (null);
        \\global CURRENT: MaybeByte = null;
    ;
    var parsed = try test_support.parseCheckedModule("c_nullable_null_global_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expectEqual(@as(usize, 2), module_mir.global_initializer_facts.len);
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_nullable_null_global_plan.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "DEFAULT = NULL;");
    try expectContains(output.items, "CURRENT = NULL;");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, " = NULL;"));
}

test "lower-c emits direct global-address plans without AST initializer artifacts" {
    const source =
        \\global shared: u32 = 7;
        \\global shared_ptr: *mut u32 = &shared;
    ;
    var parsed = try test_support.parseCheckedModule("c_global_address_initializer_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expect(module_mir.checkedGlobalAddressGlobal(module_mir.checked_globals[1]) != null);
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_global_address_initializer_plan.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "shared_ptr = &shared;");
}

test "lower-c emits decoded string-byte global plans without AST initializer artifacts" {
    const source =
        \\global greeting: cstr = "hi\n";
        \\global greeting_copy: cstr = greeting;
        \\global raw: *const u8 = "raw";
    ;
    var parsed = try test_support.parseCheckedModule("c_string_bytes_global_plan.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expect(module_mir.checkedStringBytesGlobal(module_mir.checked_globals[0]) != null);
    try std.testing.expect(module_mir.checkedStringBytesGlobal(module_mir.checked_globals[1]) != null);
    try std.testing.expect(module_mir.checkedStringBytesGlobal(module_mir.checked_globals[2]) != null);
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), artifacts.decl_artifacts.len);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_string_bytes_global_plan.mc",
        .{},
        false,
        null,
    );
    try expectContains(output.items, "greeting = ((char const *)\"hi\\n\");");
    try expectContains(output.items, "greeting_copy = ((char const *)\"hi\\n\");");
    try expectContains(output.items, "raw = ((uint8_t const *)\"raw\");");
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "string_bytes_global_plan.c", .data = output.items });
    const generated_c = try temp.dir.realPathFileAlloc(std.testing.io, "string_bytes_global_plan.c", std.testing.allocator);
    defer std.testing.allocator.free(generated_c);
    const clang = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "clang", "-fsyntax-only", generated_c },
    });
    defer std.testing.allocator.free(clang.stdout);
    defer std.testing.allocator.free(clang.stderr);
    try std.testing.expect(clang.term == .exited and clang.term.exited == 0);
}

test "lower-c emits strict nullable control plans from MIR without body fallback" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn maybe_ptr_from(seed: u32) -> ?*mut u8;
        \\extern fn next_seed() -> u32;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\type NullableAlias = ?*mut u8;
        \\const DEFAULT_NULL: NullableAlias = (null);
        \\global saved_nullable: NullableAlias = null;
        \\struct NullableBox { maybe: ?*mut u8, }
        \\
        \\fn unwrap_call_or_zero() -> u32 {
        \\    if let p = maybe_ptr() { return ptr_value(p); }
        \\    return 0;
        \\}
        \\fn unwrap_global_or_zero() -> u32 {
        \\    if let p = saved_nullable { return ptr_value(p); }
        \\    return 0;
        \\}
        \\fn unwrap_field_or_zero(box: NullableBox) -> u32 {
        \\    if let p = box.maybe { return ptr_value(p); }
        \\    return 0;
        \\}
        \\fn nullable_switch(maybe: ?*mut u8) -> u32 {
        \\    switch maybe { p => { return ptr_value(p); }, _ => { return 0; }, }
        \\}
        \\fn nullable_switch_call_seed() -> u32 {
        \\    switch maybe_ptr_from(next_seed()) { p => { return ptr_value(p); }, _ => { return 0; }, }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_variant_control.mc", source, &output);

    try expectContains(output.items, "DEFAULT_NULL = NULL;");
    try expectContains(output.items, "saved_nullable = NULL;");

    const call = try cFunctionBody(output.items, "static uint32_t unwrap_call_or_zero(void)");
    try expectContains(call, "/* canonical executable MIR */");
    try expectContains(call, "= maybe_ptr();");
    try expectContains(call, "!= NULL");
    try expectContains(call, "= ptr_value(");
    try expectContains(call, "return mc_exec_tmp_");

    const global = try cFunctionBody(output.items, "static uint32_t unwrap_global_or_zero(void)");
    try expectContains(global, "__atomic_load_n(&saved_nullable, __ATOMIC_RELAXED)");
    try expectContains(global, "= ptr_value(");
    try expectContains(global, "return mc_exec_tmp_");

    const field = try cFunctionBody(output.items, "unwrap_field_or_zero(");
    try expectContains(field, ".maybe;");
    try expectContains(field, "ptr_value(");

    const switched = try cFunctionBody(output.items, "static uint32_t nullable_switch(uint8_t * maybe)");
    try expectContains(switched, "= maybe;");
    try expectContains(switched, "if (mc_exec_tmp_");
    try expectContains(switched, "uint8_t * p = mc_exec_tmp_");
    try expectContains(switched, "return mc_exec_tmp_");

    const seeded = try cFunctionBody(output.items, "static uint32_t nullable_switch_call_seed(void)");
    const seed = std.mem.indexOf(u8, seeded, "= next_seed();") orelse return error.TestUnexpectedResult;
    const nullable = std.mem.indexOfPos(u8, seeded, seed, "= maybe_ptr_from(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(seed < nullable);
    try expectContains(seeded, "= ptr_value(");
    try expectContains(seeded, "return mc_exec_tmp_");
}

test "lower-c emits scalar CFG plans from MIR without body fallback" {
    const source =
        \\fn adjust(n: u32, flag: bool) -> u32 {
        \\    var x: u32 = n;
        \\    if flag { x = x + 1; } else { x = x - 1; }
        \\    return x;
        \\}
        \\fn maybe_inc(n: u32, flag: bool) -> u32 {
        \\    var x: u32 = n;
        \\    if flag { x = x + 1; }
        \\    return x;
        \\}
        \\fn count_down(n: u32) -> u32 {
        \\    var x: u32 = n;
        \\    while x != 0 { x = x - 1; }
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_scalar_cfg.mc", source, &output);

    const adjust = try cFunctionBody(output.items, "static uint32_t adjust(uint32_t n, bool flag)");
    if (isCanonicalExecutableCBody(adjust)) {
        try expectContains(adjust, "uint32_t x = mc_exec_tmp_");
        try expectContains(adjust, "mc_checked_add_u32(");
        try expectContains(adjust, "mc_checked_sub_u32(");
        try expectContains(adjust, "return mc_exec_tmp_");
    } else {
        try expectContains(adjust, "uint32_t x = n;");
        try expectContains(adjust, "if (flag) {");
        try expectContains(adjust, "x = mc_checked_add_u32(x, 1);");
        try expectContains(adjust, "x = mc_checked_sub_u32(x, 1);");
        try expectContains(adjust, "return x;");
    }

    const maybe_inc = try cFunctionBody(output.items, "static uint32_t maybe_inc(uint32_t n, bool flag)");
    if (isCanonicalExecutableCBody(maybe_inc)) {
        try expectContains(maybe_inc, "mc_checked_add_u32(");
        try expectContains(maybe_inc, "return mc_exec_tmp_");
    } else {
        try expectContains(maybe_inc, "if (flag) {");
        try expectContains(maybe_inc, "x = mc_checked_add_u32(x, 1);");
        try expectNotContains(maybe_inc, "} else {");
        try expectContains(maybe_inc, "return x;");
    }

    const count_down = try cFunctionBody(output.items, "static uint32_t count_down(uint32_t n)");
    try expectLegacyOrCanonicalLoop(count_down, "while (x != 0) {");
    try expectContains(count_down, "mc_checked_sub_u32(");
    try expectContains(count_down, if (isCanonicalExecutableCBody(count_down)) "return mc_exec_tmp_" else "return x;");
}

test "lower-c emits nullable binding and checked fallback return from MIR without body fallback" {
    const source =
        \\fn unwrap_or(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
        \\    if let p = maybe {
        \\        return p;
        \\    }
        \\    return fallback;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var parsed = try test_support.parseCheckedModule("c_mir_nullable_binding_fallback.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expect(module_mir.functions[0].executable_body.isComplete());
    try mir_executable_body.verify(&module_mir.functions[0]);
    try appendCheckedCTestWithMir("c_mir_nullable_binding_fallback.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint8_t * unwrap_or(uint8_t * maybe, uint8_t * fallback)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "= maybe;");
    try expectContains(body, "!= NULL");
    try expectContains(body, "uint8_t * p = mc_exec_tmp_");
    try expectContains(body, "if (mc_exec_tmp_");
    try expectContains(body, "== NULL) mc_trap_InvalidRepresentation();");
    try expectContains(body, "return mc_exec_tmp_");
}

test "lower-c canonical executable MIR preserves high-word typing and flag-set order" {
    const source =
        \\extern fn read_word(addr: usize) -> u64;
        \\fn high_word(v: u64) -> u32 {
        \\    let hi: u32 = (v >> 32) as u32;
        \\    return hi + 1;
        \\}
        \\fn flag_set(addr: usize, mask: u64) -> bool {
        \\    return (read_word(addr) & mask) != 0;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_canonical_scalar_expressions.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expect(module_mir.functions[1].executable_body.isComplete());
    try std.testing.expect(module_mir.functions[2].executable_body.isComplete());

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_canonical_scalar_expressions.mc", .{}, false, null);

    const high = try cFunctionBody(output.items, "static uint32_t high_word(uint64_t v)");
    try expectContains(high, "/* canonical executable MIR */");
    try expectContains(high, "mc_checked_shr_u64(");
    try expectContains(high, "uint32_t hi = ");
    try expectContains(high, "mc_checked_add_u32(");
    const shift = std.mem.indexOf(u8, high, "mc_checked_shr_u64") orelse return error.TestUnexpectedResult;
    const add = std.mem.indexOf(u8, high, "mc_checked_add_u32") orelse return error.TestUnexpectedResult;
    try std.testing.expect(shift < add);

    const flag = try cFunctionBody(output.items, "static bool flag_set(uintptr_t addr, uint64_t mask)");
    const call = std.mem.indexOf(u8, flag, "read_word(") orelse return error.TestUnexpectedResult;
    const and_ = std.mem.indexOf(u8, flag, " & ") orelse return error.TestUnexpectedResult;
    const compare = std.mem.indexOf(u8, flag, " != ") orelse return error.TestUnexpectedResult;
    try std.testing.expect(call < and_ and and_ < compare);
}

test "lower-c emits nested classify conditional return from MIR without body fallback" {
    const source =
        \\fn classify(x: u32, flag: bool) -> u32 {
        \\    if !flag {
        \\        return 5;
        \\    } else if x > 10 {
        \\        return 6;
        \\    } else {
        \\        return 7;
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("bool_switch.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "bool_switch.mc", .{}, false, null);

    const body = try cFunctionBody(output.items, "static uint32_t classify(uint32_t x, bool flag)");
    try expectCanonicalConditional(body);
    try expectContains(body, " = 5;");
    try expectContains(body, " > ");
    try expectContains(body, " = 6;");
    try expectContains(body, " = 7;");
}

test "lower-c emits aggregate assignment sequences from canonical MIR" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\struct Bag { values: [4]u32, tail: []const u32 }
        \\global matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
        \\extern fn consume_row(row: [2]u32) -> u32;
        \\extern fn make_values(seed: u32) -> [4]u32;
        \\extern fn make_tail(seed: u32) -> []const u32;
        \\fn consume_pair(pair: Pair) -> u32 { return pair.left + pair.right; }
        \\fn aggregate_call_after_assignment() -> u32 {
        \\    var row: [2]u32 = uninit;
        \\    row = matrix[0];
        \\    var pair: Pair = uninit;
        \\    pair = .{ .left = 71, .right = 72 };
        \\    return consume_row(row) + consume_pair(pair);
        \\}
        \\fn make_bag(seed: u32) -> Bag {
        \\    return .{ .values = make_values(seed), .tail = make_tail(seed) };
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_canonical_aggregate_assignment.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try std.testing.expect(module_mir.functions[5].executable_body.isComplete());
    try std.testing.expect(module_mir.functions[6].executable_body.isComplete());
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_canonical_aggregate_assignment.mc", .{}, false, null);
    const sequence = try cFunctionBody(output.items, "static uint32_t aggregate_call_after_assignment(void)");
    try expectContains(sequence, "/* canonical executable MIR */");
    try expectContains(sequence, "row;");
    try expectContains(sequence, "(matrix).elems[mc_check_index_usize(");
    try expectContains(sequence, ", 2)]");
    try expectContains(sequence, "pair = mc_exec_tmp_");
    const row_call = std.mem.indexOf(u8, sequence, "= consume_row(mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    const pair_call = std.mem.indexOf(u8, sequence, "= consume_pair(mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    const add = std.mem.indexOf(u8, sequence, "mc_checked_add_u32") orelse return error.TestUnexpectedResult;
    try std.testing.expect(row_call < pair_call and pair_call < add);
    const bag = try cFunctionBody(output.items, "static Bag make_bag(uint32_t seed)");
    try expectContains(bag, "/* canonical executable MIR */");
    const values = std.mem.indexOf(u8, bag, "= make_values(") orelse return error.TestUnexpectedResult;
    const tail = std.mem.indexOf(u8, bag, "= make_tail(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(values < tail);
    try expectContains(bag, "mc_trap_InvalidRepresentation();");
    try expectContains(bag, "(Bag){ mc_exec_tmp_");
    try expectContains(bag, "return mc_exec_tmp_");
}

test "lower-c emits canonical local workflows without body fallback" {
    const source =
        \\struct BinOp { combine: fn(u32, u32) -> u32 }
        \\struct Env { value: u32 }
        \\fn mul(a: u32, b: u32) -> u32 { return a * b; }
        \\fn dispatch(o: *BinOp, x: u32, y: u32) -> u32 { return o.combine(x, y); }
        \\extern fn consume_u32(value: u32) -> void;
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\fn store_value(env: *mut Env, value: u32) -> void { env.value = value; }
        \\fn local_vtable_call(x: u32, y: u32) -> u32 {
        \\    var op: BinOp = .{ .combine = mul };
        \\    return dispatch(&op, x, y);
        \\}
        \\fn scoped_block(value: u32) -> u32 {
        \\    var out: u32 = value;
        \\    { let inner: u32 = combine(value, 1); consume_u32(inner); }
        \\    return out;
        \\}
        \\fn call_closure(value: u32) -> void {
        \\    var env: Env = .{ .value = 0 };
        \\    let set: closure(u32) -> void = bind(&env, store_value);
        \\    set(value);
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_mir_workflow.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mir_workflow.mc", .{}, false, null);
    const vtable = try cFunctionBody(output.items, "static uint32_t local_vtable_call(uint32_t x, uint32_t y)");
    try std.testing.expect(isCanonicalExecutableCBody(vtable));
    try expectContains(vtable, "(BinOp){ mul }");
    try expectContains(vtable, "dispatch(");
    const scoped = try cFunctionBody(output.items, "static uint32_t scoped_block(uint32_t value)");
    try std.testing.expect(isCanonicalExecutableCBody(scoped));
    try expectContains(scoped, "combine(");
    try expectContains(scoped, "consume_u32(");
    try expectContains(scoped, "return mc_exec_tmp_");
    const closure = try cFunctionBody(output.items, "static void call_closure(uint32_t value)");
    try std.testing.expect(isCanonicalExecutableCBody(closure));
    try expectContains(closure, "Env env =");
    try expectContains(closure, ".code = (");
    try expectContains(closure, "store_value, .env = (void *)");
    try expectContains(closure, ").code((");

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "workflow.c", .data = output.items });
    const generated_c = try temp.dir.realPathFileAlloc(std.testing.io, "workflow.c", std.testing.allocator);
    defer std.testing.allocator.free(generated_c);
    const clang = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "clang", "-fsyntax-only", generated_c },
    });
    defer std.testing.allocator.free(clang.stdout);
    defer std.testing.allocator.free(clang.stderr);
    try std.testing.expect(clang.term == .exited and clang.term.exited == 0);
}

test "lower-c emits loop-local array through canonical MIR without body fallback" {
    const source =
        \\const ITERS: u32 = 16;
        \\const BUF: usize = 256;
        \\export fn alloca_hoist_run() -> u32 {
        \\    var sum: u32 = 0;
        \\    var i: u32 = 0;
        \\    while i < ITERS {
        \\        var scratch: [BUF]u8 = uninit;
        \\        let slot: usize = (i as usize) % BUF;
        \\        scratch[slot] = (i & 0xFF) as u8;
        \\        sum = sum + (scratch[slot] as u32);
        \\        i = i + 1;
        \\    }
        \\    return sum;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_mir_alloca_hoist.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mir_alloca_hoist.mc", .{}, false, null);
    const body = try cFunctionBody(output.items, "uint32_t alloca_hoist_run(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "mc_array_u8_256 scratch;");
    try expectContains(body, "mc_checked_mod_usize");
    try expectContains(body, "mc_check_index_usize");
    try expectContains(body, "mc_checked_add_u32");

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var probe_source: std.ArrayList(u8) = .empty;
    defer probe_source.deinit(std.testing.allocator);
    try probe_source.appendSlice(std.testing.allocator, output.items);
    try probe_source.appendSlice(std.testing.allocator, "\nint main(void) { return alloca_hoist_run() == 120 ? 0 : 1; }\n");
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "alloca_hoist.c", .data = probe_source.items });
    const generated_c = try temp.dir.realPathFileAlloc(std.testing.io, "alloca_hoist.c", std.testing.allocator);
    defer std.testing.allocator.free(generated_c);
    const clang = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "clang", "-fsyntax-only", generated_c } });
    defer std.testing.allocator.free(clang.stdout);
    defer std.testing.allocator.free(clang.stderr);
    try std.testing.expect(clang.term == .exited and clang.term.exited == 0);
    const compile_probe = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "clang", "alloca_hoist.c", "-o", "alloca_probe" }, .cwd = .{ .dir = temp.dir } });
    defer std.testing.allocator.free(compile_probe.stdout);
    defer std.testing.allocator.free(compile_probe.stderr);
    try std.testing.expect(compile_probe.term == .exited and compile_probe.term.exited == 0);
    const probe = try temp.dir.realPathFileAlloc(std.testing.io, "alloca_probe", std.testing.allocator);
    defer std.testing.allocator.free(probe);
    const run_probe = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{probe} });
    defer std.testing.allocator.free(run_probe.stdout);
    defer std.testing.allocator.free(run_probe.stderr);
    try std.testing.expect(run_probe.term == .exited and run_probe.term.exited == 0);
}

test "lower-c emits access slice plans without body fallback" {
    const source =
        \\extern fn make_slice() -> []const u32;
        \\fn read_slice(xs: []const u32, i: usize) -> u32 { return xs[i]; }
        \\fn read_literal(xs: []const u32) -> u32 { return xs[0]; }
        \\fn write_slice(xs: []mut u32, i: usize, value: u32) -> void { xs[i] = value; return; }
        \\fn direct_call_slice(i: usize) -> u32 { return make_slice()[i]; }
    ;
    var parsed = try test_support.parseCheckedModule("c_mir_access_slice.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mir_access_slice.mc", .{}, false, null);
    const read_slice = try cFunctionBody(output.items, "static uint32_t read_slice(");
    try expectContains(read_slice, "/* canonical executable MIR */");
    try expectContains(read_slice, "mc_race_load_u32");
    try expectContains(read_slice, "mc_check_index_usize(");
    const read_literal = try cFunctionBody(output.items, "static uint32_t read_literal(");
    try expectContains(read_literal, "/* canonical executable MIR */");
    try expectContains(read_literal, "mc_race_load_u32");
    try expectContains(read_literal, "mc_check_index_usize(");
    try expectContains(try cFunctionBody(output.items, "static void write_slice("), "mc_race_store_u32");
    try expectContains(try cFunctionBody(output.items, "static void write_slice("), "(uint32_t)");
    try expectContains(try cFunctionBody(output.items, "static uint32_t direct_call_slice("), "= make_slice();");
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "access_slice.c", .data = output.items });
    const generated_c = try temp.dir.realPathFileAlloc(std.testing.io, "access_slice.c", std.testing.allocator);
    defer std.testing.allocator.free(generated_c);
    const clang = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "clang", "-fsyntax-only", generated_c } });
    defer std.testing.allocator.free(clang.stdout);
    defer std.testing.allocator.free(clang.stderr);
    try std.testing.expect(clang.term == .exited and clang.term.exited == 0);
}

test "lower-c emits local address update from MIR without body fallback" {
    const source =
        \\fn update(seed: u32) -> u32 {
        \\    var value: u32 = seed;
        \\    let pointer: *mut u32 = &value;
        \\    *pointer = value + 1;
        \\    return value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_address_update.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t update(uint32_t seed)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "uint32_t value = mc_exec_tmp_");
    try expectContains(body, "uint32_t * pointer = mc_exec_tmp_");
    try expectContains(body, "mc_checked_add_u32(");
    try expectContains(body, "if (pointer == NULL) mc_trap_InvalidRepresentation();");
    try expectContains(body, "(*(pointer)) = mc_exec_tmp_");
    try expectContains(body, "return mc_exec_tmp_");
}

test "lower-c emits the structural access tail from MIR without body fallback" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\global pair: Pair = .{ .left = 1, .right = 2 };
        \\global shared: u32 = 7;
        \\global shared_ptr: *mut u32 = &shared;
        \\fn address_global_field(value: u32) -> u32 { let p: *mut u32 = &pair.right; *p = value; return pair.right; }
        \\fn address_array_element(value: u32) -> u32 { var xs: [2]u32 = .{ 3, 4 }; let p: *mut u32 = &xs[1]; *p = value; return xs[1]; }
        \\fn address_field(value: u32) -> u32 { var pair_local: Pair = .{ .left = 5, .right = 6 }; let p: *mut u32 = &pair_local.right; *p = value; return pair_local.right; }
        \\fn write_through_global_pointer(value: u32) -> u32 { *shared_ptr = value; return shared; }
        \\fn slice_from_slice(xs: []const u8, lo: usize, hi: usize) -> usize { let s: []const u8 = xs[lo..hi]; return s.len; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_structural_access_tail.mc", source, &output);

    const global_field = try cFunctionBody(output.items, "static uint32_t address_global_field(uint32_t value)");
    try expectContains(global_field, "mc_race_store_u32");
    try expectContains(global_field, "mc_race_load_u32(&((pair).right))");

    const array_element = try cFunctionBody(output.items, "static uint32_t address_array_element(uint32_t value)");
    try expectContains(array_element, "(*(p)) =");
    try expectContains(array_element, ").elems[mc_check_index_usize(");

    const local_field = try cFunctionBody(output.items, "static uint32_t address_field(uint32_t value)");
    try expectContains(local_field, "(*(p)) =");
    try expectContains(local_field, "(pair_local).right");

    const global_pointer = try cFunctionBody(output.items, "static uint32_t write_through_global_pointer(uint32_t value)");
    try expectContains(global_pointer, "mc_race_store_u32");
    try expectContains(global_pointer, "shared");

    const slice = try cFunctionBody(output.items, "static uintptr_t slice_from_slice(");
    try expectContains(slice, "mc_trap_Bounds();");
    try expectContains(slice, "return mc_exec_tmp_");

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "structural_access_tail.c", .data = output.items });
    const generated_c = try temp.dir.realPathFileAlloc(std.testing.io, "structural_access_tail.c", std.testing.allocator);
    defer std.testing.allocator.free(generated_c);
    const clang = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &.{ "clang", "-fsyntax-only", generated_c } });
    defer std.testing.allocator.free(clang.stdout);
    defer std.testing.allocator.free(clang.stderr);
    try std.testing.expect(clang.term == .exited and clang.term.exited == 0);
}

test "lower-c nullable narrowing with long identifiers never falls back to constants" {
    var long_name: std.ArrayList(u8) = .empty;
    defer long_name.deinit(std.testing.allocator);
    try long_name.appendSlice(std.testing.allocator, "nullable_subject_");
    for (0..320) |_| try long_name.append(std.testing.allocator, 'x');

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.print(std.testing.allocator,
        \\fn maybe_u32(x: u32) -> ?u32 {{
        \\    if x > 0 {{ return x; }}
        \\    return null;
        \\}}
        \\fn long_iflet() -> u32 {{
        \\    let {s}: ?u32 = maybe_u32(3);
        \\    if let value = {s} {{ return value; }}
        \\    return 0;
        \\}}
        \\fn long_switch() -> u32 {{
        \\    let {s}: ?u32 = maybe_u32(4);
        \\    switch {s} {{
        \\        value => {{ return value; }},
        \\        _ => {{ return 0; }},
        \\    }}
        \\}}
        \\
    , .{ long_name.items, long_name.items, long_name.items, long_name.items });

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_long_nullable_identifier.mc", source.items, &output);
    const iflet_body = try cFunctionBody(output.items, "static uint32_t long_iflet(void)");
    const switch_body = try cFunctionBody(output.items, "static uint32_t long_switch(void)");
    try expectContains(iflet_body, "/* canonical executable MIR */");
    try expectContains(iflet_body, ".present");
    try expectContains(iflet_body, ".value");
    try expectContains(switch_body, "/* canonical executable MIR */");
    try expectContains(switch_body, ".present");
    try expectContains(switch_body, ".value");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (0)") == null);
}

test "lower-c MIR conditional fast path uses only the switch subject expression" {
    const source =
        \\global g: u32 = 0;
        \\extern fn hit(value: u32) -> void;
        \\fn choose_cmp(a: i32, b: i32) -> i32 {
        \\    if (a < b) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_not(flag: bool) -> i32 {
        \\    if (!flag) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_local(a: i32, b: i32) -> i32 {
        \\    var c: bool = a < b;
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_local_not(flag: bool) -> i32 {
        \\    var c: bool = !flag;
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_reassign(a: i32, b: i32) -> i32 {
        \\    var c: bool = a < b;
        \\    c = false;
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_early(flag: bool) -> i32 {
        \\    if (flag) {
        \\        return 1;
        \\    }
        \\    return 0;
        \\}
        \\fn choose_branch_local_return(flag: bool) -> i32 {
        \\    if (flag) {
        \\        let x: i32 = 1;
        \\        return x;
        \\    } else {
        \\        var y: i32 = 0;
        \\        y = 2;
        \\        return y;
        \\    }
        \\}
        \\fn choose_literal_local_condition() -> i32 {
        \\    var c: bool = false;
        \\    if (c) {
        \\        return 1;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\fn choose_store_then_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    return x;
        \\}
        \\fn choose_call_then_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        hit(x);
        \\    }
        \\    return x;
        \\}
        \\fn choose_store_suffix_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    hit(x);
        \\    return x;
        \\}
        \\fn choose_call_suffix_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        hit(x);
        \\    }
        \\    g = x;
        \\    return x;
        \\}
        \\fn choose_empty_suffix_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\    }
        \\    g = x;
        \\    return x;
        \\}
        \\fn choose_empty_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\    }
        \\    return x;
        \\}
        \\fn loop_empty_return(flag: bool, x: u32) -> u32 {
        \\    while flag {
        \\    }
        \\    return x;
        \\}
        \\fn loop_call_return(flag: bool, x: u32) -> u32 {
        \\    while flag {
        \\        hit(x);
        \\    }
        \\    return x;
        \\}
        \\fn loop_cmp_return(a: i32, b: i32, x: u32) -> u32 {
        \\    while a < b {
        \\        hit(x);
        \\    }
        \\    return x;
        \\}
        \\fn choose_branch_effect_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        hit(x);
        \\        return 1;
        \\    } else {
        \\        g = x;
        \\        return 2;
        \\    }
        \\}
        \\fn choose_mixed_branch_effect_return(flag: bool, x: u32) -> u32 {
        \\    if (flag) {
        \\        hit(x);
        \\        return 1;
        \\    }
        \\    g = x;
        \\    return 2;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conditional_subject.mc", source, &output);

    const compare_body = try cFunctionBody(output.items, "static int32_t choose_cmp(int32_t a, int32_t b)");
    try expectCanonicalConditional(compare_body);
    try expectContains(compare_body, " < ");

    const not_body = try cFunctionBody(output.items, "static int32_t choose_not(bool flag)");
    try expectCanonicalConditional(not_body);
    try expectContains(not_body, "(!");

    const local_body = try cFunctionBody(output.items, "static int32_t choose_local(int32_t a, int32_t b)");
    try expectCanonicalConditional(local_body);
    try expectContains(local_body, " < ");
    try expectNotContains(local_body, "bool c = (a < b);");

    const local_not_body = try cFunctionBody(output.items, "static int32_t choose_local_not(bool flag)");
    try expectCanonicalConditional(local_not_body);
    try expectContains(local_not_body, "(!");
    try expectNotContains(local_not_body, "bool c = !flag;");

    const reassign_body = try cFunctionBody(output.items, "static int32_t choose_reassign(int32_t a, int32_t b)");
    try expectCanonicalConditional(reassign_body);
    try expectContains(reassign_body, " = false;");
    try expectContains(reassign_body, " = 1;");
    try expectContains(reassign_body, " = 0;");
    try expectContains(reassign_body, "bool c = mc_exec_tmp_");
    try expectContains(reassign_body, "c = mc_exec_tmp_");
    try expectNotContains(reassign_body, "switch");

    const early_body = try cFunctionBody(output.items, "static int32_t choose_early(bool flag)");
    if (isCanonicalExecutableCBody(early_body)) {
        try expectContains(early_body, "if (mc_exec_tmp_");
        try expectContains(early_body, "goto mc_bb_");
        try expectContains(early_body, " = 1;");
        try expectContains(early_body, " = 0;");
        try expectContains(early_body, "return mc_exec_tmp_");
    } else {
        try expectContains(early_body, "if (flag)");
        try expectContains(early_body, "return 1;");
        try expectContains(early_body, "return 0;");
    }
    try expectNotContains(early_body, "switch");

    const branch_local_body = try cFunctionBody(output.items, "static int32_t choose_branch_local_return(bool flag)");
    if (isCanonicalExecutableCBody(branch_local_body)) {
        try expectCanonicalConditional(branch_local_body);
        try expectContains(branch_local_body, " = 1;");
        try expectContains(branch_local_body, " = 2;");
    } else {
        try expectContains(branch_local_body, "if (flag)");
        try expectContains(branch_local_body, "return 1;");
        try expectContains(branch_local_body, "return 2;");
        try expectNotContains(branch_local_body, "int32_t x");
        try expectNotContains(branch_local_body, "int32_t y");
        try expectNotContains(branch_local_body, "y =");
    }
    try expectNotContains(branch_local_body, "switch");

    const literal_body = try cFunctionBody(output.items, "static int32_t choose_literal_local_condition(void)");
    try expectCanonicalConditional(literal_body);
    try expectContains(literal_body, " = false;");
    try expectContains(literal_body, " = 1;");
    try expectContains(literal_body, " = 0;");
    try expectContains(literal_body, "bool c = mc_exec_tmp_");
    try expectNotContains(literal_body, "switch");

    const store_return_body = try cFunctionBody(output.items, "static uint32_t choose_store_then_return(bool flag, uint32_t x)");
    const store_if = std.mem.indexOf(u8, store_return_body, if (isCanonicalExecutableCBody(store_return_body)) "if (mc_exec_tmp_" else "if (flag)") orelse return error.TestUnexpectedResult;
    const store_stmt = std.mem.indexOf(u8, store_return_body, "mc_race_store_u32(&g, (uint32_t)") orelse return error.TestUnexpectedResult;
    const store_return = std.mem.indexOf(u8, store_return_body, if (isCanonicalExecutableCBody(store_return_body)) "return mc_exec_tmp_" else "return x;") orelse return error.TestUnexpectedResult;
    if (!isCanonicalExecutableCBody(store_return_body)) {
        try std.testing.expect(store_if < store_stmt);
        try std.testing.expect(store_stmt < store_return);
    }
    try expectNotContains(store_return_body, "switch");
    try expectNotContains(store_return_body, "mc_tmp");

    const call_return_body = try cFunctionBody(output.items, "static uint32_t choose_call_then_return(bool flag, uint32_t x)");
    if (isCanonicalExecutableCBody(call_return_body)) {
        try expectContains(call_return_body, "if (mc_exec_tmp_");
        try expectContains(call_return_body, "hit(");
        try expectContains(call_return_body, "return mc_exec_tmp_");
    } else {
        const call_if = std.mem.indexOf(u8, call_return_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const call_stmt = std.mem.indexOf(u8, call_return_body, "hit(x);") orelse return error.TestUnexpectedResult;
        const call_return = std.mem.indexOf(u8, call_return_body, "return x;") orelse return error.TestUnexpectedResult;
        try std.testing.expect(call_if < call_stmt);
        try std.testing.expect(call_stmt < call_return);
    }
    try expectNotContains(call_return_body, "switch");
    try expectNotContains(call_return_body, "mc_tmp");

    const store_suffix_return_body = try cFunctionBody(output.items, "static uint32_t choose_store_suffix_return(bool flag, uint32_t x)");
    if (isCanonicalExecutableCBody(store_suffix_return_body)) {
        try expectContains(store_suffix_return_body, "if (mc_exec_tmp_");
        try expectContains(store_suffix_return_body, "mc_race_store_u32(&g, (uint32_t)");
        try expectContains(store_suffix_return_body, "hit(");
        try expectContains(store_suffix_return_body, "return mc_exec_tmp_");
    } else {
        const store_suffix_if = std.mem.indexOf(u8, store_suffix_return_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const store_suffix_store = std.mem.indexOf(u8, store_suffix_return_body, "mc_race_store_u32(&g, (uint32_t)x);") orelse return error.TestUnexpectedResult;
        const store_suffix_call = std.mem.indexOf(u8, store_suffix_return_body, "hit(x);") orelse return error.TestUnexpectedResult;
        const store_suffix_return = std.mem.indexOf(u8, store_suffix_return_body, "return x;") orelse return error.TestUnexpectedResult;
        try std.testing.expect(store_suffix_if < store_suffix_store);
        try std.testing.expect(store_suffix_store < store_suffix_call);
        try std.testing.expect(store_suffix_call < store_suffix_return);
    }
    try expectNotContains(store_suffix_return_body, "switch");
    try expectNotContains(store_suffix_return_body, "mc_tmp");

    const call_suffix_return_body = try cFunctionBody(output.items, "static uint32_t choose_call_suffix_return(bool flag, uint32_t x)");
    if (isCanonicalExecutableCBody(call_suffix_return_body)) {
        try expectContains(call_suffix_return_body, "if (mc_exec_tmp_");
        try expectContains(call_suffix_return_body, "hit(");
        try expectContains(call_suffix_return_body, "mc_race_store_u32(&g, (uint32_t)");
        try expectContains(call_suffix_return_body, "return mc_exec_tmp_");
    } else {
        const call_suffix_if = std.mem.indexOf(u8, call_suffix_return_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const call_suffix_call = std.mem.indexOf(u8, call_suffix_return_body, "hit(x);") orelse return error.TestUnexpectedResult;
        const call_suffix_store = std.mem.indexOf(u8, call_suffix_return_body, "mc_race_store_u32(&g, (uint32_t)x);") orelse return error.TestUnexpectedResult;
        const call_suffix_return = std.mem.indexOf(u8, call_suffix_return_body, "return x;") orelse return error.TestUnexpectedResult;
        try std.testing.expect(call_suffix_if < call_suffix_call);
        try std.testing.expect(call_suffix_call < call_suffix_store);
        try std.testing.expect(call_suffix_store < call_suffix_return);
    }
    try expectNotContains(call_suffix_return_body, "switch");
    try expectNotContains(call_suffix_return_body, "mc_tmp");

    const empty_suffix_return_body = try cFunctionBody(output.items, "static uint32_t choose_empty_suffix_return(bool flag, uint32_t x)");
    if (isCanonicalExecutableCBody(empty_suffix_return_body)) {
        try expectContains(empty_suffix_return_body, "if (mc_exec_tmp_");
        try expectContains(empty_suffix_return_body, "mc_race_store_u32(&g, (uint32_t)");
        try expectContains(empty_suffix_return_body, "return mc_exec_tmp_");
    } else {
        const empty_suffix_if = std.mem.indexOf(u8, empty_suffix_return_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const empty_suffix_store = std.mem.indexOf(u8, empty_suffix_return_body, "mc_race_store_u32(&g, (uint32_t)x);") orelse return error.TestUnexpectedResult;
        const empty_suffix_return = std.mem.indexOf(u8, empty_suffix_return_body, "return x;") orelse return error.TestUnexpectedResult;
        try std.testing.expect(empty_suffix_if < empty_suffix_store);
        try std.testing.expect(empty_suffix_store < empty_suffix_return);
    }
    try expectNotContains(empty_suffix_return_body, "switch");
    try expectNotContains(empty_suffix_return_body, "mc_tmp");

    const empty_return_body = try cFunctionBody(output.items, "static uint32_t choose_empty_return(bool flag, uint32_t x)");
    if (isCanonicalExecutableCBody(empty_return_body)) {
        try expectContains(empty_return_body, "if (mc_exec_tmp_");
        try expectContains(empty_return_body, "return mc_exec_tmp_");
    } else {
        const empty_return_if = std.mem.indexOf(u8, empty_return_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const empty_return_stmt = std.mem.indexOf(u8, empty_return_body, "return x;") orelse return error.TestUnexpectedResult;
        try std.testing.expect(empty_return_if < empty_return_stmt);
    }
    try expectNotContains(empty_return_body, "switch");
    try expectNotContains(empty_return_body, "mc_tmp");

    const loop_empty_body = try cFunctionBody(output.items, "static uint32_t loop_empty_return(bool flag, uint32_t x)");
    try expectLegacyOrCanonicalLoop(loop_empty_body, "while (flag)");
    try expectLegacyOrCanonicalReturn(loop_empty_body, "return x;", " = x;");
    try expectNotContains(loop_empty_body, "switch");
    try expectNotContains(loop_empty_body, "mc_tmp");

    const loop_call_body = try cFunctionBody(output.items, "static uint32_t loop_call_return(bool flag, uint32_t x)");
    try expectLegacyOrCanonicalLoop(loop_call_body, "while (flag)");
    try expectContains(loop_call_body, "hit(");
    try expectLegacyOrCanonicalReturn(loop_call_body, "return x;", " = x;");
    try expectNotContains(loop_call_body, "switch");
    try expectNotContains(loop_call_body, "mc_tmp");

    const loop_cmp_return_body = try cFunctionBody(output.items, "static uint32_t loop_cmp_return(int32_t a, int32_t b, uint32_t x)");
    try expectLegacyOrCanonicalLoop(loop_cmp_return_body, "while ((a < b))");
    try expectContains(loop_cmp_return_body, "hit(");
    try expectLegacyOrCanonicalReturn(loop_cmp_return_body, "return x;", " = x;");
    try expectNotContains(loop_cmp_return_body, "switch");
    try expectNotContains(loop_cmp_return_body, "mc_tmp");

    const branch_effect_body = try cFunctionBody(output.items, "static uint32_t choose_branch_effect_return(bool flag, uint32_t x)");
    if (isCanonicalExecutableCBody(branch_effect_body)) {
        try expectContains(branch_effect_body, "if (mc_exec_tmp_");
        try expectContains(branch_effect_body, "hit(");
        try expectContains(branch_effect_body, "mc_race_store_u32(&g, (uint32_t)");
        try std.testing.expect(std.mem.count(u8, branch_effect_body, "return mc_exec_tmp_") >= 2);
    } else {
        const branch_effect_if = std.mem.indexOf(u8, branch_effect_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const branch_effect_call = std.mem.indexOf(u8, branch_effect_body, "hit(x);") orelse return error.TestUnexpectedResult;
        const branch_effect_return1 = std.mem.indexOf(u8, branch_effect_body, "return 1;") orelse return error.TestUnexpectedResult;
        const branch_effect_store = std.mem.indexOf(u8, branch_effect_body, "mc_race_store_u32(&g, (uint32_t)x);") orelse return error.TestUnexpectedResult;
        const branch_effect_return2 = std.mem.indexOf(u8, branch_effect_body, "return 2;") orelse return error.TestUnexpectedResult;
        try std.testing.expect(branch_effect_if < branch_effect_call);
        try std.testing.expect(branch_effect_call < branch_effect_return1);
        try std.testing.expect(branch_effect_return1 < branch_effect_store);
        try std.testing.expect(branch_effect_store < branch_effect_return2);
    }
    try expectNotContains(branch_effect_body, "switch");
    try expectNotContains(branch_effect_body, "mc_tmp");

    const mixed_branch_effect_body = try cFunctionBody(output.items, "static uint32_t choose_mixed_branch_effect_return(bool flag, uint32_t x)");
    if (isCanonicalExecutableCBody(mixed_branch_effect_body)) {
        try expectContains(mixed_branch_effect_body, "if (mc_exec_tmp_");
        try expectContains(mixed_branch_effect_body, "hit(");
        try expectContains(mixed_branch_effect_body, "mc_race_store_u32(&g, (uint32_t)");
        try std.testing.expect(std.mem.count(u8, mixed_branch_effect_body, "return mc_exec_tmp_") >= 2);
    } else {
        const mixed_branch_effect_if = std.mem.indexOf(u8, mixed_branch_effect_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const mixed_branch_effect_call = std.mem.indexOf(u8, mixed_branch_effect_body, "hit(x);") orelse return error.TestUnexpectedResult;
        const mixed_branch_effect_return1 = std.mem.indexOf(u8, mixed_branch_effect_body, "return 1;") orelse return error.TestUnexpectedResult;
        const mixed_branch_effect_store = std.mem.indexOf(u8, mixed_branch_effect_body, "mc_race_store_u32(&g, (uint32_t)x);") orelse return error.TestUnexpectedResult;
        const mixed_branch_effect_return2 = std.mem.indexOf(u8, mixed_branch_effect_body, "return 2;") orelse return error.TestUnexpectedResult;
        try std.testing.expect(mixed_branch_effect_if < mixed_branch_effect_call);
        try std.testing.expect(mixed_branch_effect_call < mixed_branch_effect_return1);
        try std.testing.expect(mixed_branch_effect_return1 < mixed_branch_effect_store);
        try std.testing.expect(mixed_branch_effect_store < mixed_branch_effect_return2);
    }
    try expectNotContains(mixed_branch_effect_body, "switch");
    try expectNotContains(mixed_branch_effect_body, "mc_tmp");
}

test "lower-c emits simple void conditional direct calls from MIR" {
    const source =
        \\global cg: i32 = 0;
        \\extern fn hit(value: i32) -> void;
        \\struct Flags { ok: bool }
        \\struct SignedPair { a: i32, b: i32 }
        \\fn choose_void(flag: bool) -> void {
        \\    if (flag) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\}
        \\fn choose_void_cmp(a: i32, b: i32) -> void {
        \\    if (a < b) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\}
        \\fn choose_void_sequence(flag: bool) -> void {
        \\    hit(9);
        \\    if (flag) {
        \\        hit(1);
        \\        hit(2);
        \\    } else {
        \\        hit(3);
        \\        hit(4);
        \\    }
        \\}
        \\fn choose_void_sequence_suffix(flag: bool) -> void {
        \\    hit(9);
        \\    if (flag) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\    hit(8);
        \\}
        \\fn choose_void_two_suffix(flag: bool, x: i32) -> void {
        \\    if (flag) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\    hit(x);
        \\    hit(x);
        \\}
        \\fn choose_void_suffix_store(flag: bool, x: i32) -> void {
        \\    if (flag) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\    cg = x;
        \\    hit(x);
        \\}
        \\fn choose_void_no_else(flag: bool) -> void {
        \\    if (flag) {
        \\        hit(5);
        \\        hit(6);
        \\    }
        \\}
        \\fn choose_void_local_args(flag: bool) -> void {
        \\    if (flag) {
        \\        let x: i32 = 1;
        \\        hit(x);
        \\    } else {
        \\        var y: i32 = 0;
        \\        y = 2;
        \\        hit(y);
        \\    }
        \\}
        \\fn choose_void_checked_args(flag: bool, a: i32, b: i32) -> void {
        \\    if (flag) {
        \\        hit(a + b);
        \\    } else {
        \\        hit(a - b);
        \\    }
        \\}
        \\fn choose_void_field_cond(f: Flags, p: SignedPair) -> void {
        \\    if f.ok {
        \\        hit(p.a);
        \\    } else {
        \\        hit(p.b);
        \\    }
        \\}
        \\fn choose_void_field_cond_not(f: Flags, p: SignedPair) -> void {
        \\    if !f.ok {
        \\        hit(p.a);
        \\    } else {
        \\        hit(p.b);
        \\    }
        \\}
        \\extern fn pred(value: i32) -> bool;
        \\fn choose_void_call_cond(a: i32) -> void {
        \\    if pred(a) {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\}
        \\fn choose_void_local_call_cond(a: i32) -> void {
        \\    let ok: bool = pred(a);
        \\    if ok {
        \\        hit(1);
        \\    } else {
        \\        hit(0);
        \\    }
        \\}
        \\extern fn hit_bool(value: bool) -> void;
        \\fn call_compare_arg(a: i32, b: i32) -> void {
        \\    hit_bool(a < b);
        \\}
        \\fn call_not_arg(flag: bool) -> void {
        \\    hit_bool(!flag);
        \\}
        \\fn loop_void(flag: bool) -> void {
        \\    while flag {
        \\        hit(7);
        \\    }
        \\}
        \\fn loop_void_not(flag: bool) -> void {
        \\    while !flag {
        \\        hit(8);
        \\    }
        \\}
        \\fn loop_void_cmp(a: i32, b: i32) -> void {
        \\    while a < b {
        \\        hit(a);
        \\    }
        \\}
        \\fn loop_void_field(f: Flags, p: SignedPair) -> void {
        \\    while f.ok {
        \\        hit(p.a);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_conditional_calls.mc", source, &output);

    const param_body = try cFunctionBody(output.items, "static void choose_void(bool flag)");
    if (isCanonicalExecutableCBody(param_body)) try expectCanonicalConditional(param_body) else try expectContains(param_body, "if (flag)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, param_body, "hit("));
    try expectNotContains(param_body, "switch");

    const compare_body = try cFunctionBody(output.items, "static void choose_void_cmp(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(compare_body)) try expectCanonicalConditional(compare_body) else try expectContains(compare_body, "if ((a < b))");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, compare_body, "hit("));
    try expectNotContains(compare_body, "switch");

    const sequence_body = try cFunctionBody(output.items, "static void choose_void_sequence(bool flag)");
    if (isCanonicalExecutableCBody(sequence_body)) try expectCanonicalConditional(sequence_body) else try expectContains(sequence_body, "if (flag)");
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, sequence_body, "hit("));
    try expectNotContains(sequence_body, "switch");

    const suffix_body = try cFunctionBody(output.items, "static void choose_void_sequence_suffix(bool flag)");
    if (isCanonicalExecutableCBody(suffix_body)) {
        try expectCanonicalConditional(suffix_body);
        try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, suffix_body, "hit("));
    } else {
        const prefix_index = std.mem.indexOf(u8, suffix_body, "hit(9);") orelse return error.TestUnexpectedResult;
        const suffix_if_index = std.mem.indexOf(u8, suffix_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const then_call_index = std.mem.indexOf(u8, suffix_body, "hit(1);") orelse return error.TestUnexpectedResult;
        const else_call_index = std.mem.indexOf(u8, suffix_body, "hit(0);") orelse return error.TestUnexpectedResult;
        const suffix_index = std.mem.indexOf(u8, suffix_body, "hit(8);") orelse return error.TestUnexpectedResult;
        try std.testing.expect(prefix_index < suffix_if_index);
        try std.testing.expect(suffix_if_index < then_call_index);
        try std.testing.expect(then_call_index < suffix_index);
        try std.testing.expect(else_call_index < suffix_index);
    }
    try expectNotContains(suffix_body, "switch");
    try expectNotContains(suffix_body, "mc_tmp");

    const two_suffix_body = try cFunctionBody(output.items, "static void choose_void_two_suffix(bool flag, int32_t x)");
    if (isCanonicalExecutableCBody(two_suffix_body)) {
        try expectCanonicalConditional(two_suffix_body);
        try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, two_suffix_body, "hit("));
    } else {
        const two_suffix_if = std.mem.indexOf(u8, two_suffix_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const two_suffix_then = std.mem.indexOf(u8, two_suffix_body, "hit(1);") orelse return error.TestUnexpectedResult;
        const two_suffix_else = std.mem.indexOf(u8, two_suffix_body, "hit(0);") orelse return error.TestUnexpectedResult;
        const two_suffix_first = std.mem.indexOf(u8, two_suffix_body, "hit(x);") orelse return error.TestUnexpectedResult;
        const two_suffix_second = std.mem.lastIndexOf(u8, two_suffix_body, "hit(x);") orelse return error.TestUnexpectedResult;
        try std.testing.expect(two_suffix_if < two_suffix_then);
        try std.testing.expect(two_suffix_then < two_suffix_first);
        try std.testing.expect(two_suffix_else < two_suffix_first);
        try std.testing.expect(two_suffix_first < two_suffix_second);
    }
    try expectNotContains(two_suffix_body, "switch");
    try expectNotContains(two_suffix_body, "mc_tmp");

    const suffix_store_body = try cFunctionBody(output.items, "static void choose_void_suffix_store(bool flag, int32_t x)");
    if (isCanonicalExecutableCBody(suffix_store_body)) {
        try expectCanonicalConditional(suffix_store_body);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, suffix_store_body, "hit("));
        try expectContains(suffix_store_body, "mc_race_store_i32(");
    } else {
        const suffix_store_if = std.mem.indexOf(u8, suffix_store_body, "if (flag)") orelse return error.TestUnexpectedResult;
        const suffix_store_then = std.mem.indexOf(u8, suffix_store_body, "hit(1);") orelse return error.TestUnexpectedResult;
        const suffix_store_else = std.mem.indexOf(u8, suffix_store_body, "hit(0);") orelse return error.TestUnexpectedResult;
        const suffix_store = std.mem.indexOf(u8, suffix_store_body, "mc_race_store_i32(&cg, (int32_t)x);") orelse return error.TestUnexpectedResult;
        const suffix_store_call = std.mem.indexOf(u8, suffix_store_body, "hit(x);") orelse return error.TestUnexpectedResult;
        try std.testing.expect(suffix_store_if < suffix_store_then);
        try std.testing.expect(suffix_store_then < suffix_store);
        try std.testing.expect(suffix_store_else < suffix_store);
        try std.testing.expect(suffix_store < suffix_store_call);
    }
    try expectNotContains(suffix_store_body, "switch");
    try expectNotContains(suffix_store_body, "mc_tmp");

    const no_else_body = try cFunctionBody(output.items, "static void choose_void_no_else(bool flag)");
    if (isCanonicalExecutableCBody(no_else_body)) try expectCanonicalConditional(no_else_body) else try expectContains(no_else_body, "if (flag)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, no_else_body, "hit("));
    try expectNotContains(no_else_body, "switch");
    try expectNotContains(no_else_body, "mc_tmp");

    const local_args_body = try cFunctionBody(output.items, "static void choose_void_local_args(bool flag)");
    try expectContains(local_args_body, if (isCanonicalExecutableCBody(local_args_body)) "if (mc_exec_tmp_" else "if (flag)");
    try expectContains(local_args_body, "hit(");
    if (!isCanonicalExecutableCBody(local_args_body)) {
        try expectContains(local_args_body, "hit(1);");
        try expectContains(local_args_body, "hit(2);");
        try expectNotContains(local_args_body, "int32_t x");
        try expectNotContains(local_args_body, "int32_t y");
        try expectNotContains(local_args_body, "y =");
    }
    try expectNotContains(local_args_body, "switch");

    const checked_args_body = try cFunctionBody(output.items, "static void choose_void_checked_args(bool flag, int32_t a, int32_t b)");
    try expectContains(checked_args_body, if (isCanonicalExecutableCBody(checked_args_body)) "if (mc_exec_tmp_" else "if (flag)");
    if (isCanonicalExecutableCBody(checked_args_body)) {
        try expectNeedlesInOrder(checked_args_body, &.{ "mc_checked_add_i32(", "hit(" });
        try expectNeedlesInOrder(checked_args_body, &.{ "mc_checked_sub_i32(", "hit(" });
    } else {
        try expectContains(checked_args_body, "hit(mc_checked_add_i32(a, b));");
        try expectContains(checked_args_body, "hit(mc_checked_sub_i32(a, b));");
    }
    try expectNotContains(checked_args_body, "mc_tmp");
    try expectNotContains(checked_args_body, "switch");

    const field_cond_body = try cFunctionBody(output.items, "static void choose_void_field_cond(Flags f, SignedPair p)");
    if (isCanonicalExecutableCBody(field_cond_body)) {
        try expectContains(field_cond_body, ").ok;");
        try expectContains(field_cond_body, ").a;");
        try expectContains(field_cond_body, ").b;");
        try expectContains(field_cond_body, "if (mc_exec_tmp_");
        try expectContains(field_cond_body, "hit(mc_exec_tmp_");
    } else {
        try expectContains(field_cond_body, "if (f.ok)");
        try expectContains(field_cond_body, "hit(p.a);");
        try expectContains(field_cond_body, "hit(p.b);");
    }
    try expectNotContains(field_cond_body, "switch");
    try expectNotContains(field_cond_body, "mc_tmp");

    const field_cond_not_body = try cFunctionBody(output.items, "static void choose_void_field_cond_not(Flags f, SignedPair p)");
    if (isCanonicalExecutableCBody(field_cond_not_body)) {
        try expectContains(field_cond_not_body, ").ok;");
        try expectContains(field_cond_not_body, ").a;");
        try expectContains(field_cond_not_body, ").b;");
        try expectContains(field_cond_not_body, "!mc_exec_tmp_");
        try expectContains(field_cond_not_body, "hit(mc_exec_tmp_");
    } else {
        try expectContains(field_cond_not_body, "if (!f.ok)");
        try expectContains(field_cond_not_body, "hit(p.a);");
        try expectContains(field_cond_not_body, "hit(p.b);");
    }
    try expectNotContains(field_cond_not_body, "switch");
    try expectNotContains(field_cond_not_body, "mc_tmp");

    const call_cond_body = try cFunctionBody(output.items, "static void choose_void_call_cond(int32_t a)");
    if (isCanonicalExecutableCBody(call_cond_body)) try expectCanonicalConditional(call_cond_body) else try expectContains(call_cond_body, "if (pred(a))");
    try expectContains(call_cond_body, "pred(");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, call_cond_body, "hit("));
    try expectNotContains(call_cond_body, "switch");
    try expectNotContains(call_cond_body, "mc_tmp");

    const local_call_cond_body = try cFunctionBody(output.items, "static void choose_void_local_call_cond(int32_t a)");
    if (isCanonicalExecutableCBody(local_call_cond_body)) try expectCanonicalConditional(local_call_cond_body) else try expectContains(local_call_cond_body, "if (pred(a))");
    try expectContains(local_call_cond_body, "pred(");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, local_call_cond_body, "hit("));
    if (!isCanonicalExecutableCBody(local_call_cond_body)) try expectNotContains(local_call_cond_body, "bool ok");
    try expectNotContains(local_call_cond_body, "switch");
    try expectNotContains(local_call_cond_body, "mc_tmp");

    const compare_arg_body = try cFunctionBody(output.items, "static void call_compare_arg(int32_t a, int32_t b)");
    try expectContains(compare_arg_body, if (isCanonicalExecutableCBody(compare_arg_body)) "hit_bool(" else "hit_bool((a < b));");
    try expectContains(compare_arg_body, " < ");
    try expectNotContains(compare_arg_body, "switch");

    const not_arg_body = try cFunctionBody(output.items, "static void call_not_arg(bool flag)");
    try expectContains(not_arg_body, if (isCanonicalExecutableCBody(not_arg_body)) "hit_bool(" else "hit_bool(!flag);");
    try expectContains(not_arg_body, "!");
    try expectNotContains(not_arg_body, "switch");

    const loop_void_body = try cFunctionBody(output.items, "static void loop_void(bool flag)");
    try expectLegacyOrCanonicalLoop(loop_void_body, "while (flag)");
    try expectContains(loop_void_body, "hit(");
    try expectNotContains(loop_void_body, "switch");
    try expectNotContains(loop_void_body, "mc_tmp");

    const loop_void_not_body = try cFunctionBody(output.items, "static void loop_void_not(bool flag)");
    try expectLegacyOrCanonicalLoop(loop_void_not_body, "while (!flag)");
    try expectContains(loop_void_not_body, "hit(");
    try expectNotContains(loop_void_not_body, "switch");
    try expectNotContains(loop_void_not_body, "mc_tmp");

    const loop_void_cmp_body = try cFunctionBody(output.items, "static void loop_void_cmp(int32_t a, int32_t b)");
    try expectLegacyOrCanonicalLoop(loop_void_cmp_body, "while ((a < b))");
    try expectContains(loop_void_cmp_body, "hit(");
    try expectNotContains(loop_void_cmp_body, "switch");
    try expectNotContains(loop_void_cmp_body, "mc_tmp");

    const loop_void_field_body = try cFunctionBody(output.items, "static void loop_void_field(Flags f, SignedPair p)");
    if (isCanonicalExecutableCBody(loop_void_field_body)) {
        try expectContains(loop_void_field_body, ").ok;");
        try expectContains(loop_void_field_body, ").a;");
        try expectContains(loop_void_field_body, "hit(mc_exec_tmp_");
    } else {
        const loop_void_field_while = std.mem.indexOf(u8, loop_void_field_body, "while (f.ok)") orelse return error.TestUnexpectedResult;
        const loop_void_field_call = std.mem.indexOf(u8, loop_void_field_body, "hit(p.a);") orelse return error.TestUnexpectedResult;
        try std.testing.expect(loop_void_field_while < loop_void_field_call);
    }
    try expectNotContains(loop_void_field_body, "switch");
    try expectNotContains(loop_void_field_body, "mc_tmp");
}

test "lower-c emits simple sequential void direct calls from MIR" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\fn id(value: i32) -> i32 {
        \\    return value;
        \\}
        \\fn sequence() -> void {
        \\    hit(1);
        \\    hit(2);
        \\    hit(3);
        \\}
        \\fn local_then_call() -> void {
        \\    let x: u32 = 1;
        \\    hit(2);
        \\}
        \\fn assign_then_call() -> void {
        \\    var x: u32 = 0;
        \\    x = 1;
        \\    hit(2);
        \\}
        \\fn call_local_arg() -> void {
        \\    let x: i32 = 1;
        \\    hit(x);
        \\}
        \\fn call_assigned_arg() -> void {
        \\    var x: i32 = 0;
        \\    x = 1;
        \\    hit(x);
        \\}
        \\fn call_local_checked_arg(a: i32, b: i32) -> void {
        \\    let x: i32 = a + b;
        \\    hit(x);
        \\}
        \\fn call_assigned_checked_arg(a: i32, b: i32) -> void {
        \\    var x: i32 = 0;
        \\    x = a + b;
        \\    hit(x);
        \\}
        \\fn call_local_call_arg(a: i32) -> void {
        \\    let x: i32 = id(a);
        \\    hit(x);
        \\}
        \\fn call_assigned_call_arg(a: i32) -> void {
        \\    var x: i32 = 0;
        \\    x = id(a);
        \\    hit(x);
        \\}
        \\fn call_checked_add_arg(a: i32, b: i32) -> void {
        \\    hit(a + b);
        \\}
        \\fn call_checked_neg_arg(a: i32) -> void {
        \\    hit(-a);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_call_sequence.mc", source, &output);

    const body = try cFunctionBody(output.items, "static void sequence(void)");
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, body, "hit("));
    try expectNotContains(body, "switch");

    const local_body = try cFunctionBody(output.items, "static void local_then_call(void)");
    try expectContains(local_body, "/* canonical executable MIR */");
    try expectContains(local_body, "hit(");
    try expectContains(local_body, "uint32_t x =");

    const assign_body = try cFunctionBody(output.items, "static void assign_then_call(void)");
    try expectContains(assign_body, "/* canonical executable MIR */");
    try expectContains(assign_body, "hit(");
    try expectContains(assign_body, "uint32_t x =");
    try expectContains(assign_body, "x =");

    const local_arg_body = try cFunctionBody(output.items, "static void call_local_arg(void)");
    try expectContains(local_arg_body, if (isCanonicalExecutableCBody(local_arg_body)) "hit(" else "hit(1);");
    try expectContains(local_arg_body, " = 1;");

    const assigned_arg_body = try cFunctionBody(output.items, "static void call_assigned_arg(void)");
    try expectContains(assigned_arg_body, if (isCanonicalExecutableCBody(assigned_arg_body)) "hit(" else "hit(1);");
    if (isCanonicalExecutableCBody(assigned_arg_body)) try expectContains(assigned_arg_body, " = 1;");

    const local_checked_arg_body = try cFunctionBody(output.items, "static void call_local_checked_arg(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(local_checked_arg_body))
        try expectNeedlesInOrder(local_checked_arg_body, &.{ "mc_checked_add_i32(", "int32_t x =", "hit(" })
    else
        try expectContains(local_checked_arg_body, "hit(mc_checked_add_i32(a, b));");
    if (!isCanonicalExecutableCBody(local_checked_arg_body)) try expectNotContains(local_checked_arg_body, "int32_t x");
    try expectNotContains(local_checked_arg_body, "mc_tmp");

    const assigned_checked_arg_body = try cFunctionBody(output.items, "static void call_assigned_checked_arg(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(assigned_checked_arg_body))
        try expectNeedlesInOrder(assigned_checked_arg_body, &.{ "mc_checked_add_i32(", "x =", "hit(" })
    else {
        try expectContains(assigned_checked_arg_body, "hit(mc_checked_add_i32(a, b));");
        try expectNotContains(assigned_checked_arg_body, "int32_t x");
        try expectNotContains(assigned_checked_arg_body, "x =");
    }
    try expectNotContains(assigned_checked_arg_body, "mc_tmp");

    const local_call_arg_body = try cFunctionBody(output.items, "static void call_local_call_arg(int32_t a)");
    if (isCanonicalExecutableCBody(local_call_arg_body))
        try expectNeedlesInOrder(local_call_arg_body, &.{ "= id(", "hit(" })
    else
        try expectContains(local_call_arg_body, "hit(id(a));");

    const assigned_call_arg_body = try cFunctionBody(output.items, "static void call_assigned_call_arg(int32_t a)");
    if (isCanonicalExecutableCBody(assigned_call_arg_body))
        try expectNeedlesInOrder(assigned_call_arg_body, &.{ "= id(", "hit(" })
    else
        try expectContains(assigned_call_arg_body, "hit(id(a));");

    const checked_add_arg_body = try cFunctionBody(output.items, "static void call_checked_add_arg(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(checked_add_arg_body))
        try expectNeedlesInOrder(checked_add_arg_body, &.{ "mc_checked_add_i32(", "hit(" })
    else
        try expectContains(checked_add_arg_body, "hit(mc_checked_add_i32(a, b));");
    try expectNotContains(checked_add_arg_body, "switch");

    const checked_neg_arg_body = try cFunctionBody(output.items, "static void call_checked_neg_arg(int32_t a)");
    if (isCanonicalExecutableCBody(checked_neg_arg_body))
        try expectNeedlesInOrder(checked_neg_arg_body, &.{ "mc_checked_neg_i32(", "hit(" })
    else
        try expectContains(checked_neg_arg_body, "hit(mc_checked_neg_i32(a));");
    try expectNotContains(checked_neg_arg_body, "switch");
}

test "lower-c emits pure local-only void functions from MIR" {
    const source =
        \\extern fn hit(value: u32) -> void;
        \\fn local_only() { let x: u32 = 1; }
        \\fn param_local(p: u32) { let x: u32 = p; }
        \\fn var_only() { var x: u32 = 1; x = 2; }
        \\fn if_local(flag: bool) { if (flag) { let x: u32 = 1; } else { let y: u32 = 2; } }
        \\fn if_assign(flag: bool) { var x: u32 = 0; if (flag) { x = 1; } else { x = 2; } }
        \\fn if_no_else(flag: bool) { if (flag) { let x: u32 = 1; } }
        \\fn call_then_if_empty(flag: bool, value: u32) { hit(value); if (flag) { let x: u32 = 1; } }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_local_only.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static void local_only(void)");
    if (isCanonicalExecutableCBody(local_body)) try expectContains(local_body, "uint32_t x") else try expectNotContains(local_body, "uint32_t x");

    const param_body = try cFunctionBody(output.items, "static void param_local(uint32_t p)");
    if (isCanonicalExecutableCBody(param_body)) try expectContains(param_body, "uint32_t x") else try expectNotContains(param_body, "uint32_t x");

    const var_body = try cFunctionBody(output.items, "static void var_only(void)");
    if (isCanonicalExecutableCBody(var_body)) try expectContains(var_body, "uint32_t x") else try expectNotContains(var_body, "uint32_t x");

    const if_local_body = try cFunctionBody(output.items, "static void if_local(bool flag)");
    if (isCanonicalExecutableCBody(if_local_body)) {
        try expectContains(if_local_body, "if (mc_exec_tmp_");
        try expectContains(if_local_body, "uint32_t x");
        try expectContains(if_local_body, "uint32_t y");
    } else {
        try expectNotContains(if_local_body, "if (flag)");
        try expectNotContains(if_local_body, "uint32_t x");
        try expectNotContains(if_local_body, "uint32_t y");
    }

    const if_assign_body = try cFunctionBody(output.items, "static void if_assign(bool flag)");
    if (isCanonicalExecutableCBody(if_assign_body)) {
        try expectContains(if_assign_body, "if (mc_exec_tmp_");
        try expectContains(if_assign_body, "uint32_t x");
    } else {
        try expectNotContains(if_assign_body, "if (flag)");
        try expectNotContains(if_assign_body, "uint32_t x");
    }

    const if_no_else_body = try cFunctionBody(output.items, "static void if_no_else(bool flag)");
    if (isCanonicalExecutableCBody(if_no_else_body)) {
        try expectContains(if_no_else_body, "if (mc_exec_tmp_");
        try expectContains(if_no_else_body, "uint32_t x");
    } else {
        try expectNotContains(if_no_else_body, "if (flag)");
        try expectNotContains(if_no_else_body, "uint32_t x");
    }

    const call_then_empty_body = try cFunctionBody(output.items, "static void call_then_if_empty(bool flag, uint32_t value)");
    try expectContains(call_then_empty_body, if (isCanonicalExecutableCBody(call_then_empty_body)) "hit(" else "hit(value);");
    if (isCanonicalExecutableCBody(call_then_empty_body)) try expectContains(call_then_empty_body, "if (mc_exec_tmp_") else try expectNotContains(call_then_empty_body, "if (flag)");
    try expectNotContains(call_then_empty_body, "switch");
}

test "lower-c emits simple global stores after specialized plan retirement" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\enum E {
        \\    bad,
        \\}
        \\struct Pair {
        \\    a: u32,
        \\    b: u32,
        \\}
        \\global g: u32 = 0;
        \\global h: u32 = 0;
        \\global flag: bool = false;
        \\global s: i32 = 0;
        \\global wide: u64 = 0;
        \\global byte: u8 = 0;
        \\global small_float: f32 = 0.0;
        \\global wide_float: f64 = 0.0;
        \\global current: Color = .red;
        \\global maybe: ?u32 = null;
        \\global pair: Pair = .{ .a = 0, .b = 0 };
        \\global result: Result<u32, E>;
        \\fn id(x: u32) -> u32 {
        \\    return x;
        \\}
        \\extern fn hit(x: u32) -> void;
        \\fn store_param(x: u32) {
        \\    g = x;
        \\}
        \\fn store_literal() {
        \\    g = 7;
        \\}
        \\fn store_char() {
        \\    byte = 'A';
        \\}
        \\fn store_float() {
        \\    small_float = 1.5;
        \\}
        \\fn store_double() {
        \\    wide_float = 2.5;
        \\}
        \\fn store_local_float() {
        \\    let x: f32 = 1.5;
        \\    small_float = x;
        \\}
        \\fn store_assigned_float() {
        \\    var x: f32 = 0.0;
        \\    x = 1.5;
        \\    small_float = x;
        \\}
        \\fn store_bool_literal() {
        \\    flag = true;
        \\}
        \\fn store_field(p: Pair) {
        \\    g = p.a;
        \\}
        \\fn store_global() {
        \\    h = g;
        \\}
        \\fn store_compare(a: i32, b: i32) {
        \\    flag = a < b;
        \\}
        \\fn store_not(input: bool) {
        \\    flag = !input;
        \\}
        \\fn store_local(x: u32) {
        \\    let y: u32 = x;
        \\    g = y;
        \\}
        \\fn store_var(x: u32) {
        \\    var y: u32 = 0;
        \\    y = x;
        \\    g = y;
        \\}
        \\fn store_call(x: u32) {
        \\    g = id(x);
        \\}
        \\fn store_many(x: u32, input: bool) {
        \\    g = x;
        \\    h = g;
        \\    flag = !input;
        \\}
        \\fn store_add(a: i32, b: i32) {
        \\    s = a + b;
        \\}
        \\fn store_wrap(a: u32) {
        \\    g = wrapping.add(a, 1);
        \\}
        \\fn store_unchecked(a: u32) {
        \\    #[unsafe_contract(no_overflow)] {
        \\        g = unchecked.add(a, 1);
        \\    }
        \\}
        \\fn store_cast(value: u32) {
        \\    wide = value as u64;
        \\}
        \\fn store_conversion(value: u64) {
        \\    byte = u8.wrap_from(value);
        \\}
        \\fn store_enum() {
        \\    current = .blue;
        \\}
        \\fn store_none() {
        \\    maybe = null;
        \\}
        \\fn store_pair(x: u32) {
        \\    pair = .{ .a = x, .b = 7 };
        \\}
        \\fn store_result_ok(x: u32) {
        \\    result = ok(x);
        \\}
        \\fn store_result_err() {
        \\    result = err(.bad);
        \\}
        \\fn store_neg(a: i32) {
        \\    s = -a;
        \\}
        \\fn call_then_store(x: u32) {
        \\    hit(x);
        \\    g = x;
        \\}
        \\fn store_then_call(x: u32) {
        \\    g = x;
        \\    hit(x);
        \\}
        \\fn if_store(flag: bool, x: u32, y: u32) {
        \\    if (flag) {
        \\        g = x;
        \\    } else {
        \\        g = y;
        \\    }
        \\}
        \\fn if_store_float(flag: bool) {
        \\    if (flag) {
        \\        small_float = 1.5;
        \\    } else {
        \\        small_float = 2.5;
        \\    }
        \\}
        \\fn if_store_no_else(flag: bool, x: u32) {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\}
        \\fn if_store_else_only(flag: bool, x: u32) {
        \\    if (flag) {
        \\    } else {
        \\        g = x;
        \\    }
        \\}
        \\fn call_then_if_store(flag: bool, x: u32, y: u32) {
        \\    hit(x);
        \\    if (flag) {
        \\        g = x;
        \\    } else {
        \\        g = y;
        \\    }
        \\}
        \\fn call_if_store_call(flag: bool, x: u32) {
        \\    hit(x);
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    hit(x);
        \\}
        \\fn if_store_two_suffix(flag: bool, x: u32) {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    hit(x);
        \\    hit(x);
        \\}
        \\fn if_store_suffix_store_call(flag: bool, x: u32) {
        \\    if (flag) {
        \\        g = x;
        \\    }
        \\    h = x;
        \\    hit(x);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_mir_global_store.mc", source, &output);

    const param_body = try cFunctionBody(output.items, "static void store_param(uint32_t x)");
    try expectContains(param_body, "mc_race_store_u32(&g, (uint32_t)");
    try expectNotContains(param_body, "mc_tmp");

    const literal_body = try cFunctionBody(output.items, "static void store_literal(void)");
    try expectContains(literal_body, "mc_race_store_u32(&g, (uint32_t)");
    try expectNotContains(literal_body, "mc_tmp");

    const char_body = try cFunctionBody(output.items, "static void store_char(void)");
    try expectContains(char_body, "mc_race_store_u8(&byte, (uint8_t)");
    try expectNotContains(char_body, "mc_tmp");

    const float_body = try cFunctionBody(output.items, "static void store_float(void)");
    try expectContains(float_body, "mc_race_store_f32(&small_float, (float)");
    if (isCanonicalExecutableCBody(float_body)) try expectContains(float_body, "0x3FC00000U") else try expectNotContains(float_body, "mc_tmp");

    const double_body = try cFunctionBody(output.items, "static void store_double(void)");
    try expectContains(double_body, "mc_race_store_f64(&wide_float, (double)");
    if (isCanonicalExecutableCBody(double_body)) try expectContains(double_body, "__builtin_bit_cast(double") else try expectNotContains(double_body, "mc_tmp");

    const local_float_body = try cFunctionBody(output.items, "static void store_local_float(void)");
    try expectContains(local_float_body, "mc_race_store_f32(&small_float, (float)");
    if (isCanonicalExecutableCBody(local_float_body)) {
        try expectContains(local_float_body, "float x = mc_exec_tmp_");
        try expectContains(local_float_body, "0x3FC00000U");
    } else {
        try expectNotContains(local_float_body, "float x");
        try expectNotContains(local_float_body, "mc_tmp");
    }

    const assigned_float_body = try cFunctionBody(output.items, "static void store_assigned_float(void)");
    if (isCanonicalExecutableCBody(assigned_float_body)) {
        try expectContains(assigned_float_body, "mc_race_store_f32(&small_float, (float)");
        try expectContains(assigned_float_body, "0x3FC00000U");
    } else {
        try expectContains(assigned_float_body, "mc_race_store_f32(&small_float, (float)1.5f);");
        try expectNotContains(assigned_float_body, "float x");
        try expectNotContains(assigned_float_body, "x =");
        try expectNotContains(assigned_float_body, "mc_tmp");
    }

    const bool_literal_body = try cFunctionBody(output.items, "static void store_bool_literal(void)");
    try expectContains(bool_literal_body, "mc_race_store_bool(&flag, (bool)");
    try expectNotContains(bool_literal_body, "mc_tmp");

    const field_body = try cFunctionBody(output.items, "static void store_field(Pair p)");
    if (isCanonicalExecutableCBody(field_body)) {
        try expectContains(field_body, ").a;");
        try expectContains(field_body, "mc_race_store_u32(&g, (uint32_t)mc_exec_tmp_");
    } else try expectContains(field_body, "mc_race_store_u32(&g, (uint32_t)p.a);");
    try expectNotContains(field_body, "mc_tmp");

    const global_body = try cFunctionBody(output.items, "static void store_global(void)");
    try expectContains(global_body, "mc_race_load_u32(&g)");
    try expectContains(global_body, "mc_race_store_u32(&h, (uint32_t)");
    try expectNotContains(global_body, "mc_tmp");

    const compare_body = try cFunctionBody(output.items, "static void store_compare(int32_t a, int32_t b)");
    try expectContains(compare_body, "mc_race_store_bool(&flag, (bool)");
    try expectNotContains(compare_body, "mc_tmp");

    const not_body = try cFunctionBody(output.items, "static void store_not(bool input)");
    try expectContains(not_body, "mc_race_store_bool(&flag, (bool)");
    try expectNotContains(not_body, "mc_tmp");

    const local_body = try cFunctionBody(output.items, "static void store_local(uint32_t x)");
    try expectContains(local_body, "mc_race_store_u32(&g, (uint32_t)");
    if (!isCanonicalExecutableCBody(local_body)) try expectNotContains(local_body, "uint32_t y");
    try expectNotContains(local_body, "mc_tmp");

    const var_body = try cFunctionBody(output.items, "static void store_var(uint32_t x)");
    try expectContains(var_body, "mc_race_store_u32(&g, (uint32_t)");
    if (!isCanonicalExecutableCBody(var_body)) try expectNotContains(var_body, "uint32_t y");
    try expectNotContains(var_body, "mc_tmp");

    const call_body = try cFunctionBody(output.items, "static void store_call(uint32_t x)");
    try expectContains(call_body, "id(");
    try expectContains(call_body, "mc_race_store_u32(&g, (uint32_t)");
    try expectNotContains(call_body, "mc_tmp");

    const many_body = try cFunctionBody(output.items, "static void store_many(uint32_t x, bool input)");
    try expectContains(many_body, "mc_race_store_u32(&g, (uint32_t)");
    try expectContains(many_body, "mc_race_load_u32(&g)");
    try expectContains(many_body, "mc_race_store_u32(&h, (uint32_t)");
    try expectContains(many_body, "mc_race_store_bool(&flag, (bool)");
    try expectNotContains(many_body, "mc_tmp");

    const add_body = try cFunctionBody(output.items, "static void store_add(int32_t a, int32_t b)");
    try expectContains(add_body, "mc_checked_add_i32(");
    try expectContains(add_body, "mc_race_store_i32(&s, (int32_t)");
    try expectNotContains(add_body, "mc_tmp");

    const wrap_body = try cFunctionBody(output.items, "static void store_wrap(uint32_t a)");
    try expectContains(wrap_body, " + ");
    try expectContains(wrap_body, "mc_race_store_u32(&g, (uint32_t)");

    const unchecked_body = try cFunctionBody(output.items, "static void store_unchecked(uint32_t a)");
    try expectContains(unchecked_body, "/* MC_MIR_RANGE no_overflow region=1 op=add */");
    try expectContains(unchecked_body, "mc_race_store_u32(&g, (uint32_t)");

    const cast_body = try cFunctionBody(output.items, "static void store_cast(uint32_t value)");
    try expectContains(cast_body, "((uint64_t)(");
    try expectContains(cast_body, "mc_race_store_u64(&wide, (uint64_t)");
    try expectNotContains(cast_body, "mc_tmp");

    const conversion_body = try cFunctionBody(output.items, "static void store_conversion(uint64_t value)");
    try expectContains(conversion_body, "/* canonical executable MIR */");
    try expectContains(conversion_body, "((uint8_t)(mc_exec_tmp_");
    try expectContains(conversion_body, "mc_race_store_u8(&byte, (uint8_t)");

    const enum_body = try cFunctionBody(output.items, "static void store_enum(void)");
    if (isCanonicalExecutableCBody(enum_body))
        try expectContains(enum_body, "/* canonical executable MIR */")
    else
        try expectContains(enum_body, "Color_blue");
    try expectContains(enum_body, if (isCanonicalExecutableCBody(enum_body))
        "__atomic_store_n(&current,"
    else
        "mc_race_store_isize(&current, (intptr_t)");

    const none_body = try cFunctionBody(output.items, "static void store_none(void)");
    try expectContains(none_body, "/* canonical executable MIR */");
    try expectContains(none_body, ".present = false");
    try expectContains(none_body, "mc_race_store_bool(&(maybe.present)");
    try expectContains(none_body, "mc_race_store_u32(&(maybe.value)");

    const pair_body = try cFunctionBody(output.items, "static void store_pair(uint32_t x)");
    try expectContains(pair_body, "/* canonical executable MIR */");
    try expectContains(pair_body, "mc_race_store_u32(&(pair.a)");
    try expectContains(pair_body, "mc_race_store_u32(&(pair.b)");

    const result_ok_body = try cFunctionBody(output.items, "static void store_result_ok(uint32_t x)");
    try expectContains(result_ok_body, "result = mc_exec_tmp_");
    try expectContains(result_ok_body, ".is_ok = true");
    try expectContains(result_ok_body, ".payload.ok = ");
    try expectContains(result_ok_body, "mc_result_");

    const result_err_body = try cFunctionBody(output.items, "static void store_result_err(void)");
    try expectContains(result_err_body, "/* canonical executable MIR */");
    try expectContains(result_err_body, "result = mc_exec_tmp_");
    try expectContains(result_err_body, ".is_ok = false");
    try expectContains(result_err_body, ".payload.err =");

    const neg_body = try cFunctionBody(output.items, "static void store_neg(int32_t a)");
    try expectContains(neg_body, "mc_checked_neg_i32(");
    try expectContains(neg_body, "mc_race_store_i32(&s, (int32_t)");
    try expectNotContains(neg_body, "mc_tmp");

    const call_then_store_body = try cFunctionBody(output.items, "static void call_then_store(uint32_t x)");
    try expectContains(call_then_store_body, "hit(");
    try expectContains(call_then_store_body, "mc_race_store_u32(&g, (uint32_t)");
    try expectNotContains(call_then_store_body, "mc_tmp");

    const store_then_call_body = try cFunctionBody(output.items, "static void store_then_call(uint32_t x)");
    try expectContains(store_then_call_body, "mc_race_store_u32(&g, (uint32_t)");
    try expectContains(store_then_call_body, "hit(");
    try expectNotContains(store_then_call_body, "mc_tmp");

    const if_body = try cFunctionBody(output.items, "static void if_store(bool flag, uint32_t x, uint32_t y)");
    try expectCanonicalConditional(if_body);
    try expectContains(if_body, "mc_race_store_u32(&g, (uint32_t)mc_exec_tmp_");
    try expectNotContains(if_body, "switch");
    try expectNotContains(if_body, "mc_tmp");

    const if_float_body = try cFunctionBody(output.items, "static void if_store_float(bool flag)");
    try expectCanonicalConditional(if_float_body);
    try expectContains(if_float_body, "mc_race_store_f32(&small_float, (float)mc_exec_tmp_");
    try expectNotContains(if_float_body, "switch");
    try expectNotContains(if_float_body, "mc_tmp");

    const no_else_body = try cFunctionBody(output.items, "static void if_store_no_else(bool flag, uint32_t x)");
    try expectCanonicalConditional(no_else_body);
    try expectContains(no_else_body, "mc_race_store_u32(&g, (uint32_t)mc_exec_tmp_");
    try expectNotContains(no_else_body, "switch");
    try expectNotContains(no_else_body, "mc_tmp");

    const else_only_body = try cFunctionBody(output.items, "static void if_store_else_only(bool flag, uint32_t x)");
    try expectCanonicalConditional(else_only_body);
    try expectContains(else_only_body, "mc_race_store_u32(&g, (uint32_t)mc_exec_tmp_");
    try expectNotContains(else_only_body, "switch");
    try expectNotContains(else_only_body, "mc_tmp");

    const call_if_body = try cFunctionBody(output.items, "static void call_then_if_store(bool flag, uint32_t x, uint32_t y)");
    try expectCanonicalConditional(call_if_body);
    try expectContains(call_if_body, "hit(");
    try expectContains(call_if_body, "mc_race_store_u32(&g, (uint32_t)mc_exec_tmp_");
    try expectNotContains(call_if_body, "switch");
    try expectNotContains(call_if_body, "mc_tmp");

    const call_if_call_body = try cFunctionBody(output.items, "static void call_if_store_call(bool flag, uint32_t x)");
    try expectCanonicalConditional(call_if_call_body);
    try expectContains(call_if_call_body, "hit(");
    try expectContains(call_if_call_body, "mc_race_store_u32(&g, (uint32_t)mc_exec_tmp_");
    try expectNotContains(call_if_call_body, "switch");
    try expectNotContains(call_if_call_body, "mc_tmp");

    const two_suffix_store_body = try cFunctionBody(output.items, "static void if_store_two_suffix(bool flag, uint32_t x)");
    try expectCanonicalConditional(two_suffix_store_body);
    try expectContains(two_suffix_store_body, "mc_race_store_u32(&g, (uint32_t)mc_exec_tmp_");
    try expectContains(two_suffix_store_body, "hit(");
    try expectNotContains(two_suffix_store_body, "switch");
    try expectNotContains(two_suffix_store_body, "mc_tmp");

    const suffix_store_call_body = try cFunctionBody(output.items, "static void if_store_suffix_store_call(bool flag, uint32_t x)");
    try expectCanonicalConditional(suffix_store_call_body);
    try expectContains(suffix_store_call_body, "mc_race_store_u32(&g, (uint32_t)mc_exec_tmp_");
    try expectContains(suffix_store_call_body, "mc_race_store_u32(&h, (uint32_t)mc_exec_tmp_");
    try expectContains(suffix_store_call_body, "hit(");
    try expectNotContains(suffix_store_call_body, "switch");
    try expectNotContains(suffix_store_call_body, "mc_tmp");
}

test "lower-c preserves MIR void calls before simple returns" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\fn side_then_return(x: i32) -> i32 {
        \\    hit(1);
        \\    hit(2);
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_calls_before_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static int32_t side_then_return(int32_t x)");
    const hit1 = std.mem.indexOf(u8, body, "hit(") orelse return error.TestUnexpectedResult;
    const hit2 = std.mem.indexOfPos(u8, body, hit1 + 1, "hit(") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, if (isCanonicalExecutableCBody(body)) "return mc_exec_tmp_" else "return x;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit1 < hit2);
    try std.testing.expect(hit2 < ret);
}

test "lower-c emits direct struct parameter field returns from MIR" {
    const source =
        \\struct Pair { a: u32, b: u32 }
        \\fn first(p: Pair) -> u32 {
        \\    return p.a;
        \\}
        \\fn local_first(p: Pair) -> u32 {
        \\    let x: u32 = p.a;
        \\    return x;
        \\}
        \\fn assigned_second(p: Pair) -> u32 {
        \\    var x: u32 = 0;
        \\    x = p.b;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_param_field_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t first(Pair p)");
    try expectContains(body, if (isCanonicalExecutableCBody(body)) ").a;" else "return p.a;");
    if (isCanonicalExecutableCBody(body)) try expectContains(body, "return mc_exec_tmp_");
    try expectNotContains(body, "mc_tmp");
    try expectNotContains(body, "switch");

    const local_body = try cFunctionBody(output.items, "static uint32_t local_first(Pair p)");
    try expectContains(local_body, if (isCanonicalExecutableCBody(local_body)) ").a;" else "return p.a;");
    if (isCanonicalExecutableCBody(local_body)) try expectContains(local_body, "return mc_exec_tmp_");
    if (!isCanonicalExecutableCBody(local_body)) try expectNotContains(local_body, "uint32_t x");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static uint32_t assigned_second(Pair p)");
    try expectContains(assigned_body, if (isCanonicalExecutableCBody(assigned_body)) ").b;" else "return p.b;");
    if (isCanonicalExecutableCBody(assigned_body)) try expectContains(assigned_body, "return mc_exec_tmp_");
    if (!isCanonicalExecutableCBody(assigned_body)) try expectNotContains(assigned_body, "uint32_t x");
    try expectNotContains(assigned_body, "mc_tmp");
    if (!isCanonicalExecutableCBody(assigned_body)) try expectNotContains(assigned_body, "x =");
}

test "lower-c emits nested parameter and global field places from MIR without body fallback" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\struct Box { pair: Pair }
        \\global box: Box = .{ .pair = .{ .left = 1, .right = 2 } };
        \\fn update(value: u32) -> u32 {
        \\    box.pair.left = value;
        \\    return box.pair.left;
        \\}
        \\fn read(value: Box) -> u32 {
        \\    return value.pair.right;
        \\}
        \\fn read_local_global() -> u32 {
        \\    let copy: Box = box;
        \\    return copy.pair.right;
        \\}
        \\fn read_local_parameter(value: Box) -> u32 {
        \\    let copy: Box = value;
        \\    return copy.pair.left;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_nested_place_return.mc", source, &output);

    const update = try cFunctionBody(output.items, "static uint32_t update(uint32_t value)");
    try expectContains(update, "/* canonical executable MIR */");
    try expectContains(update, "mc_race_store_u32");
    try expectContains(update, "mc_race_load_u32");
    const read = try cFunctionBody(output.items, "static uint32_t read(Box value)");
    if (isCanonicalExecutableCBody(read)) {
        try expectContains(read, ").pair");
        try expectContains(read, ").right");
        try expectContains(read, "return mc_exec_tmp_");
    } else try expectContains(read, "return value.pair.right;");
    try expectNotContains(read, "mc_tmp");
    const read_global = try cFunctionBody(output.items, "static uint32_t read_local_global(void)");
    try expectContains(read_global, "/* canonical executable MIR */");
    try expectContains(read_global, "Box copy =");
    try expectContains(read_global, "return ");
    const read_parameter = try cFunctionBody(output.items, "static uint32_t read_local_parameter(Box value)");
    if (isCanonicalExecutableCBody(read_parameter)) {
        try expectContains(read_parameter, "Box copy = mc_exec_tmp_");
        try expectContains(read_parameter, ").pair");
        try expectContains(read_parameter, ".left");
    } else {
        try expectContains(read_parameter, "Box copy = value;");
        try expectContains(read_parameter, "return copy.pair.left;");
    }
}

test "lower-c emits fixed-array constant-index places from MIR without body fallback" {
    const source =
        \\global values: [2]u32 = .{ 10, 20 };
        \\global matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
        \\fn take_row(row: [2]u32) -> u32 {
        \\    return row[1];
        \\}
        \\fn read_global_array() -> u32 {
        \\    return values[1];
        \\}
        \\fn write_global_array(value: u32) -> u32 {
        \\    values[0] = value;
        \\    return values[0];
        \\}
        \\fn local_array_copy(row: [2]u32) -> u32 {
        \\    let copy: [2]u32 = row;
        \\    return copy[0];
        \\}
        \\fn nested_global() -> u32 {
        \\    matrix[1][0] = 11;
        \\    return matrix[1][0];
        \\}
        \\fn replace_row() -> u32 {
        \\    matrix[1] = .{ 31, 32 };
        \\    return matrix[1][1];
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_array_place_return.mc", source, &output);

    const take = try cFunctionBody(output.items, "static uint32_t take_row(mc_array_u32_2 row)");
    try expectContains(take, "/* canonical executable MIR */");
    try expectContains(take, "mc_check_index_usize(");
    const read = try cFunctionBody(output.items, "static uint32_t read_global_array(void)");
    try std.testing.expect(isCanonicalExecutableCBody(read));
    try expectContains(read, "mc_race_load_u32(&((values).elems[mc_check_index_usize(");
    try expectContains(read, ", 2)]");
    const write = try cFunctionBody(output.items, "static uint32_t write_global_array(uint32_t value)");
    try std.testing.expect(isCanonicalExecutableCBody(write));
    try expectContains(write, "mc_race_store_u32(&((values).elems[mc_check_index_usize(");
    try expectContains(write, "mc_race_load_u32(&((values).elems[mc_check_index_usize(");
    const local = try cFunctionBody(output.items, "static uint32_t local_array_copy(mc_array_u32_2 row)");
    try std.testing.expect(isCanonicalExecutableCBody(local));
    try expectContains(local, "mc_array_u32_2 copy = mc_exec_tmp_");
    try expectContains(local, ".elems[mc_check_index_usize(mc_exec_tmp_");
    const nested = try cFunctionBody(output.items, "static uint32_t nested_global(void)");
    try std.testing.expect(isCanonicalExecutableCBody(nested));
    try expectContains(nested, "mc_race_store_u32(&((matrix).elems[mc_check_index_usize(");
    try expectContains(nested, ", 2)].elems[mc_check_index_usize(");
    try expectContains(nested, "mc_race_load_u32(&((matrix).elems[mc_check_index_usize(");
    const replace = try cFunctionBody(output.items, "static uint32_t replace_row(void)");
    try expectContains(replace, "/* canonical executable MIR */");
    try expectContains(replace, "31");
    try expectContains(replace, "32");
    try expectContains(replace, "mc_check_index_usize(");
    try expectContains(replace, "mc_race_load_u32");
}

test "lower-c checked dynamic fixed-array stores use canonical executable MIR" {
    const source =
        \\global values: [4]u32 = .{ 0, 0, 0, 0 };
        \\fn store_at(index: usize, value: u32) -> void {
        \\    values[index] = value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_dynamic_array_store.mc", source, &output);

    const body = try cFunctionBody(output.items, "static void store_at(uintptr_t index, uint32_t value)");
    try std.testing.expect(isCanonicalExecutableCBody(body));
    try expectContains(body, "mc_race_store_u32(&((values).elems[mc_check_index_usize(");
    try expectContains(body, ", 4)]");
}

test "lower-c emits local aggregate projection updates from MIR without body fallback" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\struct Box { pair: Pair }
        \\fn assign_field(value: u32) -> u32 {
        \\    var pair: Pair = .{ .left = 1, .right = 2 };
        \\    pair.left = value;
        \\    return pair.left;
        \\}
        \\fn assign_nested_array(value: u32) -> u32 {
        \\    var xs: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
        \\    xs[0][1] = value;
        \\    return xs[0][1];
        \\}
        \\fn local_nested_struct(value: u32) -> u32 {
        \\    var box: Box = .{ .pair = .{ .left = 5, .right = 6 } };
        \\    box.pair.right = value;
        \\    return box.pair.right;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_aggregate_projection_updates.mc", source, &output);

    const field_body = try cFunctionBody(output.items, "static uint32_t assign_field(uint32_t value)");
    try expectContains(field_body, "/* canonical executable MIR */");
    try expectContains(field_body, "Pair pair = mc_exec_tmp_");
    try expectContains(field_body, "(pair).left = mc_exec_tmp_");
    try expectContains(field_body, "return mc_exec_tmp_");

    const array_body = try cFunctionBody(output.items, "static uint32_t assign_nested_array(uint32_t value)");
    try expectContains(array_body, "/* canonical executable MIR */");
    try expectContains(array_body, "xs = mc_exec_tmp_");
    try expectContains(array_body, "(xs).elems[mc_check_index_usize(");
    try expectContains(array_body, "return mc_exec_tmp_");

    const struct_body = try cFunctionBody(output.items, "static uint32_t local_nested_struct(uint32_t value)");
    try expectContains(struct_body, "/* canonical executable MIR */");
    try expectContains(struct_body, "Box box = mc_exec_tmp_");
    try expectContains(struct_body, "(box).pair.right = mc_exec_tmp_");
    try expectContains(struct_body, "return mc_exec_tmp_");
}

test "lower-c emits conditional struct parameter field returns from MIR" {
    const source =
        \\struct Pair { a: u32, b: u32 }
        \\fn choose(flag: bool, p: Pair) -> u32 {
        \\    if (flag) {
        \\        return p.a;
        \\    } else {
        \\        return p.b;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conditional_param_field_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t choose(bool flag, Pair p)");
    try expectCanonicalConditional(body);
    try expectContains(body, ").a;");
    try expectContains(body, ").b;");
    try expectContains(body, "return mc_exec_tmp_");
    try expectNotContains(body, "mc_tmp");
    try expectNotContains(body, "switch");
}

test "lower-c emits conditional boolean struct field conditions from MIR" {
    const source =
        \\struct Flags { ok: bool, other: bool }
        \\fn choose(f: Flags) -> bool {
        \\    if (f.ok) {
        \\        return f.other;
        \\    } else {
        \\        return false;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conditional_param_bool_field.mc", source, &output);

    const body = try cFunctionBody(output.items, "static bool choose(Flags f)");
    try expectCanonicalConditional(body);
    try expectContains(body, ").ok;");
    try expectContains(body, ").other;");
    try expectContains(body, " = false;");
    try expectNotContains(body, "switch");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits struct parameter field call arguments from MIR" {
    const source =
        \\struct Pair { a: u32, b: u32 }
        \\extern fn make(x: u32) -> u32;
        \\extern fn hit(x: u32) -> void;
        \\fn call_field(p: Pair) -> u32 {
        \\    return make(p.a);
        \\}
        \\fn void_field(p: Pair) -> void {
        \\    hit(p.b);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_param_field_call_args.mc", source, &output);

    const call_body = try cFunctionBody(output.items, "static uint32_t call_field(Pair p)");
    if (isCanonicalExecutableCBody(call_body)) {
        try expectContains(call_body, ").a;");
        try expectContains(call_body, "make(mc_exec_tmp_");
        try expectContains(call_body, "return mc_exec_tmp_");
    } else try expectContains(call_body, "return make(p.a);");
    try expectNotContains(call_body, "mc_tmp");

    const void_body = try cFunctionBody(output.items, "static void void_field(Pair p)");
    if (isCanonicalExecutableCBody(void_body)) {
        try expectContains(void_body, ").b;");
        try expectContains(void_body, "hit(mc_exec_tmp_");
    } else try expectContains(void_body, "hit(p.b);");
    try expectNotContains(void_body, "mc_tmp");
}

test "lower-c emits struct parameter field checked operands from MIR" {
    const source =
        \\struct Pair { a: u32, b: u32 }
        \\fn add_left(p: Pair, x: u32) -> u32 {
        \\    return p.a + x;
        \\}
        \\fn add_right(p: Pair, x: u32) -> u32 {
        \\    return x + p.b;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_param_field_checked_operands.mc", source, &output);

    const left_body = try cFunctionBody(output.items, "static uint32_t add_left(Pair p, uint32_t x)");
    if (isCanonicalExecutableCBody(left_body)) {
        try expectContains(left_body, ").a;");
        try expectContains(left_body, "mc_checked_add_u32(mc_exec_tmp_");
    } else try expectContains(left_body, "return mc_checked_add_u32(p.a, x);");
    try expectNotContains(left_body, "mc_tmp");

    const right_body = try cFunctionBody(output.items, "static uint32_t add_right(Pair p, uint32_t x)");
    if (isCanonicalExecutableCBody(right_body)) {
        try expectContains(right_body, ").b;");
        try expectContains(right_body, "mc_checked_add_u32(mc_exec_tmp_");
    } else try expectContains(right_body, "return mc_checked_add_u32(x, p.b);");
    try expectNotContains(right_body, "mc_tmp");
}

test "lower-c emits struct parameter field comparisons from MIR" {
    const source =
        \\extern fn take_bool(v: bool) -> void;
        \\struct Pair { a: u32, b: u32 }
        \\fn cmp_left(p: Pair, x: u32) -> bool {
        \\    return p.a == x;
        \\}
        \\fn cmp_right(p: Pair, x: u32) -> bool {
        \\    return x < p.b;
        \\}
        \\fn call_cmp(p: Pair, x: u32) -> void {
        \\    take_bool(p.a == x);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_param_field_compare_operands.mc", source, &output);

    const left_body = try cFunctionBody(output.items, "static bool cmp_left(Pair p, uint32_t x)");
    if (isCanonicalExecutableCBody(left_body)) {
        try expectContains(left_body, ").a;");
        try expectContains(left_body, " == ");
    } else try expectContains(left_body, "return (p.a == x);");
    try expectNotContains(left_body, "return (p == x);");

    const right_body = try cFunctionBody(output.items, "static bool cmp_right(Pair p, uint32_t x)");
    if (isCanonicalExecutableCBody(right_body)) {
        try expectContains(right_body, ").b;");
        try expectContains(right_body, " < ");
    } else try expectContains(right_body, "return (x < p.b);");

    const call_body = try cFunctionBody(output.items, "static void call_cmp(Pair p, uint32_t x)");
    if (isCanonicalExecutableCBody(call_body)) {
        try expectContains(call_body, ").a;");
        try expectContains(call_body, "take_bool(mc_exec_tmp_");
    } else try expectContains(call_body, "take_bool((p.a == x));");
    try expectNotContains(call_body, "take_bool((p == x));");
}

test "lower-c emits simple struct literal returns from MIR" {
    const source =
        \\struct Pair { a: i32, b: i32 }
        \\struct Flags { ok: bool }
        \\extern fn hit(value: i32) -> void;
        \\fn make_pair(a: i32, b: i32) -> Pair {
        \\    return .{ .a = a, .b = b };
        \\}
        \\fn return_field_pair(p: Pair) -> Pair {
        \\    return .{ .a = p.a, .b = p.b };
        \\}
        \\fn bool_pair(f: Flags) -> Flags {
        \\    return .{ .ok = f.ok };
        \\}
        \\fn choose_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    if (flag) {
        \\        return .{ .a = a, .b = b };
        \\    } else {
        \\        return .{ .a = b, .b = a };
        \\    }
        \\}
        \\fn choose_field_pair(flag: bool, p: Pair) -> Pair {
        \\    if (flag) {
        \\        return .{ .a = p.a, .b = p.b };
        \\    } else {
        \\        return .{ .a = p.b, .b = p.a };
        \\    }
        \\}
        \\fn choose_assign_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    if (flag) {
        \\        out = .{ .a = b, .b = a };
        \\    }
        \\    return out;
        \\}
        \\fn choose_assign_field_pair(flag: bool, p: Pair) -> Pair {
        \\    var out: Pair = .{ .a = p.a, .b = p.b };
        \\    if (flag) {
        \\        out = .{ .a = p.b, .b = p.a };
        \\    }
        \\    return out;
        \\}
        \\fn local_pair(a: i32, b: i32) -> Pair {
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    return out;
        \\}
        \\fn local_field_pair(p: Pair) -> Pair {
        \\    var out: Pair = .{ .a = p.a, .b = p.b };
        \\    return out;
        \\}
        \\fn assigned_pair(a: i32, b: i32) -> Pair {
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    out = .{ .a = b, .b = a };
        \\    return out;
        \\}
        \\fn assigned_field_pair(p: Pair) -> Pair {
        \\    var out: Pair = .{ .a = p.a, .b = p.b };
        \\    out = .{ .a = p.b, .b = p.a };
        \\    return out;
        \\}
        \\fn loop_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    while (flag) {
        \\    }
        \\    return .{ .a = a, .b = b };
        \\}
        \\fn loop_local_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    while (flag) {
        \\    }
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    return out;
        \\}
        \\fn side_then_pair(a: i32, b: i32) -> Pair {
        \\    hit(a);
        \\    return .{ .a = a, .b = b };
        \\}
        \\fn side_then_local_pair(a: i32, b: i32) -> Pair {
        \\    hit(a);
        \\    var out: Pair = .{ .a = a, .b = b };
        \\    return out;
        \\}
        \\fn early_pair(flag: bool, a: i32, b: i32) -> Pair {
        \\    if (flag) {
        \\        return .{ .a = b, .b = a };
        \\    }
        \\    return .{ .a = a, .b = b };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_struct_literal_returns.mc", source, &output);

    const make_body = try cFunctionBody(output.items, "static Pair make_pair(int32_t a, int32_t b)");
    try expectContains(make_body, "/* canonical executable MIR */");
    try expectContains(make_body, "= (Pair){ mc_exec_tmp_");
    try expectContains(make_body, "return mc_exec_tmp_");
    try expectNotContains(make_body, "mc_tmp");

    const field_body = try cFunctionBody(output.items, "static Pair return_field_pair(Pair p)");
    if (isCanonicalExecutableCBody(field_body)) {
        try expectContains(field_body, ").a;");
        try expectContains(field_body, ").b;");
        try expectContains(field_body, "= (Pair){ mc_exec_tmp_");
    } else try expectContains(field_body, "return (Pair){ .a = p.a, .b = p.b };");
    try expectNotContains(field_body, "mc_tmp");

    const bool_body = try cFunctionBody(output.items, "static Flags bool_pair(Flags f)");
    if (isCanonicalExecutableCBody(bool_body)) {
        try expectContains(bool_body, ").ok;");
        try expectContains(bool_body, "= (Flags){ mc_exec_tmp_");
    } else try expectContains(bool_body, "return (Flags){ .ok = f.ok };");
    try expectNotContains(bool_body, "mc_tmp");

    const choose_body = try cFunctionBody(output.items, "static Pair choose_pair(bool flag, int32_t a, int32_t b)");
    try expectCanonicalConditional(choose_body);
    try expectContains(choose_body, "= (Pair){ mc_exec_tmp_");
    try expectContains(choose_body, "return mc_exec_tmp_");
    try expectNotContains(choose_body, "mc_tmp");
    try expectNotContains(choose_body, "switch");

    const choose_field_body = try cFunctionBody(output.items, "static Pair choose_field_pair(bool flag, Pair p)");
    try expectCanonicalConditional(choose_field_body);
    try expectContains(choose_field_body, "= (Pair){ mc_exec_tmp_");
    try expectContains(choose_field_body, "return mc_exec_tmp_");
    try expectNotContains(choose_field_body, "mc_tmp");
    try expectNotContains(choose_field_body, "switch");

    const choose_assign_body = try cFunctionBody(output.items, "static Pair choose_assign_pair(bool flag, int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(choose_assign_body)) {
        try expectCanonicalConditional(choose_assign_body);
        try std.testing.expect(std.mem.count(u8, choose_assign_body, "= (Pair){") >= 2);
        try std.testing.expect(std.mem.count(u8, choose_assign_body, "return mc_exec_tmp_") >= 1);
    } else {
        try expectContains(choose_assign_body, "if (flag) {");
        try expectContains(choose_assign_body, "return (Pair){ .a = b, .b = a };");
        try expectContains(choose_assign_body, "return (Pair){ .a = a, .b = b };");
    }
    try expectNotContains(choose_assign_body, "mc_tmp");
    try expectNotContains(choose_assign_body, "switch");

    const choose_assign_field_body = try cFunctionBody(output.items, "static Pair choose_assign_field_pair(bool flag, Pair p)");
    if (isCanonicalExecutableCBody(choose_assign_field_body)) {
        try expectCanonicalConditional(choose_assign_field_body);
        try std.testing.expect(std.mem.count(u8, choose_assign_field_body, "= (Pair){") >= 2);
        try std.testing.expect(std.mem.count(u8, choose_assign_field_body, ").a;") >= 2);
        try std.testing.expect(std.mem.count(u8, choose_assign_field_body, ").b;") >= 2);
        try expectContains(choose_assign_field_body, "return mc_exec_tmp_");
    } else {
        try expectContains(choose_assign_field_body, "return (Pair){ .a = p.b, .b = p.a };");
        try expectContains(choose_assign_field_body, "return (Pair){ .a = p.a, .b = p.b };");
    }
    try expectNotContains(choose_assign_field_body, "mc_tmp");
    try expectNotContains(choose_assign_field_body, "switch");

    const local_body = try cFunctionBody(output.items, "static Pair local_pair(int32_t a, int32_t b)");
    try expectContains(local_body, "/* canonical executable MIR */");
    try expectContains(local_body, "= (Pair){ mc_exec_tmp_");
    try expectContains(local_body, "return mc_exec_tmp_");
    try expectNotContains(local_body, "mc_tmp");

    const local_field_body = try cFunctionBody(output.items, "static Pair local_field_pair(Pair p)");
    if (isCanonicalExecutableCBody(local_field_body)) {
        try expectContains(local_field_body, ").a;");
        try expectContains(local_field_body, ").b;");
        try expectContains(local_field_body, "= (Pair){ mc_exec_tmp_");
    } else try expectContains(local_field_body, "return (Pair){ .a = p.a, .b = p.b };");
    try expectNotContains(local_field_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static Pair assigned_pair(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(assigned_body)) {
        try std.testing.expect(std.mem.count(u8, assigned_body, "= (Pair){") >= 2);
        try expectContains(assigned_body, "return mc_exec_tmp_");
    } else {
        try expectContains(assigned_body, "return (Pair){ .a = b, .b = a };");
        try expectNotContains(assigned_body, "return (Pair){ .a = a, .b = b };");
    }
    try expectNotContains(assigned_body, "mc_tmp");

    const assigned_field_body = try cFunctionBody(output.items, "static Pair assigned_field_pair(Pair p)");
    if (isCanonicalExecutableCBody(assigned_field_body)) {
        try expectContains(assigned_field_body, ").a;");
        try expectContains(assigned_field_body, ").b;");
        try expectContains(assigned_field_body, "= (Pair){ mc_exec_tmp_");
    } else {
        try expectContains(assigned_field_body, "return (Pair){ .a = p.b, .b = p.a };");
        try expectNotContains(assigned_field_body, "return (Pair){ .a = p.a, .b = p.b };");
    }
    try expectNotContains(assigned_field_body, "mc_tmp");

    const loop_body = try cFunctionBody(output.items, "static Pair loop_pair(bool flag, int32_t a, int32_t b)");
    try expectContains(loop_body, "/* canonical executable MIR */");
    try expectContains(loop_body, "goto mc_bb_");
    try expectContains(loop_body, "= (Pair){ mc_exec_tmp_");
    try expectContains(loop_body, "return mc_exec_tmp_");
    try expectNotContains(loop_body, "mc_tmp");
    try expectNotContains(loop_body, "switch");

    const loop_local_body = try cFunctionBody(output.items, "static Pair loop_local_pair(bool flag, int32_t a, int32_t b)");
    try expectContains(loop_local_body, "/* canonical executable MIR */");
    try expectContains(loop_local_body, "goto mc_bb_");
    try expectContains(loop_local_body, "= (Pair){ mc_exec_tmp_");
    try expectContains(loop_local_body, "return mc_exec_tmp_");
    try expectNotContains(loop_local_body, "mc_tmp");
    try expectNotContains(loop_local_body, "switch");

    const side_body = try cFunctionBody(output.items, "static Pair side_then_pair(int32_t a, int32_t b)");
    try expectContains(side_body, "/* canonical executable MIR */");
    const side_call = std.mem.indexOf(u8, side_body, "hit(") orelse return error.TestUnexpectedResult;
    const side_ret = std.mem.indexOf(u8, side_body, "= (Pair){") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side_call < side_ret);
    try expectNotContains(side_body, "mc_tmp");

    const side_local_body = try cFunctionBody(output.items, "static Pair side_then_local_pair(int32_t a, int32_t b)");
    try expectContains(side_local_body, "/* canonical executable MIR */");
    const side_local_call = std.mem.indexOf(u8, side_local_body, "hit(") orelse return error.TestUnexpectedResult;
    const side_local_ret = std.mem.indexOf(u8, side_local_body, "= (Pair){") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side_local_call < side_local_ret);
    try expectNotContains(side_local_body, "mc_tmp");

    const early_body = try cFunctionBody(output.items, "static Pair early_pair(bool flag, int32_t a, int32_t b)");
    try expectContains(early_body, "/* canonical executable MIR */");
    try expectContains(early_body, "if (mc_exec_tmp_");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, early_body, "= (Pair){"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, early_body, "return mc_exec_tmp_"));
    try expectNotContains(early_body, "mc_tmp");
    try expectNotContains(early_body, "switch");
}

test "lower-c canonical executable MIR emits nested by-value struct member reads" {
    const source =
        \\struct Inner { value: u32 }
        \\struct Outer { inner: Inner }
        \\fn read(outer: Outer) -> u32 {
        \\    return outer.inner.value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_executable_struct_member.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t read(Outer outer)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, ").inner;");
    try expectContains(body, ").value;");
}

test "lower-c canonical executable MIR emits nested parameter array indexes" {
    const source =
        \\fn read(matrix: [2][3]u32) -> u32 {
        \\    return matrix[0][0];
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_nested_parameter_array_index.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t read(");
    try expectContains(body, "/* canonical executable MIR */");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, ".elems[mc_check_index_usize("));
    try expectContains(body, ", 2)]");
    try expectContains(body, ", 3)]");
}

test "C canonical executable MIR keeps ordinary len fields distinct from slice length" {
    const source =
        \\struct WithLen { items: [8]u32, len: u32 }
        \\fn read_len(value: WithLen) -> u32 { return value.len; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_struct_len_field.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t read_len(WithLen value)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, ").len;");
    try expectNotContains(body, ").length;");
}

test "lower-c emits simple array literal returns from MIR" {
    const source =
        \\const WIDE_LENGTH: usize = 20;
        \\fn array_direct(a: u32, b: u32) -> [2]u32 {
        \\    return .{ a, b };
        \\}
        \\fn array_local(a: u32, b: u32) -> [2]u32 {
        \\    var out: [2]u32 = .{ a, b };
        \\    return out;
        \\}
        \\fn array_assigned(a: u32, b: u32) -> [2]u32 {
        \\    var out: [2]u32 = .{ a, b };
        \\    out = .{ b, a };
        \\    return out;
        \\}
        \\fn array_wide(value: u32) -> [WIDE_LENGTH]u32 {
        \\    return .{ value, value, value, value, value, value, value, value, value, value,
        \\        value, value, value, value, value, value, value, value, value, value };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_array_literal_returns.mc", source, &output);

    const direct_body = try cFunctionBody(output.items, "static mc_array_u32_2 array_direct(uint32_t a, uint32_t b)");
    try expectContains(direct_body, "(mc_array_u32_2){ .elems = {");
    try expectContains(direct_body, if (isCanonicalExecutableCBody(direct_body)) "return mc_exec_tmp_" else "return (mc_array_u32_2)");
    try expectNotContains(direct_body, "mc_tmp");

    const local_body = try cFunctionBody(output.items, "static mc_array_u32_2 array_local(uint32_t a, uint32_t b)");
    try expectContains(local_body, "(mc_array_u32_2){ .elems = {");
    try expectContains(local_body, if (isCanonicalExecutableCBody(local_body)) "return mc_exec_tmp_" else "return (mc_array_u32_2)");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static mc_array_u32_2 array_assigned(uint32_t a, uint32_t b)");
    try expectContains(assigned_body, "(mc_array_u32_2){ .elems = {");
    try expectContains(assigned_body, if (isCanonicalExecutableCBody(assigned_body)) "return mc_exec_tmp_" else "return (mc_array_u32_2)");
    try expectNotContains(assigned_body, "mc_tmp");

    const wide_body = try cFunctionBody(output.items, "static mc_array_u32_20 array_wide(uint32_t value)");
    try expectContains(wide_body, "/* canonical executable MIR */");
    try expectContains(wide_body, "(mc_array_u32_20){ .elems = {");
}

test "lower-c preserves local aggregate assignment and return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\fn array_assignment() -> [2]u32 {
        \\    var values: [2]u32 = uninit;
        \\    values = .{ 7, 9 };
        \\    return values;
        \\}
        \\fn struct_assignment() -> Pair {
        \\    var value: Pair = uninit;
        \\    value = .{ .second = 11, .first = 22 };
        \\    return value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_aggregate_assignment_canonical.mc", source, &output);

    const array_body = try cFunctionBody(output.items, "static mc_array_u32_2 array_assignment(void)");
    try expectContains(array_body, "/* canonical executable MIR */");
    try expectContains(array_body, "mc_array_u32_2 values;");
    try expectContains(array_body, "(mc_array_u32_2){ .elems = {");
    try expectContains(array_body, "values = mc_exec_tmp_");
    try expectContains(array_body, "return mc_exec_tmp_");
    const array_declaration = std.mem.indexOf(u8, array_body, "mc_array_u32_2 values;") orelse return error.TestUnexpectedResult;
    const array_assignment = std.mem.indexOf(u8, array_body, "values = mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    const array_return = std.mem.indexOf(u8, array_body, "return mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(array_declaration < array_assignment);
    try std.testing.expect(array_assignment < array_return);

    const struct_body = try cFunctionBody(output.items, "static Pair struct_assignment(void)");
    try expectContains(struct_body, "/* canonical executable MIR */");
    try expectContains(struct_body, "Pair value;");
    try expectContains(struct_body, "(Pair){");
    try expectContains(struct_body, "value = mc_exec_tmp_");
    try expectContains(struct_body, "return mc_exec_tmp_");
    const struct_declaration = std.mem.indexOf(u8, struct_body, "Pair value;") orelse return error.TestUnexpectedResult;
    const struct_assignment = std.mem.indexOf(u8, struct_body, "value = mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    const struct_return = std.mem.indexOf(u8, struct_body, "return mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(struct_declaration < struct_assignment);
    try std.testing.expect(struct_assignment < struct_return);
}

test "lower-c emits array control-flow returns from MIR" {
    const source =
        \\extern fn hit(value: u32) -> void;
        \\fn choose_array(flag: bool, a: u32, b: u32) -> [2]u32 {
        \\    if (flag) {
        \\        return .{ a, b };
        \\    } else {
        \\        return .{ b, a };
        \\    }
        \\}
        \\fn choose_assign_array(flag: bool, a: u32, b: u32) -> [2]u32 {
        \\    var out: [2]u32 = .{ a, b };
        \\    if (flag) {
        \\        out = .{ b, a };
        \\    }
        \\    return out;
        \\}
        \\fn loop_array(flag: bool, a: u32, b: u32) -> [2]u32 {
        \\    while (flag) {
        \\    }
        \\    return .{ a, b };
        \\}
        \\fn side_then_array(a: u32, b: u32) -> [2]u32 {
        \\    hit(a);
        \\    return .{ a, b };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_array_control_returns.mc", source, &output);

    const choose_body = try cFunctionBody(output.items, "static mc_array_u32_2 choose_array(bool flag, uint32_t a, uint32_t b)");
    try expectCanonicalConditional(choose_body);
    try std.testing.expect(std.mem.count(u8, choose_body, "(mc_array_u32_2){ .elems = {") == 2);
    try std.testing.expect(std.mem.count(u8, choose_body, "return mc_exec_tmp_") == 2);
    try expectNotContains(choose_body, "mc_tmp");
    try expectNotContains(choose_body, "switch");

    const choose_assign_body = try cFunctionBody(output.items, "static mc_array_u32_2 choose_assign_array(bool flag, uint32_t a, uint32_t b)");
    try expectCanonicalConditional(choose_assign_body);
    try std.testing.expect(std.mem.count(u8, choose_assign_body, "(mc_array_u32_2){ .elems = {") >= 2);
    try expectContains(choose_assign_body, "return mc_exec_tmp_");
    try expectNotContains(choose_assign_body, "mc_tmp");
    try expectNotContains(choose_assign_body, "switch");

    const loop_body = try cFunctionBody(output.items, "static mc_array_u32_2 loop_array(bool flag, uint32_t a, uint32_t b)");
    if (isCanonicalExecutableCBody(loop_body)) {
        try expectContains(loop_body, "goto mc_bb_");
        try expectContains(loop_body, "(mc_array_u32_2){ .elems = {");
        try expectContains(loop_body, "return mc_exec_tmp_");
    } else {
        try expectContains(loop_body, "while (flag) {");
        try expectContains(loop_body, "return (mc_array_u32_2){ .elems = { a, b } };");
    }
    try expectNotContains(loop_body, "mc_tmp");
    try expectNotContains(loop_body, "switch");

    const side_body = try cFunctionBody(output.items, "static mc_array_u32_2 side_then_array(uint32_t a, uint32_t b)");
    const side_call = std.mem.indexOf(u8, side_body, "hit(") orelse return error.TestUnexpectedResult;
    const side_ret = std.mem.indexOf(u8, side_body, if (isCanonicalExecutableCBody(side_body)) "return mc_exec_tmp_" else "return (mc_array_u32_2)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side_call < side_ret);
    try expectNotContains(side_body, "mc_tmp");
}

test "lower-c emits scalar comparison returns from MIR" {
    const source =
        \\fn lt_u32(a: u32, b: u32) -> bool {
        \\    return a < b;
        \\}
        \\fn eq_i32(a: i32, b: i32) -> bool {
        \\    return a == b;
        \\}
        \\fn local_compare(a: u32, b: u32) -> bool {
        \\    let out: bool = a >= b;
        \\    return out;
        \\}
        \\fn assigned_compare(a: i32, b: i32) -> bool {
        \\    var out: bool = false;
        \\    out = a != b;
        \\    return out;
        \\}
        \\fn lt_f32(a: f32, b: f32) -> bool {
        \\    return a < b;
        \\}
        \\fn local_float_compare(a: f32, b: f32) -> bool {
        \\    let out: bool = a >= b;
        \\    return out;
        \\}
        \\fn assigned_float_compare(a: f32, b: f32) -> bool {
        \\    var out: bool = false;
        \\    out = a != b;
        \\    return out;
        \\}
        \\fn choose_compare(flag: bool, a: u32, b: u32) -> bool {
        \\    if (flag) {
        \\        return a < b;
        \\    } else {
        \\        return a > b;
        \\    }
        \\}
        \\fn choose_float_compare(flag: bool, a: f32, b: f32) -> bool {
        \\    if (flag) {
        \\        return a < b;
        \\    } else {
        \\        return a > b;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_scalar_comparison_returns.mc", source, &output);

    const lt_body = try cFunctionBody(output.items, "static bool lt_u32(uint32_t a, uint32_t b)");
    try expectLegacyOrCanonicalReturn(lt_body, "return (a < b);", " < ");

    const eq_body = try cFunctionBody(output.items, "static bool eq_i32(int32_t a, int32_t b)");
    try expectLegacyOrCanonicalReturn(eq_body, "return (a == b);", " == ");

    const local_body = try cFunctionBody(output.items, "static bool local_compare(uint32_t a, uint32_t b)");
    try expectLegacyOrCanonicalReturn(local_body, "return (a >= b);", " >= ");

    const assigned_body = try cFunctionBody(output.items, "static bool assigned_compare(int32_t a, int32_t b)");
    try expectLegacyOrCanonicalReturn(assigned_body, "return (a != b);", " != ");

    const lt_f32_body = try cFunctionBody(output.items, "static bool lt_f32(float a, float b)");
    try expectLegacyOrCanonicalReturn(lt_f32_body, "return (a < b);", " < ");

    const local_float_body = try cFunctionBody(output.items, "static bool local_float_compare(float a, float b)");
    try expectLegacyOrCanonicalReturn(local_float_body, "return (a >= b);", " >= ");

    const assigned_float_body = try cFunctionBody(output.items, "static bool assigned_float_compare(float a, float b)");
    try expectLegacyOrCanonicalReturn(assigned_float_body, "return (a != b);", " != ");

    const choose_body = try cFunctionBody(output.items, "static bool choose_compare(bool flag, uint32_t a, uint32_t b)");
    if (isCanonicalExecutableCBody(choose_body)) {
        try expectContains(choose_body, "if (mc_exec_tmp_");
        try expectContains(choose_body, " < ");
        try expectContains(choose_body, " > ");
        try expectContains(choose_body, "return mc_exec_tmp_");
    } else {
        try expectContains(choose_body, "if (flag) {");
        try expectContains(choose_body, "return (a < b);");
        try expectContains(choose_body, "return (a > b);");
    }
    try expectNotContains(choose_body, "switch");

    const choose_float_body = try cFunctionBody(output.items, "static bool choose_float_compare(bool flag, float a, float b)");
    try expectCanonicalConditional(choose_float_body);
    try expectContains(choose_float_body, " < ");
    try expectContains(choose_float_body, " > ");
    try expectContains(choose_float_body, "return mc_exec_tmp_");
    try expectNotContains(choose_float_body, "switch");
}

test "lower-c emits checked arithmetic returns from MIR without body fallback" {
    const source =
        \\fn add_u32(a: u32, b: u32) -> u32 {
        \\    return a + b;
        \\}
        \\fn sub_i32(a: i32, b: i32) -> i32 {
        \\    return a - b;
        \\}
        \\fn local_add(a: u32, b: u32) -> u32 {
        \\    let out: u32 = a + b;
        \\    return out;
        \\}
        \\fn assigned_sub(a: i32, b: i32) -> i32 {
        \\    var out: i32 = a;
        \\    out = a - b;
        \\    return out;
        \\}
        \\fn choose_add(flag: bool, a: u32, b: u32) -> u32 {
        \\    if (flag) {
        \\        return a + b;
        \\    } else {
        \\        return a - b;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_checked_arithmetic_returns.mc", source, &output);

    const add_body = try cFunctionBody(output.items, "static uint32_t add_u32(uint32_t a, uint32_t b)");
    try expectLegacyOrCanonicalReturn(add_body, "return mc_checked_add_u32(a, b);", "mc_checked_add_u32(");
    try expectNotContains(add_body, "mc_tmp");

    const sub_body = try cFunctionBody(output.items, "static int32_t sub_i32(int32_t a, int32_t b)");
    try expectLegacyOrCanonicalReturn(sub_body, "return mc_checked_sub_i32(a, b);", "mc_checked_sub_i32(");
    try expectNotContains(sub_body, "mc_tmp");

    const local_body = try cFunctionBody(output.items, "static uint32_t local_add(uint32_t a, uint32_t b)");
    try expectLegacyOrCanonicalReturn(local_body, "return mc_checked_add_u32(a, b);", "mc_checked_add_u32(");
    if (!isCanonicalExecutableCBody(local_body)) try expectNotContains(local_body, "uint32_t out");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static int32_t assigned_sub(int32_t a, int32_t b)");
    try expectLegacyOrCanonicalReturn(assigned_body, "return mc_checked_sub_i32(a, b);", "mc_checked_sub_i32(");
    if (!isCanonicalExecutableCBody(assigned_body)) {
        try expectNotContains(assigned_body, "int32_t out");
        try expectNotContains(assigned_body, "out =");
    }
    try expectNotContains(assigned_body, "mc_tmp");

    const choose_body = try cFunctionBody(output.items, "static uint32_t choose_add(bool flag, uint32_t a, uint32_t b)");
    if (isCanonicalExecutableCBody(choose_body)) {
        try expectContains(choose_body, "if (mc_exec_tmp_");
        try expectContains(choose_body, "mc_checked_add_u32(");
        try expectContains(choose_body, "mc_checked_sub_u32(");
    } else {
        try expectContains(choose_body, "if (flag) {");
        try expectContains(choose_body, "return mc_checked_add_u32(a, b);");
        try expectContains(choose_body, "return mc_checked_sub_u32(a, b);");
    }
    try expectNotContains(choose_body, "mc_tmp");
    try expectNotContains(choose_body, "switch");
}

test "lower-c emits checked unary returns from MIR without body fallback" {
    const source =
        \\fn neg_i32(a: i32) -> i32 {
        \\    return -a;
        \\}
        \\fn local_neg(a: i32) -> i32 {
        \\    let out: i32 = -a;
        \\    return out;
        \\}
        \\fn assigned_neg(a: i32) -> i32 {
        \\    var out: i32 = 0;
        \\    out = -a;
        \\    return out;
        \\}
        \\fn choose_neg(flag: bool, a: i32, b: i32) -> i32 {
        \\    if (flag) {
        \\        return -a;
        \\    } else {
        \\        return -b;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_checked_unary_returns.mc", source, &output);

    const neg_body = try cFunctionBody(output.items, "static int32_t neg_i32(int32_t a)");
    try expectLegacyOrCanonicalReturn(neg_body, "return mc_checked_neg_i32(a);", "mc_checked_neg_i32(");
    try expectNotContains(neg_body, "mc_tmp");

    const local_body = try cFunctionBody(output.items, "static int32_t local_neg(int32_t a)");
    try expectLegacyOrCanonicalReturn(local_body, "return mc_checked_neg_i32(a);", "mc_checked_neg_i32(");
    if (!isCanonicalExecutableCBody(local_body)) try expectNotContains(local_body, "int32_t out");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static int32_t assigned_neg(int32_t a)");
    try expectLegacyOrCanonicalReturn(assigned_body, "return mc_checked_neg_i32(a);", "mc_checked_neg_i32(");
    if (!isCanonicalExecutableCBody(assigned_body)) {
        try expectNotContains(assigned_body, "int32_t out");
        try expectNotContains(assigned_body, "out =");
    }
    try expectNotContains(assigned_body, "mc_tmp");

    const choose_body = try cFunctionBody(output.items, "static int32_t choose_neg(bool flag, int32_t a, int32_t b)");
    try expectContains(choose_body, if (isCanonicalExecutableCBody(choose_body)) "if (mc_exec_tmp_" else "if (flag)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, choose_body, "mc_checked_neg_i32("));
    try expectNotContains(choose_body, "mc_tmp");
    try expectNotContains(choose_body, "switch");
}

test "lower-c target-types negated integer literals in canonical MIR" {
    const source =
        \\fn inferred_suffix() -> i8 { let value = -1_i8; return value; }
        \\fn min_neg() -> i32 { let value: i32 = -2147483648; return -value; }
        \\fn min_div() -> i32 { let value: i32 = -2147483648; return value / -1; }
        \\fn min_rem() -> i32 { let value: i32 = -2147483648; return value % -1; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_target_typed_negated_literals.mc", source, &output);

    const suffix_body = try cFunctionBody(output.items, "static int8_t inferred_suffix(void)");
    try expectContains(suffix_body, "/* canonical executable MIR */");
    try expectContains(suffix_body, "= -1;");
    try expectNotContains(suffix_body, "mc_checked_neg_i8(");

    const neg_body = try cFunctionBody(output.items, "static int32_t min_neg(void)");
    try expectContains(neg_body, "/* canonical executable MIR */");
    try expectContains(neg_body, "mc_checked_neg_i32(");

    const div_body = try cFunctionBody(output.items, "static int32_t min_div(void)");
    try expectContains(div_body, "/* canonical executable MIR */");
    try expectContains(div_body, "mc_checked_div_i32(");

    const rem_body = try cFunctionBody(output.items, "static int32_t min_rem(void)");
    try expectContains(rem_body, "/* canonical executable MIR */");
    try expectContains(rem_body, "mc_checked_mod_i32(");
}

test "lower-c emits negative integer literal return from MIR without body fallback" {
    const source =
        \\fn negative_one() -> i32 {
        \\    return -1;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_negative_integer_literal_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static int32_t negative_one(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "= -1;");
    try expectContains(body, "return mc_exec_tmp_");
    try expectNotContains(body, "mc_checked_neg_i32");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits conversion literal return from MIR without body fallback" {
    const source =
        \\type W = wrap<u8>;
        \\fn convert() -> W {
        \\    return W.from_mod(300);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conversion_literal_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint8_t convert(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "((uint8_t)(mc_exec_tmp_");
    try expectContains(body, "return mc_exec_tmp_");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits typed unary call-target returns from MIR without body fallback" {
    const source =
        \\open enum State: u8 { ready = 1 }
        \\fn float_bits(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
        \\fn bits_float(value: u32) -> f32 {
        \\    return bitcast<f32>(value);
        \\}
        \\fn state_raw(state: State) -> u8 {
        \\    return state.raw();
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_typed_unary_call_target_returns.mc", source, &output);

    const float_bits = try cFunctionBody(output.items, "static uint32_t float_bits(float value)");
    try expectContains(float_bits, "mc_exec_tmp_0 = value;");
    try expectContains(float_bits, "mc_exec_tmp_1 = __builtin_bit_cast(uint32_t, mc_exec_tmp_0);");
    try expectContains(float_bits, "return mc_exec_tmp_1;");
    try expectNotContains(float_bits, "__builtin_memcpy");
    try expectNotContains(float_bits, "((uint32_t)(mc_exec_tmp_0))");

    const bits_float = try cFunctionBody(output.items, "static float bits_float(uint32_t value)");
    try expectContains(bits_float, "mc_exec_tmp_0 = value;");
    try expectContains(bits_float, "mc_exec_tmp_1 = __builtin_bit_cast(float, mc_exec_tmp_0);");
    try expectContains(bits_float, "return mc_exec_tmp_1;");
    try expectNotContains(bits_float, "__builtin_memcpy");
    try expectNotContains(bits_float, "((float)(mc_exec_tmp_0))");

    const state_raw = try cFunctionBody(output.items, "static uint8_t state_raw(State state)");
    try expectContains(state_raw, "mc_exec_tmp_0 = state;");
    try expectContains(state_raw, "mc_exec_tmp_1 = ((uint8_t)(mc_exec_tmp_0));");
    try expectContains(state_raw, "return mc_exec_tmp_1;");
    try expectNotContains(state_raw, "raw(");
}

test "lower-c typed unary fast path never substitutes an operand descendant" {
    const source =
        \\fn masked_bits(x: u32, y: u32) -> f32 {
        \\    return bitcast<f32>(x & y);
        \\}
        \\fn masked_phys(x: usize, y: usize) -> PAddr {
        \\    return phys(x & y);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_mir_typed_unary_operand_root.mc", source, &output);

    const masked_bits = try cFunctionBody(output.items, "static float masked_bits(uint32_t x, uint32_t y)");
    try expectContains(masked_bits, "mc_exec_tmp_2 = (mc_exec_tmp_0 & mc_exec_tmp_1);");
    try expectContains(masked_bits, "__builtin_bit_cast(float, mc_exec_tmp_2)");
    try expectNotContains(masked_bits, "__builtin_memcpy");

    const masked_phys = try cFunctionBody(output.items, "static uintptr_t masked_phys(uintptr_t x, uintptr_t y)");
    try expectContains(masked_phys, "/* canonical executable MIR */");
    try expectContains(masked_phys, " = (mc_exec_tmp_0 & mc_exec_tmp_1);");
    try expectContains(masked_phys, " = ((uintptr_t)(mc_exec_tmp_2));");
}

test "lower-c emits typed binary domain calls from MIR without body fallback" {
    const source =
        \\type S = serial<u32>;
        \\type T = counter<u64>;
        \\#[no_lang_trap]
        \\fn wrap_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
        \\    return wrapping.add(a, b);
        \\}
        \\fn seq_before(a: S, b: S) -> bool {
        \\    return S.before(a, b);
        \\}
        \\fn seq_after(a: S, b: S) -> bool {
        \\    return S.after(a, b);
        \\}
        \\fn seq_distance(a: S, b: S) -> wrap<u32> {
        \\    return S.distance(a, b);
        \\}
        \\fn tick_delta(now: T, start: T) -> wrap<u64> {
        \\    return T.delta_mod(now, start);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_typed_binary_domain_calls.mc", source, &output);

    try expectContains(try cFunctionBody(output.items, "static uint32_t wrap_add(uint32_t a, uint32_t b)"), "((uint32_t)(mc_exec_tmp_0) + (uint32_t)(mc_exec_tmp_1))");
    try expectContains(try cFunctionBody(output.items, "static bool seq_before(uint32_t a, uint32_t b)"), "(((int32_t)((mc_exec_tmp_0) - (mc_exec_tmp_1))) < 0)");
    try expectContains(try cFunctionBody(output.items, "static bool seq_after(uint32_t a, uint32_t b)"), "(((int32_t)((mc_exec_tmp_0) - (mc_exec_tmp_1))) > 0)");
    try expectContains(try cFunctionBody(output.items, "static uint32_t seq_distance(uint32_t a, uint32_t b)"), "((uint32_t)((mc_exec_tmp_0) - (mc_exec_tmp_1)))");
    try expectContains(try cFunctionBody(output.items, "static uint64_t tick_delta(uint64_t now, uint64_t start)"), "((uint64_t)((mc_exec_tmp_0) - (mc_exec_tmp_1)))");
}

test "lower-c typed binary domain fast path rejects call operands" {
    const source =
        \\type S = serial<u32>;
        \\fn identity(value: S) -> S { return value; }
        \\fn nested(a: S, b: S) -> bool {
        \\    return S.before(identity(a), b);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_mir_typed_binary_domain_nested.mc", source, &output);
    try expectContains(try cFunctionBody(output.items, "static bool nested(uint32_t a, uint32_t b)"), "identity(mc_exec_tmp_0)");
}

test "lower-c emits char literal return from MIR without body fallback" {
    const source =
        \\fn char_value() -> u16 {
        \\    return 'A';
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_char_literal_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint16_t char_value(void)");
    try expectContains(body, "65;");
    if (isCanonicalExecutableCBody(body)) {
        try expectContains(body, "return mc_exec_tmp_");
    } else {
        try expectContains(body, "return 65;");
        try expectNotContains(body, "mc_tmp");
    }
}

test "lower-c emits float literal returns from MIR without body fallback" {
    const source =
        \\extern fn mark_float(value: f32) -> f32;
        \\fn small() -> f32 {
        \\    return 1.5;
        \\}
        \\fn wide() -> f64 {
        \\    return 2.5;
        \\}
        \\fn local_small() -> f32 {
        \\    let x: f32 = 1.5;
        \\    return x;
        \\}
        \\fn assigned_small() -> f32 {
        \\    var x: f32 = 0.0;
        \\    x = 1.5;
        \\    return x;
        \\}
        \\fn direct_call_small() -> f32 {
        \\    return mark_float(1.5);
        \\}
        \\fn choose(flag: bool) -> f32 {
        \\    if (flag) {
        \\        return 1.5;
        \\    } else {
        \\        return 2.5;
        \\    }
        \\}
        \\fn choose_early(flag: bool) -> f32 {
        \\    if (flag) {
        \\        return 1.5;
        \\    }
        \\    return 2.5;
        \\}
        \\fn less_than_literal(value: f32) -> bool {
        \\    return value < 1.5;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_float_literal_return.mc", source, &output);

    const small_body = try cFunctionBody(output.items, "static float small(void)");
    try expectContains(small_body, "__builtin_bit_cast(float, ((uint32_t)0x3FC00000U))");
    try expectContains(small_body, "return mc_exec_tmp_");

    const wide_body = try cFunctionBody(output.items, "static double wide(void)");
    try expectContains(wide_body, "__builtin_bit_cast(double, ((uint64_t)0x4004000000000000ULL))");
    try expectContains(wide_body, "return mc_exec_tmp_");

    const local_body = try cFunctionBody(output.items, "static float local_small(void)");
    try expectContains(local_body, "__builtin_bit_cast(float, ((uint32_t)0x3FC00000U))");
    try expectContains(local_body, "float x = mc_exec_tmp_");
    try expectContains(local_body, "return mc_exec_tmp_");

    const assigned_body = try cFunctionBody(output.items, "static float assigned_small(void)");
    try expectContains(assigned_body, "__builtin_bit_cast(float, ((uint32_t)0x3FC00000U))");
    try expectContains(assigned_body, "return mc_exec_tmp_");

    const call_body = try cFunctionBody(output.items, "static float direct_call_small(void)");
    try expectContains(call_body, "__builtin_bit_cast(float, ((uint32_t)0x3FC00000U))");
    try expectContains(call_body, "mark_float(mc_exec_tmp_");

    const choose_body = try cFunctionBody(output.items, "static float choose(bool flag)");
    if (isCanonicalExecutableCBody(choose_body)) {
        try expectContains(choose_body, "0x3FC00000U");
        try expectContains(choose_body, "0x40200000U");
    } else {
        try expectContains(choose_body, "return 1.5f;");
        try expectContains(choose_body, "return 2.5f;");
    }

    const choose_early_body = try cFunctionBody(output.items, "static float choose_early(bool flag)");
    if (isCanonicalExecutableCBody(choose_early_body)) {
        try expectContains(choose_early_body, "0x3FC00000U");
        try expectContains(choose_early_body, "0x40200000U");
    } else {
        try expectContains(choose_early_body, "return 1.5f;");
        try expectContains(choose_early_body, "return 2.5f;");
    }

    const less_body = try cFunctionBody(output.items, "static bool less_than_literal(float value)");
    try expectContains(less_body, "0x3FC00000U");
    try expectContains(less_body, " < ");
    try expectContains(less_body, "return mc_exec_tmp_");
}

test "lower-c emits plain float binary returns from MIR without body fallback" {
    const source =
        \\fn product() -> f32 {
        \\    return 1.7 * 2.3;
        \\}
        \\fn quotient() -> f64 {
        \\    return 4.0 / 2.0;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_plain_float_binary_returns.mc", source, &output);

    const product_body = try cFunctionBody(output.items, "static float product(void)");
    try std.testing.expect(std.mem.count(u8, product_body, "__builtin_bit_cast(float") >= 2);
    try expectContains(product_body, " * ");
    try expectContains(product_body, "return mc_exec_tmp_");

    const quotient_body = try cFunctionBody(output.items, "static double quotient(void)");
    try std.testing.expect(std.mem.count(u8, quotient_body, "__builtin_bit_cast(double") >= 2);
    try expectContains(quotient_body, " / ");
    try expectContains(quotient_body, "return mc_exec_tmp_");
}

test "lower-c emits local and assigned char literal returns from MIR without body fallback" {
    const source =
        \\fn local_char() -> u16 {
        \\    let x: u16 = 'A';
        \\    return x;
        \\}
        \\fn assigned_char() -> u16 {
        \\    var x: u16 = 0;
        \\    x = 'B';
        \\    return x;
        \\}
        \\fn choose_char(flag: bool) -> u16 {
        \\    if (flag) {
        \\        return 'A';
        \\    } else {
        \\        return 'B';
        \\    }
        \\}
        \\fn choose_char_early(flag: bool) -> u16 {
        \\    if (flag) {
        \\        return 'A';
        \\    }
        \\    return 'B';
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_assigned_char_literal_return.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static uint16_t local_char(void)");
    try expectContains(local_body, "65;");
    if (isCanonicalExecutableCBody(local_body)) {
        try expectContains(local_body, "uint16_t x = mc_exec_tmp_");
        try expectContains(local_body, "return mc_exec_tmp_");
    } else {
        try expectContains(local_body, "return 65;");
        try expectNotContains(local_body, "uint16_t x");
        try expectNotContains(local_body, "mc_tmp");
    }

    const assigned_body = try cFunctionBody(output.items, "static uint16_t assigned_char(void)");
    try expectContains(assigned_body, "66;");
    if (isCanonicalExecutableCBody(assigned_body)) {
        try expectContains(assigned_body, "uint16_t x = mc_exec_tmp_");
        try expectContains(assigned_body, "x = mc_exec_tmp_");
        try expectContains(assigned_body, "return mc_exec_tmp_");
    } else {
        try expectContains(assigned_body, "return 66;");
        try expectNotContains(assigned_body, "uint16_t x");
        try expectNotContains(assigned_body, "x =");
        try expectNotContains(assigned_body, "mc_tmp");
    }

    const choose_body = try cFunctionBody(output.items, "static uint16_t choose_char(bool flag)");
    if (isCanonicalExecutableCBody(choose_body)) {
        try expectContains(choose_body, "= 65;");
        try expectContains(choose_body, "= 66;");
        try expectContains(choose_body, "return mc_exec_tmp_");
    } else {
        try expectContains(choose_body, "return 65;");
        try expectContains(choose_body, "return 66;");
        try expectNotContains(choose_body, "mc_tmp");
    }

    const choose_early_body = try cFunctionBody(output.items, "static uint16_t choose_char_early(bool flag)");
    if (isCanonicalExecutableCBody(choose_early_body)) {
        try expectContains(choose_early_body, "= 65;");
        try expectContains(choose_early_body, "= 66;");
        try expectContains(choose_early_body, "return mc_exec_tmp_");
    } else {
        try expectContains(choose_early_body, "return 65;");
        try expectContains(choose_early_body, "return 66;");
        try expectNotContains(choose_early_body, "mc_tmp");
    }
}

test "lower-c emits logical-not returns from MIR without body fallback" {
    const source =
        \\fn not_param(flag: bool) -> bool {
        \\    return !flag;
        \\}
        \\fn local_not(flag: bool) -> bool {
        \\    let out: bool = !flag;
        \\    return out;
        \\}
        \\fn assigned_not(flag: bool) -> bool {
        \\    var out: bool = false;
        \\    out = !flag;
        \\    return out;
        \\}
        \\fn choose_not(flag: bool, other: bool) -> bool {
        \\    if (flag) {
        \\        return !other;
        \\    } else {
        \\        return !flag;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_logical_not_returns.mc", source, &output);

    const not_body = try cFunctionBody(output.items, "static bool not_param(bool flag)");
    try expectLegacyOrCanonicalReturn(not_body, "return !flag;", "(!");

    const local_body = try cFunctionBody(output.items, "static bool local_not(bool flag)");
    try expectLegacyOrCanonicalReturn(local_body, "return !flag;", "(!");

    const assigned_body = try cFunctionBody(output.items, "static bool assigned_not(bool flag)");
    try expectLegacyOrCanonicalReturn(assigned_body, "return !flag;", "(!");

    const choose_body = try cFunctionBody(output.items, "static bool choose_not(bool flag, bool other)");
    if (isCanonicalExecutableCBody(choose_body)) {
        try expectContains(choose_body, "if (mc_exec_tmp_");
        try std.testing.expect(std.mem.count(u8, choose_body, "(!") >= 2);
        try expectContains(choose_body, "return mc_exec_tmp_");
    } else {
        try expectContains(choose_body, "if (flag) {");
        try expectContains(choose_body, "return !other;");
        try expectContains(choose_body, "return !flag;");
    }
    try expectNotContains(choose_body, "switch");
}

test "lower-c emits basic scalar returns from MIR without body fallback" {
    const source =
        \\fn int_literal() -> u32 {
        \\    return 42;
        \\}
        \\fn bool_literal() -> bool {
        \\    return true;
        \\}
        \\fn param_return(a: u32) -> u32 {
        \\    return a;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_basic_scalar_returns.mc", source, &output);

    const int_body = try cFunctionBody(output.items, "static uint32_t int_literal(void)");
    try expectLegacyOrCanonicalReturn(int_body, "return 42;", " = 42;");

    const bool_body = try cFunctionBody(output.items, "static bool bool_literal(void)");
    try expectLegacyOrCanonicalReturn(bool_body, "return true;", " = true;");

    const param_body = try cFunctionBody(output.items, "static uint32_t param_return(uint32_t a)");
    try expectLegacyOrCanonicalReturn(param_body, "return a;", " = a;");
}

test "lower-c emits local and assigned scalar returns from MIR without body fallback" {
    const source =
        \\fn local_int() -> u32 {
        \\    let x: u32 = 42;
        \\    return x;
        \\}
        \\fn assigned_int() -> u32 {
        \\    var x: u32 = 0;
        \\    x = 42;
        \\    return x;
        \\}
        \\fn local_bool() -> bool {
        \\    let b: bool = true;
        \\    return b;
        \\}
        \\fn assigned_bool() -> bool {
        \\    var b: bool = false;
        \\    b = true;
        \\    return b;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_assigned_scalar_returns.mc", source, &output);

    const local_int_body = try cFunctionBody(output.items, "static uint32_t local_int(void)");
    try expectLegacyOrCanonicalReturn(local_int_body, "return 42;", " = 42;");

    const assigned_int_body = try cFunctionBody(output.items, "static uint32_t assigned_int(void)");
    try expectLegacyOrCanonicalReturn(assigned_int_body, "return 42;", " = 42;");

    const local_bool_body = try cFunctionBody(output.items, "static bool local_bool(void)");
    try expectLegacyOrCanonicalReturn(local_bool_body, "return true;", " = true;");

    const assigned_bool_body = try cFunctionBody(output.items, "static bool assigned_bool(void)");
    try expectLegacyOrCanonicalReturn(assigned_bool_body, "return true;", " = true;");
}

test "lower-c preserves nullable pointer promotion locals from MIR without body fallback" {
    const source =
        \\extern fn consume_nullable(p: ?*mut u8) -> void;
        \\fn pointer_none() -> ?*mut u8 {
        \\    return null;
        \\}
        \\fn local_promotion(p: *mut u8) -> ?*mut u8 {
        \\    let maybe: ?*mut u8 = p;
        \\    return maybe;
        \\}
        \\fn call_promotion(p: *mut u8) -> void {
        \\    consume_nullable(p);
        \\}
        \\fn assigned_promotion(p: *mut u8) -> ?*mut u8 {
        \\    var maybe: ?*mut u8 = null;
        \\    maybe = p;
        \\    return maybe;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_nullable_pointer_promotions.mc", source, &output);

    const none_body = try cFunctionBody(output.items, "static uint8_t * pointer_none(void)");
    try expectContains(none_body, "= NULL;");
    try expectContains(none_body, "return mc_exec_tmp_");
    try expectNotContains(none_body, ".present");

    const local_body = try cFunctionBody(output.items, "static uint8_t * local_promotion(uint8_t * p)");
    try expectContains(local_body, "/* canonical executable MIR */");
    const local_guard = std.mem.indexOf(u8, local_body, "== NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const local_init = std.mem.indexOf(u8, local_body, "uint8_t * maybe = mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(local_guard < local_init);
    try expectContains(local_body, "return mc_exec_tmp_");

    const assigned_body = try cFunctionBody(output.items, "static uint8_t * assigned_promotion(uint8_t * p)");
    try expectContains(assigned_body, "/* canonical executable MIR */");
    try expectContains(assigned_body, "= NULL;");
    try expectContains(assigned_body, "uint8_t * maybe = mc_exec_tmp_");
    const assigned_guard = std.mem.indexOf(u8, assigned_body, "== NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const assigned_store = std.mem.indexOfPos(u8, assigned_body, assigned_guard, "\n        maybe = mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(assigned_guard < assigned_store);
    try expectContains(assigned_body, "return mc_exec_tmp_");

    const call_body = try cFunctionBody(output.items, "static void call_promotion(uint8_t * p)");
    try expectContains(call_body, "/* canonical executable MIR */");
    const guard = std.mem.indexOf(u8, call_body, "== NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const call = std.mem.indexOf(u8, call_body, "consume_nullable(mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < call);
}

test "lower-c emits nullable pointer try from MIR without body fallback" {
    const source =
        \\extern fn maybe_ptr() -> ?*mut u8;
        \\extern fn ptr_value(p: *mut u8) -> u32;
        \\extern fn consume_ptr(p: *mut u8) -> void;
        \\fn unwrap_param(maybe: ?*mut u8) -> *mut u8 {
        \\    return maybe?;
        \\}
        \\fn unwrap_call() -> *mut u8 {
        \\    return maybe_ptr()?;
        \\}
        \\fn arg_try(maybe: ?*mut u8) -> u32 {
        \\    return ptr_value(maybe?);
        \\}
        \\fn direct_arg_try() -> u32 {
        \\    return ptr_value(maybe_ptr()?);
        \\}
        \\fn expr_nullable_try() -> void {
        \\    consume_ptr(maybe_ptr()?);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_nullable_pointer_try.mc", source, &output);

    const unwrap_param_body = try cFunctionBody(output.items, "static uint8_t * unwrap_param(uint8_t * maybe)");
    try expectContains(unwrap_param_body, "= maybe;");
    try expectContains(unwrap_param_body, "== NULL) mc_trap_NullUnwrap();");
    try expectContains(unwrap_param_body, "return mc_exec_tmp_");

    const unwrap_call_body = try cFunctionBody(output.items, "static uint8_t * unwrap_call(void)");
    try expectContains(unwrap_call_body, "= maybe_ptr();");
    try expectContains(unwrap_call_body, "== NULL) mc_trap_NullUnwrap();");

    const arg_try_body = try cFunctionBody(output.items, "static uint32_t arg_try(uint8_t * maybe)");
    try expectContains(arg_try_body, "= maybe;");
    try expectContains(arg_try_body, "ptr_value(mc_exec_tmp_");

    const direct_arg_body = try cFunctionBody(output.items, "static uint32_t direct_arg_try(void)");
    try expectContains(direct_arg_body, "= maybe_ptr();");
    try expectContains(direct_arg_body, "ptr_value(mc_exec_tmp_");

    const expr_body = try cFunctionBody(output.items, "static void expr_nullable_try(void)");
    try expectContains(expr_body, "= maybe_ptr();");
    try expectContains(expr_body, "consume_ptr(mc_exec_tmp_");
    try expectNotContains(expr_body, "return consume_ptr");
}

test "lower-c emits nullable none returns from MIR without body fallback" {
    const source =
        \\fn direct_none() -> ?u32 {
        \\    return null;
        \\}
        \\fn local_none() -> ?u32 {
        \\    let x: ?u32 = null;
        \\    return x;
        \\}
        \\fn assigned_none() -> ?u32 {
        \\    var x: ?u32 = null;
        \\    x = null;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_nullable_none_returns.mc", source, &output);

    const direct_body = try cFunctionBody(output.items, "static mc_opt_u32 direct_none(void)");
    try expectContains(direct_body, "/* canonical executable MIR */");
    try expectContains(direct_body, "(mc_opt_u32){ .present = false }");
    try expectNotContains(direct_body, "mc_tmp");

    const local_body = try cFunctionBody(output.items, "static mc_opt_u32 local_none(void)");
    try expectContains(local_body, "/* canonical executable MIR */");
    try expectContains(local_body, "(mc_opt_u32){ .present = false }");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static mc_opt_u32 assigned_none(void)");
    try expectContains(assigned_body, "(mc_opt_u32){ .present = false }");
    try expectContains(assigned_body, if (isCanonicalExecutableCBody(assigned_body)) "return mc_exec_tmp_" else "return (mc_opt_u32)");
    try expectNotContains(assigned_body, "mc_tmp");
}

test "lower-c emits conditional nullable none returns from MIR without body fallback" {
    const source =
        \\fn choose_none(flag: bool) -> ?u32 {
        \\    if (flag) {
        \\        return null;
        \\    } else {
        \\        return null;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conditional_nullable_none_returns.mc", source, &output);

    const body = try cFunctionBody(output.items, "static mc_opt_u32 choose_none(bool flag)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "if (mc_exec_tmp_");
    try expectContains(body, "(mc_opt_u32){ .present = false }");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c preserves MIR void calls before nullable none returns" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\fn side_then_none() -> ?u32 {
        \\    hit(7);
        \\    return null;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_calls_before_nullable_none_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static mc_opt_u32 side_then_none(void)");
    const hit = std.mem.indexOf(u8, body, "hit(") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, if (isCanonicalExecutableCBody(body)) "return mc_exec_tmp_" else "return (mc_opt_u32){ .present = false };") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit < ret);
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits loop nullable none returns from MIR without body fallback" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\fn loop_then_none(flag: bool) -> ?u32 {
        \\    while flag {
        \\        hit(9);
        \\    }
        \\    return null;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_loop_nullable_none_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static mc_opt_u32 loop_then_none(bool flag)");
    try expectLegacyOrCanonicalLoop(body, "while (flag)");
    try expectContains(body, "hit(");
    try expectContains(body, if (isCanonicalExecutableCBody(body)) "return mc_exec_tmp_" else "return (mc_opt_u32){ .present = false };");
    try expectNotContains(body, "switch");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits enum literal returns from MIR without body fallback" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\fn color() -> Color {
        \\    return .blue;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_enum_literal_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static Color color(void)");
    // Canonical executable MIR carries the enum's numeric tag and nominal
    // result type; the C renderer no longer needs source case spelling.
    try expectNeedlesInOrder(body, &.{ "= 1;", "return mc_exec_tmp_" });
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits enum variant raw values from MIR without body fallback" {
    const source =
        \\enum Color: u32 { red = 3, blue = 20 }
        \\open enum OpenTag: u8 { lo = 1, hi = 2 }
        \\fn closed_variant_raw() -> u32 { return Color.blue.raw(); }
        \\fn open_variant_raw() -> u8 { return OpenTag.hi.raw(); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_enum_variant_raw.mc", source, &output);

    const closed = try cFunctionBody(output.items, "static uint32_t closed_variant_raw(void)");
    try expectContains(closed, "/* canonical executable MIR */");
    try expectContains(closed, "20");
    const open = try cFunctionBody(output.items, "static uint8_t open_variant_raw(void)");
    try expectContains(open, "/* canonical executable MIR */");
    try expectContains(open, "2");
}

test "lower-c emits nominal scalar resource flow from MIR without body fallback" {
    const source =
        \\extern fn disable_interrupts() -> IrqOff;
        \\extern fn restore_interrupts(cs: IrqOff) -> void;
        \\fn read_device(reg: u32, cs: IrqOff) -> u32 { return reg; }
        \\fn critical_read(reg: u32) -> u32 {
        \\    let cs: IrqOff = disable_interrupts();
        \\    let value: u32 = read_device(reg, cs);
        \\    restore_interrupts(cs);
        \\    return value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_nominal_scalar_resource.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t critical_read(uint32_t reg)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "uint8_t cs =");
    try expectContains(body, "read_device(");
    try expectContains(body, "restore_interrupts(");
}

test "lower-c emits nested fixed-array aggregates from MIR without body fallback" {
    const source =
        \\struct Bag { values: [2][2]u32 }
        \\fn make_bag() -> Bag {
        \\    return .{ .values = .{ .{ 1, 2 }, .{ 3, 4 } } };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_nested_array_aggregate.mc", source, &output);

    const body = try cFunctionBody(output.items, "static Bag make_bag(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "mc_array_mc_type_array_3_u32_1_2_2");
    try expectContains(body, "return mc_exec_tmp_");
}

test "lower-c compares value optionals with null from MIR without body fallback" {
    const source =
        \\fn present(value: u32) -> ?u32 { return value; }
        \\fn is_present(value: u32) -> bool { return present(value) != null; }
        \\fn is_absent(value: u32) -> bool { return present(value) == null; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_optional_null_compare.mc", source, &output);

    const present_body = try cFunctionBody(output.items, "static bool is_present(uint32_t value)");
    try expectContains(present_body, "/* canonical executable MIR */");
    try expectContains(present_body, ".present)");
    const absent_body = try cFunctionBody(output.items, "static bool is_absent(uint32_t value)");
    try expectContains(absent_body, "/* canonical executable MIR */");
    try expectContains(absent_body, "(!");
    try expectContains(absent_body, ".present)");
}

test "lower-c emits local and loop enum returns from MIR without body fallback" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\extern fn hit(value: u32) -> void;
        \\fn local_color() -> Color {
        \\    let c: Color = .blue;
        \\    return c;
        \\}
        \\fn assigned_color() -> Color {
        \\    var c: Color = .red;
        \\    c = .blue;
        \\    return c;
        \\}
        \\fn loop_color(flag: bool) -> Color {
        \\    while flag {
        \\        hit(1);
        \\    }
        \\    return .blue;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_loop_enum_returns.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static Color local_color(void)");
    try expectContains(local_body, "/* canonical executable MIR */");
    try expectContains(local_body, "mc_trap_InvalidRepresentation");
    try expectContains(local_body, "return mc_exec_tmp_");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static Color assigned_color(void)");
    if (isCanonicalExecutableCBody(assigned_body)) {
        try expectContains(assigned_body, "mc_trap_InvalidRepresentation");
        try expectContains(assigned_body, "return mc_exec_tmp_");
    } else try expectContains(assigned_body, "return Color_blue;");
    try expectNotContains(assigned_body, "mc_tmp");

    const loop_body = try cFunctionBody(output.items, "static Color loop_color(bool flag)");
    try expectLegacyOrCanonicalLoop(loop_body, "while (flag)");
    try expectContains(loop_body, "hit(");
    try expectContains(loop_body, if (isCanonicalExecutableCBody(loop_body)) "return mc_exec_tmp_" else "return Color_blue;");
    try expectNotContains(loop_body, "switch");
    try expectNotContains(loop_body, "mc_tmp");
}

test "lower-c preserves MIR void calls before local enum returns" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\extern fn hit(value: u32) -> void;
        \\fn side_then_local_color() -> Color {
        \\    hit(2);
        \\    let c: Color = .blue;
        \\    return c;
        \\}
        \\fn side_then_assigned_color() -> Color {
        \\    hit(3);
        \\    var c: Color = .red;
        \\    c = .blue;
        \\    return c;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_calls_before_local_enum_return.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static Color side_then_local_color(void)");
    const local_hit = std.mem.indexOf(u8, local_body, "hit(") orelse return error.TestUnexpectedResult;
    const local_ret = std.mem.indexOf(u8, local_body, "return mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(local_hit < local_ret);
    try expectContains(local_body, "mc_trap_InvalidRepresentation");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static Color side_then_assigned_color(void)");
    const assigned_hit = std.mem.indexOf(u8, assigned_body, "hit(") orelse return error.TestUnexpectedResult;
    const assigned_ret = std.mem.indexOf(u8, assigned_body, if (isCanonicalExecutableCBody(assigned_body)) "return mc_exec_tmp_" else "return Color_blue;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(assigned_hit < assigned_ret);
    if (isCanonicalExecutableCBody(assigned_body)) try expectContains(assigned_body, "mc_trap_InvalidRepresentation");
    try expectNotContains(assigned_body, "mc_tmp");
}

test "lower-c emits conditional enum literal returns from MIR without body fallback" {
    const source =
        \\enum Color {
        \\    red,
        \\    blue,
        \\}
        \\fn choose(flag: bool) -> Color {
        \\    if (flag) {
        \\        return .red;
        \\    } else {
        \\        return .blue;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conditional_enum_literal_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static Color choose(bool flag)");
    try expectCanonicalConditional(body);
    try expectContains(body, " = 0;");
    try expectContains(body, " = 1;");
    try expectContains(body, "return ");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c preserves MIR void calls before direct-call returns" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\extern fn make(value: i32) -> i32;
        \\fn side_then_call() -> i32 {
        \\    hit(0);
        \\    return make(1);
        \\}
        \\fn return_call_add(a: i32, b: i32) -> i32 {
        \\    return make(a + b);
        \\}
        \\fn return_call_neg(a: i32) -> i32 {
        \\    return make(-a);
        \\}
        \\fn return_local_call(a: i32) -> i32 {
        \\    let x: i32 = make(a);
        \\    return x;
        \\}
        \\fn return_assigned_call(a: i32) -> i32 {
        \\    var x: i32 = 0;
        \\    x = make(a);
        \\    return x;
        \\}
        \\fn return_local_call_add(a: i32, b: i32) -> i32 {
        \\    let x: i32 = make(a + b);
        \\    return x;
        \\}
        \\fn return_assigned_call_neg(a: i32) -> i32 {
        \\    var x: i32 = 0;
        \\    x = make(-a);
        \\    return x;
        \\}
        \\fn side_then_local_call_add(a: i32, b: i32) -> i32 {
        \\    hit(0);
        \\    let x: i32 = make(a + b);
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_calls_before_direct_call_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static int32_t side_then_call(void)");
    const hit = std.mem.indexOf(u8, body, "hit(") orelse return error.TestUnexpectedResult;
    const ret = std.mem.indexOf(u8, body, if (isCanonicalExecutableCBody(body)) "return mc_exec_tmp_" else "return make(1);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit < ret);
    try expectNotContains(body, "mc_tmp");

    const add_body = try cFunctionBody(output.items, "static int32_t return_call_add(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(add_body))
        try expectNeedlesInOrder(add_body, &.{ "mc_checked_add_i32(", "= make(", "return mc_exec_tmp_" })
    else
        try expectContains(add_body, "return make(mc_checked_add_i32(a, b));");
    try expectNotContains(add_body, "mc_tmp");

    const neg_body = try cFunctionBody(output.items, "static int32_t return_call_neg(int32_t a)");
    if (isCanonicalExecutableCBody(neg_body))
        try expectNeedlesInOrder(neg_body, &.{ "mc_checked_neg_i32(", "= make(", "return mc_exec_tmp_" })
    else
        try expectContains(neg_body, "return make(mc_checked_neg_i32(a));");
    try expectNotContains(neg_body, "mc_tmp");

    const local_call_body = try cFunctionBody(output.items, "static int32_t return_local_call(int32_t a)");
    try expectLegacyOrCanonicalReturn(local_call_body, "return make(a);", "= make(");

    const assigned_call_body = try cFunctionBody(output.items, "static int32_t return_assigned_call(int32_t a)");
    try expectLegacyOrCanonicalReturn(assigned_call_body, "return make(a);", "= make(");

    const local_call_add_body = try cFunctionBody(output.items, "static int32_t return_local_call_add(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(local_call_add_body))
        try expectNeedlesInOrder(local_call_add_body, &.{ "mc_checked_add_i32(", "= make(", "return mc_exec_tmp_" })
    else
        try expectContains(local_call_add_body, "return make(mc_checked_add_i32(a, b));");
    if (!isCanonicalExecutableCBody(local_call_add_body)) try expectNotContains(local_call_add_body, "int32_t x");
    try expectNotContains(local_call_add_body, "mc_tmp");

    const assigned_call_neg_body = try cFunctionBody(output.items, "static int32_t return_assigned_call_neg(int32_t a)");
    if (isCanonicalExecutableCBody(assigned_call_neg_body)) {
        try expectNeedlesInOrder(assigned_call_neg_body, &.{ "mc_checked_neg_i32(", "= make(", "return mc_exec_tmp_" });
    } else {
        try expectContains(assigned_call_neg_body, "return make(mc_checked_neg_i32(a));");
        try expectNotContains(assigned_call_neg_body, "int32_t x");
        try expectNotContains(assigned_call_neg_body, "x =");
        try expectNotContains(assigned_call_neg_body, "mc_tmp");
    }

    const side_then_local_call_add_body = try cFunctionBody(output.items, "static int32_t side_then_local_call_add(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(side_then_local_call_add_body)) {
        try expectNeedlesInOrder(side_then_local_call_add_body, &.{ "hit(", "mc_checked_add_i32(", "= make(", "return mc_exec_tmp_" });
    } else {
        const side_hit = std.mem.indexOf(u8, side_then_local_call_add_body, "hit(0);") orelse return error.TestUnexpectedResult;
        const side_ret = std.mem.indexOf(u8, side_then_local_call_add_body, "return make(mc_checked_add_i32(a, b));") orelse return error.TestUnexpectedResult;
        try std.testing.expect(side_hit < side_ret);
        try expectNotContains(side_then_local_call_add_body, "int32_t x");
    }
    try expectNotContains(side_then_local_call_add_body, "mc_tmp");
}

test "lower-c emits local-init call feeding return call from MIR without body fallback" {
    const source =
        \\extern fn make_count(seed: u32) -> u32;
        \\extern fn use_count(value: u32) -> u32;
        \\extern fn use_count_with_seed(value: u32, seed: u32) -> u32;
        \\extern fn align_count(value: u32, amount: u32) -> u32;
        \\fn local_call_arg(seed: u32) -> u32 {
        \\    let count: u32 = make_count(seed);
        \\    return use_count(count);
        \\}
        \\fn local_call_arg_with_leaf(seed: u32) -> u32 {
        \\    let count: u32 = make_count(seed);
        \\    return use_count_with_seed(count, seed);
        \\}
        \\fn local_nested_init_call_arg(seed: u32) -> u32 {
        \\    let count: u32 = align_count(make_count(seed), 4096);
        \\    return use_count(count);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_init_call_feeds_return_call.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static uint32_t local_call_arg(uint32_t seed)");
    if (isCanonicalExecutableCBody(local_body)) {
        try expectNeedlesInOrder(local_body, &.{ "= make_count(", "= use_count(", "return mc_exec_tmp_" });
    } else {
        const init = std.mem.indexOf(u8, local_body, "uint32_t count = make_count(seed);") orelse return error.TestUnexpectedResult;
        const ret = std.mem.indexOf(u8, local_body, "return use_count(count);") orelse return error.TestUnexpectedResult;
        try std.testing.expect(init < ret);
    }
    try expectNotContains(local_body, "return use_count(make_count(seed));");
    try expectNotContains(local_body, "mc_tmp");

    const leaf_body = try cFunctionBody(output.items, "static uint32_t local_call_arg_with_leaf(uint32_t seed)");
    if (isCanonicalExecutableCBody(leaf_body)) {
        try expectNeedlesInOrder(leaf_body, &.{ "= make_count(", "= use_count_with_seed(", "return mc_exec_tmp_" });
    } else {
        const leaf_init = std.mem.indexOf(u8, leaf_body, "uint32_t count = make_count(seed);") orelse return error.TestUnexpectedResult;
        const leaf_ret = std.mem.indexOf(u8, leaf_body, "return use_count_with_seed(count, seed);") orelse return error.TestUnexpectedResult;
        try std.testing.expect(leaf_init < leaf_ret);
    }
    try expectNotContains(leaf_body, "return use_count_with_seed(make_count(seed), seed);");
    try expectNotContains(leaf_body, "mc_tmp");

    const nested_body = try cFunctionBody(output.items, "static uint32_t local_nested_init_call_arg(uint32_t seed)");
    if (isCanonicalExecutableCBody(nested_body)) {
        try expectNeedlesInOrder(nested_body, &.{ "= make_count(", "= align_count(", "= use_count(", "return mc_exec_tmp_" });
    } else {
        const nested_init = std.mem.indexOf(u8, nested_body, "uint32_t count = align_count(make_count(seed), 4096);") orelse return error.TestUnexpectedResult;
        const nested_ret = std.mem.indexOf(u8, nested_body, "return use_count(count);") orelse return error.TestUnexpectedResult;
        try std.testing.expect(nested_init < nested_ret);
    }
    try expectNotContains(nested_body, "mc_tmp");
}

test "lower-c emits discarded and indirect calls from MIR without body fallback" {
    const source =
        \\extern fn combine(left: u32, right: u32) -> u32;
        \\extern fn entry_of() -> fn() -> void;
        \\fn discard_value(left: u32, right: u32) -> void {
        \\    combine(left, right);
        \\}
        \\fn call_entry_param(entry: fn() -> void) -> void {
        \\    entry();
        \\}
        \\fn call_fn_pointer() -> void {
        \\    let entry: fn() -> void = entry_of();
        \\    entry();
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_call_statements.mc", source, &output);

    const discard_body = try cFunctionBody(output.items, "static void discard_value(uint32_t left, uint32_t right)");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, discard_body, if (isCanonicalExecutableCBody(discard_body)) "= combine(" else "combine(left, right);"));
    try expectNotContains(discard_body, "return combine");
    try expectNotContains(discard_body, "mc_tmp");

    const parameter_body = try cFunctionBody(output.items, "static void call_entry_param(mc_fnptr_4_void entry)");
    try expectContains(parameter_body, "/* canonical executable MIR */");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, parameter_body, "__auto_type mc_exec_tmp_0 = entry;"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, parameter_body, "(mc_exec_tmp_0)();"));
    try expectNotContains(parameter_body, "mc_tmp");

    const local_body = try cFunctionBody(output.items, "static void call_fn_pointer(void)");
    try expectContains(local_body, "/* canonical executable MIR */");
    const init = std.mem.indexOf(u8, local_body, "__auto_type mc_exec_tmp_0 = entry_of();") orelse return error.TestUnexpectedResult;
    const call = std.mem.indexOfPos(u8, local_body, init + 1, "(mc_exec_tmp_1)();") orelse return error.TestUnexpectedResult;
    try std.testing.expect(init < call);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, local_body, "entry_of();"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, local_body, "__auto_type entry = mc_exec_tmp_0;"));
    try expectNotContains(local_body, "entry_of()();");
    try expectNotContains(local_body, "mc_tmp");
}

test "lower-c emits enum literal direct-call arguments from MIR without body fallback" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\extern fn sink(mode: Mode) -> Mode;
        \\fn pass() -> Mode {
        \\    return sink(.write);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_enum_direct_call_argument.mc", source, &output);

    const body = try cFunctionBody(output.items, "static Mode pass(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "= sink(");
    try expectContains(body, "mc_trap_InvalidRepresentation");
    try expectContains(body, "return mc_exec_tmp_");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits enum literal compare operands from MIR without body fallback" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn is_read(mode: Mode) -> bool {
        \\    return mode == .read;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_enum_literal_compare_operands.mc", source, &output);

    const body = try cFunctionBody(output.items, "static bool is_read(Mode mode)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "mc_trap_InvalidRepresentation");
    try expectContains(body, " == ");
    try expectContains(body, "return mc_exec_tmp_");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits enum literal explicit casts from MIR without body fallback" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn cast_mode() -> Mode {
        \\    return .write as Mode;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_enum_literal_explicit_cast.mc", source, &output);

    const body = try cFunctionBody(output.items, "static Mode cast_mode(void)");
    try expectContains(body, "mc_exec_tmp_1 = ((Mode)(mc_exec_tmp_0));");
    try expectContains(body, "return mc_exec_tmp_1;");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c emits enum, pointer-address, and signedness casts from executable MIR" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn enum_raw(mode: Mode) -> u8 { return mode as u8; }
        \\fn pointer_address(pointer: *mut u8) -> PAddr { unsafe { return pointer as PAddr; } }
        \\fn signed_bits(value: u64) -> i64 { return value as i64; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_representation_casts.mc", source, &output);

    for ([_][]const u8{ "static uint8_t enum_raw(Mode mode)", "static uintptr_t pointer_address(uint8_t * pointer)", "static int64_t signed_bits(uint64_t value)" }) |signature| {
        const body = try cFunctionBody(output.items, signature);
        try expectContains(body, "/* canonical executable MIR */");
    }
}

test "lower-c emits transparent integer domain casts from executable MIR" {
    const source =
        \\fn wrapping_add_u64(a: u64, b: u64) -> u64 {
        \\    let wa: wrap<u64> = a as wrap<u64>;
        \\    let wb: wrap<u64> = b as wrap<u64>;
        \\    return (wa + wb) as u64;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_domain_casts.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint64_t wrapping_add_u64(uint64_t a, uint64_t b)");
    try expectContains(body, "/* canonical executable MIR */");
}

test "lower-c scalar switch returns lower from MIR without body fallback" {
    const source =
        \\fn classify(n: i32) -> u32 {
        \\    switch n {
        \\        -1 => { return 1; },
        \\        0, 2 => { return 2; },
        \\        _ => { return 3; },
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_scalar_switch.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t classify(int32_t n)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "switch (mc_exec_tmp_");
    try expectContains(body, "case -1: goto mc_bb_");
    try expectContains(body, "case 0: goto mc_bb_");
    try expectContains(body, "case 2: goto mc_bb_");
    try expectContains(body, "default: goto mc_bb_");
    try expectContains(body, "return mc_exec_tmp_");
}

test "lower-c emits local global returns from MIR" {
    const source =
        \\global g: u32 = 0;
        \\fn local_global_return() -> u32 {
        \\    let x: u32 = g;
        \\    return x;
        \\}
        \\fn assigned_global_return() -> u32 {
        \\    var x: u32 = 0;
        \\    x = g;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_global_return.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static uint32_t local_global_return(void)");
    try expectContains(local_body, "mc_race_load_u32(&g)");
    if (!isCanonicalExecutableCBody(local_body)) try expectNotContains(local_body, "uint32_t x");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static uint32_t assigned_global_return(void)");
    try expectContains(assigned_body, "mc_race_load_u32(&g)");
    if (!isCanonicalExecutableCBody(assigned_body)) {
        try expectNotContains(assigned_body, "uint32_t x");
        try expectNotContains(assigned_body, "x =");
    }
    try expectNotContains(assigned_body, "mc_tmp");
}

test "lower-c inferred local global return lowers without function body fallback" {
    const source =
        \\global g: u32 = 0;
        \\fn inferred_global_return() -> u32 {
        \\    let x = g;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_global_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t inferred_global_return(void)");
    try expectContains(body, "mc_race_load_u32(&g)");
    if (!isCanonicalExecutableCBody(body)) try expectNotContains(body, "uint32_t x");
    try expectNotContains(body, "mc_tmp");
}

test "lower-c preserves MIR void calls before global returns" {
    const source =
        \\global g: u32 = 0;
        \\extern fn hit(value: i32) -> void;
        \\fn side_then_global_return() -> u32 {
        \\    hit(4);
        \\    return g;
        \\}
        \\fn side_then_local_global_return() -> u32 {
        \\    hit(5);
        \\    let x: u32 = g;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_calls_before_global_return.mc", source, &output);

    const direct_body = try cFunctionBody(output.items, "static uint32_t side_then_global_return(void)");
    const direct_hit = std.mem.indexOf(u8, direct_body, "hit(") orelse return error.TestUnexpectedResult;
    const direct_ret = std.mem.indexOf(u8, direct_body, if (isCanonicalExecutableCBody(direct_body)) "return mc_exec_tmp_" else "return ((uint32_t)mc_race_load_u32(&g));") orelse return error.TestUnexpectedResult;
    try std.testing.expect(direct_hit < direct_ret);
    try expectNotContains(direct_body, "mc_tmp");

    const local_body = try cFunctionBody(output.items, "static uint32_t side_then_local_global_return(void)");
    const local_hit = std.mem.indexOf(u8, local_body, "hit(") orelse return error.TestUnexpectedResult;
    const local_ret = std.mem.indexOf(u8, local_body, if (isCanonicalExecutableCBody(local_body)) "return mc_exec_tmp_" else "return ((uint32_t)mc_race_load_u32(&g));") orelse return error.TestUnexpectedResult;
    try std.testing.expect(local_hit < local_ret);
    if (!isCanonicalExecutableCBody(local_body)) try expectNotContains(local_body, "uint32_t x");
    try expectNotContains(local_body, "mc_tmp");
}

test "lower-c scalar global reads lower from MIR without body fallback" {
    const source =
        \\global flag: bool = false;
        \\const LIMIT: u32 = 7;
        \\fn read_flag() -> bool {
        \\    return flag;
        \\}
        \\fn write_flag(value: bool) -> void {
        \\    flag = value;
        \\}
        \\fn read_limit() -> u32 {
        \\    return LIMIT;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_scalar_global_reads.mc", source, &output);

    const load_body = try cFunctionBody(output.items, "static bool read_flag(void)");
    try expectContains(load_body, "mc_race_load_bool(&flag)");

    const store_body = try cFunctionBody(output.items, "static void write_flag(bool value)");
    try expectContains(store_body, "mc_race_store_bool(&flag, (bool)");

    const const_body = try cFunctionBody(output.items, "static uint32_t read_limit(void)");
    try expectContains(const_body, "LIMIT");
}

test "lower-c ordinary bool global accesses lower from MIR without body fallback" {
    const source =
        \\global flag: bool = false;
        \\fn read_flag() -> bool {
        \\    return flag;
        \\}
        \\fn write_flag(value: bool) -> void {
        \\    flag = value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_ordinary_bool_global.mc", source, &output);

    const load_body = try cFunctionBody(output.items, "static bool read_flag(void)");
    try expectContains(load_body, "mc_race_load_bool(&flag)");

    const store_body = try cFunctionBody(output.items, "static void write_flag(bool value)");
    try expectContains(store_body, "mc_race_store_bool(&flag, (bool)");
}

test "lower-c immutable scalar global reads lower from MIR without body fallback" {
    const source =
        \\const LIMIT: u32 = 7;
        \\fn read_limit() -> u32 {
        \\    return LIMIT;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_immutable_scalar_global.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t read_limit(void)");
    try expectContains(body, "LIMIT");
    try expectNotContains(body, "mc_race_load");
}

test "lower-c preserves MIR void calls before conditional returns" {
    const source =
        \\extern fn hit(value: i32) -> void;
        \\extern fn make(value: i32) -> i32;
        \\fn side_then_cond(flag: bool) -> i32 {
        \\    hit(0);
        \\    if (flag) {
        \\        return 1;
        \\    } else {
        \\        return 2;
        \\    }
        \\}
        \\fn choose_return_call_checked(flag: bool, a: i32, b: i32) -> i32 {
        \\    if (flag) {
        \\        return make(a + b);
        \\    } else {
        \\        return make(a - b);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_calls_before_conditional_return.mc", source, &output);

    const body = try cFunctionBody(output.items, "static int32_t side_then_cond(bool flag)");
    const hit = std.mem.indexOf(u8, body, "hit(") orelse return error.TestUnexpectedResult;
    const branch = std.mem.indexOf(u8, body, if (isCanonicalExecutableCBody(body)) "if (mc_exec_tmp_" else "if (flag)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(hit < branch);
    if (isCanonicalExecutableCBody(body)) {
        try expectContains(body, " = 1;");
        try expectContains(body, " = 2;");
    } else {
        try expectContains(body, "return 1;");
        try expectContains(body, "return 2;");
    }

    const checked_body = try cFunctionBody(output.items, "static int32_t choose_return_call_checked(bool flag, int32_t a, int32_t b)");
    try expectCanonicalConditional(checked_body);
    try expectContains(checked_body, "mc_checked_add_i32(");
    try expectContains(checked_body, "mc_checked_sub_i32(");
    try expectContains(checked_body, "= make(");
    try expectContains(checked_body, "return mc_exec_tmp_");
    try expectNotContains(checked_body, "mc_tmp");
    try expectNotContains(checked_body, "switch");
}

test "lower-c runtime hook suppression uses VerifiedProgram runtime hook facts" {
    const source =
        \\export fn mc_ksan_check(addr: usize, size: usize) -> void {}
        \\export fn mc_ksan_store(addr: usize, size: usize) -> void {}
    ;
    var parsed = try test_support.parseModule("c_runtime_hook_facts.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const program = try backend_mod.VerifiedProgram.init(&module_mir, &parsed.reporter);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c_runtime.appendHeaderAndSanitizerHooks(
        std.testing.allocator,
        program.runtime_hooks,
        &output,
        "/* test-profile */\n",
    );

    try expectNotContains(output.items, "MC_WEAK void mc_ksan_check");
    try expectNotContains(output.items, "MC_WEAK void mc_ksan_store");
    try expectContains(output.items, "MC_WEAK void mc_ksan_poison");
    try expectContains(output.items, "MC_WEAK void mc_csan_read");
}

test "lower-c typed indirect call returns lower from MIR without body fallback" {
    const source =
        \\fn add(left: u32, right: u32) -> u32 { return left + right; }
        \\fn mul(left: u32, right: u32) -> u32 { return left * right; }
        \\global default_op: fn(u32, u32) -> u32 = add;
        \\global default_ops: [2]fn(u32, u32) -> u32 = .{ add, mul };
        \\struct BinOp { combine: fn(u32, u32) -> u32 }
        \\global default_box: BinOp = .{ .combine = add };
        \\global default_boxes: [2]BinOp = .{ .{ .combine = add }, .{ .combine = mul } };
        \\fn apply(op: fn(u32, u32) -> u32, x: u32, y: u32) -> u32 { return op(x, y); }
        \\fn dispatch(o: *BinOp, x: u32, y: u32) -> u32 { return o.combine(x, y); }
        \\fn global_op_call(x: u32, y: u32) -> u32 { return default_op(x, y); }
        \\fn global_op_array_call(x: u32, y: u32) -> u32 { return default_ops[1](x, y); }
        \\fn global_box_call(x: u32, y: u32) -> u32 { return default_box.combine(x, y); }
        \\fn global_box_array_call(x: u32, y: u32) -> u32 { return default_boxes[1].combine(x, y); }
        \\fn local_fn_pointer_call(x: u32, y: u32) -> u32 {
        \\    let op: fn(u32, u32) -> u32 = mul;
        \\    return op(x, y);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_typed_indirect_call_returns.mc", source, &output);

    const param_body = try cFunctionBody(output.items, "static uint32_t apply(");
    try expectContains(param_body, "/* canonical executable MIR */");
    try expectContains(param_body, "__auto_type mc_exec_tmp_0 = op;");
    try expectContains(param_body, "(mc_exec_tmp_0)(mc_exec_tmp_1, mc_exec_tmp_2)");
    try expectContains(param_body, "return mc_exec_tmp_3;");
    try expectNotContains(param_body, "mc_tmp");

    const dispatch_body = try cFunctionBody(output.items, "static uint32_t dispatch(");
    try expectContains(dispatch_body, "/* canonical executable MIR */");
    try expectContains(dispatch_body, "__atomic_load_n(");
    try expectContains(dispatch_body, ")(mc_exec_tmp_");

    const global_body = try cFunctionBody(output.items, "static uint32_t global_op_call(");
    try expectContains(global_body, "/* canonical executable MIR */");
    try expectContains(global_body, "__auto_type mc_exec_tmp_0 = __atomic_load_n(&default_op, __ATOMIC_RELAXED);");
    try expectContains(global_body, ")(mc_exec_tmp_");
    try expectNotContains(global_body, "mc_tmp");

    const field_body = try cFunctionBody(output.items, "static uint32_t global_box_call(");
    try expectContains(field_body, "/* canonical executable MIR */");
    try expectContains(field_body, "__atomic_load_n(&((default_box).combine), __ATOMIC_RELAXED)");
    try expectContains(field_body, ")(mc_exec_tmp_");
    try expectNotContains(field_body, "mc_tmp");

    const array_body = try cFunctionBody(output.items, "static uint32_t global_op_array_call(");
    try expectContains(array_body, "/* canonical executable MIR */");
    try expectContains(array_body, "default_ops).elems[mc_check_index_usize(mc_exec_tmp_0, 2)]");
    try expectContains(array_body, ")(mc_exec_tmp_");
    try expectNotContains(array_body, "mc_tmp");

    const array_field_body = try cFunctionBody(output.items, "static uint32_t global_box_array_call(");
    try expectContains(array_field_body, "/* canonical executable MIR */");
    try expectContains(array_field_body, "default_boxes).elems[mc_check_index_usize(mc_exec_tmp_0, 2)].combine");
    try expectContains(array_field_body, ")(mc_exec_tmp_");
    try expectNotContains(array_field_body, "mc_tmp");

    const local_body = try cFunctionBody(output.items, "static uint32_t local_fn_pointer_call(");
    try expectContains(local_body, "/* canonical executable MIR */");
    try expectContains(local_body, "= mul;");
    try expectContains(local_body, ")(mc_exec_tmp_");
    try expectContains(local_body, "return mc_exec_tmp_");
}

test "lower-c value optional pointer derefs lower race-tolerantly" {
    const source =
        \\struct Point { x: u32, y: u32 }
        \\fn load_scalar(p: *mut ?u32) -> ?u32 { return p.*; }
        \\fn store_scalar(p: *mut ?u32, value: ?u32) -> void { p.* = value; }
        \\fn load_point(p: *mut ?Point) -> ?Point { return p.*; }
        \\fn store_point(p: *mut ?Point, value: ?Point) -> void { p.* = value; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_optional_race.mc", source, &output);

    const scalar_load = try cFunctionBody(output.items, "static mc_opt_u32 load_scalar(mc_opt_u32 * p)");
    try expectContains(scalar_load, "mc_race_load_bool");
    try expectContains(scalar_load, "mc_race_load_u32");
    const scalar_store = try cFunctionBody(output.items, "static void store_scalar(mc_opt_u32 * p, mc_opt_u32 value)");
    try expectContains(scalar_store, "mc_race_store_u32");
    try expectContains(scalar_store, "mc_race_store_bool");

    const point_load = try cFunctionBody(output.items, "static mc_opt_mc_type_struct_5_Point load_point(mc_opt_mc_type_struct_5_Point * p)");
    try expectContains(point_load, "mc_race_load_bool");
    try std.testing.expect(std.mem.count(u8, point_load, "mc_race_load_u32") == 2);
    const point_store = try cFunctionBody(output.items, "static void store_point(mc_opt_mc_type_struct_5_Point * p, mc_opt_mc_type_struct_5_Point value)");
    try std.testing.expect(std.mem.count(u8, point_store, "mc_race_store_u32") == 2);
    try expectContains(point_store, "mc_race_store_bool");
}

fn appendCTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try appendCDeclsTest(std.testing.allocator, parsed.decls(), output);
}

fn appendCheckedCTest(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    try appendCDeclsTest(std.testing.allocator, parsed.decls(), output);
}

fn appendCheckedCTestWithMir(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, .kernel, source_name, .{}, false, null);
}

test "lower-c synthesized function-pointer names encode pointer mutability" {
    const source =
        \\fn use_const(callback: fn(*const u8) -> void) -> void {}
        \\fn use_mut(callback: fn(*mut u8) -> void) -> void {}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_fnptr_structural_names.mc", source, &output);

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "typedef void (*mc_fnptr"));
    try expectContains(output.items, "mc_type_ptr_c_2_u8");
    try expectContains(output.items, "mc_type_ptr_m_2_u8");
}

test "lower-c struct literal call fields lower from MIR in lexical order" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn mark(value: u32) -> u32;
        \\fn ordered_literal() -> Pair {
        \\    return .{ .first = mark(1), .second = mark(2) };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_struct_literal_call_fields.mc", source, &output);

    const body = try cFunctionBody(output.items, "static Pair ordered_literal(void)");
    const first = std.mem.indexOf(u8, body, "mark(") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, body, first + 1, "mark(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first < second);
    if (isCanonicalExecutableCBody(body)) try expectContains(body, "return mc_exec_tmp_") else try expectContains(body, "return (Pair){ .first = mark(1), .second = mark(2) };");
}

test "lower-c struct literal call fields keep source order from MIR" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn mark(value: u32) -> u32;
        \\fn ordered_literal() -> Pair {
        \\    return .{ .second = mark(2), .first = mark(1) };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_struct_literal_source_order.mc", source, &output);

    const body = try cFunctionBody(output.items, "static Pair ordered_literal(void)");
    if (isCanonicalExecutableCBody(body)) {
        const literal_two = std.mem.indexOf(u8, body, " = 2;") orelse return error.TestUnexpectedResult;
        const first_call = std.mem.indexOfPos(u8, body, literal_two, "mark(") orelse return error.TestUnexpectedResult;
        const literal_one = std.mem.indexOfPos(u8, body, first_call, " = 1;") orelse return error.TestUnexpectedResult;
        const second_call = std.mem.indexOfPos(u8, body, literal_one, "mark(") orelse return error.TestUnexpectedResult;
        try std.testing.expect(literal_two < first_call and first_call < literal_one and literal_one < second_call);
    } else {
        const second = std.mem.indexOf(u8, body, "mark(2)") orelse return error.TestUnexpectedResult;
        const first = std.mem.indexOfPos(u8, body, second + "mark(2)".len, "mark(1)") orelse return error.TestUnexpectedResult;
        try std.testing.expect(second < first);
    }
}

test "lower-c array literal call elements lower from MIR in lexical order" {
    const source =
        \\extern fn mark(value: u32) -> u32;
        \\fn ordered_literal() -> [2]u32 {
        \\    return .{ mark(1), mark(2) };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_array_literal_call_elements.mc", source, &output);

    const body = try cFunctionBody(output.items, "static mc_array_u32_2 ordered_literal(void)");
    const first = std.mem.indexOf(u8, body, "mark(") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, body, first + 1, "mark(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first < second);
    if (isCanonicalExecutableCBody(body)) try expectContains(body, "return mc_exec_tmp_") else try expectContains(body, "return (mc_array_u32_2){ .elems = { mark(1), mark(2) } };");
}

test "lower-c literal unary components lower from MIR without body fallback" {
    const source =
        \\struct Flags { first: bool, second: bool }
        \\fn struct_ops(flag: bool, other: bool) -> Flags {
        \\    return .{ .first = !flag, .second = !other };
        \\}
        \\fn array_ops(flag: bool, other: bool) -> [2]bool {
        \\    return .{ !flag, !other };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_literal_unary_components.mc", source, &output);

    const struct_body = try cFunctionBody(output.items, "static Flags struct_ops(bool flag, bool other)");
    try expectContains(struct_body, "/* canonical executable MIR */");
    try expectContains(struct_body, "= (Flags){ mc_exec_tmp_");

    const array_body = try cFunctionBody(output.items, "static mc_array_bool_2 array_ops(bool flag, bool other)");
    try expectContains(array_body, "(mc_array_bool_2){ .elems = {");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "!"));
}

test "lower-c literal compare components lower from MIR without body fallback" {
    const source =
        \\struct Flags { first: bool, second: bool }
        \\fn struct_ops(flag: bool, other: bool) -> Flags {
        \\    return .{ .first = flag == other, .second = flag != other };
        \\}
        \\fn array_ops(flag: bool, other: bool) -> [2]bool {
        \\    return .{ flag == other, flag != other };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_literal_compare_components.mc", source, &output);

    const struct_body = try cFunctionBody(output.items, "static Flags struct_ops(bool flag, bool other)");
    try expectContains(struct_body, "/* canonical executable MIR */");
    try expectContains(struct_body, "= (Flags){ mc_exec_tmp_");

    const array_body = try cFunctionBody(output.items, "static mc_array_bool_2 array_ops(bool flag, bool other)");
    try expectContains(array_body, "(mc_array_bool_2){ .elems = {");
    try expectContains(array_body, " == ");
    try expectContains(array_body, " != ");
}

test "lower-c literal checked arithmetic components lower from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\fn struct_ops(a: u32, b: u32, c: u32) -> Pair {
        \\    return .{ .first = a + b, .second = b + c };
        \\}
        \\fn array_ops(a: u32, b: u32, c: u32) -> [2]u32 {
        \\    return .{ a + b, b + c };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_literal_checked_arithmetic_components.mc", source, &output);

    const struct_body = try cFunctionBody(output.items, "static Pair struct_ops(uint32_t a, uint32_t b, uint32_t c)");
    try expectContains(struct_body, "/* canonical executable MIR */");
    try expectContains(struct_body, "mc_checked_add_u32(");
    try expectContains(struct_body, "= (Pair){ mc_exec_tmp_");

    const array_body = try cFunctionBody(output.items, "static mc_array_u32_2 array_ops(uint32_t a, uint32_t b, uint32_t c)");
    try expectContains(array_body, "(mc_array_u32_2){ .elems = {");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "mc_checked_add_u32("));
}

test "lower-c literal checked unary components lower from MIR without body fallback" {
    const source =
        \\struct Pair { first: i32, second: i32 }
        \\fn struct_ops(a: i32, b: i32) -> Pair {
        \\    return .{ .first = -a, .second = -b };
        \\}
        \\fn array_ops(a: i32, b: i32) -> [2]i32 {
        \\    return .{ -a, -b };
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_literal_checked_unary_components.mc", source, &output);

    const struct_body = try cFunctionBody(output.items, "static Pair struct_ops(int32_t a, int32_t b)");
    if (isCanonicalExecutableCBody(struct_body)) {
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, struct_body, "mc_checked_neg_i32("));
        try expectContains(struct_body, "= (Pair){ mc_exec_tmp_");
    } else try expectContains(struct_body, "return (Pair){ .first = mc_checked_neg_i32(a), .second = mc_checked_neg_i32(b) };");

    const array_body = try cFunctionBody(output.items, "static mc_array_i32_2 array_ops(int32_t a, int32_t b)");
    try expectContains(array_body, "(mc_array_i32_2){ .elems = {");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "mc_checked_neg_i32("));
}

test "lower-c local literal checked components return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\fn local_struct(a: u32, b: u32, c: u32) -> Pair {
        \\    let p: Pair = .{ .first = a + b, .second = b + c };
        \\    return p;
        \\}
        \\fn local_array(a: u32, b: u32, c: u32) -> [2]u32 {
        \\    let p: [2]u32 = .{ a + b, b + c };
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_literal_checked_components.mc", source, &output);

    const struct_body = try cFunctionBody(output.items, "static Pair local_struct(uint32_t a, uint32_t b, uint32_t c)");
    try expectContains(struct_body, "/* canonical executable MIR */");
    try expectContains(struct_body, "mc_checked_add_u32(");
    try expectContains(struct_body, "= (Pair){ mc_exec_tmp_");

    const array_body = try cFunctionBody(output.items, "static mc_array_u32_2 local_array(uint32_t a, uint32_t b, uint32_t c)");
    try expectContains(array_body, "(mc_array_u32_2){ .elems = {");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "mc_checked_add_u32("));
}

test "lower-c assigned literal checked components return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\fn assigned_struct(a: u32, b: u32, c: u32) -> Pair {
        \\    var p: Pair = .{ .first = a, .second = b };
        \\    p = .{ .first = a + b, .second = b + c };
        \\    return p;
        \\}
        \\fn assigned_array(a: u32, b: u32, c: u32) -> [2]u32 {
        \\    var p: [2]u32 = .{ a, b };
        \\    p = .{ a + b, b + c };
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_assigned_literal_checked_components.mc", source, &output);

    const struct_body = try cFunctionBody(output.items, "static Pair assigned_struct(uint32_t a, uint32_t b, uint32_t c)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, struct_body, "mc_checked_add_u32("));
    try expectContains(struct_body, "= (Pair){");
    try expectContains(struct_body, "return mc_exec_tmp_");

    const array_body = try cFunctionBody(output.items, "static mc_array_u32_2 assigned_array(uint32_t a, uint32_t b, uint32_t c)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, array_body, "mc_checked_add_u32("));
    try expectContains(array_body, "(mc_array_u32_2){ .elems = {");
    try expectContains(array_body, "return mc_exec_tmp_");
}

test "lower-c local and assigned literal call components return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn mark(value: u32) -> u32;
        \\fn local_struct() -> Pair {
        \\    let p: Pair = .{ .first = mark(1), .second = mark(2) };
        \\    return p;
        \\}
        \\fn assigned_struct() -> Pair {
        \\    var p: Pair = .{ .first = 0, .second = 0 };
        \\    p = .{ .first = mark(3), .second = mark(4) };
        \\    return p;
        \\}
        \\fn local_array() -> [2]u32 {
        \\    let p: [2]u32 = .{ mark(5), mark(6) };
        \\    return p;
        \\}
        \\fn assigned_array() -> [2]u32 {
        \\    var p: [2]u32 = .{ 0, 0 };
        \\    p = .{ mark(7), mark(8) };
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_assigned_literal_call_components.mc", source, &output);

    const local_struct_body = try cFunctionBody(output.items, "static Pair local_struct(void)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, local_struct_body, "mark("));
    try expectContains(local_struct_body, if (isCanonicalExecutableCBody(local_struct_body)) "return mc_exec_tmp_" else "return (Pair){ .first = mark(1), .second = mark(2) };");

    const assigned_struct_body = try cFunctionBody(output.items, "static Pair assigned_struct(void)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assigned_struct_body, "mark("));
    try expectContains(assigned_struct_body, if (isCanonicalExecutableCBody(assigned_struct_body)) "return mc_exec_tmp_" else "return (Pair){ .first = mark(3), .second = mark(4) };");

    const local_array_body = try cFunctionBody(output.items, "static mc_array_u32_2 local_array(void)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, local_array_body, "mark("));
    try expectContains(local_array_body, if (isCanonicalExecutableCBody(local_array_body)) "return mc_exec_tmp_" else "return (mc_array_u32_2){ .elems = { mark(5), mark(6) } };");

    const assigned_array_body = try cFunctionBody(output.items, "static mc_array_u32_2 assigned_array(void)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assigned_array_body, "mark("));
    try expectContains(assigned_array_body, if (isCanonicalExecutableCBody(assigned_array_body)) "return mc_exec_tmp_" else "return (mc_array_u32_2){ .elems = { mark(7), mark(8) } };");
}

test "lower-c local and assigned aggregate direct calls return from MIR without body fallback" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn hit(value: u32) -> void;
        \\extern fn make_pair(value: u32) -> Pair;
        \\extern fn make_array(value: u32) -> [2]u32;
        \\fn local_struct(value: u32) -> Pair {
        \\    let p: Pair = make_pair(value);
        \\    return p;
        \\}
        \\fn assigned_struct(value: u32) -> Pair {
        \\    var p: Pair = .{ .first = 0, .second = 0 };
        \\    p = make_pair(value);
        \\    return p;
        \\}
        \\fn side_then_local_struct(value: u32) -> Pair {
        \\    hit(1);
        \\    let p: Pair = make_pair(value);
        \\    return p;
        \\}
        \\fn local_array(value: u32) -> [2]u32 {
        \\    let p: [2]u32 = make_array(value);
        \\    return p;
        \\}
        \\fn assigned_array(value: u32) -> [2]u32 {
        \\    var p: [2]u32 = .{ 0, 0 };
        \\    p = make_array(value);
        \\    return p;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_assigned_aggregate_direct_calls.mc", source, &output);

    const local_struct_body = try cFunctionBody(output.items, "static Pair local_struct(uint32_t value)");
    try expectLegacyOrCanonicalReturn(local_struct_body, "return make_pair(value);", "= make_pair(");

    const assigned_struct_body = try cFunctionBody(output.items, "static Pair assigned_struct(uint32_t value)");
    try expectLegacyOrCanonicalReturn(assigned_struct_body, "return make_pair(value);", "= make_pair(");

    const side_body = try cFunctionBody(output.items, "static Pair side_then_local_struct(uint32_t value)");
    if (isCanonicalExecutableCBody(side_body)) {
        try expectNeedlesInOrder(side_body, &.{ "hit(", "make_pair(", "return mc_exec_tmp_" });
    } else {
        const hit = std.mem.indexOf(u8, side_body, "hit(1);") orelse return error.TestUnexpectedResult;
        const ret = std.mem.indexOf(u8, side_body, "return make_pair(value);") orelse return error.TestUnexpectedResult;
        try std.testing.expect(hit < ret);
    }

    const local_array_body = try cFunctionBody(output.items, "static mc_array_u32_2 local_array(uint32_t value)");
    try expectLegacyOrCanonicalReturn(local_array_body, "return make_array(value);", "= make_array(");

    const assigned_array_body = try cFunctionBody(output.items, "static mc_array_u32_2 assigned_array(uint32_t value)");
    try expectLegacyOrCanonicalReturn(assigned_array_body, "return make_array(value);", "= make_array(");
}

test "lower-c grouped scalar expressions return from MIR without body fallback" {
    const source =
        \\extern fn make(value: u16) -> u16;
        \\fn grouped_param(value: u16) -> u16 {
        \\    return (value);
        \\}
        \\fn grouped_binary(value: u16) -> u16 {
        \\    return (value) + 1;
        \\}
        \\fn grouped_call(value: u16) -> u16 {
        \\    let x: u16 = (make(value));
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_grouped_scalar_returns.mc", source, &output);

    const param_body = try cFunctionBody(output.items, "static uint16_t grouped_param(uint16_t value)");
    try expectLegacyOrCanonicalReturn(param_body, "return value;", " = value;");

    const binary_body = try cFunctionBody(output.items, "static uint16_t grouped_binary(uint16_t value)");
    try expectLegacyOrCanonicalReturn(binary_body, "return mc_checked_add_u16(value, 1);", "mc_checked_add_u16(");

    const call_body = try cFunctionBody(output.items, "static uint16_t grouped_call(uint16_t value)");
    try expectLegacyOrCanonicalReturn(call_body, "return make(value);", "= make(");
}

test "lower-c void calls before grouped scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn hit(value: u16) -> void;
        \\extern fn make(value: u16) -> u16;
        \\fn side_then_grouped_param(value: u16) -> u16 {
        \\    hit(1);
        \\    return (value);
        \\}
        \\fn side_then_grouped_binary(value: u16) -> u16 {
        \\    hit(2);
        \\    return (value) + 1;
        \\}
        \\fn side_then_grouped_call(value: u16) -> u16 {
        \\    hit(3);
        \\    let x: u16 = (make(value));
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_calls_before_grouped_scalar_returns.mc", source, &output);

    const param_body = try cFunctionBody(output.items, "static uint16_t side_then_grouped_param(uint16_t value)");
    const param_hit = std.mem.indexOf(u8, param_body, "hit(") orelse return error.TestUnexpectedResult;
    const param_ret = std.mem.indexOf(u8, param_body, if (isCanonicalExecutableCBody(param_body)) "return mc_exec_tmp_" else "return value;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(param_hit < param_ret);

    const binary_body = try cFunctionBody(output.items, "static uint16_t side_then_grouped_binary(uint16_t value)");
    const binary_hit = std.mem.indexOf(u8, binary_body, "hit(") orelse return error.TestUnexpectedResult;
    const binary_ret = std.mem.indexOf(u8, binary_body, if (isCanonicalExecutableCBody(binary_body)) "return mc_exec_tmp_" else "return mc_checked_add_u16(value, 1);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(binary_hit < binary_ret);

    const call_body = try cFunctionBody(output.items, "static uint16_t side_then_grouped_call(uint16_t value)");
    const call_hit = std.mem.indexOf(u8, call_body, "hit(") orelse return error.TestUnexpectedResult;
    const call_ret = std.mem.indexOf(u8, call_body, if (isCanonicalExecutableCBody(call_body)) "return mc_exec_tmp_" else "return make(value);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(call_hit < call_ret);
    if (!isCanonicalExecutableCBody(call_body)) try expectNotContains(call_body, "uint16_t x");
}

test "lower-c conditional grouped scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn make(value: u16) -> u16;
        \\fn choose_grouped_param(flag: bool, value: u16) -> u16 {
        \\    if (flag) {
        \\        return (value);
        \\    } else {
        \\        return (value);
        \\    }
        \\}
        \\fn choose_grouped_binary(flag: bool, value: u16) -> u16 {
        \\    if (flag) {
        \\        return (value) + 1;
        \\    } else {
        \\        return (value) + 2;
        \\    }
        \\}
        \\fn choose_grouped_call(flag: bool, value: u16) -> u16 {
        \\    if (flag) {
        \\        return (make(value));
        \\    } else {
        \\        return (make(value));
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conditional_grouped_scalar_returns.mc", source, &output);

    const param_body = try cFunctionBody(output.items, "static uint16_t choose_grouped_param(bool flag, uint16_t value)");
    try expectCanonicalConditional(param_body);
    try expectContains(param_body, " = value;");
    try expectContains(param_body, "return mc_exec_tmp_");
    try expectNotContains(param_body, "mc_tmp");

    const binary_body = try cFunctionBody(output.items, "static uint16_t choose_grouped_binary(bool flag, uint16_t value)");
    try expectCanonicalConditional(binary_body);
    try expectContains(binary_body, "mc_checked_add_u16(");
    try expectContains(binary_body, " = 1;");
    try expectContains(binary_body, " = 2;");
    try expectNotContains(binary_body, "mc_tmp");

    const call_body = try cFunctionBody(output.items, "static uint16_t choose_grouped_call(bool flag, uint16_t value)");
    try expectCanonicalConditional(call_body);
    try expectContains(call_body, "= make(");
    try expectContains(call_body, "return mc_exec_tmp_");
    try expectNotContains(call_body, "mc_tmp");
}

test "lower-c conditional global and call returns lower from MIR without body fallback" {
    const source =
        \\global g: u32 = 0;
        \\extern fn hit(value: u32) -> void;
        \\extern fn make(value: u32) -> u32;
        \\fn choose_global(flag: bool) -> u32 {
        \\    if (flag) {
        \\        hit(g);
        \\        return g;
        \\    } else {
        \\        return g;
        \\    }
        \\}
        \\fn choose_call(flag: bool, value: u32) -> u32 {
        \\    if (flag) {
        \\        hit(value);
        \\        return make(value);
        \\    } else {
        \\        return make(value);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conditional_global_call_returns.mc", source, &output);

    const global_body = try cFunctionBody(output.items, "static uint32_t choose_global(bool flag)");
    try expectCanonicalConditional(global_body);
    try expectContains(global_body, "mc_race_load_u32(&g)");
    try expectContains(global_body, "hit(");
    try expectContains(global_body, "return mc_exec_tmp_");
    try expectNotContains(global_body, "mc_tmp");

    const call_body = try cFunctionBody(output.items, "static uint32_t choose_call(bool flag, uint32_t value)");
    try expectCanonicalConditional(call_body);
    try expectContains(call_body, "hit(");
    try expectContains(call_body, "= make(");
    try expectContains(call_body, "return mc_exec_tmp_");
    try expectNotContains(call_body, "mc_tmp");
}

test "lower-c conditional statement returns lower from MIR" {
    const source =
        \\extern fn hit(value: u32) -> void;
        \\extern fn make(value: u32) -> u32;
        \\fn choose_call(flag: bool, value: u32) -> u32 {
        \\    if (flag) {
        \\        hit(value);
        \\        return make(value);
        \\    } else {
        \\        return make(value);
        \\    }
        \\}
    ;
    var parsed = try test_support.parseModule("c_mir_fallback_poison.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var artifacts = try test_artifact_support.collectArtifactsFromDecls(std.testing.allocator, parsed.decls(), &module_mir);
    defer artifacts.deinit(std.testing.allocator);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try lower_c.appendCProfileWithMirArtifacts(
        std.testing.allocator,
        artifacts.codegen(),
        &module_mir,
        &output,
        .kernel,
        "c_mir_fallback_poison.mc",
        .{},
        false,
        null,
    );

    const call_body = try cFunctionBody(output.items, "static uint32_t choose_call(bool flag, uint32_t value)");
    try expectCanonicalConditional(call_body);
    try expectContains(call_body, "hit(");
    try expectContains(call_body, "= make(");
    try expectContains(call_body, "return mc_exec_tmp_");
}

test "lower-c loop grouped scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn hit(value: u16) -> void;
        \\extern fn make(value: u16) -> u16;
        \\fn loop_grouped_param(flag: bool, value: u16) -> u16 {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    return (value);
        \\}
        \\fn loop_grouped_call(flag: bool, value: u16) -> u16 {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    let x: u16 = (make(value));
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_loop_grouped_scalar_returns.mc", source, &output);

    const param_body = try cFunctionBody(output.items, "static uint16_t loop_grouped_param(bool flag, uint16_t value)");
    try expectLegacyOrCanonicalLoop(param_body, "while (flag)");
    try expectContains(param_body, if (isCanonicalExecutableCBody(param_body)) "hit(" else "hit(value);");
    try expectLegacyOrCanonicalReturn(param_body, "return value;", " = value;");

    const call_body = try cFunctionBody(output.items, "static uint16_t loop_grouped_call(bool flag, uint16_t value)");
    try expectLegacyOrCanonicalLoop(call_body, "while (flag)");
    try expectLegacyOrCanonicalReturn(call_body, "return make(value);", "= make(");
}

test "lower-c loop derived scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn hit(value: u16) -> void;
        \\fn loop_compare(flag: bool, value: u16) -> bool {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    return value == 0;
        \\}
        \\fn loop_not(flag: bool, value: u16, other: bool) -> bool {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    return !other;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_loop_derived_scalar_returns.mc", source, &output);

    const compare_body = try cFunctionBody(output.items, "static bool loop_compare(bool flag, uint16_t value)");
    try expectLegacyOrCanonicalLoop(compare_body, "while (flag)");
    try expectContains(compare_body, if (isCanonicalExecutableCBody(compare_body)) "hit(" else "hit(value);");
    try expectLegacyOrCanonicalReturn(compare_body, "return (value == 0);", " == ");

    const not_body = try cFunctionBody(output.items, "static bool loop_not(bool flag, uint16_t value, bool other)");
    try expectLegacyOrCanonicalLoop(not_body, "while (flag)");
    try expectContains(not_body, if (isCanonicalExecutableCBody(not_body)) "hit(" else "hit(value);");
    try expectLegacyOrCanonicalReturn(not_body, "return !other;", "(!");
}

test "lower-c loop checked scalar returns lower from MIR without body fallback" {
    const source =
        \\extern fn hit(value: u16) -> void;
        \\fn loop_checked_add(flag: bool, value: u16) -> u16 {
        \\    while flag {
        \\        hit(value);
        \\    }
        \\    return (value) + 1;
        \\}
        \\fn loop_checked_neg(flag: bool, value: i16) -> i16 {
        \\    while flag {
        \\        hit(1);
        \\    }
        \\    return -value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_loop_checked_scalar_returns.mc", source, &output);

    const add_body = try cFunctionBody(output.items, "static uint16_t loop_checked_add(bool flag, uint16_t value)");
    try expectLegacyOrCanonicalLoop(add_body, "while (flag)");
    try expectContains(add_body, if (isCanonicalExecutableCBody(add_body)) "hit(" else "hit(value);");
    try expectLegacyOrCanonicalReturn(add_body, "return mc_checked_add_u16(value, 1);", "mc_checked_add_u16(");
    try expectNotContains(add_body, "mc_tmp");

    const neg_body = try cFunctionBody(output.items, "static int16_t loop_checked_neg(bool flag, int16_t value)");
    try expectLegacyOrCanonicalLoop(neg_body, "while (flag)");
    try expectContains(neg_body, "hit(");
    try expectLegacyOrCanonicalReturn(neg_body, "return mc_checked_neg_i16(value);", "mc_checked_neg_i16(");
    try expectNotContains(neg_body, "mc_tmp");
}

test "lower-c loop call and global returns lower from MIR without body fallback" {
    const source =
        \\global g: u32 = 0;
        \\extern fn hit_u16(value: u16) -> void;
        \\extern fn hit_u32(value: u32) -> void;
        \\extern fn make(value: u16) -> u16;
        \\fn loop_direct_call(flag: bool, value: u16) -> u16 {
        \\    while flag {
        \\        hit_u16(value);
        \\    }
        \\    return make(value);
        \\}
        \\fn loop_global(flag: bool) -> u32 {
        \\    while flag {
        \\        hit_u32(g);
        \\    }
        \\    return g;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_loop_call_global_returns.mc", source, &output);

    const call_body = try cFunctionBody(output.items, "static uint16_t loop_direct_call(bool flag, uint16_t value)");
    try expectLegacyOrCanonicalLoop(call_body, "while (flag)");
    try expectContains(call_body, if (isCanonicalExecutableCBody(call_body)) "hit_u16(" else "hit_u16(value);");
    try expectLegacyOrCanonicalReturn(call_body, "return make(value);", "= make(");

    const global_body = try cFunctionBody(output.items, "static uint32_t loop_global(bool flag)");
    try expectLegacyOrCanonicalLoop(global_body, "while (flag)");
    try expectContains(global_body, "hit_u32(");
    try expectContains(global_body, "mc_race_load_u32(&g)");
    try expectNotContains(global_body, "mc_tmp");
}

test "lower-c sequences dynamic packed bits fields lexically" {
    const source =
        \\packed bits Flags: u8 { first: bool, second: bool }
        \\extern fn mark(id: u32) -> bool;
        \\fn flags() -> Flags { return .{ .second = mark(2), .first = mark(1) }; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("packed_bits_order.mc", source, &output);
    const body = try cFunctionBody(output.items, "static Flags flags(void)");
    const second = std.mem.indexOf(u8, body, "mark(") orelse return error.TestUnexpectedResult;
    const first = std.mem.indexOfPos(u8, body, second + "mark(".len, "mark(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(second < first);
    try expectContains(body[second..first], "2");
    try expectContains(body[first..], "1");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "bool mc_exec_tmp_");
}

test "lower-c target-typed char literals require MIR facts" {
    const source =
        \\fn char_value() -> u16 { return 'A'; }
    ;
    var parsed = try test_support.parseModule("c_char_literal_facts.mc", source);
    defer parsed.deinit();

    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_char_literal_facts.mc", .{}, false, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "= 65;") != null or
            std.mem.indexOf(u8, output.items, "return 65;") != null or
            std.mem.indexOf(u8, output.items, "((uint16_t)65)") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "char_value", .char_literal);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_char_literal_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try renameTargetTypeFactForFunction(&module_mir, "char_value", .char_literal, "u8");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_char_literal_facts.mc", .{}, false, null));
    }
}

test "lower-c materialized aggregate globals use the C aggregate representation policy" {
    const source =
        \\struct Holder { value: u32 }
        \\enum InitError { failed }
        \\global scalar: u32;
        \\global fixed: [2]u32;
        \\global view: []const u8;
        \\global result: Result<u32, InitError>;
        \\global holder: Holder;
        \\global uninit_holder: MaybeUninit<Holder>;
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_aggregate_global_representation_policy.mc", source, &output);

    try expectContains(output.items, "scalar = 0;");
    for ([_][]const u8{
        "fixed = {0};",
        "view = {0};",
        "result = {0};",
        "holder = {0};",
        "uninit_holder = {0};",
    }) |needle| try expectContains(output.items, needle);
}

fn clearRangeFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        module_mir.allocator.free(function.range_facts);
        function.range_facts = try module_mir.allocator.alloc(mir.RangeFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearBoundsFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.bounds_facts.len != 0) module_mir.allocator.free(function.bounds_facts);
        function.bounds_facts = &.{};
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearRepresentationFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        module_mir.allocator.free(function.representation_facts);
        function.representation_facts = try module_mir.allocator.alloc(mir.RepresentationFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearIntegerFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.integer_facts.len != 0) module_mir.allocator.free(function.integer_facts);
        function.integer_facts = try module_mir.allocator.alloc(mir.IntegerFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearConstGetFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.const_get_facts.len != 0) module_mir.allocator.free(function.const_get_facts);
        function.const_get_facts = try module_mir.allocator.alloc(mir.ConstGetFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn retargetConstGetFactForFunction(module_mir: *mir.Module, name: []const u8, index: usize) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.const_get_facts.len != 1) return error.TestUnexpectedResult;
        function.const_get_facts[0].index = index;
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearCallTargetFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.call_target_facts.len != 0) module_mir.allocator.free(function.call_target_facts);
        function.call_target_facts = try module_mir.allocator.alloc(mir.CallTargetFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearTargetTypeFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.target_type_facts.len != 0) module_mir.allocator.free(function.target_type_facts);
        function.target_type_facts = try module_mir.allocator.alloc(mir.TargetTypeFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearFloatFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.float_facts.len != 0) module_mir.allocator.free(function.float_facts);
        function.float_facts = try module_mir.allocator.alloc(mir.FloatFact, 0);
        return;
    }
    return error.TestUnexpectedResult;
}

fn signatureTypeIdByName(module_mir: *const mir.Module, target_name: []const u8) ?mir.SignatureTypeId {
    for (module_mir.signature_types.shapes, 0..) |shape, index| switch (shape) {
        .name => |name| if (std.mem.eql(u8, name, target_name)) return mir.SignatureTypeId.fromIndex(index),
        else => {},
    };
    return null;
}

fn signaturePointerTypeIdWithMutability(module_mir: *const mir.Module, current: mir.SignatureTypeId, mutability: ast.Mutability) ?mir.SignatureTypeId {
    const current_shape = module_mir.signature_types.get(current) orelse return null;
    const current_pointer = switch (current_shape) {
        .pointer => |pointer| pointer,
        else => return null,
    };
    const expected: mir.TypeMutability = switch (mutability) {
        .mut => .mut,
        .@"const" => .@"const",
    };
    for (module_mir.signature_types.shapes, 0..) |shape, index| switch (shape) {
        .pointer => |pointer| if (pointer.mutability == expected and pointer.child.eql(current_pointer.child)) return mir.SignatureTypeId.fromIndex(index),
        else => {},
    };
    return null;
}

fn removeTargetTypeKindForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained_count: usize = 0;
        for (function.target_type_facts) |fact| {
            if (fact.kind != kind) retained_count += 1;
        }
        if (retained_count == function.target_type_facts.len) return error.TestUnexpectedResult;
        const retained = try module_mir.allocator.alloc(mir.TargetTypeFact, retained_count);
        var index: usize = 0;
        for (function.target_type_facts) |fact| {
            if (fact.kind == kind) continue;
            retained[index] = fact;
            index += 1;
        }
        if (function.target_type_facts.len != 0) module_mir.allocator.free(function.target_type_facts);
        function.target_type_facts = retained;
        return;
    }
    return error.TestUnexpectedResult;
}

fn removeTargetTypeKindForFunctionLineAndTargetName(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, line: usize, target_name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained_count: usize = 0;
        var removed_count: usize = 0;
        for (function.target_type_facts) |fact| {
            const remove = fact.kind == kind and
                fact.source.line == line and
                fact.target_type_id.eql(signatureTypeIdByName(module_mir, target_name) orelse return error.TestUnexpectedResult);
            if (remove) {
                removed_count += 1;
            } else {
                retained_count += 1;
            }
        }
        if (removed_count == 0) return error.TestUnexpectedResult;
        const retained = try module_mir.allocator.alloc(mir.TargetTypeFact, retained_count);
        var index: usize = 0;
        for (function.target_type_facts) |fact| {
            const remove = fact.kind == kind and
                fact.source.line == line and
                fact.target_type_id.eql(signatureTypeIdByName(module_mir, target_name) orelse return error.TestUnexpectedResult);
            if (remove) continue;
            retained[index] = fact;
            index += 1;
        }
        if (function.target_type_facts.len != 0) module_mir.allocator.free(function.target_type_facts);
        function.target_type_facts = retained;
        return;
    }
    return error.TestUnexpectedResult;
}

fn renameTargetTypeFactForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, target_name: []const u8) !void {
    const target_type_id: mir.SignatureTypeId = signatureTypeIdByName(module_mir, target_name) orelse mir.SignatureTypeId.invalid;
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != kind) continue;
            fact.target_type_id = target_type_id;
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn retargetTargetTypeResultForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, result_ty: mir.ValueType) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var fact_count: usize = 0;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != kind) continue;
            fact.result_ty = result_ty;
            fact_count += 1;
        }
        var instruction_count: usize = 0;
        for (function.blocks) |*block| {
            for (block.instructions) |*instruction| {
                if (instruction.kind != .target_type) continue;
                if (!std.mem.eql(u8, instruction.detail, @tagName(kind))) continue;
                instruction.result_ty = result_ty;
                instruction_count += 1;
            }
        }
        if (fact_count == 0 or instruction_count == 0) return error.TestUnexpectedResult;
        return;
    }
    return error.TestUnexpectedResult;
}

fn renameTargetTypeFactAtOffsetForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, source_offset: usize, source_len: usize, target_name: []const u8) !void {
    const target_type_id: mir.SignatureTypeId = signatureTypeIdByName(module_mir, target_name) orelse mir.SignatureTypeId.invalid;
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != kind or fact.source.offset != source_offset or fact.source.len != source_len) continue;
            fact.target_type_id = target_type_id;
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn retargetPointerMutabilityFactAtOffsetForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, source_offset: usize, source_len: usize, mutability: ast.Mutability) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != kind or fact.source.offset != source_offset or fact.source.len != source_len) continue;
            fact.target_type_id = signaturePointerTypeIdWithMutability(module_mir, fact.target_type_id, mutability) orelse return error.TestUnexpectedResult;
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn removeTargetTypeFactAtOffsetForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.TargetTypeKind, source_offset: usize, source_len: usize) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained_count: usize = 0;
        var removed = false;
        for (function.target_type_facts) |fact| {
            if (fact.kind == kind and fact.source.offset == source_offset and fact.source.len == source_len) {
                removed = true;
            } else {
                retained_count += 1;
            }
        }
        if (!removed) return error.TestUnexpectedResult;
        const retained = try module_mir.allocator.alloc(mir.TargetTypeFact, retained_count);
        var index: usize = 0;
        for (function.target_type_facts) |fact| {
            if (fact.kind == kind and fact.source.offset == source_offset and fact.source.len == source_len) continue;
            retained[index] = fact;
            index += 1;
        }
        if (function.target_type_facts.len != 0) module_mir.allocator.free(function.target_type_facts);
        function.target_type_facts = retained;
        return;
    }
    return error.TestUnexpectedResult;
}

fn retargetAggregateConstructionForFunction(module_mir: *mir.Module, name: []const u8, construction: ?mir.AggregateConstructionKind) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.target_type_facts) |*fact| {
            if (fact.kind != .struct_literal) continue;
            fact.aggregate_construction = construction;
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

test "lower-c rejects prebuilt MIR with missing target type facts" {
    const source =
        \\enum E { bad }
        \\fn make(value: u32) -> Result<u32, E> { return ok(value); }
        \\fn make_err() -> Result<u32, E> { return err(.bad); }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_result_constructor_target_type_facts.mc", source, &complete_output);

    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_target_type_facts.mc", .{}, false, null));
}

test "lower-c Result constructors require MIR call target facts" {
    const source =
        \\enum E { bad }
        \\fn make(value: u32) -> Result<u32, E> { return ok(value); }
        \\fn forward(value: Result<u32, E>) -> Result<u32, E> { return ok(value?); }
    ;
    var parsed = try test_support.parseCheckedModule("c_result_constructor_call_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "make", "forward" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_result_constructor_call_facts.mc", .{}, false, null));
    }
}

test "lower-c bind closures require MIR call target facts" {
    const source =
        \\fn add_scalar(env: u32, value: u32) -> u32 { return env + value; }
        \\fn make() -> closure(u32) -> u32 { return (bind(3, add_scalar)); }
    ;
    var parsed = try test_support.parseCheckedModule("c_bind_call_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_bind_call_facts.mc", .{}, false, null));
}

test "lower-c rejects missing tagged-union target type facts" {
    const source =
        \\union Token { number: i64, eof }
        \\fn make() -> Token { return number(7); }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_union_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_union_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing enum-literal target type facts" {
    const source =
        \\enum Mode: u8 { read = 1, write = 2 }
        \\fn make() -> Mode { return .read; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_enum_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "make");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_enum_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing string-literal target type facts" {
    const source =
        \\fn text() -> *const u8 { return "text"; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_string_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "text");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_string_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing aggregate-literal target type facts" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\fn pair() -> Pair { return .{ .left = 1, .right = 2 }; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_aggregate_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "pair");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_aggregate_target_type_facts.mc", .{}, false, null));
}

test "lower-c struct literal construction class is MIR-owned" {
    const source =
        \\struct Pair { left: u32, right: u32 }
        \\packed bits Flags: u8 { ready: bool }
        \\#[c_union]
        \\struct CWord { word: u32, byte: u8 }
        \\fn pair() -> Pair { return .{ .left = 1, .right = 2 }; }
        \\fn flags() -> Flags { return .{ .ready = true }; }
        \\fn c_word() -> CWord { return .{ .word = 7, .byte = uninit }; }
    ;
    var parsed = try test_support.parseCheckedModule("c_aggregate_construction_fact.mc", source);
    defer parsed.deinit();
    var valid_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer valid_mir.deinit();
    var valid_output: std.ArrayList(u8) = .empty;
    defer valid_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &valid_mir, &valid_output, .kernel, "c_aggregate_construction_fact.mc", .{}, false, null);

    for ([_]?mir.AggregateConstructionKind{ null, .packed_bits }) |stale| {
        var stale_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale_mir.deinit();
        try retargetAggregateConstructionForFunction(&stale_mir, "pair", stale);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_mir, &output, .kernel, "c_aggregate_construction_fact.mc", .{}, false, null));
    }
}

test "lower-c rejects missing typed float facts" {
    const source =
        \\fn value() -> f32 { return 1.25; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_float_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearFloatFactsForFunction(&module_mir, "value");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirFloatFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_float_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing null and value-optional target type facts" {
    const source =
        \\fn present(value: u32) -> ?u32 { return value; }
        \\fn absent() -> ?u32 { return null; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_optional_target_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "present", "absent" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_optional_target_type_facts.mc", .{}, false, null));
    }
}

test "lower-c rejects missing dyn-coercion target type facts" {
    const source =
        \\trait Shape { fn area(self: *Self) -> u32; }
        \\struct Square { side: u32 }
        \\impl Shape for Square { fn area(self: *Square) -> u32 { return self.side; } }
        \\fn as_dyn(value: *Square) -> *dyn Shape { return value; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_dyn_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "as_dyn");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_dyn_target_type_facts.mc", .{}, false, null));
}

test "lower-c rejects missing dyn-coercion source type facts" {
    const source =
        \\trait Shape { fn area(self: *Self) -> u32; }
        \\struct Square { side: u32 }
        \\impl Shape for Square { fn area(self: *Square) -> u32 { return self.side; } }
        \\fn as_dyn(value: *Square) -> *dyn Shape { return value; }
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_dyn_source_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try removeTargetTypeKindForFunction(&module_mir, "as_dyn", .dyn_coercion_source);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_dyn_source_type_facts.mc", .{}, false, null));
}

fn retargetCallTargetFactsForFunction(module_mir: *mir.Module, name: []const u8, kind: mir.CallTargetKind) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.call_target_facts.len == 0) return error.TestUnexpectedResult;
        function.call_target_facts[0].kind = kind;
        return;
    }
    return error.TestUnexpectedResult;
}

test "lower-c conversion builtins require exact MIR call-target facts" {
    const source =
        \\fn convert(x: u64) -> u8 { return u8.trap_from(x); }
    ;
    var parsed = try test_support.parseCheckedModule("c_conversion_call_target_facts.mc", source);
    defer parsed.deinit();

    var missing_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_mir.deinit();
    try clearCallTargetFactsForFunction(&missing_mir, "convert");
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_mir, &missing_output, .kernel, "c_conversion_call_target_facts.mc", .{}, false, null));

    var stale_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_mir.deinit();
    try retargetCallTargetFactsForFunction(&stale_mir, "convert", .conversion_sat_from);
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_mir, &stale_output, .kernel, "c_conversion_call_target_facts.mc", .{}, false, null));

    var missing_types_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_types_mir.deinit();
    try clearTargetTypeFactsForFunction(&missing_types_mir, "convert");
    var missing_types_output: std.ArrayList(u8) = .empty;
    defer missing_types_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_types_mir, &missing_types_output, .kernel, "c_conversion_call_target_facts.mc", .{}, false, null));
}

test "lower-c explicit casts require MIR source and target type facts" {
    const source =
        \\fn widen(value: u32) -> u64 { return value as u64; }
    ;
    var parsed = try test_support.parseCheckedModule("c_explicit_cast_type_facts.mc", source);
    defer parsed.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_explicit_cast_type_facts.mc", source, &complete_output);
    try expectContains(complete_output.items, "((uint64_t)(mc_exec_tmp_");

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "widen");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_explicit_cast_type_facts.mc", .{}, false, null));
}

test "lower-c local and assigned explicit casts lower from MIR without body fallback" {
    const source =
        \\fn local_cast(value: u32) -> u64 {
        \\    let widened = value as u64;
        \\    return widened;
        \\}
        \\fn assigned_cast(value: u32) -> u64 {
        \\    var widened: u64 = 0;
        \\    widened = value as u64;
        \\    return widened;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_assigned_explicit_cast_return.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static uint64_t local_cast(uint32_t value)");
    try expectContains(local_body, "((uint64_t)(mc_exec_tmp_");
    try expectContains(local_body, "return mc_exec_tmp_");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static uint64_t assigned_cast(uint32_t value)");
    try expectContains(assigned_body, "((uint64_t)(mc_exec_tmp_");
    try expectContains(assigned_body, "widened = mc_exec_tmp_");
    try expectContains(assigned_body, "return mc_exec_tmp_");
    try expectNotContains(assigned_body, "mc_tmp");
}

test "lower-c local and assigned conversion calls lower from MIR without body fallback" {
    const source =
        \\fn local_conversion(value: u64) -> u8 {
        \\    let narrowed = u8.wrap_from(value);
        \\    return narrowed;
        \\}
        \\fn assigned_conversion(value: u64) -> u8 {
        \\    var narrowed: u8 = 0;
        \\    narrowed = u8.wrap_from(value);
        \\    return narrowed;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_assigned_conversion_return.mc", source, &output);

    const local_body = try cFunctionBody(output.items, "static uint8_t local_conversion(uint64_t value)");
    try expectContains(local_body, "/* canonical executable MIR */");
    try expectContains(local_body, "((uint8_t)(mc_exec_tmp_");
    try expectContains(local_body, "return mc_exec_tmp_");
    try expectNotContains(local_body, "mc_tmp");

    const assigned_body = try cFunctionBody(output.items, "static uint8_t assigned_conversion(uint64_t value)");
    try expectContains(assigned_body, "/* canonical executable MIR */");
    try expectContains(assigned_body, "((uint8_t)(mc_exec_tmp_");
    try expectContains(assigned_body, "return mc_exec_tmp_");
    try expectNotContains(assigned_body, "mc_tmp");
}

test "lower-c cast deref pointee requires MIR expression result" {
    const source =
        \\fn read(p: *mut u32) -> u32 {
        \\    unsafe { return (p as *mut u32).*; }
        \\}
    ;
    const cast_text = "p as *mut u32";
    const cast_offset = std.mem.indexOf(u8, source, cast_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("c_cast_deref_expression_result.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMir, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_cast_deref_expression_result.mc", .{}, false, null));

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "read", .expression_result, cast_offset, cast_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_cast_deref_expression_result.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "read", .expression_result, cast_offset, cast_text.len, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_cast_deref_expression_result.mc", .{}, false, null));
}

test "lower-c member deref pointee requires MIR expression result" {
    const source =
        \\struct Holder { ptr: *mut u32 }
        \\fn read(holder: Holder) -> u32 {
        \\    unsafe { return holder.ptr.*; }
        \\}
    ;
    const member_text = "holder.ptr";
    const member_offset = std.mem.indexOf(u8, source, member_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("c_member_deref_expression_result.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_member_deref_expression_result.mc", .{}, false, null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "read", .expression_result, member_offset, member_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_member_deref_expression_result.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "read", .expression_result, member_offset, member_text.len, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_member_deref_expression_result.mc", .{}, false, null));
}

test "lower-c implicit view const narrowing requires MIR source and target type facts" {
    const source =
        \\fn narrow(xs: []mut u8) -> []const u8 { return xs; }
    ;
    var parsed = try test_support.parseCheckedModule("c_view_const_narrow_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "narrow");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_view_const_narrow_type_facts.mc", .{}, false, null));
}

test "lower-c self-typed union and enum paths require MIR result type facts" {
    const source =
        \\enum E { first, second }
        \\union Token { number: i64, eof }
        \\fn make(value: i64) -> Token { return Token.number(value); }
        \\fn variant() -> E { return E.second; }
    ;
    var parsed = try test_support.parseCheckedModule("c_self_typed_expression_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "make", "variant" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_self_typed_expression_facts.mc", .{}, false, null));
    }
}

fn retargetIntegerFactsForFunction(module_mir: *mir.Module, name: []const u8, target_ty: mir.ValueType) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.integer_facts.len == 0) return error.TestUnexpectedResult;
        for (function.type_identities) |identity| {
            const candidate = identity.ty orelse continue;
            if (!mir.ValueType.eql(candidate, target_ty)) continue;
            function.integer_facts[0].target_type_id = identity.id;
            return;
        }
        return error.TestUnexpectedResult;
    }
    return error.TestUnexpectedResult;
}

fn retargetRepresentationFactsForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.representation_facts.len == 0) return error.TestUnexpectedResult;
        function.representation_facts[0].typed_value_id = mir.ValueId.fromIndex(function.value_identities.len);
        return;
    }
    return error.TestUnexpectedResult;
}

fn appendStaleRepresentationFactForFunction(module_mir: *mir.Module, name: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        if (function.representation_facts.len == 0) return error.TestUnexpectedResult;

        var facts: std.ArrayList(mir.RepresentationFact) = .empty;
        errdefer facts.deinit(module_mir.allocator);
        try facts.appendSlice(module_mir.allocator, function.representation_facts);
        var stale = function.representation_facts[0];
        stale.typed_value_id = mir.ValueId.fromIndex(function.value_identities.len);
        try facts.append(module_mir.allocator, stale);

        module_mir.allocator.free(function.representation_facts);
        function.representation_facts = try facts.toOwnedSlice(module_mir.allocator);
        return;
    }
    return error.TestUnexpectedResult;
}

fn retargetRangeFactsForFunction(module_mir: *mir.Module, name: []const u8, target: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        for (function.range_facts) |*fact| {
            fact.target = target;
        }
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearPointerProvenanceFactsForFunctionSubject(module_mir: *mir.Module, name: []const u8, subject: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained: std.ArrayList(mir.PointerProvenanceFact) = .empty;
        errdefer retained.deinit(module_mir.allocator);
        for (function.pointer_provenance_facts) |fact| {
            if (std.mem.eql(u8, fact.subject, subject)) {
                if (fact.field_path) |field_path| module_mir.allocator.free(field_path);
                continue;
            }
            try retained.append(module_mir.allocator, fact);
        }
        module_mir.allocator.free(function.pointer_provenance_facts);
        function.pointer_provenance_facts = try retained.toOwnedSlice(module_mir.allocator);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearPointerProvenanceFactsForFunctionSubjectField(module_mir: *mir.Module, name: []const u8, subject: []const u8, field_path: []const u8) !void {
    for (module_mir.functions) |*function| {
        if (!std.mem.eql(u8, function.name, name)) continue;
        var retained: std.ArrayList(mir.PointerProvenanceFact) = .empty;
        errdefer retained.deinit(module_mir.allocator);
        for (function.pointer_provenance_facts) |fact| {
            if (std.mem.eql(u8, fact.subject, subject)) {
                if (fact.field_path) |actual_field| {
                    if (std.mem.eql(u8, actual_field, field_path)) {
                        module_mir.allocator.free(actual_field);
                        continue;
                    }
                }
            }
            try retained.append(module_mir.allocator, fact);
        }
        module_mir.allocator.free(function.pointer_provenance_facts);
        function.pointer_provenance_facts = try retained.toOwnedSlice(module_mir.allocator);
        return;
    }
    return error.TestUnexpectedResult;
}

fn clearAggregateReturnPointerFact(module_mir: *mir.Module, callee: []const u8, field_path: []const u8) !void {
    var retained: std.ArrayList(mir.AggregateReturnPointerFact) = .empty;
    errdefer retained.deinit(module_mir.allocator);
    var removed = false;
    for (module_mir.aggregate_return_pointer_facts) |fact| {
        if (std.mem.eql(u8, fact.callee, callee) and std.mem.eql(u8, fact.field_path, field_path)) {
            module_mir.allocator.free(fact.field_path);
            removed = true;
            continue;
        }
        try retained.append(module_mir.allocator, fact);
    }
    if (!removed) return error.TestUnexpectedResult;
    module_mir.allocator.free(module_mir.aggregate_return_pointer_facts);
    module_mir.aggregate_return_pointer_facts = try retained.toOwnedSlice(module_mir.allocator);
}

fn appendCheckedCTestWithoutRangeFacts(source_name: []const u8, source: []const u8, function_names: []const []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    for (function_names) |function_name| {
        try clearRangeFactsForFunction(&module_mir, function_name);
    }

    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, .kernel, source_name, .{}, false, null);
}

test "lower-c canonical executable body does not depend on legacy bounds facts" {
    const source =
        \\fn bounds_fact_gate(a: [2]u32, i: usize) -> u32 {
        \\    return a[i];
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_missing_bounds_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try clearBoundsFactsForFunction(&module_mir, "bounds_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_bounds_facts.mc", .{}, false, null);
    try expectContains(output.items, "/* canonical executable MIR */");
}

test "lower-c rejects prebuilt MIR with missing representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearRepresentationFactsForFunction(&module_mir, "representation_fact_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_representation_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with stale representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_stale_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetRepresentationFactsForFunction(&module_mir, "representation_fact_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_stale_representation_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with extra stale representation facts" {
    const source =
        \\fn representation_fact_gate(p: *mut u32) -> u32 {
        \\    unsafe { return p.*; }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_extra_stale_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try appendStaleRepresentationFactForFunction(&module_mir, "representation_fact_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_extra_stale_representation_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing Result try payload representation facts" {
    const source =
        \\extern fn make_result_pointer() -> Result<*mut u8, Error>;
        \\
        \\fn result_try_payload_representation_gate() -> *mut u8 {
        \\    return make_result_pointer()?;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_result_try_payload_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearRepresentationFactsForFunction(&module_mir, "result_try_payload_representation_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_result_try_payload_representation_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with stale Result try payload representation facts" {
    const source =
        \\extern fn make_result_pointer() -> Result<*mut u8, Error>;
        \\
        \\fn result_try_payload_representation_gate() -> *mut u8 {
        \\    return make_result_pointer()?;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_stale_result_try_payload_representation_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetRepresentationFactsForFunction(&module_mir, "result_try_payload_representation_gate");

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirRepresentationFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_stale_result_try_payload_representation_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing integer facts" {
    const source =
        \\fn integer_fact_gate() -> u8 {
        \\    let a: u8 = 7;
        \\    return a;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_integer_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_integer_fact_gate.mc", source, &complete_output);

    try clearIntegerFactsForFunction(&module_mir, "integer_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirIntegerFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_integer_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing call target facts" {
    const source =
        \\fn call_target_fact_gate(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing reflection call target facts" {
    const source =
        \\fn reflection_call_target_fact_gate() -> usize {
        \\    return size_of<u32>();
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_reflection_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "reflection_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_reflection_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing byte-view call target facts" {
    const source =
        \\fn byte_view_call_target_fact_gate(left: []const u8, right: []const u8) -> bool {
        \\    return mem.bytes_equal(left, right);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_byte_view_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "byte_view_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_byte_view_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c reflection and complete byte-view types require MIR target facts" {
    const source =
        \\extern struct Packet { len: u16, tag: u8 }
        \\enum Mode: u8 { normal = 0 }
        \\fn reflected_size() -> usize { return size_of<Packet>(); }
        \\fn reflected_alignment() -> usize { return alignof<Packet>(); }
        \\fn reflected_field_offset() -> usize { return field_offset<Packet>(.tag); }
        \\fn reflected_bit_offset() -> usize { return bit_offset<Packet>(.tag); }
        \\fn reflected_repr() -> usize { return repr_of<Mode>(); }
        \\fn view(value: u32) -> []const u8 { return mem.as_bytes(&value); }
        \\fn equal(left: []const u8, right: []const u8) -> bool { return mem.bytes_equal(left, right); }
    ;
    var parsed = try test_support.parseCheckedModule("c_reflection_byte_view_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "reflected_size", "reflected_alignment", "reflected_field_offset", "reflected_bit_offset", "reflected_repr", "view", "equal" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_reflection_byte_view_type_facts.mc", .{}, false, null));
    }
}

test "lower-c rejects prebuilt MIR with missing semantic escape call target facts" {
    const source =
        \\fn reveal_fact_gate(secret: Secret<u8>) -> u8 {
        \\    unsafe { return reveal(secret); }
        \\}
        \\fn noalias_fact_gate(p: *mut u8, n: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)] {
        \\        return compiler.assume_noalias_unchecked(p, n);
        \\    }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_semantic_escape_call_target_facts.mc", source);
    defer parsed.deinit();

    var reveal_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer reveal_mir.deinit();
    try clearCallTargetFactsForFunction(&reveal_mir, "reveal_fact_gate");
    var reveal_output: std.ArrayList(u8) = .empty;
    defer reveal_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &reveal_mir, &reveal_output, .kernel, "c_missing_semantic_escape_call_target_facts.mc", .{}, false, null),
    );

    var noalias_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer noalias_mir.deinit();
    try clearCallTargetFactsForFunction(&noalias_mir, "noalias_fact_gate");
    var noalias_output: std.ArrayList(u8) = .empty;
    defer noalias_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &noalias_mir, &noalias_output, .kernel, "c_missing_semantic_escape_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c semantic escape types require MIR target facts" {
    const source =
        \\fn reveal_type_gate(secret: Secret<u8>) -> u8 {
        \\    unsafe { return reveal(secret); }
        \\}
        \\fn noalias_type_gate(p: *mut u8, n: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)] {
        \\        return compiler.assume_noalias_unchecked(p, n);
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_semantic_escape_target_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "reveal_type_gate", "noalias_type_gate" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_semantic_escape_target_type_facts.mc", .{}, false, null));
    }
}

test "lower-c executable MIR forget evaluates its operand once without a release call" {
    const source =
        \\linear struct Token { id: u32 }
        \\fn next_value() -> u32 { return 41; }
        \\fn forget_token(token: Token) -> void {
        \\    unsafe { forget_unchecked(token); }
        \\}
        \\fn forget_result() -> u32 {
        \\    unsafe { forget_unchecked(next_value()); }
        \\    return 42;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_discard_value.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.items, "next_value()"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "((void)(mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "forget_unchecked(") == null);
    const forget_body = try cFunctionBody(output.items, "MC_UNUSED static void forget_token(");
    try std.testing.expect(std.mem.indexOf(u8, forget_body, "/* canonical executable MIR */") != null);
}

test "lower-c wrapping arithmetic requires MIR identity and operand/result type facts" {
    const source =
        \\fn wrapping_fact_gate(a: u32) -> u32 {
        \\    return wrapping.add(a, 1);
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_wrapping_call_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_mir_wrapping_call_facts.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "((uint32_t)(mc_exec_tmp_0) + (uint32_t)(mc_exec_tmp_1))") != null);

    var missing_identity = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_identity.deinit();
    try clearCallTargetFactsForFunction(&missing_identity, "wrapping_fact_gate");
    var identity_output: std.ArrayList(u8) = .empty;
    defer identity_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_identity, &identity_output, .kernel, "c_wrapping_call_facts.mc", .{}, false, null));

    inline for ([_]mir.TargetTypeKind{ .wrapping_left, .wrapping_right, .wrapping_result }) |kind| {
        var missing_type = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing_type.deinit();
        try removeTargetTypeKindForFunction(&missing_type, "wrapping_fact_gate", kind);
        var type_output: std.ArrayList(u8) = .empty;
        defer type_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_type, &type_output, .kernel, "c_wrapping_call_facts.mc", .{}, false, null));
    }
}

test "lower-c emits wrapping arithmetic call from MIR without body fallback" {
    const source =
        \\fn wrapping_fact_gate(a: u32) -> u32 {
        \\    return wrapping.add(a, 1);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_wrapping_call.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "((uint32_t)(mc_exec_tmp_0) + (uint32_t)(mc_exec_tmp_1))") != null);
}

test "lower-c emits local wrapping arithmetic from MIR without body fallback" {
    const source =
        \\fn local_wrap(a: u32) -> u32 {
        \\    let out = wrapping.add(a, 1);
        \\    return out;
        \\}
        \\fn assigned_wrap(a: u32) -> u32 {
        \\    var out: u32 = 0;
        \\    out = wrapping.add(a, 1);
        \\    return out;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_wrapping_call.mc", source, &output);
    try expectContains(try cFunctionBody(output.items, "static uint32_t local_wrap(uint32_t a)"), "((uint32_t)(mc_exec_tmp_0) + (uint32_t)(mc_exec_tmp_1))");
    try expectContains(try cFunctionBody(output.items, "static uint32_t assigned_wrap(uint32_t a)"), "((uint32_t)(mc_exec_tmp_1) + (uint32_t)(mc_exec_tmp_2))");
}

test "lower-c unchecked arithmetic requires MIR identity and operand/result type facts" {
    const source =
        \\fn unchecked_fact_gate(a: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.add(a, 1);
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_unchecked_call_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_mir_unchecked_call_facts.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "MC_MIR_RANGE no_overflow region=1 op=add") != null);

    var missing_identity = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_identity.deinit();
    try clearCallTargetFactsForFunction(&missing_identity, "unchecked_fact_gate");
    var identity_output: std.ArrayList(u8) = .empty;
    defer identity_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_identity, &identity_output, .kernel, "c_unchecked_call_facts.mc", .{}, false, null));

    inline for ([_]mir.TargetTypeKind{ .unchecked_left, .unchecked_right, .unchecked_result }) |kind| {
        var missing_type = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing_type.deinit();
        try removeTargetTypeKindForFunction(&missing_type, "unchecked_fact_gate", kind);
        var type_output: std.ArrayList(u8) = .empty;
        defer type_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_type, &type_output, .kernel, "c_unchecked_call_facts.mc", .{}, false, null));
    }
}

test "lower-c emits unchecked arithmetic call from MIR without body fallback" {
    const source =
        \\fn unchecked_fact_gate(a: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.add(a, 1);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_unchecked_call.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_MIR_RANGE no_overflow region=1 op=add") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " + ") != null);
}

test "lower-c emits local unchecked arithmetic from MIR without body fallback" {
    const source =
        \\fn local_unchecked(a: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        let out = unchecked.add(a, 1);
        \\        return out;
        \\    }
        \\}
        \\fn assigned_unchecked(a: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        var out: u32 = 0;
        \\        out = unchecked.add(a, 1);
        \\        return out;
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_unchecked_call.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "MC_MIR_RANGE no_overflow region=1 op=add"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "/* canonical executable MIR */"));
}

test "lower-c emits unchecked sub and mul returns from MIR without body fallback" {
    const source =
        \\fn unchecked_sub_gate(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.sub(a, b);
        \\    }
        \\}
        \\fn unchecked_mul_gate(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)] {
        \\        return unchecked.mul(a, b);
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_unchecked_sub_mul_calls.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_MIR_RANGE no_overflow region=1 op=sub") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " - ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_MIR_RANGE no_overflow region=1 op=mul") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " * ") != null);
}

test "lower-c rejects prebuilt MIR with missing atomic call target facts" {
    const source =
        \\fn atomic_call_target_fact_gate() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(0);
        \\    return counter.fetch_add(1, .acq_rel);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_atomic_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "atomic_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_atomic_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c atomic and MaybeUninit payloads require MIR target facts" {
    const source =
        \\struct Node { value: u32 }
        \\
        \\fn atomic_payload_fact_gate() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(0);
        \\    counter.store(1, .release);
        \\    return counter.fetch_add(1, .acq_rel);
        \\}
        \\fn maybe_uninit_payload_fact_gate() -> u32 {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    slot.write(.{ .value = 7 });
        \\    return slot.assume_init().value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_atomic_maybe_uninit_payload_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "atomic_payload_fact_gate", "maybe_uninit_payload_fact_gate" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_atomic_maybe_uninit_payload_facts.mc", .{}, false, null));
    }
}

test "lower-c atomic init requires MIR identity and complete types" {
    const source =
        \\global boot_counter: atomic<u64> = atomic.init(9);
        \\fn local_init() -> void {
        \\    var counter: atomic<u32> = atomic.init(1);
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_atomic_init_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_atomic_init_facts.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "boot_counter = 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t counter = mc_exec_tmp_") != null);

    for ([_][]const u8{ "boot_counter", "local_init" }) |name| {
        var missing_identity = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing_identity.deinit();
        try clearCallTargetFactsForFunction(&missing_identity, name);
        var missing_identity_output: std.ArrayList(u8) = .empty;
        defer missing_identity_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_identity, &missing_identity_output, .kernel, "c_atomic_init_facts.mc", .{}, false, null));

        inline for ([_]mir.TargetTypeKind{ .atomic_init_payload, .atomic_init_result }) |kind| {
            var missing_type = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
            defer missing_type.deinit();
            try removeTargetTypeKindForFunction(&missing_type, name, kind);
            var missing_type_output: std.ArrayList(u8) = .empty;
            defer missing_type_output.deinit(std.testing.allocator);
            try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_type, &missing_type_output, .kernel, "c_atomic_init_facts.mc", .{}, false, null));
        }

        var stale_payload = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale_payload.deinit();
        try renameTargetTypeFactForFunction(&stale_payload, name, .atomic_init_payload, "bool");
        var stale_payload_output: std.ArrayList(u8) = .empty;
        defer stale_payload_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_payload, &stale_payload_output, .kernel, "c_atomic_init_facts.mc", .{}, false, null));

        var stale_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale_result.deinit();
        try renameTargetTypeFactForFunction(&stale_result, name, .atomic_init_result, "u32");
        var stale_result_output: std.ArrayList(u8) = .empty;
        defer stale_result_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_result, &stale_result_output, .kernel, "c_atomic_init_facts.mc", .{}, false, null));
    }
}

test "lower-c rejects prebuilt MIR with missing bitcast call target facts" {
    const source =
        \\fn bitcast_call_target_fact_gate(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_bitcast_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "bitcast_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_bitcast_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing bitcast target type facts" {
    const source =
        \\fn bitcast_target_type_fact_gate(value: f32) -> u32 {
        \\    return bitcast<u32>(value);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_bitcast_target_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "bitcast_target_type_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirTargetTypeFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_bitcast_target_type_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing const_get call target facts" {
    const source =
        \\fn const_get_call_target_fact_gate(xs: [3]u32) -> u32 {
        \\    return xs.const_get<1>();
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_const_get_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "const_get_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_const_get_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c const_get consumes MIR base result and index facts" {
    const source =
        \\type Words = [3]u32;
        \\fn const_get_fact_gate(xs: Words) -> u32 { let value = xs.const_get<2>(); return value; }
    ;
    var parsed = try test_support.parseCheckedModule("c_const_get_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_const_get_facts.mc", .{}, false, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "[2]") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "const_get_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_const_get_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearConstGetFactsForFunction(&module_mir, "const_get_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirConstGetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_const_get_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetConstGetFactForFunction(&module_mir, "const_get_fact_gate", 1);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirConstGetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_const_get_facts.mc", .{}, false, null));
    }
}

test "lower-c DMA calls consume MIR identities and complete types" {
    const source =
        \\extern struct Packet { len: u16, tag: u8 }
        \\type Buffer = DmaBuf<Packet, .noncoherent>;
        \\fn dma_fact_gate(buf: Buffer) -> []mut Packet {
        \\    cache.clean(buf);
        \\    cache.invalidate(buf);
        \\    let addr: DmaAddr = buf.dma_addr();
        \\    let view = buf.as_slice();
        \\    return view;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_dma_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_dma_facts.mc", .{}, false, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "((void)(buf), mc_barrier_release_before())") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "((void)(buf), mc_barrier_acquire_after())") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_release_before()") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_barrier_acquire_after()") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "((uintptr_t)(") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, ".len = 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_slice_mut_mc_type_struct_6_Packet") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "dma_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_dma_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetCallTargetFactsForFunction(&module_mir, "dma_fact_gate", .const_get);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_dma_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "dma_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_dma_facts.mc", .{}, false, null));
    }
}

test "lower-c raw-many offset consumes MIR identity and complete types" {
    const source =
        \\type Words = [*]mut u16;
        \\fn raw_many_offset_fact_gate(p: Words, index: usize) -> Words {
        \\    unsafe { let q = p.offset(index); return q; }
        \\}
        \\fn raw_many_offset_deref_fact_gate(p: Words, index: usize) -> u16 {
        \\    unsafe { let value = p.offset(index).*; return value; }
        \\}
        \\fn raw_many_offset_address_fact_gate(p: Words, index: usize) -> *mut u16 {
        \\    unsafe { return &p.offset(index).*; }
        \\}
        \\fn raw_many_offset_store_fact_gate(p: Words, index: usize, value: u16) -> void {
        \\    unsafe { p.offset(index).* = value; }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_raw_many_offset_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_many_offset_facts.mc", .{}, false, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, " + ") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_load_u16(mc_exec_tmp_") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t value =") != null);
        const deref_body = try cFunctionBody(output.items, "static uint16_t raw_many_offset_deref_fact_gate(uint16_t * p, uintptr_t index)");
        try expectContains(deref_body, "/* canonical executable MIR */");
        try expectNotContains(deref_body, "mc_trap_InvalidRepresentation");
        const address_body = try cFunctionBody(output.items, "static uint16_t * raw_many_offset_address_fact_gate(uint16_t * p, uintptr_t index)");
        try expectContains(address_body, "/* canonical executable MIR */");
        try expectContains(address_body, "return mc_exec_tmp_");
        try expectNotContains(address_body, "mc_trap_InvalidRepresentation");
        const store_body = try cFunctionBody(output.items, "static void raw_many_offset_store_fact_gate(uint16_t * p, uintptr_t index, uint16_t value)");
        try expectContains(store_body, "/* canonical executable MIR */");
        try expectContains(store_body, "mc_race_store_u16(mc_exec_tmp_");
        try expectNotContains(store_body, "mc_trap_InvalidRepresentation");
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "raw_many_offset_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_many_offset_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetCallTargetFactsForFunction(&module_mir, "raw_many_offset_fact_gate", .const_get);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_many_offset_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "raw_many_offset_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_many_offset_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "raw_many_offset_fact_gate", .inferred_local);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_many_offset_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try renameTargetTypeFactForFunction(&module_mir, "raw_many_offset_fact_gate", .inferred_local, "u64");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_many_offset_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "raw_many_offset_deref_fact_gate", .inferred_local);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_many_offset_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try renameTargetTypeFactForFunction(&module_mir, "raw_many_offset_deref_fact_gate", .inferred_local, "u64");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_many_offset_facts.mc", .{}, false, null));
    }
}

test "lower-c inferred local try payloads require MIR types" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\extern fn make_nullable() -> ?*const u8;
        \\fn result_local() -> Result<u32, u32> { let value = make_result()?; return ok(value); }
        \\fn nullable_local() -> *const u8 { let value = make_nullable()?; return value; }
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_try_payloads.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_try_payloads.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "result_local") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "nullable_local") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "result_local", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_try_payloads.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "result_local", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_try_payloads.mc", .{}, false, null));
}

test "lower-c grouped expressions consume their own MIR result facts" {
    const source =
        \\fn grouped_result(value: u16) -> u16 {
        \\    return (value) + 1;
        \\}
    ;
    const grouped_text = "(value)";
    const grouped_offset = std.mem.indexOf(u8, source, grouped_text) orelse return error.TestUnexpectedResult;

    var parsed = try test_support.parseCheckedModule("c_grouped_expression_result.mc", source);
    defer parsed.deinit();

    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_grouped_expression_result_fact_gate.mc", source, &complete_output);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "grouped_result") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "grouped_result", .expression_result, grouped_offset, grouped_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_grouped_expression_result.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "grouped_result", .expression_result, grouped_offset, grouped_text.len, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_grouped_expression_result.mc", .{}, false, null));
}

test "lower-c grouped direct calls consume the outer MIR result fact" {
    const source =
        \\fn make() -> u16 { return 7; }
        \\fn grouped_call_result() -> u16 {
        \\    let value = (make());
        \\    return value;
        \\}
    ;
    const grouped_text = "(make())";
    const grouped_offset = std.mem.indexOf(u8, source, grouped_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("c_grouped_call_result.mc", source);
    defer parsed.deinit();

    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_grouped_call_result_fact_gate.mc", source, &complete_output);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "grouped_call_result", .expression_result, grouped_offset, grouped_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_grouped_call_result.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "grouped_call_result", .expression_result, grouped_offset, grouped_text.len, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_grouped_call_result.mc", .{}, false, null));
}

test "lower-c direct-call inferred local lowers without function body fallback" {
    const source =
        \\fn make_count() -> u64 { return 7; }
        \\fn caller() -> u64 {
        \\    let count = make_count();
        \\    return count;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_direct_call_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint64_t caller(void)");
    try expectLegacyOrCanonicalReturn(body, "return make_count();", "= make_count(");
}

test "lower-c literal inferred local lowers without function body fallback" {
    const source =
        \\fn literal_local() -> u32 {
        \\    let count = 7;
        \\    return count;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_literal_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint32_t literal_local(void)");
    try expectLegacyOrCanonicalReturn(body, "return 7;", " = 7;");
}

test "lower-c bool-literal inferred local lowers without function body fallback" {
    const source =
        \\fn bool_local() -> bool {
        \\    let flag = true;
        \\    return flag;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_bool_literal_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static bool bool_local(void)");
    try expectLegacyOrCanonicalReturn(body, "return true;", " = true;");
}

test "lower-c checked-unary inferred local lowers without function body fallback" {
    const source =
        \\fn unary_local(value: i64) -> i64 {
        \\    let negated = -value;
        \\    return negated;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_checked_unary_return.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_neg_i64(") != null);
}

test "lower-c checked-binary inferred local lowers without function body fallback" {
    const source =
        \\fn binary_local(left: u64, right: u64) -> u64 {
        \\    let sum = left + right;
        \\    return sum;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_checked_binary_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint64_t binary_local(uint64_t left, uint64_t right)");
    try expectLegacyOrCanonicalReturn(body, "return mc_checked_add_u64(left, right);", "mc_checked_add_u64(");
}

test "lower-c logical-not inferred local lowers without function body fallback" {
    const source =
        \\fn not_local(enabled: bool) -> bool {
        \\    let disabled = !enabled;
        \\    return disabled;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_logical_not_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static bool not_local(bool enabled)");
    try expectLegacyOrCanonicalReturn(body, "return !enabled;", "(!");
}

test "lower-c logical return tree lowers without function body fallback" {
    const source =
        \\fn bool_and(a: bool, b: bool) -> bool { return a && b; }
        \\fn bool_or(a: bool, b: bool) -> bool { return a || b; }
        \\fn nested_bool(a: bool, b: bool, c: bool) -> bool { return !a || (b && c); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_logical_return_tree.mc", source, &output);
    const and_body = try cFunctionBody(output.items, "static bool bool_and(bool a, bool b)");
    const or_body = try cFunctionBody(output.items, "static bool bool_or(bool a, bool b)");
    const nested_body = try cFunctionBody(output.items, "static bool nested_bool(bool a, bool b, bool c)");
    for ([_][]const u8{ and_body, or_body, nested_body }) |body| try expectContains(body, "/* canonical executable MIR */");
    try expectContains(and_body, " && ");
    try expectContains(or_body, " || ");
    try expectContains(nested_body, "(!");
    try expectContains(nested_body, " && ");
    try expectContains(nested_body, " || ");
}

test "lower-c compare inferred local lowers without function body fallback" {
    const source =
        \\fn compare_local(left: u64, right: u64) -> bool {
        \\    let less = left < right;
        \\    return less;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_compare_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static bool compare_local(uint64_t left, uint64_t right)");
    try expectLegacyOrCanonicalReturn(body, "return (left < right);", " < ");
}

test "lower-c copied inferred local lowers without function body fallback" {
    const source =
        \\fn copy_local(value: u64) -> u64 {
        \\    let copy = value;
        \\    return copy;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_copy_return.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return value;") != null);
}

test "lower-c param-field copied inferred local lowers without function body fallback" {
    const source =
        \\struct Box { value: u64 }
        \\fn copy_field(box: Box) -> u64 {
        \\    let copy = box.value;
        \\    return copy;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_param_field_copy_return.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ").value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_exec_tmp_") != null);
}

test "lower-c null inferred local lowers without function body fallback" {
    const source =
        \\fn null_local() -> ?u32 {
        \\    let none: ?u32 = null;
        \\    return none;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_inferred_local_null_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static mc_opt_u32 null_local(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "(mc_opt_u32){ .present = false }");
}

test "lower-c diagnoses source block expressions instead of inferring their result" {
    const source =
        \\fn block_result() -> u32 {
        \\    return { 1 + 2; };
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_block_expression_policy.mc", source);
    defer parsed.deinit();
    var typed_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer typed_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &typed_mir, &output, .kernel, "c_block_expression_policy.mc", .{}, false, null));
}

test "lower-c indexes direct fixed-array call results through MIR return types" {
    const source =
        \\fn make_matrix() -> [2][2]u32 { return .{ .{ 1, 2 }, .{ 3, 4 } }; }
        \\fn read_matrix_row() -> u32 {
        \\    let row = make_matrix()[0];
        \\    return row[1];
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_direct_array_call_index.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_direct_array_call_index.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_matrix()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".elems[") != null);
}

test "lower-c projects direct aggregate call results from MIR without body fallback" {
    const source =
        \\struct Bag { values: [4]u32, tail: []const u32 }
        \\extern fn make_values(seed: u32) -> [4]u32;
        \\extern fn make_bag(seed: u32) -> Bag;
        \\fn direct_array_call_index(seed: u32, index: usize) -> u32 {
        \\    return make_values(seed)[index];
        \\}
        \\fn call_array_field_index(seed: u32, index: usize) -> u32 {
        \\    return make_bag(seed).values[index];
        \\}
        \\fn call_slice_field_index(seed: u32, index: usize) -> u32 {
        \\    return make_bag(seed).tail[index];
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_direct_call_projected_return.mc", source, &output);

    const direct_body = try cFunctionBody(output.items, "static uint32_t direct_array_call_index(uint32_t seed, uintptr_t index)");
    try expectContains(direct_body, "/* canonical executable MIR */");
    try expectContains(direct_body, "make_values(mc_exec_tmp_");
    try expectContains(direct_body, "= index;");
    try expectContains(direct_body, ".elems[mc_check_index_usize(");
    try expectContains(direct_body, "return mc_exec_tmp_");

    const array_field_body = try cFunctionBody(output.items, "static uint32_t call_array_field_index(uint32_t seed, uintptr_t index)");
    try expectContains(array_field_body, "/* canonical executable MIR */");
    try expectContains(array_field_body, "make_bag(mc_exec_tmp_");
    try expectContains(array_field_body, ".values;");
    try expectContains(array_field_body, ".elems[mc_check_index_usize(");
    try expectContains(array_field_body, "return mc_exec_tmp_");

    const slice_field_body = try cFunctionBody(output.items, "static uint32_t call_slice_field_index(uint32_t seed, uintptr_t index)");
    try expectContains(slice_field_body, "/* canonical executable MIR */");
    try expectContains(slice_field_body, "make_bag(mc_exec_tmp_");
    try expectContains(slice_field_body, ".tail;");
    try expectContains(slice_field_body, ".ptr[mc_check_index_usize(");
    try expectContains(slice_field_body, "return mc_exec_tmp_");
}

test "lower-c returns first fixed-array element from MIR CFG without body fallback" {
    const source =
        \\struct Bag { values: [4]u32 }
        \\extern fn make_values(seed: u32) -> [4]u32;
        \\extern fn make_bag(seed: u32) -> Bag;
        \\extern fn next_seed() -> u32;
        \\extern fn make_slice() -> []const u32;
        \\fn first_value(seed: u32) -> u32 {
        \\    for value in make_values(seed) { return value; }
        \\    return 0;
        \\}
        \\fn first_field(seed: u32) -> u32 {
        \\    for value in make_bag(seed).values { return value; }
        \\    return 0;
        \\}
        \\fn first_parameter(values: [4]u32) -> u32 {
        \\    for value in values { return value; }
        \\    return 0;
        \\}
        \\fn first_nested_call() -> u32 {
        \\    for value in make_values(next_seed()) { return value; }
        \\    return 0;
        \\}
        \\fn first_slice(values: []const u32) -> u32 {
        \\    for value in values { return value; }
        \\    return 0;
        \\}
        \\fn first_slice_call() -> u32 {
        \\    for value in make_slice() { return value; }
        \\    return 0;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_canonical_foreach_return.mc", source, &output);

    const direct = try cFunctionBody(output.items, "static uint32_t first_value(uint32_t seed)");
    try expectContains(direct, "/* canonical executable MIR */");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, direct, "make_values("));
    try expectContains(direct, " < 4");
    try expectContains(direct, ".elems[__mc_for_index_");
    try expectContains(direct, "return mc_exec_tmp_");

    const field = try cFunctionBody(output.items, "static uint32_t first_field(uint32_t seed)");
    try expectContains(field, "/* canonical executable MIR */");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, field, "make_bag("));
    try expectContains(field, ".values;");
    try expectContains(field, ".elems[__mc_for_index_");
    try expectContains(field, "return mc_exec_tmp_");

    const parameter = try cFunctionBody(output.items, "first_parameter(");
    try expectContains(parameter, ".elems[__mc_for_index_");
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, parameter, "make_values"));

    const nested = try cFunctionBody(output.items, "first_nested_call(");
    const nested_call = std.mem.indexOf(u8, nested, "next_seed()") orelse return error.TestUnexpectedResult;
    const outer_call = std.mem.indexOf(u8, nested, "make_values(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(nested_call < outer_call);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, nested, "next_seed()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, nested, "make_values("));

    const slice = try cFunctionBody(output.items, "first_slice(");
    try expectContains(slice, ".ptr == NULL &&");
    try expectContains(slice, ".len != 0");
    try expectContains(slice, ".ptr[__mc_for_index_");

    const slice_call = try cFunctionBody(output.items, "first_slice_call(");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, slice_call, "make_slice()"));
    try expectContains(slice_call, ".ptr == NULL");
    try expectContains(slice_call, ".ptr[__mc_for_index_");
}

test "lower-c emits break and continue while CFG from MIR without body fallback" {
    const source =
        \\fn stop(flag: bool) -> void { while flag { break; } }
        \\fn repeat(flag: bool) -> void { while flag { continue; } }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_while_control.mc", source, &output);

    const stop = try cFunctionBody(output.items, "static void stop(bool flag)");
    try expectContains(stop, "/* canonical executable MIR */");
    try expectContains(stop, "goto mc_bb_1;");
    try expectContains(stop, "if (mc_exec_tmp_0) goto mc_bb_2; else goto mc_bb_3;");
    try expectContains(stop, "mc_bb_2: ;");
    try expectContains(stop, "goto mc_bb_3;");
    const repeat = try cFunctionBody(output.items, "static void repeat(bool flag)");
    try expectContains(repeat, "/* canonical executable MIR */");
    try expectContains(repeat, "goto mc_bb_1;");
    try expectContains(repeat, "if (mc_exec_tmp_0) goto mc_bb_2; else goto mc_bb_3;");
    try expectContains(repeat, "mc_bb_2: ;");
    try expectContains(repeat, "goto mc_bb_1;");
}

test "lower-c emits slice foreach local updates from MIR without body fallback" {
    const source =
        \\fn sum(values: []const u32) -> u32 {
        \\    var total: u32 = 0;
        \\    for value in values { total = total + value; continue; }
        \\    return total;
        \\}
        \\fn first(values: []const u32) -> u32 {
        \\    var seen: u32 = 0;
        \\    for value in values { seen = value; break; }
        \\    return seen;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_canonical_foreach_update.mc", source, &output);

    const sum = try cFunctionBody(output.items, "static uint32_t sum(");
    try expectContains(sum, "/* canonical executable MIR */");
    try expectContains(sum, ".ptr == NULL &&");
    try expectContains(sum, ".len != 0");
    try expectContains(sum, "mc_checked_add_u32(");
    try expectContains(sum, "__mc_for_index_");
    try expectContains(sum, " += 1;");
    try expectContains(sum, "return mc_exec_tmp_");
    const first = try cFunctionBody(output.items, "static uint32_t first(");
    try expectContains(first, "/* canonical executable MIR */");
    try expectContains(first, "seen = mc_exec_tmp_");
    try expectContains(first, "goto mc_bb_");
    try expectContains(first, "return mc_exec_tmp_");
}

test "lower-c nested struct members require MIR expression facts" {
    const source =
        \\struct Leaf { value: u32 }
        \\struct Holder { child: Leaf }
        \\fn read_nested_member(holder: Holder) -> u32 {
        \\    return holder.child.value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_struct_member_expression_result_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_struct_member_expression_result_facts.mc", .{}, false, null);
        try expectContains(output.items, ").child;");
        try expectContains(output.items, ").value;");
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        const member_offset = std.mem.indexOf(u8, source, "holder.child") orelse return error.TestUnexpectedResult;
        try removeTargetTypeFactAtOffsetForFunction(&module_mir, "read_nested_member", .expression_result, member_offset, "holder.child".len);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_struct_member_expression_result_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        const member_offset = std.mem.indexOf(u8, source, "holder.child") orelse return error.TestUnexpectedResult;
        try renameTargetTypeFactAtOffsetForFunction(&module_mir, "read_nested_member", .expression_result, member_offset, "holder.child".len, "u32");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_struct_member_expression_result_facts.mc", .{}, false, null));
    }
}

test "lower-c MMIO calls consume MIR identities and complete types" {
    const source =
        \\packed bits Status: u8 { ready: bool }
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read_write>,
        \\    flags: RegBits<u8, Status, .read>,
        \\}
        \\fn mmio_fact_gate(dev: MmioPtr<Device>, value: u32) -> Status {
        \\    dev.raw.write(value, .release);
        \\    let raw = dev.raw.read(.relaxed);
        \\    return dev.flags.read(.acquire);
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_mmio_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_facts.mc", .{}, false, null);
        const body = try cFunctionBody(output.items, "mmio_fact_gate(");
        try expectContains(body, "/* canonical executable MIR */");
        try expectNeedlesInOrder(body, &.{ "mc_mmio_write_u32", "mc_mmio_read_u32", "mc_mmio_read_u8" });
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "mc_mmio_write_u32"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "mc_mmio_read_u32"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "mc_mmio_read_u8"));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "mmio_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetCallTargetFactsForFunction(&module_mir, "mmio_fact_gate", .const_get);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "mmio_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "mmio_fact_gate", .inferred_local);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try renameTargetTypeFactForFunction(&module_mir, "mmio_fact_gate", .inferred_local, "u64");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_facts.mc", .{}, false, null));
    }
}

test "lower-c MMIO map consumes MIR identity and complete types" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read>,
        \\}
        \\fn map_fact_gate(pa: PAddr) -> MmioPtr<Device> {
        \\    unsafe { return mmio.map<Device>(pa)?; }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_mmio_map_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_map_facts.mc", .{}, false, null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "((void volatile *)((uintptr_t)mc_exec_tmp_0))") != null);
        try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_exec_tmp_1 == NULL) mc_trap_NullUnwrap();") != null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "map_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_map_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try retargetCallTargetFactsForFunction(&module_mir, "map_fact_gate", .mmio_read);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_map_facts.mc", .{}, false, null));
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "map_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_mmio_map_facts.mc", .{}, false, null));
    }
}

test "lower-c reductions require MIR source and element type facts" {
    const source =
        \\fn reduce_element_fact_gate(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_reduce_element_facts.mc", source);
    defer parsed.deinit();
    for ([_]mir.TargetTypeKind{ .reduce_source, .reduce_element }) |kind| {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try removeTargetTypeKindForFunction(&module_mir, "reduce_element_fact_gate", kind);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.InvalidMirTargetTypeFacts,
            appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_reduce_element_facts.mc", .{}, false, null),
        );
    }
}

test "lower-c enum raw requires MIR call and target type facts" {
    const source =
        \\enum Color: u32 { red = 1 }
        \\open enum Tag: u8 { ready = 2 }
        \\enum DefaultTag { idle }
        \\fn enum_raw_fact_gate(value: Color) -> u32 { return value.raw(); }
        \\fn open_raw(value: Tag) -> u8 { return value.raw(); }
        \\fn default_raw(value: DefaultTag) -> isize { return value.raw(); }
        \\fn path_raw() -> u32 { return Color.red.raw(); }
    ;

    var parsed = try test_support.parseCheckedModule("c_enum_raw_facts.mc", source);
    defer parsed.deinit();
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_enum_raw_facts.mc", .{}, false, null);
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearCallTargetFactsForFunction(&module_mir, "enum_raw_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.InvalidMirCallTargetFacts,
            appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_enum_raw_facts.mc", .{}, false, null),
        );
    }
    {
        var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, "enum_raw_fact_gate");
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(
            error.InvalidMirTargetTypeFacts,
            appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_enum_raw_facts.mc", .{}, false, null),
        );
    }
}

test "lower-c rejects prebuilt MIR with missing phys call target facts" {
    const source =
        \\fn phys_call_target_fact_gate(value: usize) -> PAddr {
        \\    return phys(value);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_phys_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "phys_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_phys_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing phys result type facts" {
    const source =
        \\fn phys_result_type_fact_gate(value: usize) -> PAddr {
        \\    return phys(value);
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_phys_result_type_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearTargetTypeFactsForFunction(&module_mir, "phys_result_type_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirTargetTypeFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_phys_result_type_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing MaybeUninit call target facts" {
    const source =
        \\struct Node { value: u32 }
        \\
        \\fn maybe_uninit_call_target_fact_gate() -> u32 {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    slot.write(.{ .value = 7 });
        \\    let value: Node = slot.assume_init();
        \\    return value.value;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_maybe_uninit_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "maybe_uninit_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_maybe_uninit_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing raw store call target facts" {
    const source =
        \\fn raw_store_call_target_fact_gate(addr: PAddr, value: u32) -> void {
        \\    unsafe { raw.store<u32>(addr, value); }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_raw_store_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_store_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_raw_store_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing raw load call target facts" {
    const source =
        \\fn raw_load_call_target_fact_gate(addr: PAddr) -> u32 {
        \\    unsafe { return raw.load<u32>(addr); }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_raw_load_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_load_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_raw_load_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing raw ptr call target facts" {
    const source =
        \\fn raw_ptr_call_target_fact_gate(addr: PAddr) -> *mut u32 {
        \\    unsafe { return raw.ptr<u32>(addr); }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_raw_ptr_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "raw_ptr_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_raw_ptr_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c raw memory calls require complete MIR target type facts" {
    const source =
        \\fn read(addr: PAddr) -> u32 { unsafe { return raw.load<u32>(addr); } }
        \\fn pointer(addr: PAddr) -> *mut u32 { unsafe { return raw.ptr<u32>(addr); } }
        \\fn write(addr: PAddr, value: u32) -> void { unsafe { raw.store<u32>(addr, value); } }
    ;
    var parsed = try test_support.parseCheckedModule("c_raw_memory_type_facts.mc", source);
    defer parsed.deinit();
    for ([_][]const u8{ "read", "pointer", "write" }) |name| {
        var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer module_mir.deinit();
        try clearTargetTypeFactsForFunction(&module_mir, name);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_raw_memory_type_facts.mc", .{}, false, null));
    }
}

test "lower-c pointer-to-PAddr coercions require MIR source type facts" {
    const source =
        \\fn write_pointer(addr: *mut u32, value: u32) -> void {
        \\    unsafe { raw.store<u32>(addr, value); }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_paddr_coercion_source_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_paddr_coercion_source_type_facts.mc", .{}, false, null);
    try expectContains(complete_output.items, "/* canonical executable MIR */");
    try expectContains(complete_output.items, "((uintptr_t)(mc_exec_tmp_");

    var missing_source = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_source.deinit();
    try removeTargetTypeKindForFunction(&missing_source, "write_pointer", .paddr_coercion_source);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_source, &missing_output, .kernel, "c_paddr_coercion_source_type_facts.mc", .{}, false, null));
}

test "lower-c explicit traps require exact MIR reason identities" {
    const source =
        \\fn trap_bounds() -> never { return trap(.Bounds); }
        \\fn trap_null_unwrap() -> never { return trap(.NullUnwrap); }
        \\fn trap_integer_overflow() -> never { return trap(.IntegerOverflow); }
        \\fn trap_divide_by_zero() -> never { return trap(.DivideByZero); }
        \\fn trap_invalid_shift() -> never { return trap(.InvalidShift); }
        \\fn trap_invalid_representation() -> never { return trap(.InvalidRepresentation); }
        \\fn trap_assert() -> never { return trap(.Assert); }
        \\fn trap_unreachable() -> never { return trap(.Unreachable); }
    ;
    var parsed = try test_support.parseCheckedModule("c_explicit_trap_target_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_explicit_trap_target_facts.mc", .{}, false, null);
    for ([_][]const u8{ "Bounds", "NullUnwrap", "IntegerOverflow", "DivideByZero", "InvalidShift", "InvalidRepresentation", "Assert", "Unreachable" }) |reason| {
        const helper = try std.fmt.allocPrint(std.testing.allocator, "mc_trap_{s}();", .{reason});
        defer std.testing.allocator.free(helper);
        try std.testing.expect(std.mem.indexOf(u8, complete_output.items, helper) != null);
    }

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try clearCallTargetFactsForFunction(&missing, "trap_bounds");
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_explicit_trap_target_facts.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try retargetCallTargetFactsForFunction(&stale, "trap_bounds", .trap_assert);
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_explicit_trap_target_facts.mc", .{}, false, null));
}

test "lower-c runtime asserts require MIR bool condition types" {
    const source =
        \\fn require_flag(flag: bool) -> void { assert(flag); }
    ;
    var parsed = try test_support.parseCheckedModule("c_assert_condition_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_mir_assert_condition_type_facts.mc", .{}, false, null);
    const complete_body = try cFunctionBody(complete_output.items, "static void require_flag(bool flag)");
    try expectContains(complete_body, "/* canonical executable MIR */");
    try expectContains(complete_body, "if (!(mc_exec_tmp_");
    try expectContains(complete_body, ")) goto mc_bb_");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, complete_body, "mc_trap_Assert();"));

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "require_flag", .assert_condition);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_assert_condition_type_facts.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "require_flag", .assert_condition, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_assert_condition_type_facts.mc", .{}, false, null));
}

test "lower-c emits runtime assert from MIR without body fallback" {
    const source =
        \\fn require_flag(flag: bool) -> void { assert(flag); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_runtime_assert.mc", source, &output);
    const body = try cFunctionBody(output.items, "static void require_flag(bool flag)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "if (!(mc_exec_tmp_");
    try expectContains(body, ")) goto mc_bb_");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "mc_trap_Assert();"));
}

test "lower-c while loops require MIR bool condition types" {
    const source =
        \\fn wait_for_flag(flag: bool) -> void { while flag { return; } }
    ;
    var parsed = try test_support.parseCheckedModule("c_loop_condition_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_mir_loop_condition_type_facts.mc", .{}, false, null);
    const complete_body = try cFunctionBody(complete_output.items, "static void wait_for_flag(bool flag)");
    try expectLegacyOrCanonicalLoop(complete_body, "while (flag)");

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "wait_for_flag", .loop_condition);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_loop_condition_type_facts.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "wait_for_flag", .loop_condition, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_loop_condition_type_facts.mc", .{}, false, null));
}

test "lower-c emits void-returning while loop from MIR without body fallback" {
    const source =
        \\fn wait_for_flag(flag: bool) -> void { while flag { return; } }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_void_returning_while_loop.mc", source, &output);
    const body = try cFunctionBody(output.items, "static void wait_for_flag(bool flag)");
    try expectLegacyOrCanonicalLoop(body, "while (flag)");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return;") != null);
}

test "lower-c switches require MIR subject types" {
    const source =
        \\enum Choice { left, right }
        \\union Token { number: u32, eof }
        \\fn result_subject(value: Result<u32, u32>) -> u32 { switch value { ok(v) => { return v; }, err(e) => { return e; }, } }
        \\fn nullable_subject(value: ?*const u8) -> u32 { switch value { p => { return 1; }, _ => { return 0; }, } }
        \\fn union_subject(value: Token) -> u32 { switch value { number(v) => { return v; }, .eof => { return 0; }, } }
        \\fn enum_subject(value: Choice) -> u32 { switch value { .left => { return 1; }, .right => { return 0; }, } }
        \\fn bool_subject(value: bool) -> u32 { switch (value) { true => { return 1; }, false => { return 0; }, } }
    ;
    var parsed = try test_support.parseCheckedModule("c_switch_subject_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_switch_subject_type_facts.mc", .{}, false, null);
    for ([_][]const u8{ "result_subject", "nullable_subject", "union_subject", "enum_subject", "bool_subject" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, complete_output.items, name) != null);
    }

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "result_subject", .switch_subject);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_switch_subject_type_facts.mc", .{}, false, null));

    for ([_][]const u8{ "result_subject", "nullable_subject", "union_subject", "enum_subject", "bool_subject" }) |name| {
        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .switch_subject, "u32");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_switch_subject_type_facts.mc", .{}, false, null));
    }

    var stale_nullable_repr = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_nullable_repr.deinit();
    try retargetTargetTypeResultForFunction(&stale_nullable_repr, "nullable_subject", .switch_subject, .{ .nullable_value = "u32" });
    var stale_nullable_repr_output: std.ArrayList(u8) = .empty;
    defer stale_nullable_repr_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_nullable_repr, &stale_nullable_repr_output, .kernel, "c_switch_subject_type_facts.mc", .{}, false, null));

    var unknown_subject_repr = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer unknown_subject_repr.deinit();
    try retargetTargetTypeResultForFunction(&unknown_subject_repr, "nullable_subject", .switch_subject, .unknown);
    var unknown_subject_repr_output: std.ArrayList(u8) = .empty;
    defer unknown_subject_repr_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &unknown_subject_repr, &unknown_subject_repr_output, .kernel, "c_switch_subject_type_facts.mc", .{}, false, null));
}

test "lower-c emits enum switch returns from MIR without body fallback" {
    const source =
        \\enum Choice { left, right }
        \\fn choose(value: Choice) -> u32 {
        \\    switch value {
        \\        .left => { return 1; },
        \\        .right => { return 2; },
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_enum_switch_returns.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation();") != null);
}

test "lower-c emits multi-arm enum switch returns from MIR without body fallback" {
    const source =
        \\enum Choice { left, middle, right }
        \\fn choose(value: Choice) -> u32 {
        \\    switch value {
        \\        .left => { return 1; },
        \\        .middle => { return 2; },
        \\        .right => { return 3; },
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_enum_switch_multi_arm_returns.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 0:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= 3;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation();") != null);
}

test "lower-c if-let statements require MIR subject types" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\extern fn make_nullable() -> ?*const u8;
        \\fn result_subject(value: Result<u32, u32>) -> u32 { if let ok(v) = value { return v; } else { return 0; } }
        \\fn nullable_subject(value: ?*const u8) -> u32 { if let p = value { return 1; } else { return 0; } }
        \\fn result_call_subject() -> u32 { if let ok(v) = make_result() { return v; } else { return 0; } }
        \\fn nullable_call_subject() -> u32 { if let p = make_nullable() { return 1; } else { return 0; } }
    ;
    var parsed = try test_support.parseCheckedModule("c_if_let_subject_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_if_let_subject_type_facts.mc", .{}, false, null);
    for ([_][]const u8{ "result_subject", "nullable_subject", "result_call_subject", "nullable_call_subject" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, complete_output.items, name) != null);
    }

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "result_subject", .if_let_subject);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_if_let_subject_type_facts.mc", .{}, false, null));

    for ([_][]const u8{ "result_subject", "nullable_subject" }) |name| {
        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .if_let_subject, "u32");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_if_let_subject_type_facts.mc", .{}, false, null));
    }

    var stale_nullable_repr = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_nullable_repr.deinit();
    try retargetTargetTypeResultForFunction(&stale_nullable_repr, "nullable_subject", .if_let_subject, .{ .nullable_value = "u32" });
    var stale_nullable_repr_output: std.ArrayList(u8) = .empty;
    defer stale_nullable_repr_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_nullable_repr, &stale_nullable_repr_output, .kernel, "c_if_let_subject_type_facts.mc", .{}, false, null));
}

test "lower-c try expressions require MIR operand and result types" {
    const source =
        \\extern fn make_result() -> Result<u32, u32>;
        \\extern fn make_nullable() -> ?*const u8;
        \\fn result_try() -> Result<u32, u32> { let value = make_result()?; return ok(value); }
        \\fn nullable_try() -> *const u8 { let value = make_nullable()?; return value; }
        \\fn result_direct_return() -> u32 { return make_result()?; }
        \\fn nullable_direct_return() -> *const u8 { return make_nullable()?; }
    ;
    var parsed = try test_support.parseCheckedModule("c_try_operand_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_try_operand_type_facts.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "result_try") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "nullable_try") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "result_direct_return") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "nullable_direct_return") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "result_try", .try_operand);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_try_operand_type_facts.mc", .{}, false, null));

    var missing_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_result.deinit();
    try removeTargetTypeKindForFunction(&missing_result, "result_try", .expression_result);
    var missing_result_output: std.ArrayList(u8) = .empty;
    defer missing_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_result, &missing_result_output, .kernel, "c_try_operand_type_facts.mc", .{}, false, null));

    for ([_][]const u8{ "result_try", "nullable_try", "result_direct_return", "nullable_direct_return" }) |name| {
        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .try_operand, "u32");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_try_operand_type_facts.mc", .{}, false, null));
    }

    for ([_][]const u8{ "result_try", "nullable_try" }) |name| {
        var stale_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale_result.deinit();
        try renameTargetTypeFactForFunction(&stale_result, name, .expression_result, "u64");
        var stale_result_output: std.ArrayList(u8) = .empty;
        defer stale_result_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_result, &stale_result_output, .kernel, "c_try_operand_type_facts.mc", .{}, false, null));
    }
}

test "lower-c for loops require MIR iterable and element types" {
    const source =
        \\extern fn make_slice() -> []const u32;
        \\fn array_loop(values: [2]u32) -> u32 { for value in values { return value; } return 0; }
        \\fn slice_loop(values: []const u32) -> u32 { for value in values { return value; } return 0; }
        \\fn call_loop() -> u32 { for value in make_slice() { return value; } return 0; }
    ;
    var parsed = try test_support.parseCheckedModule("c_for_loop_type_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_for_loop_type_facts.mc", .{}, false, null);
    for ([_][]const u8{ "array_loop", "slice_loop", "call_loop" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, complete_output.items, name) != null);
    }

    for ([_]mir.TargetTypeKind{ .for_iterable, .for_element }) |kind| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, "array_loop", kind);
        var missing_output: std.ArrayList(u8) = .empty;
        defer missing_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_for_loop_type_facts.mc", .{}, false, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, "array_loop", kind, "u64");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_for_loop_type_facts.mc", .{}, false, null));
    }
}

test "lower-c inferred local copies require MIR types" {
    const source =
        \\fn copies(value: u64, ptr: *u8) -> u64 {
        \\    let copied_value = value;
        \\    let copied_ptr = ptr;
        \\    return copied_value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_copy_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_copy_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint64_t copied_value = mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "mc_trap_InvalidRepresentation();") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "copies", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_copy_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "copies", .inferred_local, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_copy_types.mc", .{}, false, null));
}

test "lower-c inferred local casts require MIR types" {
    const source =
        \\fn casts(value: u64, ptr: *const u64) -> u32 {
        \\    let narrowed = value as u32;
        \\    let view = ptr as *const u64;
        \\    return narrowed;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_cast_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_cast_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t narrowed =") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "view =") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "casts", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_cast_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "casts", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_cast_types.mc", .{}, false, null));

    const cast_offset = std.mem.indexOf(u8, source, "value as u32") orelse return error.TestUnexpectedResult;

    var missing_cast_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_cast_result.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing_cast_result, "casts", .expression_result, cast_offset, "value as u32".len);
    var missing_cast_result_output: std.ArrayList(u8) = .empty;
    defer missing_cast_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_cast_result, &missing_cast_result_output, .kernel, "c_inferred_local_cast_types.mc", .{}, false, null));

    var stale_cast_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_cast_result.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale_cast_result, "casts", .expression_result, cast_offset, "value as u32".len, "u64");
    var stale_cast_result_output: std.ArrayList(u8) = .empty;
    defer stale_cast_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_cast_result, &stale_cast_result_output, .kernel, "c_inferred_local_cast_types.mc", .{}, false, null));
}

test "lower-c float cast operands require MIR result type" {
    const source =
        \\fn cast_float(value: f64) -> f32 {
        \\    return (value as f32) + 1.0;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_float_cast_operand_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_float_cast_operand_type.mc", .{}, false, null);

    const cast_offset = std.mem.indexOf(u8, source, "value as f32") orelse return error.TestUnexpectedResult;

    var missing_cast_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_cast_result.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing_cast_result, "cast_float", .expression_result, cast_offset, "value as f32".len);
    var missing_cast_result_output: std.ArrayList(u8) = .empty;
    defer missing_cast_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_cast_result, &missing_cast_result_output, .kernel, "c_float_cast_operand_type.mc", .{}, false, null));

    var stale_cast_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_cast_result.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale_cast_result, "cast_float", .expression_result, cast_offset, "value as f32".len, "u32");
    var stale_cast_result_output: std.ArrayList(u8) = .empty;
    defer stale_cast_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_cast_result, &stale_cast_result_output, .kernel, "c_float_cast_operand_type.mc", .{}, false, null));
}

test "lower-c inferred local binary expressions require MIR types" {
    const source =
        \\fn binary(base: u64, limit: u64, left: bool, right: bool) -> u64 {
        \\    let sum = base + 1;
        \\    let is_less = base < limit;
        \\    let both = left && right;
        \\    if is_less && both { return sum; }
        \\    return base;
        \\}
        \\fn bitwise(value: u32) -> u32 {
        \\    let combined = value & 7;
        \\    let shifted = combined << 1;
        \\    return combined | shifted;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_binary_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_binary_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint64_t sum") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "bool is_less") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "bool both") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t combined") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t shifted") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "binary", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_binary_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "binary", .inferred_local, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_binary_types.mc", .{}, false, null));

    var missing_bitwise = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_bitwise.deinit();
    try removeTargetTypeKindForFunction(&missing_bitwise, "bitwise", .inferred_local);
    var missing_bitwise_output: std.ArrayList(u8) = .empty;
    defer missing_bitwise_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_bitwise, &missing_bitwise_output, .kernel, "c_inferred_local_binary_types.mc", .{}, false, null));

    var stale_bitwise = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_bitwise.deinit();
    try renameTargetTypeFactForFunction(&stale_bitwise, "bitwise", .inferred_local, "u64");
    var stale_bitwise_output: std.ArrayList(u8) = .empty;
    defer stale_bitwise_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_bitwise, &stale_bitwise_output, .kernel, "c_inferred_local_binary_types.mc", .{}, false, null));
}

test "lower-c inferred local literals require MIR types" {
    const source =
        \\fn literals() -> u32 {
        \\    let count = 7;
        \\    let enabled = true;
        \\    if enabled { return count; }
        \\    return 0;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_literal_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_literal_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t count") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "bool enabled") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "literals", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_literal_types.mc", .{}, false, null));

    var missing_literal_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_literal_result.deinit();
    try removeTargetTypeKindForFunction(&missing_literal_result, "literals", .expression_result);
    var missing_literal_result_output: std.ArrayList(u8) = .empty;
    defer missing_literal_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_literal_result, &missing_literal_result_output, .kernel, "c_inferred_local_literal_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "literals", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_literal_types.mc", .{}, false, null));

    var stale_literal_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_literal_result.deinit();
    try renameTargetTypeFactForFunction(&stale_literal_result, "literals", .expression_result, "u64");
    var stale_literal_result_output: std.ArrayList(u8) = .empty;
    defer stale_literal_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_literal_result, &stale_literal_result_output, .kernel, "c_inferred_local_literal_types.mc", .{}, false, null));
}

test "lower-c sequenced comparison literals require MIR result types" {
    const source =
        \\fn wide() -> u64 { return 9; }
        \\fn compare() -> bool { return wide() == 7; }
    ;
    var parsed = try test_support.parseCheckedModule("c_condition_literal_result.mc", source);
    defer parsed.deinit();
    const literal_offset = std.mem.indexOf(u8, source, "7") orelse return error.TestUnexpectedResult;

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_condition_literal_result.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint64_t mc_tmp") != null or
        std.mem.indexOf(u8, complete_output.items, "uint64_t mc_exec_tmp_") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "compare", .expression_result, literal_offset, 1);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_condition_literal_result.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "compare", .expression_result, literal_offset, 1, "bool");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_condition_literal_result.mc", .{}, false, null));
}

test "lower-c sequenced comparison member operands require MIR result types" {
    const source =
        \\struct Holder { value: u64 }
        \\fn compare(holder: Holder) -> bool { return holder.value == 7; }
    ;
    const member_text = "holder.value";
    const member_offset = std.mem.indexOf(u8, source, member_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("c_condition_member_result.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_condition_member_result.mc", .{}, false, null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "compare", .expression_result, member_offset, member_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_condition_member_result.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "compare", .expression_result, member_offset, member_text.len, "bool");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_condition_member_result.mc", .{}, false, null));
}

test "lower-c boolean expressions require MIR result types" {
    const source =
        \\fn compare(left: u32, right: u32) -> bool { return !(left < right); }
    ;
    const comparison_text = "left < right";
    const comparison_offset = std.mem.indexOf(u8, source, comparison_text) orelse return error.TestUnexpectedResult;
    var parsed = try test_support.parseCheckedModule("c_boolean_expression_result.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_boolean_expression_result.mc", .{}, false, null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing, "compare", .expression_result, comparison_offset, comparison_text.len);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_boolean_expression_result.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale, "compare", .expression_result, comparison_offset, comparison_text.len, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_boolean_expression_result.mc", .{}, false, null));
}

test "lower-c inferred local unary expressions require MIR types" {
    const source =
        \\fn unary(value: i64, enabled: bool) -> i64 {
        \\    let negated = -value;
        \\    let disabled = !enabled;
        \\    if disabled { return negated; }
        \\    return value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_unary_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_unary_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "int64_t negated") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "bool disabled") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "unary", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_unary_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "unary", .inferred_local, "i32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_unary_types.mc", .{}, false, null));
}

test "lower-c inferred local direct calls require MIR types" {
    const source =
        \\extern fn get_pointer() -> *mut u32;
        \\extern fn maybe_pointer() -> ?*mut u32;
        \\fn make_count() -> u64 { return 7; }
        \\fn caller() -> u64 {
        \\    let count = make_count();
        \\    return count;
        \\}
        \\fn external_caller() -> *mut u32 {
        \\    let pointer = get_pointer();
        \\    return pointer;
        \\}
        \\fn nullable_caller() -> ?*mut u32 {
        \\    let pointer = maybe_pointer();
        \\    return pointer;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_call_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_call_types.mc", .{}, false, null);
    const caller_body = try cFunctionBody(complete_output.items, "static uint64_t caller(void)");
    try expectLegacyOrCanonicalReturn(caller_body, "return make_count();", "= make_count(");
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t * pointer = mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "= maybe_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "return mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "mc_trap_InvalidRepresentation()") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "caller", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_call_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .inferred_local, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_call_types.mc", .{}, false, null));

    const caller_offset = std.mem.indexOf(u8, source, "fn caller") orelse return error.TestUnexpectedResult;
    const call_offset = std.mem.indexOfPos(u8, source, caller_offset, "make_count()") orelse return error.TestUnexpectedResult;

    var missing_call_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_call_result.deinit();
    try removeTargetTypeFactAtOffsetForFunction(&missing_call_result, "caller", .expression_result, call_offset, "make_count()".len);
    var missing_call_result_output: std.ArrayList(u8) = .empty;
    defer missing_call_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_call_result, &missing_call_result_output, .kernel, "c_inferred_local_call_types.mc", .{}, false, null));

    var stale_call_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_call_result.deinit();
    try renameTargetTypeFactAtOffsetForFunction(&stale_call_result, "caller", .expression_result, call_offset, "make_count()".len, "u32");
    var stale_call_result_output: std.ArrayList(u8) = .empty;
    defer stale_call_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_call_result, &stale_call_result_output, .kernel, "c_inferred_local_call_types.mc", .{}, false, null));

    var external_stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer external_stale.deinit();
    try renameTargetTypeFactForFunction(&external_stale, "external_caller", .inferred_local, "u64");
    var external_stale_output: std.ArrayList(u8) = .empty;
    defer external_stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &external_stale, &external_stale_output, .kernel, "c_inferred_local_call_types.mc", .{}, false, null));

    var missing_nullable_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_nullable_result.deinit();
    try removeTargetTypeKindForFunction(&missing_nullable_result, "nullable_caller", .direct_call_result);
    var missing_nullable_result_output: std.ArrayList(u8) = .empty;
    defer missing_nullable_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_nullable_result, &missing_nullable_result_output, .kernel, "c_inferred_local_call_types.mc", .{}, false, null));

    var stale_nullable_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_nullable_result.deinit();
    try renameTargetTypeFactForFunction(&stale_nullable_result, "nullable_caller", .direct_call_result, "u64");
    var stale_nullable_result_output: std.ArrayList(u8) = .empty;
    defer stale_nullable_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_nullable_result, &stale_nullable_result_output, .kernel, "c_inferred_local_call_types.mc", .{}, false, null));
}

test "lower-c inferred local array and slice calls require MIR types" {
    const source =
        \\extern fn make_array() -> [2]u32;
        \\extern fn make_slice() -> []const u32;
        \\fn array_caller() -> u32 {
        \\    let values = make_array();
        \\    return values[0];
        \\}
        \\fn slice_caller() -> u32 {
        \\    let values = make_slice();
        \\    return values[0];
        \\}
        \\fn direct_slice_index() -> u32 {
        \\    return make_slice()[0];
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_array_slice_call_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null);
    const array_caller = try cFunctionBody(complete_output.items, "static uint32_t array_caller(void)");
    try std.testing.expect(isCanonicalExecutableCBody(array_caller));
    try expectContains(array_caller, "make_array(");
    const slice_caller = try cFunctionBody(complete_output.items, "static uint32_t slice_caller(void)");
    try std.testing.expect(isCanonicalExecutableCBody(slice_caller));
    try expectContains(slice_caller, "make_slice(");
    try expectContains(slice_caller, "values = ");
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "direct_slice_index") != null);

    var missing_array = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_array.deinit();
    try removeTargetTypeKindForFunction(&missing_array, "array_caller", .inferred_local);
    var missing_array_output: std.ArrayList(u8) = .empty;
    defer missing_array_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_array, &missing_array_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));

    var missing_array_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_array_result.deinit();
    try removeTargetTypeKindForFunction(&missing_array_result, "array_caller", .direct_call_result);
    var missing_array_result_output: std.ArrayList(u8) = .empty;
    defer missing_array_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_array_result, &missing_array_result_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));

    var stale_array = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_array.deinit();
    try renameTargetTypeFactForFunction(&stale_array, "array_caller", .inferred_local, "u64");
    var stale_array_output: std.ArrayList(u8) = .empty;
    defer stale_array_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_array, &stale_array_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));

    var stale_array_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_array_result.deinit();
    try renameTargetTypeFactForFunction(&stale_array_result, "array_caller", .direct_call_result, "u64");
    var stale_array_result_output: std.ArrayList(u8) = .empty;
    defer stale_array_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_array_result, &stale_array_result_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));

    var missing_slice_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_slice_result.deinit();
    try removeTargetTypeKindForFunction(&missing_slice_result, "slice_caller", .direct_call_result);
    var missing_slice_result_output: std.ArrayList(u8) = .empty;
    defer missing_slice_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_slice_result, &missing_slice_result_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));

    var stale_slice = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_slice.deinit();
    try renameTargetTypeFactForFunction(&stale_slice, "slice_caller", .inferred_local, "u64");
    var stale_slice_output: std.ArrayList(u8) = .empty;
    defer stale_slice_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_slice, &stale_slice_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));

    var stale_slice_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_slice_result.deinit();
    try renameTargetTypeFactForFunction(&stale_slice_result, "slice_caller", .direct_call_result, "u64");
    var stale_slice_result_output: std.ArrayList(u8) = .empty;
    defer stale_slice_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_slice_result, &stale_slice_result_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));

    var missing_direct_slice_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_direct_slice_result.deinit();
    try removeTargetTypeKindForFunction(&missing_direct_slice_result, "direct_slice_index", .direct_call_result);
    var missing_direct_slice_result_output: std.ArrayList(u8) = .empty;
    defer missing_direct_slice_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_direct_slice_result, &missing_direct_slice_result_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));

    var stale_direct_slice_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_direct_slice_result.deinit();
    try renameTargetTypeFactForFunction(&stale_direct_slice_result, "direct_slice_index", .direct_call_result, "u64");
    var stale_direct_slice_result_output: std.ArrayList(u8) = .empty;
    defer stale_direct_slice_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_direct_slice_result, &stale_direct_slice_result_output, .kernel, "c_inferred_local_array_slice_call_types.mc", .{}, false, null));
}

test "lower-c inferred local enum and tagged-union calls require MIR types" {
    const source =
        \\enum Mode { read, write }
        \\union Token { number: i64, eof }
        \\fn make_mode() -> Mode { return Mode.write; }
        \\fn make_token() -> Token { return Token.number(7); }
        \\fn enum_caller() -> Mode {
        \\    let mode = make_mode();
        \\    return mode;
        \\}
        \\fn union_caller() -> Token {
        \\    let token = make_token();
        \\    return token;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_enum_union_call_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_enum_union_call_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "make_mode()") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "make_token()") != null);

    var missing_enum_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_enum_result.deinit();
    try removeTargetTypeKindForFunction(&missing_enum_result, "enum_caller", .direct_call_result);
    var missing_enum_result_output: std.ArrayList(u8) = .empty;
    defer missing_enum_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_enum_result, &missing_enum_result_output, .kernel, "c_inferred_local_enum_union_call_types.mc", .{}, false, null));

    var stale_enum_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_enum_result.deinit();
    try renameTargetTypeFactForFunction(&stale_enum_result, "enum_caller", .direct_call_result, "u64");
    var stale_enum_result_output: std.ArrayList(u8) = .empty;
    defer stale_enum_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_enum_result, &stale_enum_result_output, .kernel, "c_inferred_local_enum_union_call_types.mc", .{}, false, null));

    var missing_union_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_union_result.deinit();
    try removeTargetTypeKindForFunction(&missing_union_result, "union_caller", .direct_call_result);
    var missing_union_result_output: std.ArrayList(u8) = .empty;
    defer missing_union_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_union_result, &missing_union_result_output, .kernel, "c_inferred_local_enum_union_call_types.mc", .{}, false, null));

    var stale_union_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_union_result.deinit();
    try renameTargetTypeFactForFunction(&stale_union_result, "union_caller", .direct_call_result, "u64");
    var stale_union_result_output: std.ArrayList(u8) = .empty;
    defer stale_union_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_union_result, &stale_union_result_output, .kernel, "c_inferred_local_enum_union_call_types.mc", .{}, false, null));
}

test "lower-c inferred local Result direct calls require MIR types" {
    const source =
        \\enum Error: u8 { failed = 1 }
        \\extern fn make_result() -> Result<u32, Error>;
        \\fn caller() -> bool {
        \\    let result = make_result();
        \\    switch result {
        \\        ok(v) => { return v != 0; },
        \\        err(e) => { return e != 0; },
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_result_call_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_result_call_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "= make_result();") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "mc_result_u32_Error result = mc_exec_tmp_") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "caller", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_result_call_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_result_call_types.mc", .{}, false, null));
}

test "lower-c inferred local indirect calls require MIR types" {
    const source =
        \\fn caller(callback: fn(u32) -> u32, value: u32) -> u32 {
        \\    let result = callback(value);
        \\    return result;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_indirect_call_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_indirect_call_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t result") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "caller", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_indirect_call_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_indirect_call_types.mc", .{}, false, null));
}

test "lower-c inferred local atomic and MaybeUninit calls require MIR types" {
    const source =
        \\struct Node { value: u32 }
        \\
        \\fn atomic_inferred_locals() -> u32 {
        \\    var counter: atomic<u32> = atomic.init(1);
        \\    let previous = counter.fetch_add(3, .acq_rel);
        \\    let loaded = counter.load(.acquire);
        \\    return previous + loaded;
        \\}
        \\
        \\fn maybe_uninit_inferred_local() -> u32 {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    slot.write(.{ .value = 7 });
        \\    let value = slot.assume_init();
        \\    return value.value;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_builtin_inferred_local_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_builtin_inferred_local_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t previous") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t loaded") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "Node value") != null);

    for ([_][]const u8{ "atomic_inferred_locals", "maybe_uninit_inferred_local" }) |name| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, name, .inferred_local);
        var missing_output: std.ArrayList(u8) = .empty;
        defer missing_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_builtin_inferred_local_types.mc", .{}, false, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .inferred_local, "u64");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_builtin_inferred_local_types.mc", .{}, false, null));
    }
}

test "lower-c inferred local phys calls require MIR types" {
    const source =
        \\fn inferred_phys(value: usize) -> PAddr {
        \\    let address = phys(value);
        \\    return address;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_phys_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_phys_local_type.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uintptr_t address = mc_exec_tmp_1") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_phys", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_phys_local_type.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_phys", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_phys_local_type.mc", .{}, false, null));
}

test "lower-c inferred local bitcast calls require MIR types" {
    const source =
        \\fn inferred_bitcast(value: f32) -> u32 {
        \\    let bits = bitcast<u32>(value);
        \\    return bits;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_bitcast_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_bitcast_local_type.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t bits") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_bitcast", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_bitcast_local_type.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_bitcast", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_bitcast_local_type.mc", .{}, false, null));
}

test "lower-c inferred local byte-view calls require MIR types" {
    const source =
        \\fn inferred_byte_view(value: u32) -> u8 {
        \\    var storage: u32 = value;
        \\    let bytes = mem.as_bytes(&storage);
        \\    return bytes[0];
        \\}
        \\
        \\fn inferred_byte_equal(left: []const u8, right: []const u8) -> bool {
        \\    let equal = mem.bytes_equal(left, right);
        \\    return equal;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_byte_view_local_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_byte_view_local_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "((mc_slice_const_u8){") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "__builtin_memcmp") != null);

    for ([_][]const u8{ "inferred_byte_view", "inferred_byte_equal" }) |name| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, name, .inferred_local);
        var missing_output: std.ArrayList(u8) = .empty;
        defer missing_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_byte_view_local_types.mc", .{}, false, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .inferred_local, "u64");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_byte_view_local_types.mc", .{}, false, null));
    }
}

test "lower-c inferred local enum raw calls require MIR types" {
    const source =
        \\enum Color: u32 { red = 1 }
        \\fn inferred_enum_raw(value: Color) -> u32 {
        \\    let raw = value.raw();
        \\    return raw;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_enum_raw_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_enum_raw_local_type.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t raw") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_enum_raw", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_enum_raw_local_type.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_enum_raw", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_enum_raw_local_type.mc", .{}, false, null));
}

test "lower-c inferred local conversion calls require MIR types" {
    const source =
        \\fn inferred_conversion(value: u64) -> u8 {
        \\    let narrowed = u8.trap_from(value);
        \\    return narrowed;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_conversion_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_conversion_local_type.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint8_t narrowed") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_conversion", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_conversion_local_type.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_conversion", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_conversion_local_type.mc", .{}, false, null));
}

test "lower-c inferred local reflection calls require MIR types" {
    const source =
        \\fn inferred_reflection() -> usize {
        \\    let size = size_of<u32>();
        \\    return size;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_reflection_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_reflection_local_type.mc", .{}, false, null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_reflection", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_reflection_local_type.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_reflection", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_reflection_local_type.mc", .{}, false, null));
}

test "lower-c inferred local semantic escape calls require MIR types" {
    const source =
        \\fn inferred_noalias(pointer: *mut u8, len: usize) -> *mut u8 {
        \\    #[unsafe_contract(noalias)]
        \\    {
        \\        let alias = compiler.assume_noalias_unchecked(pointer, len);
        \\        return alias;
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_semantic_escape_local_type.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_semantic_escape_local_type.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint8_t * alias") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "inferred_noalias", .inferred_local);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_semantic_escape_local_type.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "inferred_noalias", .inferred_local, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_semantic_escape_local_type.mc", .{}, false, null));
}

test "lower-c inferred local raw result calls require MIR types" {
    const source =
        \\fn inferred_raw_load(addr: PAddr) -> u32 {
        \\    unsafe {
        \\        let value = raw.load<u32>(addr);
        \\        return value;
        \\    }
        \\}
        \\
        \\fn inferred_raw_ptr(addr: PAddr) -> *mut u32 {
        \\    unsafe {
        \\        let pointer = raw.ptr<u32>(addr);
        \\        return pointer;
        \\    }
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_raw_local_types.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_raw_local_types.mc", .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "uint32_t value") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "pointer") != null);

    for ([_][]const u8{ "inferred_raw_load", "inferred_raw_ptr" }) |name| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, name, .inferred_local);
        var missing_output: std.ArrayList(u8) = .empty;
        defer missing_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_raw_local_types.mc", .{}, false, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .inferred_local, "u64");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_raw_local_types.mc", .{}, false, null));
    }
}

// DIAGNOSTIC_UNIT: E_EXPERIMENTAL_DYN_CODEGEN
test "lower-c rejects experimental dynamic trait dispatch at codegen admission" {
    const source =
        \\trait Shape { fn scale(self: *Self, amount: u32) -> u32; fn set(self: *mut Self, value: u32) -> void; }
        \\struct Square { side: u32 }
        \\struct Holder { shape: *mut dyn Shape }
        \\impl Shape for Square { fn scale(self: *Square, amount: u32) -> u32 { return self.side * amount; } fn set(self: *mut Square, value: u32) -> void { self.side = value; } }
        \\fn caller(shape: *dyn Shape, amount: u32) -> u32 {
        \\    let result = shape.scale(amount);
        \\    return result;
        \\}
        \\fn notify(shape: *mut dyn Shape, value: u32) -> void { shape.set(value); }
        \\fn holder_init(holder: *mut Holder, shape: *mut dyn Shape) -> void { holder.shape = shape; }
        \\fn holder_scale(holder: *mut Holder, amount: u32) -> u32 { return holder.shape.scale(amount); }
    ;
    var parsed = try test_support.parseCheckedModule("c_inferred_local_dyn_dispatch_call_types.mc", source);
    defer parsed.deinit();

    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "c_inferred_local_dyn_dispatch_call_types.mc", source);
    defer reporter.deinit();
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_inferred_local_dyn_dispatch_call_types.mc", .{}, false, &reporter));
    try std.testing.expect(reporter.has_errors);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_EXPERIMENTAL_DYN_CODEGEN") != null);

    var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing.deinit();
    try removeTargetTypeKindForFunction(&missing, "caller", .dyn_dispatch_result);
    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &missing_output, .kernel, "c_inferred_local_dyn_dispatch_call_types.mc", .{}, false, null));

    var missing_argument = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_argument.deinit();
    try removeTargetTypeKindForFunction(&missing_argument, "caller", .dyn_dispatch_argument);
    var missing_argument_output: std.ArrayList(u8) = .empty;
    defer missing_argument_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_argument, &missing_argument_output, .kernel, "c_inferred_local_dyn_dispatch_call_types.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .dyn_dispatch_result, "u64");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_inferred_local_dyn_dispatch_call_types.mc", .{}, false, null));

    var stale_argument = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale_argument.deinit();
    try renameTargetTypeFactForFunction(&stale_argument, "caller", .dyn_dispatch_argument, "u64");
    var stale_argument_output: std.ArrayList(u8) = .empty;
    defer stale_argument_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale_argument, &stale_argument_output, .kernel, "c_inferred_local_dyn_dispatch_call_types.mc", .{}, false, null));
}

test "lower-c rejects a global dynamic trait carrier at codegen admission" {
    const source =
        \\trait Shape { fn area(self: *Self) -> u32; }
        \\global selected: *dyn Shape;
        \\fn ordinary(value: u32) -> u32 { return value + 1; }
    ;
    var parsed = try test_support.parseCheckedModule("c_global_dyn_admission.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try std.testing.expect(module_mir.checked_globals[0].dyn_trait_symbol_id.isValid());
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_global_dyn_admission.mc", .{}, false, null));
}

test "lower-c rejects an extern dynamic trait signature at codegen admission" {
    const source =
        \\trait Shape { fn area(self: *Self) -> u32; }
        \\extern fn use(value: *dyn Shape) -> u32;
    ;
    var parsed = try test_support.parseCheckedModule("c_extern_dyn_admission.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const extern_function = for (module_mir.functions) |function| {
        if (std.mem.eql(u8, function.name, "use")) break function;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(!extern_function.executable_body.complete);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_extern_dyn_admission.mc", .{}, false, null));
}

test "lower-c rejects nested extern dynamic trait signature shapes at codegen admission" {
    const source =
        \\trait Shape { fn area(self: *Self) -> u32; }
        \\extern fn use(
        \\    nullable: ?*dyn Shape,
        \\    indirect: *const *dyn Shape,
        \\    result: Result<*dyn Shape, u32>,
        \\    callback: fn(*dyn Shape) -> *dyn Shape,
        \\    closure_value: closure(*dyn Shape) -> *dyn Shape,
        \\) -> ?*dyn Shape;
    ;
    var parsed = try test_support.parseCheckedModule("c_extern_nested_dyn_admission.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_extern_nested_dyn_admission.mc", .{}, false, null));
}

test "lower-c ordinary direct calls require MIR result and argument types" {
    const source =
        \\fn widen(value: u64) -> u64 { return value; }
        \\fn caller(value: u64) -> u64 { return widen(value); }
    ;
    var parsed = try test_support.parseCheckedModule("c_direct_call_type_facts.mc", source);
    defer parsed.deinit();

    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_direct_call_type_facts.mc", source, &complete_output);
    try std.testing.expect(std.mem.indexOf(u8, complete_output.items, "widen(") != null);

    var missing_result = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_result.deinit();
    try removeTargetTypeKindForFunction(&missing_result, "caller", .direct_call_result);
    var missing_result_output: std.ArrayList(u8) = .empty;
    defer missing_result_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_result, &missing_result_output, .kernel, "c_direct_call_type_facts.mc", .{}, false, null));

    var missing_argument = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer missing_argument.deinit();
    try removeTargetTypeKindForFunction(&missing_argument, "caller", .direct_call_argument);
    var missing_argument_output: std.ArrayList(u8) = .empty;
    defer missing_argument_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing_argument, &missing_argument_output, .kernel, "c_direct_call_type_facts.mc", .{}, false, null));

    var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer stale.deinit();
    try renameTargetTypeFactForFunction(&stale, "caller", .direct_call_argument, "u32");
    var stale_output: std.ArrayList(u8) = .empty;
    defer stale_output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_direct_call_type_facts.mc", .{}, false, null));
}

test "lower-c indirect calls require MIR callee signature facts" {
    const source =
        \\fn increment(value: u32) -> u32 { return value + 1; }
        \\fn invoke_pointer(callback: fn(u32) -> u32, value: u32) -> u32 { return callback(value); }
        \\fn invoke_closure(callback: closure(u32) -> u32, value: u32) -> u32 { return callback(value); }
    ;
    var parsed = try test_support.parseCheckedModule("c_indirect_call_signature_facts.mc", source);
    defer parsed.deinit();

    var complete = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer complete.deinit();
    var complete_output: std.ArrayList(u8) = .empty;
    defer complete_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &complete, &complete_output, .kernel, "c_indirect_call_signature_facts.mc", .{}, false, null);
    try expectContains(complete_output.items, "/* canonical executable MIR */");
    try expectContains(complete_output.items, ")(mc_exec_tmp_");

    for ([_][]const u8{ "invoke_pointer", "invoke_closure" }) |name| {
        var missing = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer missing.deinit();
        try removeTargetTypeKindForFunction(&missing, name, .indirect_call_callee);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidMirTargetTypeFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &missing, &output, .kernel, "c_indirect_call_signature_facts.mc", .{}, false, null));

        var stale = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
        defer stale.deinit();
        try renameTargetTypeFactForFunction(&stale, name, .indirect_call_callee, "u32");
        var stale_output: std.ArrayList(u8) = .empty;
        defer stale_output.deinit(std.testing.allocator);
        try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &stale, &stale_output, .kernel, "c_indirect_call_signature_facts.mc", .{}, false, null));
    }
}

test "lower-c rejects prebuilt MIR with missing cpu pause call target facts" {
    const source =
        \\fn cpu_pause_call_target_fact_gate() -> void {
        \\    unsafe { cpu.pause(); }
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_cpu_pause_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "cpu_pause_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_cpu_pause_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with missing fence call target facts" {
    const source =
        \\fn fence_call_target_fact_gate() -> void {
        \\    fence.full();
        \\    fence.release();
        \\    fence.acquire();
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_missing_fence_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearCallTargetFactsForFunction(&module_mir, "fence_call_target_fact_gate");
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirCallTargetFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_missing_fence_call_target_facts.mc", .{}, false, null),
    );
}

test "lower-c rejects prebuilt MIR with stale call target facts" {
    const source =
        \\fn call_target_fact_gate(xs: []const u32) -> Result<u32, Overflow> {
        \\    return reduce.sum_checked<u32>(xs);
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("c_stale_call_target_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetCallTargetFactsForFunction(&module_mir, "call_target_fact_gate", .const_get);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMirCallTargetFacts, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_stale_call_target_facts.mc", .{}, false, null));
}

test "lower-c rejects prebuilt MIR with stale integer facts" {
    const source =
        \\fn integer_fact_gate(other: u16) -> u8 {
        \\    let a: u8 = 7;
        \\    return a;
        \\}
    ;

    var parsed = try test_support.parseCheckedModule("c_stale_integer_facts.mc", source);
    defer parsed.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetIntegerFactsForFunction(&module_mir, "integer_fact_gate", .{ .integer = "u16" });
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirIntegerFacts,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_stale_integer_facts.mc", .{}, false, null),
    );
}

fn appendCheckedCTestWithRetargetedRangeFacts(source_name: []const u8, source: []const u8, function_name: []const u8, target: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try retargetRangeFactsForFunction(&module_mir, function_name, target);

    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, .kernel, source_name, .{}, false, null);
}

fn appendCheckedCTestWithoutPointerProvenanceFactsForSubject(source_name: []const u8, source: []const u8, function_name: []const u8, subject: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearPointerProvenanceFactsForFunctionSubject(&module_mir, function_name, subject);

    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, .kernel, source_name, .{}, false, null);
}

fn appendCheckedCTestWithoutPointerProvenanceFactsForSubjectField(source_name: []const u8, source: []const u8, function_name: []const u8, subject: []const u8, field_path: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearPointerProvenanceFactsForFunctionSubjectField(&module_mir, function_name, subject, field_path);

    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, .kernel, source_name, .{}, false, null);
}

fn appendCheckedCTestWithoutAggregateReturnPointerFact(source_name: []const u8, source: []const u8, callee: []const u8, field_path: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    try clearAggregateReturnPointerFact(&module_mir, callee, field_path);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, output, .kernel, source_name, .{}, false, null);
}

fn expectUnsupportedCheckedCEmission(source_name: []const u8, source: []const u8) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCDeclsTest(std.testing.allocator, parsed.decls(), &output));
}

fn expectUnsupportedCheckedCEmissionDiagnostic(source_name: []const u8, source: []const u8, expected_construct: []const u8) !void {
    var parsed = try test_support.parseCheckedModule(source_name, source);
    defer parsed.deinit();

    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{});
    defer module_mir.deinit();
    var reporter = diagnostics.Reporter.init(std.testing.allocator, source_name, source);
    defer reporter.deinit();
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.UnsupportedCEmission,
        appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, source_name, .{}, false, &reporter),
    );
    try std.testing.expect(reporter.has_errors);
    try std.testing.expectEqual(@as(usize, 1), reporter.diagnostics.items.len);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, "E_BACKEND_UNSUPPORTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, reporter.diagnostics.items[0].message, expected_construct) != null);
}

test "lower-c consumes MIR aggregate-return pointer facts and fails closed when absent" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_aggregate_return_pointer_fact.mc", source, &output);
    try expectContains(output.items, "/* canonical executable MIR */");
    try expectContains(output.items, "mc_race_load_u32");

    var missing_output: std.ArrayList(u8) = .empty;
    defer missing_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutAggregateReturnPointerFact("c_aggregate_return_mir_fact.mc", source, "returned_holder", "ptr", &missing_output);
    try expectNotContains(missing_output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    try expectContains(missing_output.items, "mc_race_load_u32");
}

test "lower-c lowers pointer parameter field stores after specialized plan retirement" {
    const source =
        \\struct Cell { value: u32 }
        \\struct Frame { child: Cell, slots: [4]u32 }
        \\fn make_cell(value: u32) -> Cell { return .{ .value = value }; }
        \\fn store_cell(cell: *mut Cell) -> void {
        \\    cell.*.value = 7;
        \\}
        \\fn store_child(frame: *mut Frame, value: u32) -> void {
        \\    frame.*.child = make_cell(value);
        \\}
        \\fn load_child(frame: *mut Frame) -> Cell {
        \\    return frame.*.child;
        \\}
        \\fn load_slot(frame: *mut Frame, index: usize) -> u32 {
        \\    return frame.*.slots[index];
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_pointer_param_field_store.mc", source, &output);
    const body = try cFunctionBody(output.items, "static void store_cell(Cell * cell)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "mc_race_store_u32(&(cell->value), (uint32_t)mc_exec_tmp_");
    const aggregate_body = try cFunctionBody(output.items, "static void store_child(Frame * frame, uint32_t value)");
    try expectContains(aggregate_body, "/* canonical executable MIR */");
    try expectContains(aggregate_body, "mc_race_store_u32");
    const load_body = try cFunctionBody(output.items, "static Cell load_child(Frame * frame)");
    try expectContains(load_body, "/* canonical executable MIR */");
    try expectContains(load_body, "mc_race_load_u32");
    const indexed_load_body = try cFunctionBody(output.items, "static uint32_t load_slot(Frame * frame, uintptr_t index)");
    try expectContains(indexed_load_body, "/* canonical executable MIR */");
    try expectContains(indexed_load_body, "mc_check_index_usize(");
    try expectContains(indexed_load_body, "mc_race_load_u32");
}

test "lower-c emits global address direct-call args from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn consume_ptr(ptr: *mut u32) -> u32 {
        \\    return 7;
        \\}
        \\
        \\fn use_global_address_arg() -> u32 {
        \\    return consume_ptr(&shared_counter);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_global_address_call_arg.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint32_t use_global_address_arg(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectNeedlesInOrder(body, &.{ "= &shared_counter;", "= consume_ptr(", "return mc_exec_tmp_" });
}

test "lower-c emits global address returns from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn returned_global_pointer() -> *mut u32 {
        \\    return & shared_counter;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_global_address_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint32_t * returned_global_pointer(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectNeedlesInOrder(body, &.{ "= &shared_counter;", "return mc_exec_tmp_" });
}

test "lower-c emits local global address returns from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn local_global_pointer() -> *mut u32 {
        \\    let gp: *mut u32 = &shared_counter;
        \\    return gp;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_local_global_address_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint32_t * local_global_pointer(void)");
    try expectNeedlesInOrder(body, &.{
        "= &shared_counter;",
        "uint32_t * gp = mc_exec_tmp_",
        "if (mc_exec_tmp_",
        "return mc_exec_tmp_",
    });
}

test "lower-c emits conditional global address returns from MIR without body fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn branched_global_pointer(flag: bool) -> *mut u32 {
        \\    if flag { return &shared_counter; } else { return &shared_counter; }
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_conditional_global_address_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint32_t * branched_global_pointer(bool flag)");
    try expectCanonicalConditional(body);
    try expectContains(body, "= &shared_counter;");
    try expectContains(body, "return mc_exec_tmp_");
}

test "lower-c aggregate-return mixed branches fail closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(flag: bool, fallback: *mut u32) -> Holder {
        \\    if flag { return .{ .ptr = &shared_counter, .tag = 1 }; } else { return .{ .ptr = fallback, .tag = 2 }; }
        \\}
        \\
        \\fn use_returned_holder(flag: bool) -> u32 {
        \\    var local: u32 = 3;
        \\    let holder: Holder = returned_holder(flag, &local);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_mixed_branch_aggregate_return_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder field=ptr");
    const body = try cFunctionBody(output.items, "static uint32_t use_returned_holder(bool flag)");
    try expectContains(body, "mc_race_load_u32");
}

test "lower-c aggregate-return nested call control fails closed" {
    const source =
        \\global shared_counter: u32 = 0;
        \\extern fn invalidate() -> void;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder(choice: u32) -> Holder {
        \\    switch choice {
        \\        0 => {
        \\            invalidate();
        \\            return .{ .ptr = &shared_counter, .tag = 1 };
        \\        }
        \\        _ => {}
        \\    }
        \\    return .{ .ptr = &shared_counter, .tag = 2 };
        \\}
        \\
        \\fn use_returned_holder(choice: u32) -> u32 {
        \\    let holder: Holder = returned_holder(choice);
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_nested_call_control_aggregate_return_fail_closed.mc", source, &output);
    try expectNotContains(output.items, "/* mir aggregate_return_pointer consumed caller=use_returned_holder callee=returned_holder");
    try expectContains(output.items, "mc_race_load_u32");
}

test "lower-c rejects ordinary defer expression cleanup fallback" {
    const source =
        \\global shared_counter: u32 = 0;
        \\struct Holder { ptr: *mut u32, tag: u32 }
        \\
        \\fn returned_holder() -> Holder {
        \\    let cleanup_value: u32 = 0;
        \\    defer cleanup_value;
        \\    return .{ .ptr = &shared_counter, .tag = 1 };
        \\}
        \\
        \\fn use_returned_holder() -> u32 {
        \\    let holder: Holder = returned_holder();
        \\    return holder.ptr.*;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try expectUnsupportedCEmission("c_ordinary_defer_expression_cleanup_fallback.mc", source, &output);
}

fn expectTaggedUnionRaceCopySupported(source_name: []const u8, source: []const u8) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest(source_name, source, &output);
    try expectContains(output.items, "__atomic_");
    try expectContains(output.items, "TokenTag_number");
}

fn expectUnsupportedCEmission(source_name: []const u8, source: []const u8, output: *std.ArrayList(u8)) !void {
    var parsed = try test_support.parseModule(source_name, source);
    defer parsed.deinit();

    try std.testing.expectError(error.UnsupportedCEmission, appendCDeclsTest(std.testing.allocator, parsed.decls(), output));
}

fn hasTestDiagnosticCode(reporter: diagnostics.Reporter, code: []const u8) bool {
    for (reporter.diagnostics.items) |diag| {
        if (std.mem.startsWith(u8, diag.message, code) and diag.message.len > code.len and diag.message[code.len] == ':') return true;
    }
    return false;
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectCNoOverflowFactRejection(result: anytype) !void {
    if (result) |_| return error.TestExpectedError else |err| switch (err) {
        error.InvalidMirExecutableBody, error.UnsupportedCEmission => {},
        else => return err,
    }
}

fn expectCNoOverflowLegacyRetarget(result: anytype) !void {
    if (result) |_| return else |err| switch (err) {
        error.InvalidMirRangeFacts, error.UnsupportedCEmission => {},
        else => return err,
    }
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn isCanonicalExecutableCBody(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "/* canonical executable MIR */") != null;
}

fn expectLegacyOrCanonicalReturn(body: []const u8, legacy_return: []const u8, canonical_operation: []const u8) !void {
    if (isCanonicalExecutableCBody(body)) {
        try expectContains(body, canonical_operation);
        try expectContains(body, "return mc_exec_tmp_");
    } else {
        try expectContains(body, legacy_return);
    }
}

fn expectLegacyOrCanonicalLoop(body: []const u8, legacy_condition: []const u8) !void {
    if (isCanonicalExecutableCBody(body)) {
        try expectContains(body, "if (mc_exec_tmp_");
        try expectContains(body, "goto mc_bb_");
    } else {
        try expectContains(body, legacy_condition);
    }
}

fn expectCanonicalConditional(body: []const u8) !void {
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "if (mc_exec_tmp_");
    try expectContains(body, "goto mc_bb_");
}

fn commentSourceText(output: []const u8, comment_prefix: []const u8) ![]const u8 {
    const comment_start = std.mem.indexOf(u8, output, comment_prefix) orelse return error.TestExpectedEqual;
    const source_start = std.mem.indexOfPos(u8, output, comment_start, "source=") orelse return error.TestExpectedEqual;
    const line_start = source_start + "source=".len;
    const source_end = std.mem.indexOfPos(u8, output, line_start, " ") orelse return error.TestExpectedEqual;
    return output[line_start..source_end];
}

fn expectCCommentSourceMatchesMirFact(c_output: []const u8, mir_dump: []const u8, comment_prefix: []const u8, mir_prefix: []const u8) !void {
    const source = try commentSourceText(c_output, comment_prefix);
    const colon = std.mem.indexOf(u8, source, ":") orelse return error.TestExpectedEqual;
    const line = try std.fmt.parseUnsigned(usize, source[0..colon], 10);
    const column = try std.fmt.parseUnsigned(usize, source[colon + 1 ..], 10);
    const mir_start = std.mem.indexOf(u8, mir_dump, mir_prefix) orelse return error.TestExpectedEqual;
    const mir_end = std.mem.indexOfPos(u8, mir_dump, mir_start, "\n") orelse mir_dump.len;
    const mir_row = mir_dump[mir_start..mir_end];
    const expected_source = try std.fmt.allocPrint(std.testing.allocator, "line={d} column={d}", .{ line, column });
    defer std.testing.allocator.free(expected_source);
    try expectContains(mir_row, expected_source);
}

fn cFunctionBody(output: []const u8, signature_prefix: []const u8) ![]const u8 {
    var search_from: usize = 0;
    const start = while (std.mem.indexOfPos(u8, output, search_from, signature_prefix)) |candidate| {
        const semicolon = std.mem.indexOfPos(u8, output, candidate, ";\n") orelse output.len;
        const brace = std.mem.indexOfPos(u8, output, candidate, "{\n") orelse return error.TestExpectedEqual;
        if (brace < semicolon) break candidate;
        search_from = candidate + signature_prefix.len;
    } else return error.TestExpectedEqual;
    const body_start = std.mem.indexOfPos(u8, output, start, "{\n") orelse return error.TestExpectedEqual;
    const body_end = std.mem.indexOfPos(u8, output, body_start, "\n}\n\n") orelse return error.TestExpectedEqual;
    const content_start = body_start + 2;
    if (body_end < content_start) return output[body_end..body_end];
    return output[content_start..body_end];
}

fn expectNeedlesInOrder(haystack: []const u8, needles: []const []const u8) !void {
    var search_from: usize = 0;
    for (needles) |needle| {
        const found = std.mem.indexOfPos(u8, haystack, search_from, needle) orelse return error.TestUnexpectedResult;
        search_from = found + needle.len;
    }
}

test "C bitcast query accepts only the real builtin call shape" {
    const source =
        \\fn probe(x: u32) -> u32 {
        \\    return (bitcast<u32>(x))(x);
        \\}
        \\fn missing_value() -> u32 {
        \\    return bitcast<u32>();
        \\}
        \\fn missing_type(x: u32) -> u32 {
        \\    return bitcast(x);
        \\}
        \\fn valid(x: u32) -> u32 {
        \\    return bitcast<u32>(x);
        \\}
    ;

    var parsed = try test_support.parseModule("c_bitcast_grouped_call_callee.mc", source);
    defer parsed.deinit();

    const probe_fn = parsed.decls()[0].kind.fn_decl;
    const probe_ret = probe_fn.body.?.items[0].kind.@"return".?;
    const outer_call = probe_ret.kind.call;
    try std.testing.expect(!lower_c_expr.isBitcastCall(outer_call));

    const grouped_callee = outer_call.callee.*.kind.grouped;
    const inner_call = grouped_callee.kind.call;
    try std.testing.expect(lower_c_expr.isBitcastCall(inner_call));

    const missing_value_fn = parsed.decls()[1].kind.fn_decl;
    const missing_value_ret = missing_value_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(!lower_c_expr.isBitcastCall(missing_value_ret.kind.call));

    const missing_type_fn = parsed.decls()[2].kind.fn_decl;
    const missing_type_ret = missing_type_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(!lower_c_expr.isBitcastCall(missing_type_ret.kind.call));

    const valid_fn = parsed.decls()[3].kind.fn_decl;
    const valid_ret = valid_fn.body.?.items[0].kind.@"return".?;
    try std.testing.expect(lower_c_expr.isBitcastCall(valid_ret.kind.call));
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
    try lower_c.appendInspectionFromDecls(std.testing.allocator, module.decls, &output);

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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

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
    for (lower_c_shape.race_scalar_helpers) |helper| {
        const definition = try std.fmt.allocPrint(std.testing.allocator, "MC_DEFINE_RACE_SCALAR({s}, {s})", .{ helper.name, helper.c_type });
        defer std.testing.allocator.free(definition);
        try std.testing.expect(std.mem.indexOf(u8, output.items, definition) != null);
    }
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

test "lower-c context-types minimum signed integer unary literals" {
    const source =
        \\fn direct() -> i32 {
        \\    let value: i32 = -2147483648;
        \\    return value;
        \\}
        \\
        \\fn grouped() -> i32 {
        \\    let value: i32 = -(2147483648);
        \\    return value;
        \\}
        \\
        \\fn dynamic(value: i32) -> i32 {
        \\    return -value;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_min_signed_unary_literal.mc", source, &output);

    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "2147483648"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= -2147483648;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_neg_i32(") != null);
}

test "lower-c emits cstr as immutable C string pointer" {
    const source =
        \\extern "C" fn strlen(s: cstr) -> usize;
        \\extern "C" fn identity(s: cstr) -> cstr;
        \\global global_cstr: cstr = "global";
        \\global copied_cstr: cstr = global_cstr;
        \\
        \\export fn use_cstr() -> usize {
        \\    let s: cstr = "abc";
        \\    return strlen(s);
        \\}
        \\
        \\export fn return_cstr() -> cstr {
        \\    return identity("xyz");
        \\}
        \\fn return_bytes() -> []const u8 { return "bytes"; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("cstr_c.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uintptr_t strlen(char const * s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * identity(char const * s);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "global_cstr = ((char const *)\"global\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "copied_cstr = ((char const *)\"global\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * s = mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_InvalidRepresentation();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * return_cstr(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "char const * mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = ((char const *)\"xyz\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " = identity(mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".len = 5") != null);
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
    try appendCProfileWithSourcePathDeclsTest(std.testing.allocator, parsed.decls(), &rebuilt_output, .kernel, "c_prebuilt_mir.mc", .{ .optimize = true }, false);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "c_prebuilt_mir.mc", source);
    defer reporter.deinit();
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, parsed.decls(), .{ .optimize = true });
    defer module_mir.deinit();
    try mir.verifyBuiltMir(module_mir, &reporter);
    try std.testing.expect(!reporter.has_errors);

    var prebuilt_output: std.ArrayList(u8) = .empty;
    defer prebuilt_output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &prebuilt_output, .kernel, "c_prebuilt_mir.mc", .{ .optimize = true }, false, &reporter);

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
    try appendCProfileWithSourcePathDeclsTest(std.testing.allocator, module.decls, &output, .kernel, "debug\"map\\case.mc", .{}, false);

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
    try appendCSourceMapDeclsTest(std.testing.allocator, module.decls, &output, .kernel, "debug_map.mc", "debug_map.c");

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

test "lower-c prefers canonical executable MIR for direct and local checked arithmetic" {
    // A direct `return <checked op of simple operands>` folds no source construct,
    // so the MIR fast path loses no source-map fidelity and is admitted even when a
    // body fallback is available (fallback available = normal emit). A `let`-folding
    // body keeps its per-construct source map by staying on the fallback (emitted as
    // a temp before the return), so it must NOT take the inline fast-path form.
    const source =
        \\fn sub_params(a: u32, b: u32) -> u32 { return b - a; }
        \\fn folded(a: u32) -> u32 { let y: u32 = a + 1; return y; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "arith.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const direct = try cFunctionBody(output.items, "static uint32_t sub_params(uint32_t a, uint32_t b)");
    try expectContains(direct, "mc_checked_sub_u32(");
    try expectContains(direct, "return mc_exec_tmp_");
    const folded = try cFunctionBody(output.items, "static uint32_t folded(uint32_t a)");
    try expectContains(folded, "mc_checked_add_u32(");
    try expectContains(folded, "uint32_t y = mc_exec_tmp_");
}

test "lower-c canonical executable MIR models explicit uninit as storage without a value" {
    const source =
        \\fn explicit_uninit(value: u32) -> u32 {
        \\    var x: u32 = uninit;
        \\    x = value;
        \\    return x;
        \\}
        \\fn grouped_uninit(value: u32) -> u32 {
        \\    var x: u32 = (uninit);
        \\    x = value;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_executable_uninit_local.mc", source, &output);

    for ([_][]const u8{
        "static uint32_t explicit_uninit(uint32_t value)",
        "static uint32_t grouped_uninit(uint32_t value)",
    }) |signature| {
        const body = try cFunctionBody(output.items, signature);
        try expectContains(body, "/* canonical executable MIR */");
        try expectContains(body, "uint32_t x;");
        try expectContains(body, "x = mc_exec_tmp_");
        try expectContains(body, "return mc_exec_tmp_");
        try std.testing.expect(std.mem.indexOf(u8, body, " = uninit") == null);
    }
}

test "lower-c lowers pointer param representation checks through canonical MIR" {
    // A value-preserving MIR wrapper owns the nonnull check. It applies in a
    // direct return and in a local initializer without backend AST inference.
    const source =
        \\fn ret_ptr(p: *mut u32) -> *mut u32 { return p; }
        \\fn folded(p: *mut u32) -> *mut u32 { let q: *mut u32 = p; return q; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "ptr.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    try expectContains(output.items, "/* canonical executable MIR */");
    try expectContains(output.items, "if (mc_exec_tmp_");
    try expectContains(output.items, "uint32_t * q = mc_exec_tmp_");
    try expectContains(output.items, "return mc_exec_tmp_");
}

test "lower-c applies pointer return coercions through canonical MIR" {
    const source =
        \\fn promote(p: *mut u32) -> ?*mut u32 { return p; }
        \\fn narrow(p: *mut u32) -> *const u32 { return p; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "pointer_return_coercions.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    for ([_][]const u8{
        "static uint32_t * promote(uint32_t * p)",
        "static uint32_t const * narrow(uint32_t * p)",
    }) |signature| {
        const body = try cFunctionBody(output.items, signature);
        try expectContains(body, "/* canonical executable MIR */");
        const guard = std.mem.indexOf(u8, body, "== NULL") orelse return error.TestUnexpectedResult;
        const returned = std.mem.indexOf(u8, body, "return mc_exec_tmp_") orelse return error.TestUnexpectedResult;
        try std.testing.expect(guard < returned);
    }
}

test "lower-c admits scalar deref returns from MIR; optional-pointee derefs stay on fallback" {
    // `return p.*` for a plain scalar pointee lowers through the race-tolerant
    // load. An optional pointee (`?u32`) needs a tag+value load, so it must NOT
    // take this single-scalar fast path — the MIR return records the payload type
    // `u32` for it too, so admission is gated on the DECLARED return type.
    const source =
        \\fn read_u32(p: *u32) -> u32 { return p.*; }
        \\fn read_opt(p: *mut ?u32) -> ?u32 { return p.*; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "deref.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    // Plain scalar deref is now emitted mechanically from the canonical body:
    // the exact representation edge guards the race-tolerant load, whose
    // value is staged before the return.
    const scalar_body = try cFunctionBody(output.items, "static uint32_t read_u32(uint32_t * p)");
    const scalar_guard = std.mem.indexOf(u8, scalar_body, "if (p == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const scalar_load = std.mem.indexOf(u8, scalar_body, "mc_race_load_u32(p)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(scalar_guard < scalar_load);
    try expectContains(scalar_body, "return mc_exec_tmp_");
    // Optional deref (fallback): loads the tag bool too — never a single scalar load.
    const opt_body = try cFunctionBody(output.items, "static mc_opt_u32 read_opt(mc_opt_u32 * p)");
    try expectContains(opt_body, "mc_race_load_bool");
}

test "lower-c canonical executable scalar parameter deref guards exact representation edge without fallback" {
    const source =
        \\fn read(pointer: *u32) -> u32 { return pointer.*; }
        \\fn identity(pointer: *mut u32) -> *mut u32 { return &pointer.*; }
        \\fn write(pointer: *mut u32, value: u32) -> void { pointer.* = value; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_executable_pointer_deref.mc", source, &output);

    const read = try cFunctionBody(output.items, "static uint32_t read(");
    const read_guard = std.mem.indexOf(u8, read, "if (pointer == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const read_load = std.mem.indexOf(u8, read, "mc_race_load_u32(pointer)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(read_guard < read_load);
    try expectContains(read, "return mc_exec_tmp_");

    const identity = try cFunctionBody(output.items, "static uint32_t * identity(");
    const identity_guard = std.mem.indexOf(u8, identity, "if (pointer == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const identity_value = std.mem.indexOf(u8, identity, "= pointer;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(identity_guard < identity_value);
    try expectNotContains(identity, "&(*");

    const write = try cFunctionBody(output.items, "static void write(");
    const write_value = std.mem.indexOf(u8, write, "= value;") orelse return error.TestUnexpectedResult;
    const write_guard = std.mem.indexOf(u8, write, "if (pointer == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const write_store = std.mem.indexOf(u8, write, "mc_race_store_u32(pointer,") orelse return error.TestUnexpectedResult;
    try std.testing.expect(write_value < write_guard and write_guard < write_store);
}

test "lower-c canonical executable local pointer deref owns its representation edge" {
    const source =
        \\fn write(pointer: *mut u32, value: u32) -> void {
        \\    let local_pointer = pointer;
        \\    local_pointer.* = value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_executable_local_pointer_deref.mc", source, &output);

    const body = try cFunctionBody(output.items, "static void write(");
    try expectContains(body, "/* canonical executable MIR */");
    const local_decl = std.mem.indexOf(u8, body, "uint32_t * local_pointer =") orelse return error.TestUnexpectedResult;
    const guard = std.mem.indexOfPos(u8, body, local_decl, "if (local_pointer == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const store = std.mem.indexOfPos(u8, body, guard, "mc_race_store_u32(local_pointer,") orelse return error.TestUnexpectedResult;
    try std.testing.expect(local_decl < guard and guard < store);
}

test "lower-c admits address-typed scalar deref returns from MIR" {
    // `return p.*` for `*PAddr` loads through the usize representation.
    const source =
        \\fn deref_pa(p: *PAddr) -> PAddr { return p.*; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "dpa.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const body = try cFunctionBody(output.items, "static uintptr_t deref_pa(uintptr_t * p)");
    const guard = std.mem.indexOf(u8, body, "if (p == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const load = std.mem.indexOf(u8, body, "mc_race_load_usize(p)") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < load);
    try expectContains(body, "return mc_exec_tmp_");
}

test "lower-c checks pointer comparison operands from canonical MIR" {
    // Nonnull operands carry explicit representation wrappers. A contextual
    // null literal shares the pointer's structural MIR type, so no backend
    // syntax rule is needed for pointer-vs-null comparison.
    const source =
        \\fn ptr_eq(a: *u32, b: *u32) -> bool { return a == b; }
        \\fn ptr_present(a: *u32) -> bool { return a != null; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "cmp.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    try expectContains(output.items, "/* canonical executable MIR */");
    try expectContains(output.items, "if (mc_exec_tmp_");
    try expectContains(output.items, " == mc_exec_tmp_");
    try expectContains(output.items, "return mc_exec_tmp_");
    const present = try cFunctionBody(output.items, "static bool ptr_present(");
    try expectContains(present, "/* canonical executable MIR */");
    try expectContains(present, "!= mc_exec_tmp_");
    try expectContains(present, "NULL");
}

test "lower-c admits single nested-call argument returns in evaluation order" {
    // Canonical executable MIR stages both call levels by ExprId; the legacy
    // path may still inline this single-argument shape.
    const source =
        \\extern fn f() -> u32;
        \\extern fn h(x: u32) -> u32;
        \\extern fn g(x: u32) -> u32;
        \\fn direct() -> u32 { return g(f()); }
        \\fn np(x: u32) -> u32 { return g(h(x)); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "nest.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const direct = try cFunctionBody(output.items, "static uint32_t direct(void)");
    if (isCanonicalExecutableCBody(direct))
        try expectNeedlesInOrder(direct, &.{ "= f();", "= g(", "return mc_exec_tmp_" })
    else
        try expectContains(direct, "return g(f());");
    const np = try cFunctionBody(output.items, "static uint32_t np(uint32_t x)");
    if (isCanonicalExecutableCBody(np))
        try expectNeedlesInOrder(np, &.{ "= h(", "= g(", "return mc_exec_tmp_" })
    else
        try expectContains(np, "return g(h(x));");
}

test "lower-c admits multi-arg call with one nested call and pure leaves" {
    // The canonical executable body gives every evaluated operand an ExprId,
    // so both the formerly-inline and formerly-fallback shapes are staged in
    // source order without relying on C argument evaluation order.
    const source =
        \\extern fn f() -> u32;
        \\extern fn k() -> u32;
        \\extern fn g2(a: u32, b: u32) -> u32;
        \\fn one_call(b: u32) -> u32 { return g2(f(), b); }
        \\fn one_call_lit() -> u32 { return g2(f(), 4096); }
        \\fn two_calls() -> u32 { return g2(f(), k()); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "mg.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const one_call = try cFunctionBody(output.items, "static uint32_t one_call(uint32_t b)");
    if (std.mem.indexOf(u8, one_call, "return g2(f(), b);") == null)
        try expectNeedlesInOrder(one_call, &.{ "= f();", "= b;", "= g2(" });
    const one_call_lit = try cFunctionBody(output.items, "static uint32_t one_call_lit(void)");
    if (std.mem.indexOf(u8, one_call_lit, "return g2(f(), 4096);") == null)
        try expectNeedlesInOrder(one_call_lit, &.{ "= f();", "= 4096;", "= g2(" });
    const two_calls = try cFunctionBody(output.items, "static uint32_t two_calls(void)");
    if (std.mem.indexOf(u8, two_calls, "return g2(mc_tmp") == null)
        try expectNeedlesInOrder(two_calls, &.{ "= f();", "= k();", "= g2(" });
    try expectNotContains(output.items, "g2(f(), k())");
}

test "lower-c admits unsigned wrap binary returns from typed MIR" {
    // The executable MIR retains the wrapping domain while the C renderer uses
    // the underlying unsigned storage type. Integer promotion is harmless: the
    // assignment back to uint8_t performs the specified modular reduction.
    const source =
        \\fn u_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> { return a + b; }
        \\fn u8_add(a: wrap<u8>, b: wrap<u8>) -> wrap<u8> { return a + b; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "wrap.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const u32_body = try cFunctionBody(output.items, "static uint32_t u_add(uint32_t a, uint32_t b)");
    try expectContains(u32_body, "/* canonical executable MIR */");
    try expectContains(u32_body, " + ");
    const u8_body = try cFunctionBody(output.items, "static uint8_t u8_add(uint8_t a, uint8_t b)");
    try expectContains(u8_body, "/* canonical executable MIR */");
    try expectContains(u8_body, " + ");
}

test "lower-c emits raw-many offset from typed MIR without body fallback" {
    const source =
        \\extern fn next_index() -> usize;
        \\fn offset(pointer: [*]mut u8) -> [*]mut u8 {
        \\    unsafe { return pointer.offset(next_index()); }
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "raw_many_offset_executable.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);
    const body = try cFunctionBody(output.items, "static uint8_t * offset(uint8_t * pointer)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectNeedlesInOrder(body, &.{ "= pointer;", "= next_index();", " + ", "return mc_exec_tmp_" });
}

test "lower-c emits raw scalar load and store from typed MIR without body fallback" {
    const source =
        \\fn load(address: PAddr) -> u32 { unsafe { return raw.load<u32>(address); } }
        \\fn pointer(address: PAddr) -> *mut u32 { unsafe { return raw.ptr<u32>(address); } }
        \\fn store(address: PAddr, value: u32) -> void { unsafe { raw.store<u32>(address, value); } }
        \\fn sync() -> void { fence.release(); fence.acquire(); fence.full(); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "raw_scalar_executable.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var module_mir = try mir.buildOptFromDecls(std.testing.allocator, module.decls, .{});
    defer module_mir.deinit();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, module.decls, &module_mir, &output, .kernel, "raw_scalar_executable.mc", .{}, false, null);
    const load = try cFunctionBody(output.items, "static uint32_t load(uintptr_t address)");
    try expectContains(load, "/* canonical executable MIR */");
    try expectContains(load, "mc_raw_load_u32(");
    const pointer = try cFunctionBody(output.items, "static uint32_t * pointer(uintptr_t address)");
    try expectContains(pointer, "/* canonical executable MIR */");
    try expectNeedlesInOrder(pointer, &.{ "((uint32_t *)((uintptr_t)(mc_exec_tmp_", "== NULL) mc_trap_InvalidRepresentation();", "return mc_exec_tmp_" });
    const store = try cFunctionBody(output.items, "static void store(uintptr_t address, uint32_t value)");
    try expectContains(store, "/* canonical executable MIR */");
    try expectContains(store, "mc_raw_store_u32(");
    const sync = try cFunctionBody(output.items, "static void sync(void)");
    try expectContains(sync, "/* canonical executable MIR */");
    try expectNeedlesInOrder(sync, &.{ "mc_barrier_release_before();", "mc_barrier_acquire_after();", "mc_barrier_full();" });
}

test "lower-c admits plain unsigned bitwise binary returns from MIR (and/or/xor)" {
    const source =
        \\fn u_and(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> { return a & b; }
        \\fn u_or(a: wrap<u64>, b: wrap<u64>) -> wrap<u64> { return a | b; }
        \\fn u_xor(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> { return a ^ b; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "bit.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    for ([_]struct { signature: []const u8, token: []const u8 }{
        .{ .signature = "static uint32_t u_and(uint32_t a, uint32_t b)", .token = " & " },
        .{ .signature = "static uint64_t u_or(uint64_t a, uint64_t b)", .token = " | " },
        .{ .signature = "static uint32_t u_xor(uint32_t a, uint32_t b)", .token = " ^ " },
    }) |case| {
        const body = try cFunctionBody(output.items, case.signature);
        try expectContains(body, "/* canonical executable MIR */");
        try expectContains(body, case.token);
    }
}

test "lower-c admits plain unary returns from MIR (bitwise not, wrapping negate)" {
    // `~a` and wrapping `-a` never trap, so they lower from MIR as `op(operand)`.
    const source =
        \\fn bnot(a: u32) -> u32 { return ~a; }
        \\fn wneg(a: wrap<u32>) -> wrap<u32> { return -a; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_plain_unary.mc", source, &output);

    const bnot = try cFunctionBody(output.items, "static uint32_t bnot(uint32_t a)");
    try expectContains(bnot, "/* canonical executable MIR */");
    try expectContains(bnot, "(~");
    const wneg = try cFunctionBody(output.items, "static uint32_t wneg(uint32_t a)");
    try expectContains(wneg, "/* canonical executable MIR */");
    try expectContains(wneg, "(-");
}

test "lower-c admits scalar pointer-field-load returns from MIR; optional field stays on fallback" {
    // `return r.a` for a scalar field of a pointer param's pointee struct lowers
    // through the race-tolerant load of &(r->a). An optional field needs a
    // tag+value load, so it stays on the fallback.
    const source =
        \\struct S { a: u32 }
        \\fn get_a(r: *S) -> u32 { return r.a; }
        \\struct T { o: ?u32 }
        \\fn get_opt(r: *T) -> ?u32 { return r.o; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "field.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const scalar_body = try cFunctionBody(output.items, "static uint32_t get_a(S * r)");
    try expectContains(scalar_body, "mc_race_load_u32(");
    if (isCanonicalExecutableCBody(scalar_body)) {
        const scalar_guard = std.mem.indexOf(u8, scalar_body, "if (r == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
        const scalar_load = std.mem.indexOf(u8, scalar_body, "mc_race_load_u32(&(r->a))") orelse return error.TestUnexpectedResult;
        try std.testing.expect(scalar_guard < scalar_load);
        try expectContains(scalar_body, "return mc_exec_tmp_");
    }
    // Optional field (fallback): loads the tag bool too.
    const opt_body = try cFunctionBody(output.items, "static mc_opt_u32 get_opt(T * r)");
    try expectContains(opt_body, "mc_race_load_bool");
}

test "lower-c admits address-typed pointer-field-load returns from MIR" {
    // `return r.start` for an opaque address-type field (PAddr, repr usize) loads
    // through mc_race_load_usize and casts to the address repr (uintptr_t).
    const source =
        \\struct PhysRange { start: PAddr, len: usize }
        \\fn pr_start(r: *PhysRange) -> PAddr { return r.start; }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "pr.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const body = try cFunctionBody(output.items, "static uintptr_t pr_start(PhysRange * r)");
    try expectContains(body, "mc_race_load_usize(");
    if (isCanonicalExecutableCBody(body)) {
        const guard = std.mem.indexOf(u8, body, "if (r == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
        const load = std.mem.indexOf(u8, body, "mc_race_load_usize(&(r->start))") orelse return error.TestUnexpectedResult;
        try std.testing.expect(guard < load);
        try expectContains(body, "return mc_exec_tmp_");
    }
}

test "lower-c pointer member load uses typed place without body fallback" {
    const source =
        \\struct Pair { first: i32, ready: bool, second: u64 }
        \\fn read_first(pair: *Pair) -> i32 { return pair.first; }
        \\fn read_ready(pair: *Pair) -> bool { return pair.ready; }
        \\fn read_second(pair: *Pair) -> u64 { return pair.second; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_executable_pointer_member.mc", source, &output);
    const first_body = try cFunctionBody(output.items, "static int32_t read_first(Pair * pair)");
    try expectContains(first_body, "mc_race_load_i32(");
    try expectContains(first_body, "if (pair == NULL) mc_trap_InvalidRepresentation();");
    try expectContains(first_body, "return mc_exec_tmp_");
    const ready_body = try cFunctionBody(output.items, "static bool read_ready(Pair * pair)");
    try expectContains(ready_body, "mc_race_load_bool(");
    try expectContains(ready_body, "if (pair == NULL) mc_trap_InvalidRepresentation();");
    try expectContains(ready_body, "return mc_exec_tmp_");
    const body = try cFunctionBody(output.items, "static uint64_t read_second(Pair * pair)");
    try expectContains(body, "mc_race_load_u64(");
    if (isCanonicalExecutableCBody(body)) {
        const guard = std.mem.indexOf(u8, body, "if (pair == NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
        const load = std.mem.indexOf(u8, body, "mc_race_load_u64(&(pair->second))") orelse return error.TestUnexpectedResult;
        try std.testing.expect(guard < load);
        try expectContains(body, "return mc_exec_tmp_");
    }
}

test "lower-c admits phys address-constructor returns from MIR" {
    // `phys(v)` builds the opaque PAddr (repr uintptr_t), so it lowers as the
    // same transparent `((uintptr_t)(v))` cast the conversion path emits.
    const source =
        \\fn to_pa(v: usize) -> PAddr { return phys(v); }
        \\fn offset(address: PAddr, amount: usize) -> PAddr {
        \\    return phys((address as usize) + amount);
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "phys.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = parser.Parser.init(source, &reporter);
    const module = try p.parseModule(arena.allocator());
    defer module.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const constructor = try cFunctionBody(output.items, "static uintptr_t to_pa(uintptr_t v)");
    try expectContains(constructor, "/* canonical executable MIR */");
    try expectContains(constructor, "((uintptr_t)(");
    try expectContains(constructor, "return mc_exec_tmp_");
    const offset = try cFunctionBody(output.items, "static uintptr_t offset(uintptr_t address, uintptr_t amount)");
    try expectContains(offset, "/* canonical executable MIR */");
    try expectContains(offset, "mc_checked_add_usize(");
    try expectContains(offset, "mc_trap_IntegerOverflow();");
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
    try appendCSourceMapDeclsTest(std.testing.allocator, module.decls, &output, .kernel, "debug_map_defer.mc", "debug_map_defer.c");

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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    // Canonical executable MIR owns the exact f32 payload.  Rendering it via a
    // bit-cast is stronger than decimal spelling: Clang cannot promote the
    // operands to double and then round the product back to f32.
    try std.testing.expect(std.mem.indexOf(u8, output.items, "0x3FD9999A") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "0x40133333") != null);
    try std.testing.expect(std.mem.count(u8, output.items, "__builtin_bit_cast(float") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "1.7f") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "2.3f") == null);
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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    try std.testing.expect(std.mem.count(u8, output.items, "typedef struct __tuple2_u32_u64 __tuple2_u32_u64;") == 1);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ")._0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ")._1") != null);
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

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("mod.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__square") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__PI") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Math__square(") != null);
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

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("impl.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "Tensor__get") != null);
    try std.testing.expect(std.mem.count(u8, output.items, "Tensor__get(") >= 2);
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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "__destr0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ")._0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ")._1") != null);
}

test "lower-c backend_name attribute emits asm label" {
    const source =
        \\#[backend_name("rss_helper_x")]
        \\fn helper(x: u64) -> u64 { return x + 1; }
        \\export fn harness() -> u64 { return helper(7); }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_backend_name_alias.mc", source, &output);

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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const body = try cFunctionBody(output.items, "static uint32_t call_direct(");
    try std.testing.expect(isCanonicalExecutableCBody(body));
    const callee = "(g_table).elems[";
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, output.items, search_from, callee)) |index| {
        count += 1;
        search_from = index + callee.len;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try expectContains(body, "mc_closure_ptr_");
    try expectContains(body, ").code((mc_exec_tmp_");
    try expectContains(body, ").env");
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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const body = try cFunctionBody(output.items, "static uint32_t classify(");
    try std.testing.expect(isCanonicalExecutableCBody(body));
    try expectContains(body, ").code((mc_exec_tmp_");
    try expectContains(body, ").env");
    try expectContains(body, "if (mc_exec_tmp_");
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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct Uart16550 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t volatile thr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint8_t volatile lsr;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void putc(Uart16550 volatile * uart, uint8_t ch)") != null);
    const putc_body = try cFunctionBody(output.items, "putc(");
    try expectContains(putc_body, "/* canonical executable MIR */");
    try expectNeedlesInOrder(putc_body, &.{ "= ch;", "mc_barrier_release_before();", "mc_mmio_write_u8" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, putc_body, "mc_mmio_write_u8"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint8_t read_lsr(Uart16550 volatile * uart)") != null);
    const read_body = try cFunctionBody(output.items, "read_lsr(");
    try expectContains(read_body, "/* canonical executable MIR */");
    try expectNeedlesInOrder(read_body, &.{ "mc_mmio_read_u8", "mc_barrier_acquire_after();", "return mc_exec_tmp_" });
    try expectContains(read_body, "+ UINT64_C(1)");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, read_body, "mc_mmio_read_u8"));
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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint16_t volatile lo;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t volatile hi;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint64_t volatile wide;") != null);
    const read_lo = try cFunctionBody(output.items, "read_lo(");
    try expectContains(read_lo, "/* canonical executable MIR */");
    try expectContains(read_lo, "mc_mmio_read_u16");
    try expectNotContains(read_lo, "mc_barrier_acquire_after");
    const write_hi = try cFunctionBody(output.items, "write_hi(");
    try expectNeedlesInOrder(write_hi, &.{ "= value;", "mc_barrier_release_before();", "mc_mmio_write_u32" });
    try expectContains(write_hi, "+ UINT64_C(4)");
    const read_wide = try cFunctionBody(output.items, "read_wide(");
    try expectNeedlesInOrder(read_wide, &.{ "mc_mmio_read_u64", "mc_barrier_acquire_after();", "return mc_exec_tmp_" });
    try expectContains(read_wide, "+ UINT64_C(8)");
    const write_wide = try cFunctionBody(output.items, "write_wide(");
    try expectNeedlesInOrder(write_wide, &.{ "= value;", "mc_mmio_write_u64" });
    try expectContains(write_wide, "+ UINT64_C(8)");
    try expectNotContains(write_wide, "mc_barrier_release_before");
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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const body = try cFunctionBody(output.items, "putc_computed(");
    try expectContains(body, "/* canonical executable MIR */");
    try expectNeedlesInOrder(body, &.{ "next_byte();", "box_byte(", "mc_barrier_release_before();", "mc_mmio_write_u8" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "next_byte()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "box_byte("));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "mc_mmio_write_u8"));
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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    try expectContains(output.items, "/* canonical executable MIR */");
    try expectContains(output.items, "mc_exec_tmp_0 = next_addr();");
    try expectContains(output.items, "mc_exec_tmp_1 = next_byte();");
    try expectContains(output.items, "mc_exec_tmp_2 = box_byte(mc_exec_tmp_1);");
    try expectContains(output.items, "mc_raw_store_u8(mc_exec_tmp_0, mc_exec_tmp_2);");
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
    try appendCDeclsTest(std.testing.allocator, module.decls, &output);

    const read_local = try cFunctionBody(output.items, "read_local(");
    try expectContains(read_local, "/* canonical executable MIR */");
    try expectNeedlesInOrder(read_local, &.{ "mc_mmio_read_u16", "mc_barrier_acquire_after();", "uint16_t value =", "return mc_exec_tmp_" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, read_local, "mc_mmio_read_u16"));
    const bits_local = try cFunctionBody(output.items, "read_inferred_bits_local(");
    try expectContains(bits_local, "/* canonical executable MIR */");
    try expectNeedlesInOrder(bits_local, &.{ "mc_mmio_read_u8", "mc_barrier_acquire_after();", " & ", "return" });
    const assign = try cFunctionBody(output.items, "assign_status(");
    try expectContains(assign, "/* canonical executable MIR */");
    try expectNeedlesInOrder(assign, &.{ "mc_mmio_read_u8", "mc_mmio_read_u8", "return" });
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
    try std.testing.expectError(error.InvalidMir, appendCDeclsTest(std.testing.allocator, module.decls, &output));
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
    const pass_body = try cFunctionBody(output.items, "static mc_result_u32_Error pass_result(mc_result_u32_Error result)");
    try expectContains(pass_body, "/* canonical executable MIR */");
    try expectContains(pass_body, "mc_result_u32_Error mc_exec_tmp_0;");
    try expectContains(pass_body, "mc_exec_tmp_0 = result;");
    try expectContains(pass_body, "return mc_exec_tmp_0;");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_result(mc_exec_tmp_") != null);
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
    const pass_body = try cFunctionBody(output.items, "static Token pass_token(Token token)");
    try expectContains(pass_body, "/* canonical executable MIR */");
    try expectContains(pass_body, "mc_exec_tmp_0 = token;");
    try expectContains(pass_body, "return mc_exec_tmp_0;");
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

    const value_body = try cFunctionBody(output.items, "static int64_t token_value(Token token)");
    try expectContains(value_body, "/* canonical executable MIR */");
    try expectContains(value_body, ").tag;");
    try expectContains(value_body, "switch (");
    try expectContains(value_body, "case 0: goto");
    try expectContains(value_body, "case 1: goto");
    try expectContains(value_body, "mc_trap_InvalidRepresentation();");
    try expectContains(value_body, ").payload.int_;");

    const kind_body = try cFunctionBody(output.items, "static uint32_t token_kind(Token token)");
    try expectContains(kind_body, "/* canonical executable MIR */");
    try expectContains(kind_body, "case 0: goto");
    try expectContains(kind_body, "case 1: goto");
    try expectContains(kind_body, "case 2: goto");
    try expectContains(kind_body, "mc_trap_InvalidRepresentation();");

    const call_body = try cFunctionBody(output.items, "static int64_t token_call_value(void)");
    try expectContains(call_body, "= make_token();");
    try expectContains(call_body, ").tag;");
    try expectContains(call_body, ").payload.int_;");

    const local_body = try cFunctionBody(output.items, "static int64_t token_local_value(void)");
    try expectContains(local_body, "= make_token();");
    try expectContains(local_body, "MC_UNUSED Token token =");
    try expectContains(local_body, ").tag;");
    try expectContains(local_body, ").payload.int_;");
}

test "lower-c emits tagged union constructors" {
    const source =
        \\union Token {
        \\    number: i64,
        \\    value: i64,
        \\    eof,
        \\    ok: u32,
        \\}
        \\
        \\fn id(token: Token) -> Token {
        \\    return token;
        \\}
        \\
        \\fn make_number() -> Token {
        \\    return value(7);
        \\}
        \\
        \\fn make_eof() -> Token {
        \\    return eof();
        \\}
        \\
        \\fn call_id() -> Token {
        \\    return id(value(7));
        \\}
        \\
        \\fn local_number() -> Token {
        \\    let token: Token = value(9);
        \\    return token;
        \\}
        \\fn number(value: i64) -> Token { return Token.number(value); }
        \\fn call_number() -> Token { return number(11); }
        \\fn make_ok_case() -> Token { return ok(12); }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_tagged_union_constructors.mc", source, &output);

    const make_number_body = try cFunctionBody(output.items, "static Token make_number(void)");
    try expectContains(make_number_body, "/* canonical executable MIR */");
    try expectContains(make_number_body, "= 7;");
    try expectContains(make_number_body, "((Token){ .tag = TokenTag_value, .payload.value =");
    try expectContains(make_number_body, "return mc_exec_tmp_");
    const make_eof_body = try cFunctionBody(output.items, "static Token make_eof(void)");
    try expectContains(make_eof_body, "((Token){ .tag = TokenTag_eof });");
    const call_id_body = try cFunctionBody(output.items, "static Token call_id(void)");
    try expectContains(call_id_body, "((Token){ .tag = TokenTag_value, .payload.value =");
    try expectContains(call_id_body, "= id(mc_exec_tmp_");
    const local_number_body = try cFunctionBody(output.items, "static Token local_number(void)");
    try expectContains(local_number_body, "((Token){ .tag = TokenTag_value, .payload.value =");
    try expectContains(local_number_body, "MC_UNUSED Token token =");
    const number_body = try cFunctionBody(output.items, "static Token number(int64_t value)");
    try expectContains(number_body, "TokenTag_number");
    const call_number_body = try cFunctionBody(output.items, "static Token call_number(void)");
    try expectContains(call_number_body, "= 11;");
    try expectContains(call_number_body, "number(");
    const ok_body = try cFunctionBody(output.items, "static Token make_ok_case(void)");
    try expectContains(ok_body, "= 12;");
    try expectContains(ok_body, "((Token){ .tag = TokenTag_ok, .payload.ok =");
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

    const ok_body = try cFunctionBody(output.items, "static mc_result_u32_Error make_ok(uint32_t value)");
    try expectContains(ok_body, "((mc_result_u32_Error){ .is_ok = true, .payload.ok = mc_exec_tmp_0 })");
    try expectContains(ok_body, "return mc_exec_tmp_1;");
    const err_body = try cFunctionBody(output.items, "static mc_result_u32_Error make_err(void)");
    try expectContains(err_body, "((mc_result_u32_Error){ .is_ok = false, .payload.err = mc_exec_tmp_0 })");
    try expectContains(err_body, "return mc_exec_tmp_1;");
    const send_body = try cFunctionBody(output.items, "static void send_ok(void)");
    try expectContains(send_body, ".is_ok = true");
    try expectContains(send_body, ".payload.ok = ");
    try expectContains(send_body, "consume_result(");
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
    try appendCheckedCTestWithMir("emit_c_result_try.mc", source, &output);

    const body = try cFunctionBody(output.items, "static mc_result_u32_Error add_one(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "make_result()");
    try expectContains(body, ".is_ok) {");
    try expectContains(body, ".payload.ok");
    try expectContains(body, "mc_checked_add_u32");
    try expectContains(body, ".is_ok = true");
}

test "lower-c emits Result try in return statements" {
    const source =
        \\enum Error: u8 {
        \\    denied = 1,
        \\}
        \\struct Pair { left: u32, right: u32, }
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
        \\fn unwrap_pair(result: Result<Pair, Error>) -> u32 {
        \\    let pair: Pair = result?;
        \\    return pair.left + pair.right;
        \\}
        \\fn propagate(result: Result<u32, Error>) -> Result<u32, Error> {
        \\    return ok(result?);
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("emit_c_result_try_return.mc", source, &output);

    const param_body = try cFunctionBody(output.items, "static uint32_t unwrap_param(mc_result_u32_Error result)");
    try expectContains(param_body, "/* canonical executable MIR */");
    try expectContains(param_body, ".is_ok == false) mc_trap_NullUnwrap();");
    try expectContains(param_body, ".payload.ok");
    try expectContains(param_body, "return mc_exec_tmp_");

    const call_body = try cFunctionBody(output.items, "static uint32_t unwrap_call(void)");
    try expectContains(call_body, "make_result()");
    try expectContains(call_body, ".is_ok == false) mc_trap_NullUnwrap();");
    try expectContains(call_body, ".payload.ok");

    const grouped_body = try cFunctionBody(output.items, "static uint32_t unwrap_grouped_call(void)");
    try expectContains(grouped_body, "make_result()");
    try expectContains(grouped_body, ".is_ok == false) mc_trap_NullUnwrap();");
    try expectContains(grouped_body, ".payload.ok");

    const pair_body = try cFunctionBody(output.items, "static uint32_t unwrap_pair(mc_result_mc_type_struct_4_Pair_Error result)");
    try expectContains(pair_body, "mc_result_mc_type_struct_4_Pair_Error mc_exec_tmp_");
    try expectContains(pair_body, ".is_ok == false) mc_trap_NullUnwrap();");
    try expectContains(pair_body, ".payload.ok");

    const propagate_body = try cFunctionBody(output.items, "static mc_result_u32_Error propagate(mc_result_u32_Error result)");
    try expectContains(propagate_body, "/* canonical executable MIR */");
    try expectContains(propagate_body, "if (!mc_exec_tmp_");
    try expectContains(propagate_body, ".is_ok) {");
    try expectContains(propagate_body, ".payload.ok");
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
    try appendCheckedCTestWithMir("emit_c_result_try_call_args.mc", source, &output);

    const arg_body = try cFunctionBody(output.items, "static uint32_t arg_try(void)");
    try expectContains(arg_body, "/* canonical executable MIR */");
    try expectContains(arg_body, ".is_ok == false) mc_trap_NullUnwrap();");
    try expectContains(arg_body, "consume(mc_exec_tmp_");

    const two_arg_body = try cFunctionBody(output.items, "static uint32_t two_arg_try(void)");
    try expectContains(two_arg_body, ".is_ok == false) mc_trap_NullUnwrap();");
    try expectContains(two_arg_body, "combine(mc_exec_tmp_");

    const nested_body = try cFunctionBody(output.items, "static uint32_t nested_arg_try(void)");
    try expectContains(nested_body, ".is_ok == false) mc_trap_NullUnwrap();");
    try expectContains(nested_body, "box_value(mc_exec_tmp_");
    try expectContains(nested_body, "consume(mc_exec_tmp_");
}

test "lower-c emits value optional try from MIR without body fallback" {
    const source =
        \\fn unwrap_value(maybe: ?u32) -> u32 {
        \\    return maybe?;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_value_optional_try.mc", source, &output);

    const body = try cFunctionBody(output.items, "static uint32_t unwrap_value(mc_opt_u32 maybe)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, ".present == false) mc_trap_NullUnwrap();");
    try expectContains(body, ".value");
    try expectContains(body, "return mc_exec_tmp_");
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

    try std.testing.expect(std.mem.indexOf(u8, output.items, "= maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= make_nullable_mut_pointer();") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= maybe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "== NULL) mc_trap_NullUnwrap();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_ptr(mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_ptr(mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "choose(mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_nullable_pointer();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "ptr_id(mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_ptr(mc_exec_tmp_") != null);
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
    try appendCheckedCTestWithMir("emit_c_try_local_initializer.mc", source, &output);

    const result_body = try cFunctionBody(output.items, "static mc_result_u32_Error local_result_try(void)");
    try expectContains(result_body, "/* canonical executable MIR */");
    try expectContains(result_body, "make_result()");
    try expectContains(result_body, ".is_ok) {");
    try expectContains(result_body, ".payload.ok");
    try expectContains(result_body, "box_value(mc_exec_tmp_");
    const nullable_body = try cFunctionBody(output.items, "static uint8_t const * local_nullable_try(void)");
    try expectContains(nullable_body, "/* canonical executable MIR */");
    try expectContains(nullable_body, "make_nullable_pointer()");
    try expectContains(nullable_body, "== NULL) mc_trap_NullUnwrap();");
    try expectContains(nullable_body, "ptr_id(mc_exec_tmp_");
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
    try appendCheckedCTestWithMir("emit_c_try_assignment_expr_stmt.mc", source, &output);

    const assign_result = try cFunctionBody(output.items, "static mc_result_u32_Error assign_result_try(void)");
    try expectContains(assign_result, "/* canonical executable MIR */");
    try expectContains(assign_result, ".is_ok) {");
    try expectContains(assign_result, ".payload.ok");
    try expectContains(assign_result, "mc_race_store_u32");
    const expr_result = try cFunctionBody(output.items, "static mc_result_u32_Error expr_result_try(void)");
    try expectContains(expr_result, ".is_ok) {");
    try expectContains(expr_result, "consume(mc_exec_tmp_");
    const assign_nullable = try cFunctionBody(output.items, "static uint8_t const * assign_nullable_try(void)");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assign_nullable, "ptr = "));
    // Two executable null checks plus their two MIR trap blocks. Count the
    // guarded checks, not textual trap-block bodies that are unreachable on
    // the successful path.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, assign_nullable, "== NULL) mc_trap_NullUnwrap();"));
    const expr_nullable = try cFunctionBody(output.items, "static void expr_nullable_try(void)");
    try expectContains(expr_nullable, "== NULL) mc_trap_NullUnwrap();");
    try expectContains(expr_nullable, "consume_ptr(mc_exec_tmp_");
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
    try appendCheckedCTestWithMir("c_mir_simple_functions_race_safe_globals.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "static MC_UNUSED uint32_t shared_counter = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t add(uint32_t a, uint32_t b)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_store_u32(&shared_counter, (uint32_t)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_race_load_u32(&shared_counter)") != null);
}

test "lower-c wide-scalar global race lowering fails closed" {
    // A u128/i128 global scalar access would name a nonexistent mc_race_load_u128/
    // mc_race_store_i128 helper and only fail at C compile time. Spec §I.13: no
    // sound race-tolerant lowering means emission must fail closed.
    try expectUnsupportedCheckedCEmission("emit_c_wide_global_load.mc",
        \\global wide: u128;
        \\
        \\fn read_wide() -> u128 {
        \\    return wide;
        \\}
    );
    try expectUnsupportedCheckedCEmission("emit_c_wide_global_store.mc",
        \\global wide: i128;
        \\
        \\fn write_wide(x: i128) -> void {
        \\    wide = x;
        \\}
    );
}

test "lower-c unproven wide-scalar pointer deref fails closed" {
    // An unproven *mut u128 deref demands race-tolerant lowering (spec I.13
    // default), but no mc_race helper exists for 128-bit scalars -> emission
    // must fail closed rather than name a nonexistent helper.
    try expectUnsupportedCheckedCEmission("emit_c_wide_deref.mc",
        \\fn read_wide(p: *mut u128) -> u128 {
        \\    return p.*;
        \\}
    );
}

test "lower-c checked pointer-root field store does not use function body fallback" {
    const source =
        \\struct Env { value: u32 }
        \\fn store_value(env: *mut Env, value: u32) -> void {
        \\    env.value = value;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_pointer_root_store.mc", source, &output);
    const body = try cFunctionBody(output.items, "static void store_value(Env * env, uint32_t value)");
    try expectContains(body, if (isCanonicalExecutableCBody(body))
        "mc_race_store_u32(&(env->value), (uint32_t)mc_exec_tmp_"
    else
        "mc_race_store_u32(&(env->value), (uint32_t)mc_tmp");
}

test "lower-c checked pointer-to-integer cast does not use function body fallback" {
    const source =
        \\fn pointer_to_usize(p: *mut u32) -> usize {
        \\    return p as usize;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_pointer_to_integer.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uintptr_t pointer_to_usize(uint32_t * p)");
    try expectContains(body, "/* canonical executable MIR */");
    const guard = std.mem.indexOf(u8, body, "== NULL) mc_trap_InvalidRepresentation();") orelse return error.TestUnexpectedResult;
    const cast = std.mem.indexOf(u8, body, "= ((uintptr_t)(mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    const returned = std.mem.indexOfPos(u8, body, cast, "return mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(guard < cast and cast < returned);
}

test "lower-c address representation cast does not use function body fallback" {
    const source =
        \\fn address_value(value: PAddr) -> usize {
        \\    return value as usize;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_address_representation_cast.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uintptr_t address_value(uintptr_t value)");
    try expectContains(body, "= ((uintptr_t)(mc_exec_tmp_0));");
    try expectContains(body, "return mc_exec_tmp_1;");
}

test "lower-c checked scalar local return does not use function body fallback" {
    const source =
        \\fn local_copy(n: u32) -> u32 {
        \\    let x: u32 = n + 1;
        \\    return x;
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_scalar_local_checked_return.mc", source, &output);
    const body = try cFunctionBody(output.items, "static uint32_t local_copy(uint32_t n)");
    try expectContains(body, "mc_checked_add_u32(");
    try expectContains(body, if (isCanonicalExecutableCBody(body)) "uint32_t x = mc_exec_tmp_" else "uint32_t x = mc_checked_add_u32(n, 1);");
    try expectContains(body, if (isCanonicalExecutableCBody(body)) "return mc_exec_tmp_" else "return x;");
}

test "lower-c pointer member slice copies lower field-wise race-tolerantly" {
    const source =
        \\struct Holder { view: []const u8 }
        \\fn load_view(p: *mut Holder) -> []const u8 { return p.view; }
        \\fn store_view(p: *mut Holder, value: []const u8) -> void { p.view = value; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_pointer_member_slice_copy.mc", source, &output);

    const load_body = try cFunctionBody(output.items, "static mc_slice_const_u8 load_view(Holder * p)");
    try expectContains(load_body, ".ptr = __atomic_load_n");
    try expectContains(load_body, ".len = (size_t)mc_race_load_usize");

    const store_body = try cFunctionBody(output.items, "static void store_view(Holder * p, mc_slice_const_u8 value)");
    try expectContains(store_body, "__atomic_store_n");
    try expectContains(store_body, "mc_race_store_usize");
}

test "lower-c direct pointer locals without MIR destination facts lower conservatively" {
    const source =
        \\global shared_counter: u32 = 0;
        \\
        \\fn c_direct_initializer_requires_mir_fact() -> u32 {
        \\    let p: *mut u32 = &shared_counter;
        \\    return p.*;
        \\}
        \\
        \\fn c_direct_assignment_requires_mir_fact() -> u32 {
        \\    var local: u32 = 1;
        \\    var p: *mut u32 = &local;
        \\    p = &shared_counter;
        \\    return p.*;
        \\}
    ;

    var normal_output: std.ArrayList(u8) = .empty;
    defer normal_output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_direct_pointer_provenance.mc", source, &normal_output);
    const normal_initializer_body = try cFunctionBody(normal_output.items, "static uint32_t c_direct_initializer_requires_mir_fact(void)");
    try expectContains(normal_initializer_body, "/* mir pointer_provenance consumed fn=c_direct_initializer_requires_mir_fact subject=p provenance=global_storage reason=none source=");
    try expectContains(normal_initializer_body, "mc_race_load_u32(p)");
    try expectNotContains(normal_initializer_body, "return *p;");

    const normal_assignment_body = try cFunctionBody(normal_output.items, "static uint32_t c_direct_assignment_requires_mir_fact(void)");
    try expectContains(normal_assignment_body, "/* mir pointer_provenance consumed fn=c_direct_assignment_requires_mir_fact subject=p provenance=local_storage reason=none source=");
    try expectContains(normal_assignment_body, "/* mir pointer_provenance consumed fn=c_direct_assignment_requires_mir_fact subject=p provenance=global_storage reason=reassignment source=");
    try expectContains(normal_assignment_body, "mc_race_load_u32(p)");
    try expectNotContains(normal_assignment_body, "return *p;");

    var missing_initializer_output: std.ArrayList(u8) = .empty;
    defer missing_initializer_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_direct_pointer_missing_provenance.mc", source, "c_direct_initializer_requires_mir_fact", "p", &missing_initializer_output);
    const missing_initializer_body = try cFunctionBody(missing_initializer_output.items, "static uint32_t c_direct_initializer_requires_mir_fact(void)");
    try expectNotContains(missing_initializer_body, "/* mir pointer_provenance consumed fn=c_direct_initializer_requires_mir_fact subject=p");
    try expectContains(missing_initializer_body, "mc_race_load_u32(p)");
    try expectNotContains(missing_initializer_body, "return *p;");

    var missing_assignment_output: std.ArrayList(u8) = .empty;
    defer missing_assignment_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithoutPointerProvenanceFactsForSubject("emit_c_direct_pointer_missing_provenance.mc", source, "c_direct_assignment_requires_mir_fact", "p", &missing_assignment_output);
    const missing_assignment_body = try cFunctionBody(missing_assignment_output.items, "static uint32_t c_direct_assignment_requires_mir_fact(void)");
    try expectNotContains(missing_assignment_body, "/* mir pointer_provenance consumed fn=c_direct_assignment_requires_mir_fact subject=p");
    try expectContains(missing_assignment_body, "mc_race_load_u32(p)");
    try expectNotContains(missing_assignment_body, "return *p;");
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

    const body = try cFunctionBody(output.items, "static uint32_t loop_once(bool flag)");
    try expectLegacyOrCanonicalLoop(body, "while (flag) {");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, if (isCanonicalExecutableCBody(body)) "out = mc_exec_tmp_" else "out = mc_tmp") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, if (isCanonicalExecutableCBody(body)) "goto mc_bb_" else "goto mc_break_") != null);
    if (!isCanonicalExecutableCBody(body)) try std.testing.expect(std.mem.indexOf(u8, body, "goto mc_continue_") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, if (isCanonicalExecutableCBody(body)) "return mc_exec_tmp_" else "return out;") != null);
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

    const poll = try cFunctionBody(output.items, "poll_and_write(");
    try expectContains(poll, "/* canonical executable MIR */");
    try expectNeedlesInOrder(poll, &.{ "mc_mmio_read_u8", "mc_barrier_acquire_after();", " & ", "pause();", "mc_mmio_write_u16" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, poll, "mc_mmio_read_u8"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, poll, "mc_mmio_write_u16"));
    const wait_raw = try cFunctionBody(output.items, "wait_raw(");
    try expectContains(wait_raw, "/* canonical executable MIR */");
    try expectNeedlesInOrder(wait_raw, &.{ "mc_mmio_read_u16", "==", "pause();", "goto mc_bb_1;" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, wait_raw, "mc_mmio_read_u16"));
    const require_ready = try cFunctionBody(output.items, "require_ready(");
    try expectNeedlesInOrder(require_ready, &.{ "mc_mmio_read_u8", "mc_barrier_acquire_after();", "mc_trap_Assert();" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, require_ready, "mc_mmio_read_u8"));
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

    const observe_body = try cFunctionBody(output.items, "observe_status(");
    try expectContains(observe_body, "/* canonical executable MIR */");
    try expectNeedlesInOrder(observe_body, &.{ "mc_mmio_read_u8", "mc_barrier_acquire_after();", "observe(" });
    const read_plus = try cFunctionBody(output.items, "read_plus(");
    try expectContains(read_plus, "/* canonical executable MIR */");
    try expectNeedlesInOrder(read_plus, &.{ "mc_mmio_read_u32", "mc_checked_add_u32(", "return mc_exec_tmp_" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, read_plus, "mc_mmio_read_u32"));
    const side_effect = try cFunctionBody(output.items, "read_side_effect(");
    try expectNeedlesInOrder(side_effect, &.{ "mc_mmio_read_u32", "mc_barrier_acquire_after();", "return;" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, side_effect, "mc_mmio_read_u32"));
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

    const local_nested = try cFunctionBody(output.items, "local_nested(");
    try expectNeedlesInOrder(local_nested, &.{ "mc_mmio_read_u32", "mc_checked_add_u32(", "uint32_t x =", "return mc_exec_tmp_" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, local_nested, "mc_mmio_read_u32"));
    const assign_nested = try cFunctionBody(output.items, "assign_nested(");
    try expectNeedlesInOrder(assign_nested, &.{ "mc_mmio_read_u32", "mc_barrier_acquire_after();", "mc_checked_add_u32(", "x =", "return mc_exec_tmp_" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, assign_nested, "mc_mmio_read_u32"));
    const local_untyped = try cFunctionBody(output.items, "local_untyped_nested(");
    try expectNeedlesInOrder(local_untyped, &.{ "mc_mmio_read_u32", "mc_checked_add_u32(", "uint32_t x =", "return mc_exec_tmp_" });
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

    const relaxed = try cFunctionBody(output.items, "switch_relaxed(");
    try expectNeedlesInOrder(relaxed, &.{ "mc_mmio_read_u32", "switch (mc_exec_tmp_" });
    try expectNotContains(relaxed, "mc_barrier_acquire_after");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, relaxed, "mc_mmio_read_u32"));
    const acquire = try cFunctionBody(output.items, "switch_acquire(");
    try expectNeedlesInOrder(acquire, &.{ "mc_mmio_read_u32", "mc_barrier_acquire_after();", "switch (mc_exec_tmp_" });
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, acquire, "mc_mmio_read_u32"));
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

    const body = try cFunctionBody(output.items, "switch_arm_expr(");
    try expectNeedlesInOrder(body, &.{ "case 0:", "default:", "mc_bb_2:", "mc_mmio_read_u32", "mc_barrier_acquire_after();", "mc_bb_3:", "mc_mmio_read_u32" });
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "mc_mmio_read_u32"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "mc_barrier_acquire_after();"));
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
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__mc_for_index_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".ptr[__mc_for_index_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef struct mc_array_u32_4 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t sum_array(mc_array_u32_4 xs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, " < 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".elems[__mc_for_index_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_slice()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".len") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "make_array()") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "sum = mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_exec_tmp_") != null);
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
    try std.testing.expect(std.mem.count(u8, output.items, "mc_check_index_usize(") >= 2);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ").elems[2]") != null);
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
    const read_slice_body = try cFunctionBody(output.items, "static uint8_t read_slice(");
    try std.testing.expect(isCanonicalExecutableCBody(read_slice_body));
    try expectContains(read_slice_body, "mc_race_load_u8");
    try expectContains(read_slice_body, "mc_check_index_usize(");
    const read_literal_body = try cFunctionBody(output.items, "static uint8_t read_literal(");
    try std.testing.expect(isCanonicalExecutableCBody(read_literal_body));
    try expectContains(read_literal_body, "mc_race_load_u8");
    try expectContains(read_literal_body, "mc_check_index_usize(");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void write_slice(mc_slice_mut_u32 xs, uintptr_t i, uint32_t value)") != null);
    const write_slice_body = try cFunctionBody(output.items, "static void write_slice(");
    try std.testing.expect(isCanonicalExecutableCBody(write_slice_body));
    try expectContains(write_slice_body, "mc_race_store_u32");
    try expectContains(write_slice_body, "mc_check_index_usize(");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static mc_slice_const_u8 same_slice(mc_slice_const_u8 xs)") != null);
    inline for (.{
        .{ "static uint8_t read_direct_literal(", "make_u8_slice(" },
        .{ "static uint32_t read_direct_index(", "make_u32_slice(" },
        .{ "static uint32_t read_inferred_slice(", "make_u32_slice(" },
        .{ "static uint8_t local_direct_literal(", "make_u8_slice(" },
        .{ "static uint32_t local_direct_index(", "make_u32_slice(" },
    }) |case| {
        const body = try cFunctionBody(output.items, case[0]);
        try std.testing.expect(isCanonicalExecutableCBody(body));
        try expectContains(body, case[1]);
        try expectContains(body, "mc_race_load_");
        try expectContains(body, "mc_check_index_usize(");
    }
    const const_range_body = try cFunctionBody(output.items, "static uint8_t const_slice_from_array_range(");
    try std.testing.expect(isCanonicalExecutableCBody(const_range_body));
    try expectContains(const_range_body, "mc_trap_Bounds()");
    try expectContains(const_range_body, "mc_slice_const_u8");
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

test "lower-c emits checked u32 mod and shifts from MIR without body fallback" {
    const source =
        \\fn mod_u32(a: u32, b: u32) -> u32 { return a % b; }
        \\fn shl_u32(a: u32, n: u32) -> u32 { return a << n; }
        \\fn shr_u32(a: u32, n: u32) -> u32 { return a >> n; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_checked_mod_shift_returns.mc", source, &output);

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

    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "switch (mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 0: goto mc_bb_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 1: goto mc_bb_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "case 2: goto mc_bb_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "default: goto mc_bb_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_exec_tmp_") != null);
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

    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED uint64_t _ignore =") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED uint64_t _seq_ignore =") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "tick();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "tick2(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ".elems[mc_check_index_usize(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (mc_exec_tmp_") != null);
}

test "lower-c emits target-typed enum literals" {
    const source =
        \\enum Mode: u8 {
        \\    read = 1,
        \\    write = 2,
        \\}
        \\
        \\extern fn sink(mode: Mode) -> u32;
        \\global global_mode: Mode = .read;
        \\type ModeAlias = Mode;
        \\const DEFAULT_ALIAS: ModeAlias = ((.read as ModeAlias));
        \\global alias_mode: ModeAlias = (.write as ModeAlias);
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
        \\fn is_read(mode: Mode) -> bool { return mode == .read; }
        \\fn cast_mode() -> Mode { return .write as Mode; }
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_enum_target_type_facts.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "typedef uint8_t Mode;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode_read = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "Mode_write = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t sink(Mode mode);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "global_mode = Mode_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "DEFAULT_ALIAS = Mode_read") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "alias_mode = Mode_write") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= sink(mc_exec_tmp_0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidRepresentation") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "((Mode)(mc_exec_tmp_0))") != null);
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

    const unwrap = try cFunctionBody(output.items, "static uint8_t * unwrap_or(uint8_t * maybe, uint8_t * fallback)");
    try expectContains(unwrap, "/* canonical executable MIR */");
    try expectContains(unwrap, "= maybe;");
    try expectContains(unwrap, "!= NULL");
    try expectContains(unwrap, "uint8_t * p = mc_exec_tmp_");
    try expectContains(unwrap, "= fallback;");

    const read_const = try cFunctionBody(output.items, "static uint8_t read_const(uint8_t const * maybe)");
    if (isCanonicalExecutableCBody(read_const)) {
        try expectContains(read_const, "!= NULL");
        try expectContains(read_const, "uint8_t const * p = mc_exec_tmp_");
        // Canonical MIR evaluates the pointer local into an SSA-style
        // temporary before loading. The observable requirement is the typed
        // dereference, not the legacy AST emitter's direct `*p` spelling.
        try expectContains(read_const, "mc_race_load_u8(p)");
    } else {
        // Const-pointer dereference canonicalization is independent of if-let
        // variant lowering and remains covered by its dedicated MIR slice.
        try expectContains(read_const, "if (maybe != NULL) {");
        try expectContains(read_const, "uint8_t const * p = maybe;");
    }

    const call = try cFunctionBody(output.items, "static uint32_t unwrap_call_or_zero(void)");
    try expectContains(call, "/* canonical executable MIR */");
    try expectContains(call, "= maybe_ptr();");
    try expectContains(call, "!= NULL");
    try expectContains(call, "uint8_t * p = mc_exec_tmp_");

    const local = try cFunctionBody(output.items, "static uint32_t unwrap_local_or_zero(void)");
    try expectContains(local, "/* canonical executable MIR */");
    try expectContains(local, "uint8_t * maybe = mc_exec_tmp_");
    try expectContains(local, "!= NULL");
    try expectContains(local, "uint8_t * p = mc_exec_tmp_");
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

    const parameter_body = try cFunctionBody(output.items, "static uint32_t nullable_switch(uint8_t * maybe)");
    try expectContains(parameter_body, "/* canonical executable MIR */");
    try expectContains(parameter_body, "= maybe;");
    try expectContains(parameter_body, "if (mc_exec_tmp_");
    try expectContains(parameter_body, "uint8_t * p = mc_exec_tmp_");
    try expectContains(parameter_body, "= ptr_value(");
    try expectContains(parameter_body, "return mc_exec_tmp_");

    const call_body = try cFunctionBody(output.items, "static uint32_t nullable_call_switch(void)");
    try expectContains(call_body, "/* canonical executable MIR */");
    try expectContains(call_body, "= maybe_ptr();");
    try expectContains(call_body, "if (mc_exec_tmp_");
    try expectContains(call_body, "uint8_t * p = mc_exec_tmp_");
    try expectContains(call_body, "= ptr_value(");
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

    const unwrap = try cFunctionBody(output.items, "static uint32_t unwrap_or_zero(mc_result_u32_Error result)");
    try expectContains(unwrap, "/* canonical executable MIR */");
    try expectContains(unwrap, ".is_ok");
    try expectContains(unwrap, ".payload.ok");
    try expectContains(unwrap, "uint32_t v = mc_exec_tmp_");

    const has_err = try cFunctionBody(output.items, "static bool has_err(mc_result_u32_Error result)");
    if (isCanonicalExecutableCBody(has_err)) {
        try expectContains(has_err, "(!mc_exec_tmp_");
        try expectContains(has_err, ".is_ok)");
        try expectContains(has_err, ".payload.err");
        try expectContains(has_err, "Error e = mc_exec_tmp_");
    } else {
        // Enum/integer comparison canonicalization is a separate slice; the
        // Result discriminant and payload remain covered by `unwrap` above.
        try expectContains(has_err, "if (!result.is_ok) {");
        try expectContains(has_err, "Error e = result.payload.err;");
        try expectContains(has_err, "return (e != 0);");
    }

    const call = try cFunctionBody(output.items, "static uint32_t unwrap_call_or_zero(void)");
    try expectContains(call, "/* canonical executable MIR */");
    try expectContains(call, "= make_result();");
    try expectContains(call, ".is_ok");
    try expectContains(call, ".payload.ok");
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

    try std.testing.expect(std.mem.indexOf(u8, output.items, "/* canonical executable MIR */") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "= src();") != null);
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
    try std.testing.expectError(error.InvalidMir, appendCTest("emit_c_structs.mc", source, &output));
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
    try appendCheckedCTestWithMir("c_mir_field_reserved_names.mc", source, &output);

    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t offsetof_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t uint32_t_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ").offsetof_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, ").uint32_t_;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(mc_exec_tmp_") != null);
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
    try std.testing.expectError(error.InvalidMir, appendCTest("emit_c_overlay_union.mc", source, &output));
}

test "lower-c emits assert trap" {
    const source =
        \\fn require_flag(flag: bool) -> void { assert(flag); }
        \\fn require_expr(a: u32, b: u32) -> void { assert(a == b || a != 0); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCTest("emit_c_assert.mc", source, &output);
    const flag_body = try cFunctionBody(output.items, "static void require_flag(bool flag)");
    try expectContains(flag_body, "/* canonical executable MIR */");
    try expectContains(flag_body, "if (!(mc_exec_tmp_");
    try expectContains(flag_body, ")) goto mc_bb_");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, flag_body, "mc_trap_Assert();"));
    const expr_body = try cFunctionBody(output.items, "static void require_expr(uint32_t a, uint32_t b)");
    try expectContains(expr_body, "/* canonical executable MIR */");
    try expectContains(expr_body, "if (!(mc_exec_tmp_");
    try expectContains(expr_body, ")) goto mc_bb_");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, expr_body, "mc_trap_Assert();"));
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
    const lexical = try cFunctionBody(output.items, "MC_UNUSED static void accept_lexical_cleanup(void)");
    try expectContains(lexical, "/* canonical executable MIR */");
    const close_b = std.mem.indexOf(u8, lexical, "close_b();") orelse return error.TestUnexpectedResult;
    const close_a = std.mem.indexOfPos(u8, lexical, close_b + 1, "close_a();") orelse return error.TestUnexpectedResult;
    const return_pos = std.mem.indexOfPos(u8, lexical, close_a + 1, "return;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(close_b < close_a and close_a < return_pos);

    const block_cleanup = try cFunctionBody(output.items, "MC_UNUSED static void accept_block_cleanup(void)");
    try expectContains(block_cleanup, "/* canonical executable MIR */");
    try expectContains(block_cleanup, "close_a();");
    const break_cleanup = try cFunctionBody(output.items, "MC_UNUSED static void accept_cleanup_before_break(bool flag)");
    try expectContains(break_cleanup, "close_a();");
    try expectContains(break_cleanup, "goto mc_bb_");
    const continue_cleanup = try cFunctionBody(output.items, "MC_UNUSED static void accept_cleanup_before_continue(bool flag)");
    try expectContains(continue_cleanup, "close_a();");
    try expectContains(continue_cleanup, "goto mc_bb_");
    const fallthrough_cleanup = try cFunctionBody(output.items, "MC_UNUSED static void accept_cleanup_on_fallthrough(void)");
    try expectContains(fallthrough_cleanup, "close_a();");
}

test "lower-c deferred drop release requires source-matched MIR explicit-drop event" {
    const source =
        \\move struct Ticket { id: u32 }
        \\fn issue_ticket() -> Ticket { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_ticket(t: *mut Ticket) -> void { t.id = 0; }
        \\fn accept_deferred_resource_release() -> void {
        \\    var t: Ticket = issue_ticket();
        \\    defer close_ticket(&t);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("emit_c_drop_attr_defer_source_requires_event.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "accept_deferred_resource_release")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.ownership_events) |*event| {
        if (event.kind == .explicit_drop) {
            event.source.line += 1;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_drop_attr_defer_source_requires_event.mc", .{}, false, null));
}

test "lower-c ordinary defer requires source-matched MIR cleanup marker" {
    const source =
        \\extern fn close_a() -> void;
        \\fn ordinary_defer_marker() -> void {
        \\    defer close_a();
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("emit_c_ordinary_defer_requires_marker.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_marker")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind == .defer_cleanup) {
                instruction.line += 1;
                break;
            }
        } else continue;
        break;
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMir, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_requires_marker.mc", .{}, false, null));
}

test "lower-c ordinary defer rejects unsupported expression fallback" {
    const source =
        \\fn ordinary_defer_expression_fallback(x: u32) -> void {
        \\    defer x + 1;
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("emit_c_ordinary_defer_expression_fallback.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_expression_fallback.mc", .{}, false, null));
}

test "lower-c canonical ordinary defer ignores legacy call spelling" {
    const source =
        \\extern fn close_a() -> void;
        \\fn ordinary_defer_call_marker() -> void {
        \\    defer close_a();
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("emit_c_ordinary_defer_requires_call_marker.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_call_marker")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, "close_a")) {
                instruction.detail = "other_close";
                break;
            }
        } else continue;
        break;
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_requires_call_marker.mc", .{}, false, null);
    try expectContains(output.items, "close_a();");
}

test "lower-c canonical ordinary defer with arguments ignores legacy call spelling" {
    const source =
        \\extern fn takes_u32(value: u32) -> void;
        \\fn ordinary_defer_arg_call_marker(x: u32) -> void {
        \\    defer takes_u32(x);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("emit_c_ordinary_defer_arg_requires_call_marker.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_arg_call_marker")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind == .call and std.mem.eql(u8, instruction.detail, "takes_u32")) {
                instruction.detail = "other_takes_u32";
                break;
            }
        } else continue;
        break;
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_arg_requires_call_marker.mc", .{}, false, null);
    try expectContains(output.items, "takes_u32(");
}

test "lower-c canonical ordinary defer with arguments ignores legacy argument facts" {
    const source =
        \\extern fn takes_u32(value: u32) -> void;
        \\fn ordinary_defer_arg_fact(x: u32) -> void {
        \\    defer takes_u32(x);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("emit_c_ordinary_defer_arg_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_arg_fact")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.kind == .target_type and std.mem.eql(u8, instruction.detail, "direct_call_argument") and instruction.target_index == 0) {
                instruction.target_index = 7;
                break;
            }
        } else continue;
        break;
    } else return error.TestUnexpectedResult;
    for (function.target_type_facts) |*fact| {
        if (fact.kind == .direct_call_argument and fact.target_index == 0) {
            fact.target_index = 7;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_arg_requires_fact.mc", .{}, false, null);
    try expectContains(output.items, "takes_u32(");
}

test "lower-c ordinary direct defer with discarded result requires MIR result fact" {
    const source =
        \\extern fn record(value: u32) -> u32;
        \\fn ordinary_defer_result_fact(x: u32) -> void {
        \\    defer record(x);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("emit_c_ordinary_defer_result_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "ordinary_defer_result_fact")) break candidate;
    } else return error.TestUnexpectedResult;
    _ = function;
    try mir.validateLoweringAdmission(module_mir);
    var drifted_callee_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_result_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => |*defer_expr| switch (defer_expr.kind) {
                    .call => |*call| {
                        call.callee.*.span.line += 1;
                        drifted_callee_span = true;
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_callee_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_result_requires_fact.mc", .{}, false, null));
}

test "lower-c ordinary call-target defer requires MIR call-target fact" {
    const source =
        \\fn ordinary_defer_call_target_fact() -> void {
        \\    defer fence.release();
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseModule("emit_c_ordinary_defer_call_target_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_callee_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_call_target_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => |*defer_expr| switch (defer_expr.kind) {
                    .call => |*call| {
                        call.callee.*.span.line += 1;
                        drifted_callee_span = true;
                    },
                    else => return error.TestUnexpectedResult,
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_callee_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_call_target_requires_fact.mc", .{}, false, null));
}

test "lower-c ordinary raw-store defer requires MIR target facts" {
    const source =
        \\fn ordinary_defer_raw_store_fact(addr: PAddr, value: u32) -> void {
        \\    unsafe {
        \\        defer raw.store<u32>(addr, value);
        \\    }
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("emit_c_ordinary_defer_raw_store_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_call_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_raw_store_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .unsafe_block => |*unsafe_block| {
                    for (unsafe_block.items) |*unsafe_stmt| switch (unsafe_stmt.kind) {
                        .@"defer" => |*defer_expr| {
                            defer_expr.span.line += 1;
                            drifted_call_span = true;
                        },
                        else => {},
                    };
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_call_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_raw_store_requires_fact.mc", .{}, false, null));
}

test "lower-c ordinary MMIO write defer requires MIR call-target facts" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read_write>,
        \\}
        \\fn ordinary_defer_mmio_write_fact(dev: MmioPtr<Device>, value: u32) -> void {
        \\    defer dev.raw.write(value, .release);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("emit_c_ordinary_defer_mmio_write_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_mmio_write_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_mmio_write_requires_fact.mc", .{}, false, null));
}

test "lower-c ordinary MMIO read defer requires MIR call-target facts" {
    const source =
        \\extern mmio struct Device {
        \\    raw: Reg<u32, .read_write>,
        \\}
        \\fn ordinary_defer_mmio_read_fact(dev: MmioPtr<Device>) -> void {
        \\    defer dev.raw.read(.acquire);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("emit_c_ordinary_defer_mmio_read_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_mmio_read_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_mmio_read_requires_fact.mc", .{}, false, null));
}

test "lower-c ordinary DMA cache defer requires MIR call-target facts" {
    const source =
        \\extern struct Packet { len: u32 }
        \\type Buffer = DmaBuf<Packet, .noncoherent>;
        \\fn ordinary_defer_dma_cache_fact(buf: Buffer) -> void {
        \\    defer cache.clean(buf);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("emit_c_ordinary_defer_dma_cache_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_dma_cache_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_dma_cache_requires_fact.mc", .{}, false, null));
}

test "lower-c ordinary MaybeUninit write defer requires MIR call-target facts" {
    const source =
        \\extern struct Node { value: u32 }
        \\fn ordinary_defer_maybe_uninit_write_fact(value: Node) -> void {
        \\    var slot: MaybeUninit<Node> = uninit;
        \\    defer slot.write(value);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("emit_c_ordinary_defer_maybe_uninit_write_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_maybe_uninit_write_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_maybe_uninit_write_requires_fact.mc", .{}, false, null));
}

test "lower-c ordinary atomic store defer requires MIR call-target facts" {
    const source =
        \\fn ordinary_defer_atomic_store_fact(value: u32) -> void {
        \\    var counter: atomic<u32> = atomic.init(0);
        \\    defer counter.store(value, .release);
        \\    return;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("emit_c_ordinary_defer_atomic_store_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_atomic_store_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_atomic_store_requires_fact.mc", .{}, false, null));
}

test "lower-c ordinary va.end defer requires MIR call-target facts" {
    const source =
        \\export fn ordinary_defer_va_end_fact(count: i32, ...) -> i32 {
        \\    var ap: va_list = va.start();
        \\    defer va.end(&ap);
        \\    return count;
        \\}
    ;
    var parsed = try test_support.parseCheckedModule("emit_c_ordinary_defer_va_end_requires_fact.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    try mir.validateLoweringAdmission(module_mir);
    var drifted_defer_span = false;
    for (parsed.decls()) |*decl| switch (decl.kind) {
        .fn_decl => |*fn_decl| {
            if (!std.mem.eql(u8, fn_decl.name.text, "ordinary_defer_va_end_fact")) continue;
            const body = fn_decl.body orelse return error.TestUnexpectedResult;
            for (body.items) |*stmt| switch (stmt.kind) {
                .@"defer" => {
                    stmt.span.line += 1;
                    drifted_defer_span = true;
                },
                else => {},
            };
        },
        else => {},
    };
    if (!drifted_defer_span) return error.TestUnexpectedResult;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "emit_c_ordinary_defer_va_end_requires_fact.mc", .{}, false, null));
}

test "lower-c rejects auto-drop transfer authorization with stale MIR resource type" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn transfer_auto_drop() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("c_drop_attr_transfer_stale_resource.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const stale_resource_symbol = for (module_mir.functions) |function| {
        if (std.mem.eql(u8, function.name, "make_guard")) break function.typed_symbol_id;
    } else return error.TestUnexpectedResult;
    const transfer_function = for (module_mir.functions) |*function| {
        if (std.mem.eql(u8, function.name, "transfer_auto_drop")) break function;
    } else return error.TestUnexpectedResult;
    for (transfer_function.ownership_events) |*event| {
        if (event.kind == .move_out) {
            event.place.root_type_symbol_id = stale_resource_symbol;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_drop_attr_transfer_stale_resource.mc", .{}, false, null));
}

test "lower-c move auto-drop cancellation requires MIR move-out event" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn transfer_auto_drop() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("c_drop_attr_transfer_requires_move_out.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const drop_glue = module_mir.drop_glue_facts[0];
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "transfer_auto_drop")) break candidate;
    } else return error.TestUnexpectedResult;
    const generated_events = function.ownership_events;
    var move_index: usize = 0;
    while (move_index < generated_events.len and generated_events[move_index].kind != .move_out) : (move_index += 1) {}
    if (move_index == generated_events.len) return error.TestUnexpectedResult;

    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, generated_events.len + 1);
    @memcpy(events[0 .. move_index + 1], generated_events[0 .. move_index + 1]);
    events[move_index].kind = .auto_drop;
    events[move_index].drop_glue_symbol_id = drop_glue.typed_release_symbol_id;
    events[move_index + 1] = generated_events[move_index];
    events[move_index + 1].kind = .storage_dead;
    events[move_index + 1].drop_glue_symbol_id = .invalid;
    @memcpy(events[move_index + 2 ..], generated_events[move_index + 1 ..]);
    function.ownership_events = events;
    std.testing.allocator.free(generated_events);
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_drop_attr_transfer_requires_move_out.mc", .{}, false, null));
}

test "lower-c move auto-drop cancellation requires source-matched MIR move-out event" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard() -> Guard { return .{ .id = 1 }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn transfer_auto_drop() -> Guard {
        \\    var g: Guard = make_guard();
        \\    return move g;
        \\}
    ;
    var parsed = try test_support.parseModule("c_drop_attr_transfer_move_out_source.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "transfer_auto_drop")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.ownership_events) |*event| {
        if (event.kind == .move_out) {
            event.source.line += 1;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_drop_attr_transfer_move_out_source.mc", .{}, false, null));
}

test "lower-c explicit drop release cancellation requires MIR explicit-drop event" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn explicit_release_keeps_other_auto_drop() -> u32 {
        \\    var g: Guard = make_guard(1);
        \\    var h: Guard = make_guard(2);
        \\    close_guard(&g);
        \\    return h.id;
        \\}
    ;
    var parsed = try test_support.parseModule("c_drop_attr_release_requires_mir_event.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "explicit_release_keeps_other_auto_drop")) break candidate;
    } else return error.TestUnexpectedResult;
    const generated_events = function.ownership_events;
    var explicit_index: usize = 0;
    while (explicit_index < generated_events.len and generated_events[explicit_index].kind != .explicit_drop) : (explicit_index += 1) {}
    if (explicit_index == generated_events.len) return error.TestUnexpectedResult;

    const events = try std.testing.allocator.alloc(mir.OwnershipEvent, generated_events.len + 1);
    @memcpy(events[0 .. explicit_index + 1], generated_events[0 .. explicit_index + 1]);
    events[explicit_index].kind = .auto_drop;
    events[explicit_index + 1] = generated_events[explicit_index];
    events[explicit_index + 1].kind = .storage_dead;
    events[explicit_index + 1].drop_glue_symbol_id = .invalid;
    @memcpy(events[explicit_index + 2 ..], generated_events[explicit_index + 1 ..]);
    function.ownership_events = events;
    std.testing.allocator.free(generated_events);
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_drop_attr_release_requires_mir_event.mc", .{}, false, null));
}

test "lower-c explicit drop release cancellation requires source-matched MIR explicit-drop event" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn explicit_release_keeps_other_auto_drop() -> u32 {
        \\    var g: Guard = make_guard(1);
        \\    var h: Guard = make_guard(2);
        \\    close_guard(&g);
        \\    return h.id;
        \\}
    ;
    var parsed = try test_support.parseModule("c_drop_attr_release_source_requires_event.mc", source);
    defer parsed.deinit();

    var module_mir = try mir.buildFromDecls(std.testing.allocator, parsed.decls());
    defer module_mir.deinit();
    const function = for (module_mir.functions) |*candidate| {
        if (std.mem.eql(u8, candidate.name, "explicit_release_keeps_other_auto_drop")) break candidate;
    } else return error.TestUnexpectedResult;
    for (function.ownership_events) |*event| {
        if (event.kind == .explicit_drop) {
            event.source.line += 1;
            break;
        }
    } else return error.TestUnexpectedResult;
    try mir.validateLoweringAdmission(module_mir);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedCEmission, appendCProfileWithMirDeclsTest(std.testing.allocator, parsed.decls(), &module_mir, &output, .kernel, "c_drop_attr_release_source_requires_event.mc", .{}, false, null));
}

test "lower-c rejects auto-drop ownership holes before lowering" {
    const source =
        \\move struct Guard { id: u32 }
        \\fn make_guard(id: u32) -> Guard { return .{ .id = id }; }
        \\#[drop]
        \\fn close_guard(g: *mut Guard) -> void { g.id = 0; }
        \\fn reject_return_via_alias() -> Guard {
        \\    var g: Guard = make_guard(1);
        \\    let p: *Guard = &g;
        \\    return move p.*;
        \\}
        \\fn reject_forget_auto_drop() -> void {
        \\    var g: Guard = make_guard(2);
        \\    unsafe { forget_unchecked(g); }
        \\}
        \\fn reject_reinit_after_move() -> Guard {
        \\    var g: Guard = make_guard(3);
        \\    let result: Guard = move g;
        \\    g = make_guard(4);
        \\    return move result;
        \\}
    ;
    try std.testing.expectError(error.TestUnexpectedResult, test_support.parseCheckedModule("emit_c_auto_drop_v0_rejects.mc", source));
}

test "lower-c emits scoped borrow expressions as addresses" {
    const source =
        \\struct Cell { value: u32 }
        \\fn read_cell(c: *Cell) -> u32 { return c.value; }
        \\fn write_cell(c: *mut Cell, value: u32) -> void { c.value = value; }
        \\fn use_borrow() -> u32 {
        \\    var c: Cell = .{ .value = 1 };
        \\    write_cell(borrow mut c, 7);
        \\    return read_cell(borrow c);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidMir, appendCTest("emit_c_scoped_borrow.mc", source, &output));
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
    const body = try cFunctionBody(output.items, "MC_UNUSED static uint32_t accept_unsafe_block(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "mc_checked_add_u32(");
    try expectContains(body, "return mc_exec_tmp_");
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
    try appendCheckedCTestWithMir("emit_c_asm.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, "/* canonical executable MIR */"));
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
    try appendCheckedCTestWithMir("emit_c_precise_asm.mc", source, &output);
    try expectContains(output.items, "/* canonical executable MIR */");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "__asm__ __volatile__(\"bsf %1, %0\" : \"=r\"(idx) : \"r\"(mc_exec_tmp_") != null);
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
    try appendCheckedCTestWithMir("c_mir_comptime_block.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_pure_comptime_block(void)") != null);
    const body = try cFunctionBody(output.items, "static uint32_t accept_pure_comptime_block(void)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "return ");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t x = 1;") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "if (!(true))") == null);
}

test "lower-c renders canonical string bytes without body fallback" {
    const source =
        \\fn escaped() -> cstr { return "tri??/line\nquote\""; }
        \\fn bytes() -> []const u8 { return "A\0B"; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_string_bytes.mc", source, &output);
    const escaped_body = try cFunctionBody(output.items, "static char const * escaped(void)");
    try expectContains(escaped_body, "/* canonical executable MIR */");
    try expectContains(escaped_body, "tri\\?\\?/line\\nquote\\\"");
    const bytes_body = try cFunctionBody(output.items, "static mc_slice_const_u8 bytes(void)");
    try expectContains(bytes_body, "/* canonical executable MIR */");
    try expectContains(bytes_body, "\\000B\", .len = 3");
}

test "lower-c emits explicit traps and unreachable" {
    const source =
        \\fn trap_as_value() -> u32 { return trap(.Bounds); }
        \\fn unreachable_as_value() -> u32 { return unreachable; }
        \\fn never_returns_by_trap() -> never { return trap(.Assert); }
        \\fn trap_statement() { trap(.InvalidShift); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_explicit_traps.mc", source, &output);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t trap_as_value(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Bounds();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Unreachable();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void never_returns_by_trap(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_Assert();") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static void trap_statement(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_trap_InvalidShift();") != null);

    var reporter = diagnostics.Reporter.init(std.testing.allocator, "c_mir_explicit_traps.mc", source);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source_parser = parser.Parser.init(source, &reporter);
    const parsed = try source_parser.parseModule(arena.allocator());
    defer parsed.deinit(arena.allocator());
    try std.testing.expect(!reporter.has_errors);
    var source_map: std.ArrayList(u8) = .empty;
    defer source_map.deinit(std.testing.allocator);
    try appendCSourceMapDeclsTest(std.testing.allocator, parsed.decls, &source_map, .kernel, "c_mir_explicit_traps.mc", "c_mir_explicit_traps.c");
    try std.testing.expect(std.mem.indexOf(u8, source_map.items, "generated_c_line=0") == null);
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
    try std.testing.expectError(error.UnsupportedCEmission, appendCDeclsTest(std.testing.allocator, parsed.decls(), &output));
}

test "lower-c preserves two MMIO reads before a short-circuit edge" {
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
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_mmio_seq.mc", source, &output);
    const probe = std.mem.indexOf(u8, output.items, "bool probe(") orelse return error.TestUnexpectedResult;
    const first = std.mem.indexOfPos(u8, output.items, probe, "mc_mmio_read_u32") orelse return error.TestUnexpectedResult;
    const second = std.mem.indexOfPos(u8, output.items, first + 1, "mc_mmio_read_u32") orelse return error.TestUnexpectedResult;
    const both = std.mem.indexOfPos(u8, output.items, second, "both(") orelse return error.TestUnexpectedResult;
    const logical = std.mem.indexOfPos(u8, output.items, both, "if (mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    try std.testing.expect(first < second and second < both and both < logical);
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
    const probe = std.mem.indexOf(u8, output.items, "bool probe(") orelse return error.TestUnexpectedResult;
    const magic_read = std.mem.indexOfPos(u8, output.items, probe, "mc_mmio_read_u32") orelse return error.TestUnexpectedResult;
    const branch = std.mem.indexOfPos(u8, output.items, magic_read, "if (mc_exec_tmp_") orelse return error.TestUnexpectedResult;
    const devid_read = std.mem.indexOfPos(u8, output.items, branch, "mc_mmio_read_u32") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOfPos(u8, output.items, devid_read + 1, "mc_mmio_read_u32") == null);
    try std.testing.expect(magic_read < branch and branch < devid_read);
}

test "lower-c uses type-directed helpers for fixed-width checked arithmetic" {
    const source =
        \\fn add_i32(a: i32, b: i32) -> i32 { return a + b; }
        \\fn div_i32(a: i32, b: i32) -> i32 { return a / b; }
        \\fn mul_u64(a: u64, b: u64) -> u64 { return a * b; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_fixed_width_arith.mc", source, &output);
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

    const ordered_two_args = try cFunctionBody(output.items, "static uint32_t ordered_two_args(void)");
    try expectNeedlesInOrder(ordered_two_args, &.{ "= next_value();", "= next_value();", "= combine(" });
    const ordered_local_init = try cFunctionBody(output.items, "static uint32_t ordered_local_init(void)");
    try expectNeedlesInOrder(ordered_local_init, &.{ "= next_value();", "= next_value();", "= combine(" });
    const ordered_typed_local_init = try cFunctionBody(output.items, "static uint32_t ordered_typed_local_init(void)");
    try expectNeedlesInOrder(ordered_typed_local_init, &.{ "= next_value();", "= next_value();", "= combine(" });
    const ordered_expr_stmt = try cFunctionBody(output.items, "static void ordered_expr_stmt(void)");
    try expectNeedlesInOrder(ordered_expr_stmt, &.{ "= next_value();", "= next_value();", "consume(" });
    const ordered_nested_return = try cFunctionBody(output.items, "static uint32_t ordered_nested_return(void)");
    try expectNeedlesInOrder(ordered_nested_return, &.{ "= next_value();", "= box_value(", "= next_value();", "= combine(" });
    const ordered_nested_local_init = try cFunctionBody(output.items, "static uint32_t ordered_nested_local_init(void)");
    try expectNeedlesInOrder(ordered_nested_local_init, &.{ "= next_value();", "= box_value(", "= next_value();", "= combine(" });
    const ordered_nested_expr_stmt = try cFunctionBody(output.items, "static void ordered_nested_expr_stmt(void)");
    try expectNeedlesInOrder(ordered_nested_expr_stmt, &.{ "= next_value();", "= box_value(", "= next_value();", "consume(" });
    const ordered_assignment = try cFunctionBody(output.items, "static uint32_t ordered_assignment(void)");
    try expectNeedlesInOrder(ordered_assignment, &.{ "= next_value();", "= next_value();", "= combine(", "value = " });
    const ordered_nested_assignment = try cFunctionBody(output.items, "static uint32_t ordered_nested_assignment(void)");
    try expectNeedlesInOrder(ordered_nested_assignment, &.{ "= next_value();", "= box_value(", "= next_value();", "= combine(", "value = " });
    const ordered_global_assignment = try cFunctionBody(output.items, "static void ordered_global_assignment(void)");
    try expectNeedlesInOrder(ordered_global_assignment, &.{ "= next_value();", "= next_value();", "= combine(", "mc_race_store_u32(&ordered_global" });
    try std.testing.expect(std.mem.indexOf(u8, output.items, "return combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "uint32_t value = combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "value = combine(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume(next_value(), next_value());") == null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "box_value(next_value())") == null);
}

test "lower-c evaluates assignment RHS before LHS and struct fields in source order" {
    const source =
        \\struct Pair { first: u32, second: u32 }
        \\extern fn next_index() -> usize;
        \\extern fn next_value() -> u32;
        \\extern fn mark(value: u32) -> u32;
        \\fn ordered_assignment(values: []mut u32) -> void { values[next_index()] = next_value(); }
        \\fn ordered_literal() -> Pair { return .{ .second = mark(2), .first = mark(1) }; }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_assignment_and_literal_order.mc", source, &output);

    const assignment = try cFunctionBody(output.items, "static void ordered_assignment(mc_slice_mut_u32 values)");
    const rhs = std.mem.indexOf(u8, assignment, "next_value()") orelse return error.TestUnexpectedResult;
    const lhs = std.mem.indexOf(u8, assignment, "next_index()") orelse return error.TestUnexpectedResult;
    try std.testing.expect(rhs < lhs);

    const literal = try cFunctionBody(output.items, "static Pair ordered_literal(void)");
    const second_value = std.mem.indexOf(u8, literal, " = 2;") orelse return error.TestUnexpectedResult;
    const second_call = std.mem.indexOfPos(u8, literal, second_value, "mark(") orelse return error.TestUnexpectedResult;
    const first_value = std.mem.indexOfPos(u8, literal, second_call, " = 1;") orelse return error.TestUnexpectedResult;
    const first_call = std.mem.indexOfPos(u8, literal, first_value, "mark(") orelse return error.TestUnexpectedResult;
    try std.testing.expect(second_value < second_call);
    try std.testing.expect(second_call < first_value);
    try std.testing.expect(first_value < first_call);
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
    const plain_scope = try cFunctionBody(output.items, "MC_UNUSED static uint32_t accept_plain_contract_scope(void)");
    try expectContains(plain_scope, "/* canonical executable MIR */");
    try expectNotContains(plain_scope, "MC_CONTRACT_");
    try std.testing.expect(std.mem.indexOf(u8, output.items, "mc_checked_add_u32(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "x = mc_exec_tmp_") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MC_UNUSED static uint32_t accept_unchecked_contract_add(uint32_t a, uint32_t b)") != null);
    try std.testing.expectEqual(@as(usize, 26), std.mem.count(u8, output.items, "MC_MIR_RANGE no_overflow"));
    try std.testing.expectEqual(@as(usize, 17), std.mem.count(u8, output.items, " op=add"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, output.items, " op=sub"));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, output.items, " op=mul"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_values(") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "consume_counter(") != null);
}

test "C race-tolerant aggregate slice loads parenthesize generated pointer expressions" {
    const source =
        \\struct Inner { x: u32 }
        \\extern fn make_inner_slice() -> []const Inner;
        \\fn read_slice_element() -> u32 {
        \\    let inner = make_inner_slice()[0];
        \\    return inner.x;
        \\}
    ;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("emit_c_aggregate_slice_race_parentheses.mc", source, &output);
    try expectContains(output.items, "/* canonical executable MIR */");
    try expectContains(output.items, "mc_race_load_u32(&((mc_exec_tmp_");
    try expectContains(output.items, ".ptr[mc_check_index_usize(");
    try expectContains(output.items, "].x)))");
}

test "C canonical executable MIR owns scalar integer conversions" {
    const source =
        \\type W = wrap<u8>;
        \\fn narrow_unsigned(value: u32) -> u8 { return u8.trap_from(value); }
        \\fn signed_to_unsigned(value: i32) -> u8 { return u8.trap_from(value); }
        \\fn unsigned_to_signed(value: u32) -> i8 { return i8.trap_from(value); }
        \\fn widen(value: u8) -> u64 { return u64.trap_from(value); }
        \\fn narrow_wrap(value: u32) -> u8 { return u8.wrap_from(value); }
        \\fn narrow_sat(value: u32) -> u8 { return u8.sat_from(value); }
        \\fn signed_sat(value: i32) -> u8 { return u8.sat_from(value); }
        \\fn unsigned_signed_sat(value: u32) -> i8 { return i8.sat_from(value); }
        \\fn narrow_try(value: u32) -> Result<u8, ConversionError> { return u8.try_from(value); }
        \\fn widen_try(value: u8) -> Result<u64, ConversionError> { return u64.try_from(value); }
        \\fn conversion_source() -> u32 { return 300; }
        \\fn narrow_try_call() -> Result<u8, ConversionError> { return u8.try_from(conversion_source()); }
        \\fn make_wrap(value: u8) -> W { return W.from(value); }
        \\fn make_wrap_mod() -> W { return W.from_mod(300); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_trap_conversion.mc", source, &output);

    try std.testing.expectEqual(@as(usize, 14), std.mem.count(u8, output.items, "/* canonical executable MIR */"));
    const narrow = try cFunctionBody(output.items, "MC_UNUSED static uint8_t narrow_unsigned(uint32_t value)");
    try expectContains(narrow, "(unsigned __int128)255");
    try expectContains(narrow, "mc_trap_IntegerOverflow()");
    const crossed = try cFunctionBody(output.items, "MC_UNUSED static uint8_t signed_to_unsigned(int32_t value)");
    try expectContains(crossed, "(__int128)0");
    try expectContains(crossed, "(unsigned __int128)255");
    const signed = try cFunctionBody(output.items, "MC_UNUSED static int8_t unsigned_to_signed(uint32_t value)");
    try expectContains(signed, "(__int128)127");
    const widen = try cFunctionBody(output.items, "MC_UNUSED static uint64_t widen(uint8_t value)");
    try expectNotContains(widen, "? (mc_trap_IntegerOverflow()");
    const wrapped = try cFunctionBody(output.items, "MC_UNUSED static uint8_t narrow_wrap(uint32_t value)");
    try expectContains(wrapped, "((uint8_t)(mc_exec_tmp_");
    const saturated = try cFunctionBody(output.items, "MC_UNUSED static uint8_t narrow_sat(uint32_t value)");
    try expectContains(saturated, "(unsigned __int128)255");
    try expectNotContains(saturated, "mc_trap_IntegerOverflow()");
    const sat_crossed = try cFunctionBody(output.items, "MC_UNUSED static uint8_t signed_sat(int32_t value)");
    try expectContains(sat_crossed, "(__int128)0");
    try expectContains(sat_crossed, "(unsigned __int128)255");
    const sat_signed = try cFunctionBody(output.items, "MC_UNUSED static int8_t unsigned_signed_sat(uint32_t value)");
    try expectContains(sat_signed, "(__int128)127");
    const tried = try cFunctionBody(output.items, "MC_UNUSED static mc_result_u8_ConversionError narrow_try(uint32_t value)");
    try expectContains(tried, ".is_ok = false");
    try expectContains(tried, ".payload.err = (uint8_t)0");
    try expectContains(tried, ".is_ok = true");
    const tried_widen = try cFunctionBody(output.items, "MC_UNUSED static mc_result_u64_ConversionError widen_try(uint8_t value)");
    try expectContains(tried_widen, ".is_ok = true");
    try expectNotContains(tried_widen, ".is_ok = false");
    const tried_call = try cFunctionBody(output.items, "MC_UNUSED static mc_result_u8_ConversionError narrow_try_call(void)");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, tried_call, "conversion_source()"));
    try expectContains(tried_call, ".is_ok = false");
    const domain = try cFunctionBody(output.items, "MC_UNUSED static uint8_t make_wrap(uint8_t value)");
    try expectContains(domain, "/* canonical executable MIR */");
    const modulo = try cFunctionBody(output.items, "MC_UNUSED static uint8_t make_wrap_mod(void)");
    try expectContains(modulo, "((uint8_t)(mc_exec_tmp_");
}

test "C canonical executable MIR owns serial compare Result" {
    const source =
        \\type Seq = serial<u32>;
        \\fn compare(a: Seq, b: Seq) -> Result<Order, AmbiguousSerialOrder> { return Seq.compare(a, b); }
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_serial_compare.mc", source, &output);

    const body = try cFunctionBody(output.items, "MC_UNUSED static mc_result_Order_AmbiguousSerialOrder compare(uint32_t a, uint32_t b)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "== (uint32_t)2147483648");
    try expectContains(body, ".is_ok = false");
    try expectContains(body, ".payload.err = (uint8_t)0");
    try expectContains(body, ".payload.ok = (int8_t)");
}

test "C canonical executable MIR owns bounded counter Result" {
    const source =
        \\type Ticks = counter<u64>;
        \\fn bounded(now: Ticks, start: Ticks, max: Duration<u64>) -> Result<Duration<u64>, AmbiguousCounterInterval> {
        \\    return Ticks.elapsed_bounded(now, start, max);
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTestWithMir("c_mir_counter_elapsed_bounded.mc", source, &output);

    const body = try cFunctionBody(output.items, "MC_UNUSED static mc_result_mc_type_generic_8_Duration_1_3_u64_AmbiguousCounterInterval bounded(uint64_t now, uint64_t start, uint64_t max)");
    try expectContains(body, "/* canonical executable MIR */");
    try expectContains(body, "((uint64_t)(mc_exec_tmp_0 - mc_exec_tmp_1)) <= mc_exec_tmp_2");
    try expectContains(body, ".is_ok = true");
    try expectContains(body, ".payload.ok = (uint64_t)");
    try expectContains(body, ".is_ok = false");
    try expectContains(body, ".payload.err = (uint8_t)0");
}

test "lower-c unchecked arithmetic requires MIR no-overflow range fact" {
    const source =
        \\struct Counter {
        \\    next: u32,
        \\}
        \\
        \\extern "C" fn consume_value(value: u32) -> u32;
        \\
        \\fn trusted_add(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return unchecked.add(a, b);
        \\    }
        \\}
        \\
        \\fn inferred_local(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        let inferred = unchecked.add(a, b);
        \\        return inferred;
        \\    }
        \\}
        \\
        \\fn assigned_local(a: u32, b: u32) -> u32 {
        \\    var sum: u32 = 0;
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        sum = unchecked.mul(a, b);
        \\    }
        \\    return sum;
        \\}
        \\
        \\fn call_arg_fact(a: u32, b: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return consume_value(unchecked.add(a, b));
        \\    }
        \\}
        \\
        \\fn binary_operand_fact(a: u32, b: u32, c: u32) -> u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return (unchecked.add(a, b)) + c;
        \\    }
        \\}
        \\
        \\fn aggregate_element_fact(a: u32, b: u32) -> [1]u32 {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ unchecked.add(a, b) };
        \\    }
        \\}
        \\
        \\fn aggregate_field_fact(a: u32, b: u32) -> Counter {
        \\    #[unsafe_contract(no_overflow)]
        \\    {
        \\        return .{ .next = unchecked.mul(a, b) };
        \\    }
        \\}
    ;
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try appendCheckedCTest("c_range_fact_required.mc", source, &output);
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, output.items, "MC_MIR_RANGE no_overflow"));
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, output.items, " op=add"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.items, " op=mul"));
    const trusted_body = try cFunctionBody(output.items, "MC_UNUSED static uint32_t trusted_add(uint32_t a, uint32_t b)");
    try expectContains(trusted_body, "/* canonical executable MIR */");
    try expectContains(trusted_body, "MC_MIR_RANGE no_overflow region=1 op=add");

    var missing_fact_output: std.ArrayList(u8) = .empty;
    defer missing_fact_output.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidMirExecutableBody,
        appendCheckedCTestWithoutRangeFacts("c_range_fact_missing.mc", source, &.{"trusted_add"}, &missing_fact_output),
    );

    const non_value_missing_fact_cases = [_]struct {
        source_name: []const u8,
        function_name: []const u8,
    }{
        .{ .source_name = "c_range_fact_missing_inferred.mc", .function_name = "inferred_local" },
        .{ .source_name = "c_range_fact_missing_assigned.mc", .function_name = "assigned_local" },
        .{ .source_name = "c_range_fact_missing_call_arg.mc", .function_name = "call_arg_fact" },
        .{ .source_name = "c_range_fact_missing_binary_operand.mc", .function_name = "binary_operand_fact" },
        .{ .source_name = "c_range_fact_missing_aggregate_element.mc", .function_name = "aggregate_element_fact" },
        .{ .source_name = "c_range_fact_missing_aggregate_field.mc", .function_name = "aggregate_field_fact" },
    };
    for (non_value_missing_fact_cases) |case| {
        var missing_non_value_fact_output: std.ArrayList(u8) = .empty;
        defer missing_non_value_fact_output.deinit(std.testing.allocator);
        try expectCNoOverflowFactRejection(
            appendCheckedCTestWithoutRangeFacts(case.source_name, source, &.{case.function_name}, &missing_non_value_fact_output),
        );
    }

    var wrong_target_output: std.ArrayList(u8) = .empty;
    defer wrong_target_output.deinit(std.testing.allocator);
    try appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_wrong_target.mc", source, "trusted_add", "wrong_target", &wrong_target_output);
    try expectContains(wrong_target_output.items, "MC_MIR_RANGE no_overflow region=1 op=add");

    var wrong_inferred_local_target_output: std.ArrayList(u8) = .empty;
    defer wrong_inferred_local_target_output.deinit(std.testing.allocator);
    try expectCNoOverflowLegacyRetarget(
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_inferred_local_wrong_target.mc", source, "inferred_local", "wrong_target", &wrong_inferred_local_target_output),
    );

    var wrong_aggregate_target_output: std.ArrayList(u8) = .empty;
    defer wrong_aggregate_target_output.deinit(std.testing.allocator);
    try expectCNoOverflowLegacyRetarget(
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_aggregate_wrong_target.mc", source, "aggregate_field_fact", "wrong_target", &wrong_aggregate_target_output),
    );

    var wrong_aggregate_element_target_output: std.ArrayList(u8) = .empty;
    defer wrong_aggregate_element_target_output.deinit(std.testing.allocator);
    try expectCNoOverflowLegacyRetarget(
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_aggregate_element_wrong_target.mc", source, "aggregate_element_fact", "wrong_target", &wrong_aggregate_element_target_output),
    );

    var wrong_call_arg_target_output: std.ArrayList(u8) = .empty;
    defer wrong_call_arg_target_output.deinit(std.testing.allocator);
    try expectCNoOverflowLegacyRetarget(
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_call_arg_wrong_target.mc", source, "call_arg_fact", "wrong_target", &wrong_call_arg_target_output),
    );

    var wrong_assigned_local_target_output: std.ArrayList(u8) = .empty;
    defer wrong_assigned_local_target_output.deinit(std.testing.allocator);
    try expectCNoOverflowLegacyRetarget(
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_assigned_local_wrong_target.mc", source, "assigned_local", "wrong_target", &wrong_assigned_local_target_output),
    );

    var wrong_binary_operand_target_output: std.ArrayList(u8) = .empty;
    defer wrong_binary_operand_target_output.deinit(std.testing.allocator);
    try expectCNoOverflowLegacyRetarget(
        appendCheckedCTestWithRetargetedRangeFacts("c_range_fact_binary_operand_wrong_target.mc", source, "binary_operand_fact", "wrong_target", &wrong_binary_operand_target_output),
    );
}
