const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const mangle_private = @import("mangle_private.zig");
const parser = @import("parser.zig");

fn parseFiles(
    allocator: std.mem.Allocator,
    reporter: *diagnostics.Reporter,
    file_a: []const u8,
    file_b: []const u8,
) ![]ast.Decl {
    var parser_a = parser.Parser.initWithFileId(file_a, reporter, 0);
    const module_a = try parser_a.parseModule(allocator);
    var parser_b = parser.Parser.initWithFileId(file_b, reporter, 1);
    const module_b = try parser_b.parseModule(allocator);
    const decls = try allocator.alloc(ast.Decl, module_a.decls.len + module_b.decls.len);
    @memcpy(decls[0..module_a.decls.len], module_a.decls);
    @memcpy(decls[module_a.decls.len..], module_b.decls);
    return decls;
}

fn expectPrivateMangle(mode: ast.VisibilityMode, expected_a: []const u8, expected_b: []const u8) !void {
    const file_a =
        \\fn helper() -> u32 { return 1; }
        \\fn call_a() -> u32 { return helper(); }
    ;
    const file_b =
        \\fn helper() -> u32 { return 2; }
        \\fn call_b() -> u32 { return helper(); }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "private_a.mc", file_a);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decls = try parseFiles(arena.allocator(), &reporter, file_a, file_b);
    const transformed_decls = try mangle_private.transformDeclsForFiles(arena.allocator(), decls, mode, 2);

    var helper_a: ?[]const u8 = null;
    var helper_b: ?[]const u8 = null;
    for (transformed_decls) |decl| {
        if (decl.kind != .fn_decl) continue;
        const fn_decl = decl.kind.fn_decl;
        if (std.mem.eql(u8, fn_decl.name.text, "call_a")) {
            helper_a = fn_decl.body.?.items[0].kind.@"return".?.kind.call.callee.kind.ident.text;
        }
        if (std.mem.eql(u8, fn_decl.name.text, "call_b")) {
            helper_b = fn_decl.body.?.items[0].kind.@"return".?.kind.call.callee.kind.ident.text;
        }
    }
    try std.testing.expectEqualStrings(expected_a, helper_a orelse return error.TestExpectedEqual);
    try std.testing.expectEqualStrings(expected_b, helper_b orelse return error.TestExpectedEqual);
}

test "explicit visibility mangles private collisions without pub opt-in" {
    try expectPrivateMangle(.legacy_pub_opt_in, "helper", "helper");
    try expectPrivateMangle(.explicit_public, "helper__mcp0", "helper__mcp1");
}

test "private mangling rewrites declaration-level value references" {
    const file_a =
        \\const N: usize = 4;
        \\struct A { bytes: [N]u8 }
    ;
    const file_b =
        \\const N: usize = 8;
        \\struct B { bytes: [N]u8 }
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "private_decl_a.mc", file_a);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decls = try parseFiles(arena.allocator(), &reporter, file_a, file_b);
    const transformed_decls = try mangle_private.transformDeclsForFiles(arena.allocator(), decls, .explicit_public, 2);

    var lengths: [2]?[]const u8 = .{ null, null };
    var index: usize = 0;
    for (transformed_decls) |decl| {
        if (decl.kind != .struct_decl) continue;
        const len = decl.kind.struct_decl.fields[0].ty.kind.array.len;
        lengths[index] = len.kind.ident.text;
        index += 1;
    }
    try std.testing.expectEqualStrings("N__mcp0", lengths[0].?);
    try std.testing.expectEqualStrings("N__mcp1", lengths[1].?);
}

test "private mangling avoids user names and rewrites statement contracts" {
    const file_a =
        \\const LIMIT: usize = 4;
        \\fn LIMIT__mcp0() -> u32 { return 9; }
        \\fn guarded_a() -> usize {
        \\    #[unsafe_contract(no_overflow, LIMIT)] { return LIMIT; }
        \\}
    ;
    const file_b =
        \\const LIMIT: usize = 8;
        \\fn guarded_b() -> usize {
        \\    #[unsafe_contract(no_overflow, LIMIT)] { return LIMIT; }
        \\}
    ;
    var reporter = diagnostics.Reporter.init(std.testing.allocator, "private_contract_a.mc", file_a);
    defer reporter.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decls = try parseFiles(arena.allocator(), &reporter, file_a, file_b);
    const transformed_decls = try mangle_private.transformDeclsForFiles(arena.allocator(), decls, .explicit_public, 2);

    var contract_names: [2]?[]const u8 = .{ null, null };
    var contract_index: usize = 0;
    var saw_disambiguated = false;
    for (transformed_decls) |decl| switch (decl.kind) {
        .global_decl => |global| {
            if (std.mem.startsWith(u8, global.name.text, "LIMIT__mcp0__g")) saw_disambiguated = true;
        },
        .fn_decl => |function| {
            if (!std.mem.startsWith(u8, function.name.text, "guarded_")) continue;
            const contract = function.body.?.items[0].kind.contract_block.attr.kind.unsafe_contract;
            contract_names[contract_index] = contract.args[0].kind.ident.text;
            contract_index += 1;
        },
        else => {},
    };
    try std.testing.expect(saw_disambiguated);
    try std.testing.expect(std.mem.startsWith(u8, contract_names[0].?, "LIMIT__mcp0__g"));
    try std.testing.expectEqualStrings("LIMIT__mcp1", contract_names[1].?);
}
