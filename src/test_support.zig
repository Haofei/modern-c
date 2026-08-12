const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const name_resolve = @import("name_resolve.zig");
const sema = @import("sema.zig");

pub const ParsedModule = struct {
    reporter: diagnostics.Reporter,
    arena: std.heap.ArenaAllocator,
    decls_slice: []ast.Decl,
    visibility_mode: ast.VisibilityMode,
    qualified_owners: [][]const u8,
    qualified_symbols: []const ast.QualifiedSymbol,

    pub fn decls(self: ParsedModule) []ast.Decl {
        return self.decls_slice;
    }

    pub fn deinit(self: *ParsedModule) void {
        self.arena.allocator().free(self.decls_slice);
        self.arena.deinit();
        self.reporter.deinit();
    }

    pub fn check(self: *ParsedModule) void {
        var checker = sema.Checker.init(&self.reporter);
        checker.checkDecls(self.decls(), self.visibility_mode, self.qualified_owners);
    }

    pub fn expectNoErrors(self: *const ParsedModule) !void {
        try std.testing.expect(!self.reporter.has_errors);
    }
};

pub fn parseModule(source_name: []const u8, source: []const u8) !ParsedModule {
    var reporter = diagnostics.Reporter.init(std.testing.allocator, source_name, source);
    errdefer reporter.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();

    var p = parser.Parser.init(source, &reporter);
    const syntax_module = try p.parseModule(arena.allocator());
    const resolved_decls = try name_resolve.transformDeclsWithSymbols(arena.allocator(), syntax_module.decls, syntax_module.qualified_symbols, null);

    var parsed = ParsedModule{
        .reporter = reporter,
        .arena = arena,
        .decls_slice = resolved_decls,
        .visibility_mode = syntax_module.visibility_mode,
        .qualified_owners = syntax_module.qualified_owners,
        .qualified_symbols = syntax_module.qualified_symbols,
    };
    try parsed.expectNoErrors();
    return parsed;
}

pub fn parseCheckedModule(source_name: []const u8, source: []const u8) !ParsedModule {
    var parsed = try parseModule(source_name, source);
    errdefer parsed.deinit();

    parsed.check();
    try parsed.expectNoErrors();
    return parsed;
}
