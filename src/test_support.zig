const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const parser = @import("parser.zig");
const sema = @import("sema.zig");

pub const ParsedModule = struct {
    reporter: diagnostics.Reporter,
    arena: std.heap.ArenaAllocator,
    module: ast.Module,

    pub fn deinit(self: *ParsedModule) void {
        self.module.deinit(self.arena.allocator());
        self.arena.deinit();
        self.reporter.deinit();
    }

    pub fn check(self: *ParsedModule) void {
        var checker = sema.Checker.init(&self.reporter);
        checker.checkModule(self.module);
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
    const module = try p.parseModule(arena.allocator());
    errdefer module.deinit(arena.allocator());

    var parsed = ParsedModule{
        .reporter = reporter,
        .arena = arena,
        .module = module,
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
