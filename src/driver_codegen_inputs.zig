//! Driver-owned codegen input assembly.
//!
//! It builds verified MIR from the session-owned resolved declaration stream.
//! Source-map declaration metadata is normalized into module-owned MIR facts
//! during that build, so no AST compatibility artifact crosses this boundary.
//! Keep this boundary out of backend lowerers.

const std = @import("std");

const backend = @import("backend.zig");
const compiler_session = @import("compiler_session.zig");
const diagnostics = @import("diagnostics.zig");
const mir = @import("mir.zig");
const module_parser = @import("module_parser.zig");

const CompilationSession = compiler_session.CompilationSession;
const StageFailure = compiler_session.StageFailure;

pub fn buildBackendInputs(
    session: *CompilationSession,
    diag: *diagnostics.Reporter,
    optimize: bool,
    module_mir: *mir.Module,
    failure_error: StageFailure,
) !backend.VerifiedProgram {
    const resolved_decls = try collectResolvedDecls(session);
    defer session.allocator.free(resolved_decls);
    const program = try session.buildVerifiedProgramFromResolvedDecls(resolved_decls, diag, optimize, module_mir, failure_error);
    errdefer module_mir.deinit();
    return program;
}

pub fn buildCArtifactInputs(
    session: *CompilationSession,
    module_mir: *mir.Module,
) !void {
    const resolved_decls = try collectResolvedDecls(session);
    defer session.allocator.free(resolved_decls);
    try session.buildMirFromResolvedDecls(resolved_decls, false, module_mir);
    errdefer module_mir.deinit();
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
