const std = @import("std");

const ast = @import("ast.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const module_parser = @import("module_parser.zig");

pub fn collectArtifactsFromDecls(allocator: std.mem.Allocator, decls: []const ast.Decl) !declaration_artifacts.EarlyDeclarationArtifacts {
    var resolved_decls = try allocator.alloc(module_parser.ResolvedDecl, decls.len);
    defer allocator.free(resolved_decls);
    for (decls, 0..) |decl, i| {
        resolved_decls[i] = .{
            .file_id = @enumFromInt(0),
            .decl = decl,
        };
    }
    return declaration_artifacts.EarlyDeclarationArtifacts.collectFromResolvedDecls(allocator, resolved_decls);
}
