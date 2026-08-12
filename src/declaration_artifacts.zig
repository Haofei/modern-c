//! Transitional backend declaration-artifact bridge.
//!
//! Early declaration metadata is still collected from syntax while declarations
//! are being normalized into VerifiedProgram facts.  Backend modules should use
//! this bridge instead of importing the collector directly, leaving
//! `codegen_request` as the named request boundary for pre-collected artifacts.

const early_declaration_metadata = @import("early_declaration_metadata.zig");

pub const CallableValueArtifact = early_declaration_metadata.CallableValueArtifact;
pub const ComptimeDeclarationArtifacts = early_declaration_metadata.ComptimeDeclarationArtifacts;
pub const EarlyDeclarationArtifacts = early_declaration_metadata.EarlyDeclarationArtifacts;
pub const SourceMapArtifact = early_declaration_metadata.SourceMapArtifact;
pub const TypeArtifact = early_declaration_metadata.TypeArtifact;
