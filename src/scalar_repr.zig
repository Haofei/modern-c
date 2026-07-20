const std = @import("std");

pub const Integer = struct {
    bits: u16,
    signed: bool,
    c_type: []const u8,
    llvm_type: []const u8,
};

pub fn integer(name: []const u8) ?Integer {
    if (std.mem.eql(u8, name, "u8")) return .{ .bits = 8, .signed = false, .c_type = "uint8_t", .llvm_type = "i8" };
    if (std.mem.eql(u8, name, "i8")) return .{ .bits = 8, .signed = true, .c_type = "int8_t", .llvm_type = "i8" };
    if (std.mem.eql(u8, name, "u16")) return .{ .bits = 16, .signed = false, .c_type = "uint16_t", .llvm_type = "i16" };
    if (std.mem.eql(u8, name, "i16")) return .{ .bits = 16, .signed = true, .c_type = "int16_t", .llvm_type = "i16" };
    if (std.mem.eql(u8, name, "u32")) return .{ .bits = 32, .signed = false, .c_type = "uint32_t", .llvm_type = "i32" };
    if (std.mem.eql(u8, name, "i32")) return .{ .bits = 32, .signed = true, .c_type = "int32_t", .llvm_type = "i32" };
    if (std.mem.eql(u8, name, "u64")) return .{ .bits = 64, .signed = false, .c_type = "uint64_t", .llvm_type = "i64" };
    if (std.mem.eql(u8, name, "i64")) return .{ .bits = 64, .signed = true, .c_type = "int64_t", .llvm_type = "i64" };
    if (std.mem.eql(u8, name, "u128")) return .{ .bits = 128, .signed = false, .c_type = "unsigned __int128", .llvm_type = "i128" };
    if (std.mem.eql(u8, name, "i128")) return .{ .bits = 128, .signed = true, .c_type = "__int128", .llvm_type = "i128" };
    if (std.mem.eql(u8, name, "usize")) return .{ .bits = 64, .signed = false, .c_type = "uintptr_t", .llvm_type = "i64" };
    if (std.mem.eql(u8, name, "isize")) return .{ .bits = 64, .signed = true, .c_type = "intptr_t", .llvm_type = "i64" };

    if (std.mem.eql(u8, name, "Order")) return .{ .bits = 8, .signed = true, .c_type = "int8_t", .llvm_type = "i8" };
    if (std.mem.eql(u8, name, "IrqOff") or
        std.mem.eql(u8, name, "Error") or
        std.mem.eql(u8, name, "AmbiguousSerialOrder") or
        std.mem.eql(u8, name, "AmbiguousCounterInterval") or
        std.mem.eql(u8, name, "ConversionError") or
        std.mem.eql(u8, name, "Overflow"))
    {
        return .{ .bits = 8, .signed = false, .c_type = "uint8_t", .llvm_type = "i8" };
    }
    return null;
}

pub fn isLibraryInteger(name: []const u8) bool {
    return integer(name) != null and
        !std.mem.eql(u8, name, "u8") and !std.mem.eql(u8, name, "i8") and
        !std.mem.eql(u8, name, "u16") and !std.mem.eql(u8, name, "i16") and
        !std.mem.eql(u8, name, "u32") and !std.mem.eql(u8, name, "i32") and
        !std.mem.eql(u8, name, "u64") and !std.mem.eql(u8, name, "i64") and
        !std.mem.eql(u8, name, "u128") and !std.mem.eql(u8, name, "i128") and
        !std.mem.eql(u8, name, "usize") and !std.mem.eql(u8, name, "isize");
}
