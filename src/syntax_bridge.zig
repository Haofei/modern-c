//! Transitional backend syntax-shape bridge.
//!
//! Backends still lower AST-shaped expressions in several paths.  Keep direct
//! expression-shape helper access behind this narrow bridge so remaining syntax
//! dependencies are inventoried in one place and can be replaced with typed
//! MIR facts without hunting through C/LLVM emitters.

const expr_syntax = @import("expr_syntax.zig");

pub const CallExpr = expr_syntax.CallExpr;
pub const IndexExpr = expr_syntax.IndexExpr;
pub const MemberCallee = expr_syntax.MemberCallee;
pub const QualifiedCallee = expr_syntax.QualifiedCallee;
pub const ReduceCallKind = expr_syntax.ReduceCallKind;
pub const ReflectionValueCallKind = expr_syntax.ReflectionValueCallKind;

pub const atomicOrderingArg = expr_syntax.atomicOrderingArg;
pub const atomicOrderingExpr = expr_syntax.atomicOrderingExpr;
pub const boolLiteralValue = expr_syntax.boolLiteralValue;
pub const byteViewAddressTarget = expr_syntax.byteViewAddressTarget;
pub const callExpr = expr_syntax.callExpr;
pub const calleeIdentName = expr_syntax.calleeIdentName;
pub const contractName = expr_syntax.contractName;
pub const dropPointerLocalReleaseCall = expr_syntax.dropPointerLocalReleaseCall;
pub const dynCalleeMethodName = expr_syntax.dynCalleeMethodName;
pub const indexExpr = expr_syntax.indexExpr;
pub const isIdentNamed = expr_syntax.isIdentNamed;
pub const isNegativeOne = expr_syntax.isNegativeOne;
pub const isRawLoadCall = expr_syntax.isRawLoadCall;
pub const isRawPtrCall = expr_syntax.isRawPtrCall;
pub const isRawStoreCall = expr_syntax.isRawStoreCall;
pub const isSatPreservingBinary = expr_syntax.isSatPreservingBinary;
pub const isUninitLiteral = expr_syntax.isUninitLiteral;
pub const memberCallee = expr_syntax.memberCallee;
pub const memberExpr = expr_syntax.memberExpr;
pub const nakedAsmStmt = expr_syntax.nakedAsmStmt;
pub const overlayMemberFromIndexBase = expr_syntax.overlayMemberFromIndexBase;
pub const qualifiedMemberCallee = expr_syntax.qualifiedMemberCallee;
pub const reduceCallKind = expr_syntax.reduceCallKind;
pub const reflectionFieldName = expr_syntax.reflectionFieldName;
pub const reflectionValueCallKind = expr_syntax.reflectionValueCallKind;
pub const taggedUnionCase = expr_syntax.taggedUnionCase;
