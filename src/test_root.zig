//! Compiler unit-test aggregation root.
//!
//! Keep this separate from `main.zig` so the CLI entrypoint does not own the
//! repository's test module inventory.  Sharded test roots may import narrower
//! subsets; this root preserves the historical `test-unit` coverage.

const main = @import("main.zig");
const artifact_model = @import("artifact_model.zig");
const codegen_options = @import("codegen_options.zig");
const codegen_request = @import("codegen_request.zig");
const compiler_session = @import("compiler_session.zig");
const verified_program = @import("verified_program.zig");

const eval_tests = @import("eval_tests.zig");
const hir_tests = @import("hir_tests.zig");
const ir_tests = @import("ir_tests.zig");
const lexer_tests = @import("lexer_tests.zig");
const lower_error = @import("lower_error.zig");
const lower_c_tests = @import("lower_c_tests.zig");
const lower_llvm_tests = @import("lower_llvm_tests.zig");
const mangle_private_tests = @import("mangle_private_tests.zig");
const mir_tests = @import("mir_tests.zig");
const mir_body_plan = @import("mir_body_plan.zig");
const mir_body_plan_tests = @import("mir_body_plan_tests.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const mir_executable_body_tests = @import("mir_executable_body_tests.zig");
const mir_access_plan_tests = @import("mir_access_plan_tests.zig");
const mir_alloca_hoist_plan_tests = @import("mir_alloca_hoist_plan_tests.zig");
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
    _ = verified_program;
    _ = eval_tests;
    _ = hir_tests;
    _ = ir_tests;
    _ = lexer_tests;
    _ = lower_error;
    _ = lower_c_tests;
    _ = lower_llvm_tests;
    _ = mangle_private_tests;
    _ = mir_tests;
    _ = mir_body_plan;
    _ = mir_body_plan_tests;
    _ = mir_executable_body;
    _ = mir_executable_body_tests;
    _ = mir_access_plan_tests;
    _ = mir_alloca_hoist_plan_tests;
    _ = module_graph;
    _ = module_parser;
    _ = monomorphize_tests;
    _ = parser_tests;
    _ = sema_tests;
    _ = spec_tests;
}
