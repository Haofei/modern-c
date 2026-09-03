//! MIR model/verifier half of the complete unit suite.

const mir_tests = @import("mir_tests.zig");
const mir_body_plan = @import("mir_body_plan.zig");
const mir_body_plan_tests = @import("mir_body_plan_tests.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const mir_executable_body_tests = @import("mir_executable_body_tests.zig");

test {
    _ = mir_tests;
    _ = mir_body_plan;
    _ = mir_body_plan_tests;
    _ = mir_executable_body;
    _ = mir_executable_body_tests;
}
