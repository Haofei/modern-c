//! MIR model/verifier half of the complete unit suite.

const fixture_expect = @import("fixture_expect.zig");
const mir_fixture_tests = @import("mir_fixture_tests.zig");
const mir_tests = @import("mir_tests.zig");
const mir_verify_fixture_tests = @import("mir_verify_fixture_tests.zig");
const mir_body_plan = @import("mir_body_plan.zig");
const mir_body_plan_tests = @import("mir_body_plan_tests.zig");
const mir_executable_body = @import("mir_executable_body.zig");
const mir_executable_body_tests = @import("mir_executable_body_tests.zig");

test {
    _ = fixture_expect;
    _ = mir_fixture_tests;
    _ = mir_tests;
    _ = mir_verify_fixture_tests;
    _ = mir_body_plan;
    _ = mir_body_plan_tests;
    _ = mir_executable_body;
    _ = mir_executable_body_tests;
}
