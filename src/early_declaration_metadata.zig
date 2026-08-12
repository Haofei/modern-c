//! Compatibility shim for the old early-declaration metadata module name.
//!
//! The artifact definitions now live in `declaration_artifacts.zig`, which is
//! the named syntax-compatibility boundary for declaration artifacts.

const declaration_artifacts = @import("declaration_artifacts.zig");

pub const CallableValueArtifact = declaration_artifacts.CallableValueArtifact;
pub const ComptimeDeclarationArtifacts = declaration_artifacts.ComptimeDeclarationArtifacts;
pub const EarlyDeclarationArtifacts = declaration_artifacts.EarlyDeclarationArtifacts;
pub const SourceMapArtifact = declaration_artifacts.SourceMapArtifact;
pub const TypeArtifact = declaration_artifacts.TypeArtifact;
