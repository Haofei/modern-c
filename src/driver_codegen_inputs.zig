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

pub const DeclarationArtifacts = declaration_artifacts.EarlyDeclarationArtifacts;
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
    artifacts.* = try collectDeclarationArtifacts(session);
    errdefer artifacts.deinit(session.allocator);
    return program;
}

pub fn buildCArtifactInputs(
    session: *CompilationSession,
    module: ast.Module,
    module_mir: *mir.Module,
    artifacts: *DeclarationArtifacts,
) !void {
    module_mir.* = try mir.buildOptFromDecls(session.allocator, module.decls, .{ .optimize = false });
    errdefer module_mir.deinit();
    artifacts.* = try collectDeclarationArtifacts(session);
    errdefer artifacts.deinit(session.allocator);
}

fn collectDeclarationArtifacts(session: *CompilationSession) !DeclarationArtifacts {
    if (session.resolved_sources) |resolved_sources| {
        const resolved_decls = try resolved_sources.collectDecls(session.allocator);
        defer session.allocator.free(resolved_decls);
        return DeclarationArtifacts.collectFromResolvedDecls(session.allocator, resolved_decls);
    }
    return error.MissingResolvedSources;
}
