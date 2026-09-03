//! Driver-owned codegen input assembly.
//!
//! It builds verified MIR and pre-collects declaration artifacts from the
//! session-owned resolved declaration stream before the backend request is
//! assembled. Keep this boundary out of backend lowerers until declaration
//! artifacts are normalized into VerifiedProgram facts.

const std = @import("std");

const backend = @import("backend.zig");
const compiler_session = @import("compiler_session.zig");
const declaration_artifacts = @import("declaration_artifacts.zig");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const module_parser = @import("module_parser.zig");

pub const DeclarationArtifacts = declaration_artifacts.EarlyDeclarationArtifacts;
const CompilationSession = compiler_session.CompilationSession;
const StageFailure = compiler_session.StageFailure;

pub fn buildBackendInputs(
    session: *CompilationSession,
    diag: *diagnostics.Reporter,
    optimize: bool,
    module_mir: *mir.Module,
    artifacts: *DeclarationArtifacts,
    failure_error: StageFailure,
) !backend.VerifiedProgram {
    const resolved_decls = try collectResolvedDecls(session);
    defer session.allocator.free(resolved_decls);
    const program = try session.buildVerifiedProgramFromResolvedDecls(resolved_decls, diag, optimize, module_mir, failure_error);
    errdefer module_mir.deinit();
    artifacts.* = try DeclarationArtifacts.collectFromResolvedDecls(session.allocator, resolved_decls, module_mir);
    errdefer artifacts.deinit(session.allocator);
    return program;
}

pub fn buildCArtifactInputs(
    session: *CompilationSession,
    module_mir: *mir.Module,
    artifacts: *DeclarationArtifacts,
) !void {
    const resolved_decls = try collectResolvedDecls(session);
    defer session.allocator.free(resolved_decls);
    try session.buildMirFromResolvedDecls(resolved_decls, false, module_mir);
    errdefer module_mir.deinit();
    artifacts.* = try DeclarationArtifacts.collectFromResolvedDecls(session.allocator, resolved_decls, module_mir);
    errdefer artifacts.deinit(session.allocator);
}

fn collectResolvedDecls(session: *CompilationSession) ![]const module_parser.ResolvedDecl {
    if (session.resolved_program) |program| {
        return session.allocator.dupe(module_parser.ResolvedDecl, program.decls);
    }
    if (session.resolved_sources) |resolved_sources| {
        return resolved_sources.collectDecls(session.allocator);
    }
    return error.MissingResolvedSources;
}
