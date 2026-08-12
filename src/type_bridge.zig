//! Transitional backend type-shape bridge.
//!
//! Backends still receive AST-shaped types in several lowering paths.  Keep
//! direct type-syntax helper access behind this narrow bridge so the remaining
//! type-shaped compatibility surface is explicit and can be replaced by
//! verified typed facts without scattered C/LLVM imports.

const type_syntax = @import("type_syntax.zig");

pub const DmaBufInfo = type_syntax.DmaBufInfo;
pub const ViewKind = type_syntax.ViewKind;
pub const ViewType = type_syntax.ViewType;

pub const aliasTargetType = type_syntax.aliasTargetType;
pub const dmaBufInfo = type_syntax.dmaBufInfo;
pub const dropPointerReleaseParamTypeName = type_syntax.dropPointerReleaseParamTypeName;
pub const isArithmeticLayoutGeneric = type_syntax.isArithmeticLayoutGeneric;
pub const isMmioStructAbi = type_syntax.isMmioStructAbi;
pub const isOpaqueAddressTypeName = type_syntax.isOpaqueAddressTypeName;
pub const isPointerLikeGeneric = type_syntax.isPointerLikeGeneric;
pub const isSatType = type_syntax.isSatType;
pub const isStringLiteralTarget = type_syntax.isStringLiteralTarget;
pub const isWrapType = type_syntax.isWrapType;
pub const mmioPointee = type_syntax.mmioPointee;
pub const overlayArrayElementType = type_syntax.overlayArrayElementType;
pub const overlayByteArrayElementType = type_syntax.overlayByteArrayElementType;
pub const resolveAliasType = type_syntax.resolveAliasType;
pub const sameTypeSyntax = type_syntax.sameTypeSyntax;
pub const simpleNameType = type_syntax.simpleNameType;
pub const stringLiteralByteLen = type_syntax.stringLiteralByteLen;
pub const typeName = type_syntax.typeName;
pub const u8SliceMutability = type_syntax.u8SliceMutability;
pub const viewType = type_syntax.viewType;
