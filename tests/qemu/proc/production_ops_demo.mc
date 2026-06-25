import "kernel/core/production_ops.mc";

fn action_code(a: RuntimeAction) -> u32 {
    switch a {
        .Allow => { return 0; }
        .Throttle => { return 1; }
        .Revoke => { return 2; }
        .Kill => { return 3; }
    }
}

export fn production_ops_run() -> u32 {
    var pass: u32 = 1;

    var agent: BundleHeader = bundle_header_init(.Agent, 10, 1, 41, 7, 0xAA55, 256);
    switch bundle_validate(&agent, 1, 8, 12, 7, .Valid) {
        ok(v) => {}
        err(e) => { pass = 0; }
    }
    agent.signature_len = 0;
    switch bundle_validate(&agent, 1, 8, 12, 7, .Missing) {
        ok(v) => { pass = 0; }
        err(e) => {
            switch e {
                .BadSignature => {}
                _ => { pass = 0; }
            }
        }
    }
    agent.signature_len = 256;
    agent.abi_version = 2;
    switch bundle_validate(&agent, 1, 8, 12, 7, .Valid) {
        ok(v) => { pass = 0; }
        err(e) => {
            switch e {
                .BadAbi => {}
                _ => { pass = 0; }
            }
        }
    }
    agent.abi_version = 1;
    agent.key_id = 8;
    switch bundle_validate(&agent, 1, 8, 12, 7, .Valid) {
        ok(v) => { pass = 0; }
        err(e) => {
            switch e {
                .WrongKey => {}
                _ => { pass = 0; }
            }
        }
    }

    var rb: RollbackState = uninit;
    rollback_init(&rb, 10);
    if rollback_active_version(&rb) != 10 { pass = 0; }
    let candidate: usize = rollback_install_candidate(&rb, 11);
    if candidate == 0 { pass = 0; }
    if rollback_active_version(&rb) != 11 { pass = 0; }
    if rollback_mark_boot_failed(&rb, 1) != true { pass = 0; }
    if rollback_active_version(&rb) != 10 { pass = 0; }
    rollback_install_candidate(&rb, 12);
    rollback_mark_boot_success(&rb);
    if rollback_active_version(&rb) != 12 { pass = 0; }

    var wd: Watchdog = uninit;
    watchdog_arm(&wd, 100, 10);
    if watchdog_expired(&wd, 109) { pass = 0; }
    if !watchdog_expired(&wd, 110) { pass = 0; }
    watchdog_pet(&wd, 111);
    if watchdog_expired(&wd, 120) { pass = 0; }
    if !watchdog_expired(&wd, 121) { pass = 0; }

    var rr: RebootRecord = uninit;
    reboot_record_set(&rr, 3, .Watchdog, 44);
    if rr.boot_epoch != 3 { pass = 0; }
    switch rr.reason {
        .Watchdog => {}
        _ => { pass = 0; }
    }
    if rr.detail != 44 { pass = 0; }

    var ctl: AgentControlState = uninit;
    agent_control_init(&ctl, 10);
    policy_apply_runtime_action(&ctl, .Throttle);
    if !ctl.throttled { pass = 0; }
    if ctl.budget != 5 { pass = 0; }
    policy_apply_runtime_action(&ctl, .Revoke);
    if !ctl.revoked { pass = 0; }
    if ctl.budget != 0 { pass = 0; }
    if !ctl.running { pass = 0; }
    policy_apply_runtime_action(&ctl, .Kill);
    if !ctl.killed { pass = 0; }
    if ctl.running { pass = 0; }

    if action_code(.Allow) != 0 { pass = 0; }
    if action_code(.Throttle) != 1 { pass = 0; }
    if action_code(.Revoke) != 2 { pass = 0; }
    if action_code(.Kill) != 3 { pass = 0; }

    return pass;
}
