const diagnostics = @import("diagnostics.zig");
const lexer = @import("lexer.zig");
const lexer_tests = @import("lexer_tests.zig");
const parser = @import("parser.zig");
const parser_tests = @import("parser_tests.zig");
const loader = @import("loader.zig");
const mangle_private_tests = @import("mangle_private_tests.zig");

test {
    _ = diagnostics;
    _ = lexer;
    _ = lexer_tests;
    _ = parser;
    _ = parser_tests;
    _ = loader;
    _ = mangle_private_tests;
}
