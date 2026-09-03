//! Frontend, checking, and compiler-driver half of the complete unit suite.

const main = @import("main.zig");
const artifact_model = @import("artifact_model.zig");
const codegen_options = @import("codegen_options.zig");
const codegen_request = @import("codegen_request.zig");
const compiler_session = @import("compiler_session.zig");
const driver_build = @import("driver_build.zig");
const verified_program = @import("verified_program.zig");

const eval_tests = @import("eval_tests.zig");
const hir_tests = @import("hir_tests.zig");
const ir_tests = @import("ir_tests.zig");
const lexer_tests = @import("lexer_tests.zig");
const lower_error = @import("lower_error.zig");
const mangle_private_tests = @import("mangle_private_tests.zig");
const module_graph = @import("module_graph.zig");
const module_parser = @import("module_parser.zig");
const monomorphize_tests = @import("monomorphize_tests.zig");
const parser_tests = @import("parser_tests.zig");
const sema_tests = @import("sema_tests.zig");
const spec_tests = @import("spec_tests.zig");

test {
    _ = main;
    _ = artifact_model;
    _ = codegen_options;
    _ = codegen_request;
    _ = compiler_session;
    _ = driver_build;
    _ = verified_program;
    _ = eval_tests;
    _ = hir_tests;
    _ = ir_tests;
    _ = lexer_tests;
    _ = lower_error;
    _ = mangle_private_tests;
    _ = module_graph;
    _ = module_parser;
    _ = monomorphize_tests;
    _ = parser_tests;
    _ = sema_tests;
    _ = spec_tests;
}
