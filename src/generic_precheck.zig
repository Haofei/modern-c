const std = @import("std");

const ast = @import("ast.zig");
const diagnostics = @import("diagnostics.zig");
const loader = @import("loader.zig");
const monomorphize = @import("monomorphize.zig");
const sema = @import("sema.zig");

pub fn check(
    allocator: std.mem.Allocator,
    module: ast.Module,
    reporter: *diagnostics.Reporter,
    file_boundaries: ?[]const loader.FileBoundary,
) std.mem.Allocator.Error!void {
    var generic_fns = std.StringHashMap(void).init(allocator);
    defer generic_fns.deinit();
    var needs_check = false;
    for (module.decls) |decl| {
        switch (decl.kind) {
            .fn_decl => |fn_decl| {
                if (monomorphize.isTypeGenericFunction(fn_decl)) {
                    try generic_fns.put(fn_decl.name.text, {});
                    needs_check = true;
                }
            },
            .struct_decl => |struct_decl| {
                if (struct_decl.type_params.len > 0) needs_check = true;
            },
            .union_decl => |union_decl| {
                if (union_decl.type_params.len > 0) needs_check = true;
            },
            else => {},
        }
    }
    if (!needs_check) return;

    var checker = sema.Checker.init(reporter);
    checker.file_boundaries = file_boundaries;
    checker.generic_template_precheck = true;
    checker.generic_template_fns = &generic_fns;
    checker.checkModule(module);
}
