//! Transitional backend syntax-shape bridge.
//!
//! Backends still lower AST-shaped expressions in several paths.  Keep direct
//! expression-shape helper access behind this narrow bridge so remaining syntax
//! dependencies are inventoried in one place and can be replaced with typed
//! MIR facts without hunting through C/LLVM emitters.

const expr_syntax = @import("expr_syntax.zig");

pub const MemberCallee = expr_syntax.MemberCallee;

pub const byteViewAddressTarget = expr_syntax.byteViewAddressTarget;
pub const isIdentNamed = expr_syntax.isIdentNamed;
pub const isNegativeOne = expr_syntax.isNegativeOne;
pub const memberCallee = expr_syntax.memberCallee;
