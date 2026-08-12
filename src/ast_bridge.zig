//! Transitional backend AST-shape bridge.
//!
//! C/LLVM lowering still receives AST-shaped expressions, declarations, spans,
//! and type expressions in compatibility paths.  Keep direct AST access behind
//! direct AST access behind this bridge so the remaining syntax-shaped backend contract is inventoried
//! in one place while VerifiedProgram moves toward typed facts.

const ast = @import("ast.zig");

pub const AsmOutput = ast.AsmOutput;
pub const AsmStmt = ast.AsmStmt;
pub const Attr = ast.Attr;
pub const BinaryOp = ast.BinaryOp;
pub const Block = ast.Block;
pub const EnumCase = ast.EnumCase;
pub const EnumDecl = ast.EnumDecl;
pub const Expr = ast.Expr;
pub const Field = ast.Field;
pub const FnDecl = ast.FnDecl;
pub const GlobalDecl = ast.GlobalDecl;
pub const Ident = ast.Ident;
pub const IfLet = ast.IfLet;
pub const ImplTrait = ast.ImplTrait;
pub const ImplTraitMethod = ast.ImplTraitMethod;
pub const LocalDecl = ast.LocalDecl;
pub const Loop = ast.Loop;
pub const Module = ast.Module;
pub const Mutability = ast.Mutability;
pub const OverlayUnionDecl = ast.OverlayUnionDecl;
pub const PackedBitsDecl = ast.PackedBitsDecl;
pub const Param = ast.Param;
pub const Pattern = ast.Pattern;
pub const Span = ast.Span;
pub const Stmt = ast.Stmt;
pub const StructDecl = ast.StructDecl;
pub const StructLiteralField = ast.StructLiteralField;
pub const Switch = ast.Switch;
pub const SwitchArm = ast.SwitchArm;
pub const SwitchBody = ast.SwitchBody;
pub const TraitDecl = ast.TraitDecl;
pub const TraitMethodSig = ast.TraitMethodSig;
pub const TypeAlias = ast.TypeAlias;
pub const TypeExpr = ast.TypeExpr;
pub const UnionDecl = ast.UnionDecl;
