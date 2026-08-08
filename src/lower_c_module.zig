//! C backend module-pipeline orchestration.
//!
//! This owns the fixed ordering of collection and top-level emission.  The
//! stateful C emitter supplies the individual operations through a deliberately
//! narrow callback context, keeping collection/emission ordering independent of
//! expression lowering and the emitter's large mutable function state.

const backend = @import("backend.zig");

/// Populate all declaration and type artifacts needed by C emission without
/// writing output.  Layout-header emission deliberately uses this same phase.
pub fn collect(emitter: anytype, declarations: backend.CEarlyDeclarationMetadataView) anyerror!void {
    const decls = declarations.declsForEarlyDeclarationScan();
    emitter.setComptimeDecls(decls);
    try emitter.collectEarlyDeclarationMetadataFromDecls(decls);
    try emitter.collectConstGlobals();
    try emitter.collectDeclArtifactsFromDecls(decls);
    try emitter.validateDropGlueFactsAgainstDecls();
    try emitter.collectBindThunks();
}

/// Emit a complete translation unit in dependency-safe module order.
pub fn emit(emitter: anytype, declarations: backend.CEarlyDeclarationMetadataView) anyerror!void {
    defer emitter.deinit();
    try collect(emitter, declarations);
    try emitter.emitTypePrelude();
    try emitter.emitFunctionDeclarations();
    try emitter.emitGeneratedDispatchArtifacts();
    try emitter.emitGlobalDefinitions();
    try emitter.emitFunctionDefinitions();
}
