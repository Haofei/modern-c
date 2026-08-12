//! Driver-owned codegen input assembly.
//!
//! This is the remaining syntax compatibility edge for CLI backend commands:
//! it builds verified MIR and pre-collects declaration artifacts before the
//! backend request is assembled. Keep this boundary out of backend lowerers and
//! out of `CompilationSession` until declaration artifacts are normalized into
//! VerifiedProgram facts.

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
    artifacts.* = try DeclarationArtifacts.collectFromDecls(session.allocator, module.decls);
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
    artifacts.* = try DeclarationArtifacts.collectFromDecls(session.allocator, module.decls);
    errdefer artifacts.deinit(session.allocator);
}
