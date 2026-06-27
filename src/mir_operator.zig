const std = @import("std");

const ast = @import("ast.zig");
const mir_model = @import("mir_model.zig");
const mir_type = @import("mir_type.zig");
const mir_verify_util = @import("mir_verify_util.zig");

const ArithmeticDomain = mir_verify_util.ArithmeticDomain;
const TrapKind = mir_model.TrapKind;
const ValueType = mir_model.ValueType;

pub fn binaryMayOverflow(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod, .shl, .shr => true,
        else => false,
    };
}

pub fn binaryTrapKind(op: ast.BinaryOp) TrapKind {
    return switch (op) {
        .div, .mod => .DivideByZero,
        .shl, .shr => .InvalidShift,
        .add, .sub, .mul => .IntegerOverflow,
        else => .Unknown,
    };
}

pub fn isShiftOp(op: ast.BinaryOp) bool {
    return op == .shl or op == .shr;
}

pub fn binaryChecksAddressClass(op: ast.BinaryOp) bool {
    return switch (op) {
        .logical_or,
        .logical_and,
        .eq,
        .ne,
        .lt,
        .le,
        .gt,
        .ge,
        .bit_or,
        .bit_xor,
        .bit_and,
        .shl,
        .shr,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        => true,
    };
}

pub fn isArithmeticBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .add, .sub, .mul, .div, .mod => true,
        else => false,
    };
}

pub fn isBitwiseBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .bit_and, .bit_or, .bit_xor, .shl, .shr => true,
        else => false,
    };
}

pub fn isLogicalBinary(op: ast.BinaryOp) bool {
    return op == .logical_and or op == .logical_or;
}

pub fn isOrderedComparison(op: ast.BinaryOp) bool {
    return switch (op) {
        .lt, .le, .gt, .ge => true,
        else => false,
    };
}

pub fn isPointerArithmetic(op: ast.BinaryOp) bool {
    return op == .add or op == .sub;
}

// A single-object pointer (`*T`) supports no arithmetic (section 9); raw-many
// pointers (`[*]T`) do.
pub fn isSingleObjectPointer(ty: ValueType) bool {
    return switch (ty) {
        .pointer => |shape| shape.kind == .single,
        else => false,
    };
}

// Pointers and views (slices) support only equality comparison, not ordering.
pub fn isPointerOrView(ty: ValueType) bool {
    return mir_type.isPointerLikeType(ty) or ty == .slice;
}

pub fn isCVoidPointer(ty: ValueType) bool {
    return switch (ty) {
        .pointer, .nullable_pointer => |shape| std.mem.eql(u8, shape.child, "c_void"),
        else => false,
    };
}

// Ordered comparison is forbidden on wrap/serial/counter, allowed on sat
// (sections 5.2-5.5).
pub fn isForbiddenOrderingDomain(domain: ?ArithmeticDomain) bool {
    return switch (domain orelse return false) {
        .wrap, .serial, .counter => true,
        .sat => false,
    };
}

pub fn isComparisonBinary(op: ast.BinaryOp) bool {
    return switch (op) {
        .eq, .ne, .lt, .le, .gt, .ge => true,
        else => false,
    };
}

pub fn logicalOperandsAllowed(left: ValueType, right: ValueType) bool {
    return logicalOperandAllowed(left) and logicalOperandAllowed(right);
}

fn logicalOperandAllowed(ty: ValueType) bool {
    return ty == .bool or ty == .unknown or ty == .never;
}

pub fn unaryNegOperandAllowed(domain: ?ArithmeticDomain, ty: ValueType) bool {
    if (domain != null) return true;
    if (isCheckedUnsignedType(ty)) return true;
    if (isCheckedSignedType(ty) or isFloatType(ty)) return true;
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "comptime_int"),
        // unary '-' on an untyped float literal (e.g. `-0.3`) is well-defined; the literal
        // is typed `comptime_float` until it unifies with f32/f64 at its use site.
        .float => |name| std.mem.eql(u8, name, "comptime_float"),
        .unknown, .never => true,
        else => false,
    };
}

pub fn bitwiseOperandAllowed(domain: ?ArithmeticDomain, ty: ValueType) bool {
    if (domain) |known| return known == .wrap or known == .sat or known == .serial or known == .counter;
    if (isCheckedUnsignedType(ty)) return true;
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "comptime_int"),
        .unknown, .never => true,
        else => false,
    };
}

pub fn checkedIntegerBinaryFinding(left: ValueType, right: ValueType) ?[]const u8 {
    if (!isCheckedIntegerType(left) or !isCheckedIntegerType(right)) return null;
    if (sameScalarTypeName(left, right)) return null;
    if ((isCheckedSignedType(left) and isCheckedUnsignedType(right)) or (isCheckedUnsignedType(left) and isCheckedSignedType(right))) {
        return "signed_unsigned_mix";
    }
    return "integer_promotion";
}

pub fn floatBinaryFinding(op: ast.BinaryOp, left: ValueType, right: ValueType) ?[]const u8 {
    if (!isFloatishType(left) and !isFloatishType(right)) return null;
    if (left == .unknown or right == .unknown or left == .never or right == .never) return null;
    if (op == .mod and (isFloatType(left) or isFloatType(right))) return "operator_operand";
    if (isFloatishType(left) and isFloatishType(right)) {
        if (isFloatType(left) and isFloatType(right) and !sameScalarTypeName(left, right)) return "float_binary_conversion";
        return null;
    }
    return "float_binary_conversion";
}

fn isCheckedIntegerType(ty: ValueType) bool {
    return isCheckedUnsignedType(ty) or isCheckedSignedType(ty);
}

pub fn isCheckedUnsignedType(ty: ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "u8") or
            std.mem.eql(u8, name, "u16") or
            std.mem.eql(u8, name, "u32") or
            std.mem.eql(u8, name, "u64") or
            std.mem.eql(u8, name, "u128") or
            std.mem.eql(u8, name, "usize"),
        else => false,
    };
}

pub fn isCheckedSignedType(ty: ValueType) bool {
    return switch (ty) {
        .integer => |name| std.mem.eql(u8, name, "i8") or
            std.mem.eql(u8, name, "i16") or
            std.mem.eql(u8, name, "i32") or
            std.mem.eql(u8, name, "i64") or
            std.mem.eql(u8, name, "i128") or
            std.mem.eql(u8, name, "isize"),
        else => false,
    };
}

fn isFloatishType(ty: ValueType) bool {
    return switch (ty) {
        .float => true,
        else => false,
    };
}

fn isFloatType(ty: ValueType) bool {
    return switch (ty) {
        .float => |name| std.mem.eql(u8, name, "f32") or std.mem.eql(u8, name, "f64"),
        else => false,
    };
}

fn sameScalarTypeName(left: ValueType, right: ValueType) bool {
    return switch (left) {
        .integer => |left_name| switch (right) {
            .integer => |right_name| std.mem.eql(u8, left_name, right_name),
            else => false,
        },
        .float => |left_name| switch (right) {
            .float => |right_name| std.mem.eql(u8, left_name, right_name),
            else => false,
        },
        else => false,
    };
}
