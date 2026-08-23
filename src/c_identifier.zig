//! Backend-neutral C presentation-name policy.
//!
//! This module deliberately imports no source syntax or semantic analysis.
//! Both the legacy C emitter and the canonical executable-MIR renderer use the
//! same reserved-name table, so a field declaration and every access receive
//! identical spelling.

const std = @import("std");

pub fn isReservedWord(name: []const u8) bool {
    const reserved = [_][]const u8{
        // C keywords, compiler extensions, and builtin spellings the emitter uses.
        "auto",              "break",              "case",              "char",             "const",
        "continue",          "default",            "do",                "double",           "else",
        "enum",              "extern",             "float",             "for",              "goto",
        "if",                "inline",             "int",               "long",             "register",
        "restrict",          "return",             "short",             "signed",           "sizeof",
        "static",            "struct",             "switch",            "typedef",          "union",
        "unsigned",          "void",               "volatile",          "while",            "_Bool",
        "_Complex",          "_Imaginary",         "_Alignas",          "_Alignof",         "_Atomic",
        "_Generic",          "_Noreturn",          "_Static_assert",    "_Thread_local",    "__auto_type",
        "__asm__",           "__attribute__",      "__builtin_trap",    "__builtin_memcpy", "__builtin_memcmp",
        "__builtin_va_list", "__builtin_va_start", "__builtin_va_copy", "__builtin_va_arg", "__builtin_va_end",
        // Macros and typedefs from the headers the generated prelude includes.
        "bool",              "true",               "false",             "NULL",             "offsetof",
        "size_t",            "ptrdiff_t",          "uintptr_t",         "intptr_t",         "uint8_t",
        "uint16_t",          "uint32_t",           "uint64_t",          "int8_t",           "int16_t",
        "int32_t",           "int64_t",            "UINT8_MAX",         "UINT16_MAX",       "UINT32_MAX",
        "UINT64_MAX",        "UINTPTR_MAX",        "INT8_MIN",          "INT16_MIN",        "INT32_MIN",
        "INT64_MIN",         "INTPTR_MIN",         "INT8_MAX",          "INT16_MAX",        "INT32_MAX",
        "INT64_MAX",         "INTPTR_MAX",         "CHAR_BIT",          "MC_UNUSED",        "MC_NORETURN",
        "MC_WEAK",
    };
    for (reserved) |word| if (std.mem.eql(u8, name, word)) return true;
    return false;
}

test "C presentation names reserve generated prelude identifiers" {
    try std.testing.expect(isReservedWord("offsetof"));
    try std.testing.expect(isReservedWord("uint32_t"));
    try std.testing.expect(isReservedWord("return"));
    try std.testing.expect(!isReservedWord("ordinary_field"));
}
