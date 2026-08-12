//! Driver-owned codegen input assembly.
//!
//! This is the remaining syntax compatibility edge for CLI backend commands:
//! it builds verified MIR and pre-collects declaration artifacts before the
//! backend request is assembled. Keep this boundary out of backend lowerers and
//! out of `CompilationSession` until declaration artifacts are normalized into
//! VerifiedProgram facts.

const std = @import("std");

const ast = @import("ast.zig");
const backend = @import("backend.zig");
const compiler_session = @import("compiler_session.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const module_parser = @import("module_parser.zig");

pub const DeclarationArtifacts = declaration_artifacts.EarlyDeclarationArtifacts;
pub const SourceMapArtifact = declaration_artifacts.SourceMapArtifact;
const CompilationSession = compiler_session.CompilationSession;
const StageFailure = compiler_session.StageFailure;

pub fn buildBackendInputs(
    session: *CompilationSession,
    module: ast.Module,
    diag: *diagnostics.Reporter,
    optimize: bool,
    module_mir: *mir.Module,
    artifacts: *DeclarationArtifacts,
    failure_error: StageFailure,
) !backend.VerifiedProgram {
    const program = try session.buildVerifiedProgram(module, diag, optimize, module_mir, failure_error);
    errdefer module_mir.deinit();
    artifacts.* = try collectDeclarationArtifacts(session, module);
    errdefer artifacts.deinit(session.allocator);
    return program;
}

pub fn buildCArtifactInputs(
    session: *CompilationSession,
    module: ast.Module,
    module_mir: *mir.Module,
    artifacts: *DeclarationArtifacts,
) !void {
    module_mir.* = try mir.buildOpt(session.allocator, module, .{ .optimize = false });
    errdefer module_mir.deinit();
    artifacts.* = try collectDeclarationArtifacts(session, module);
    errdefer artifacts.deinit(session.allocator);
}

fn collectDeclarationArtifacts(session: *CompilationSession, module: ast.Module) !DeclarationArtifacts {
    if (session.resolved_sources) |resolved_sources| {
        const resolved_decls = try resolved_sources.collectDecls(session.allocator);
        defer session.allocator.free(resolved_decls);
        return DeclarationArtifacts.collectFromResolvedDecls(session.allocator, resolved_decls);
    }
    const fallback_decls = try fallbackResolvedDecls(session.allocator, module);
    defer session.allocator.free(fallback_decls);
    return DeclarationArtifacts.collectFromResolvedDecls(session.allocator, fallback_decls);
}

fn fallbackResolvedDecls(allocator: std.mem.Allocator, module: ast.Module) ![]module_parser.ResolvedDecl {
    const decls = try allocator.alloc(module_parser.ResolvedDecl, module.decls.len);
    for (module.decls, 0..) |decl, i| {
        decls[i] = .{
            .file_id = @enumFromInt(0),
            .decl = decl,
        };
    }
    return decls;
}
