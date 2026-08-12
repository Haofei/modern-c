//! C backend module-pipeline orchestration.
//!
//! This owns the fixed ordering of collection and top-level emission.  The
//! stateful C emitter supplies the individual operations through a deliberately
//! narrow callback context, keeping collection/emission ordering independent of
//! expression lowering and the emitter's large mutable function state.

const declaration_artifacts = @import("declaration_artifacts.zig");

/// Populate all declaration and type artifacts needed by C emission without
/// writing output.  Layout-header emission deliberately uses this same phase.
pub fn collect(emitter: anytype, early_metadata: declaration_artifacts.EarlyDeclarationArtifacts) anyerror!void {
    try emitter.setComptimeDeclarationsFromArtifacts(early_metadata);
    try emitter.collectEarlyDeclarationMetadata(early_metadata);
    try emitter.collectConstGlobals();
    try emitter.collectDeclArtifacts(early_metadata);
    try emitter.validateDropGlueFactsAgainstDecls();
    try emitter.collectBindThunks();
}

/// Emit a complete translation unit in dependency-safe module order.
pub fn emit(emitter: anytype, early_metadata: declaration_artifacts.EarlyDeclarationArtifacts) anyerror!void {
    defer emitter.deinit();
    try collect(emitter, early_metadata);
    try emitter.emitTypePrelude();
    try emitter.emitFunctionDeclarations();
    try emitter.emitGeneratedDispatchArtifacts();
    try emitter.emitGlobalDefinitions();
    try emitter.emitFunctionDefinitions();
}
