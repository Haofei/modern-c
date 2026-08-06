import "kernel/core/production_ops.mc";

global g_bundle_image: [4]u8;
global g_bundle_other: [4]u8;

fn digest_is_sha256_01020304(d: *BundleDigest) -> bool {
    if d.bytes[0] != 0x9f { return false; }
    if d.bytes[1] != 0x64 { return false; }
    if d.bytes[2] != 0xa7 { return false; }
    if d.bytes[3] != 0x47 { return false; }
    if d.bytes[4] != 0xe1 { return false; }
    if d.bytes[5] != 0xb9 { return false; }
    if d.bytes[6] != 0x7f { return false; }
    if d.bytes[7] != 0x13 { return false; }
    if d.bytes[8] != 0x1f { return false; }
    if d.bytes[9] != 0xab { return false; }
    if d.bytes[10] != 0xb6 { return false; }
    if d.bytes[11] != 0xb4 { return false; }
    if d.bytes[12] != 0x47 { return false; }
    if d.bytes[13] != 0x29 { return false; }
    if d.bytes[14] != 0x6c { return false; }
    if d.bytes[15] != 0x9b { return false; }
    if d.bytes[16] != 0x6f { return false; }
    if d.bytes[17] != 0x02 { return false; }
    if d.bytes[18] != 0x01 { return false; }
    if d.bytes[19] != 0xe7 { return false; }
    if d.bytes[20] != 0x9f { return false; }
    if d.bytes[21] != 0xb3 { return false; }
    if d.bytes[22] != 0xc5 { return false; }
    if d.bytes[23] != 0x35 { return false; }
    if d.bytes[24] != 0x6e { return false; }
    if d.bytes[25] != 0x6c { return false; }
    if d.bytes[26] != 0x77 { return false; }
    if d.bytes[27] != 0xe8 { return false; }
    if d.bytes[28] != 0x9b { return false; }
    if d.bytes[29] != 0x6a { return false; }
    if d.bytes[30] != 0x80 { return false; }
    if d.bytes[31] != 0x6a { return false; }
    return true;
}

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
    var sig_auth: SignatureAuthority = signature_authority_unchecked();

    var agent: BundleHeader = bundle_header_init(.Agent, 10, 1, 41, 7, 0xAA55, 256);
    switch bundle_validate_metadata(&agent, .Agent, 1, 8, 12, 7) {
        ok(v) => {}
        err(e) => { pass = 0; }
    }
    switch bundle_validate_metadata(&agent, .Kernel, 1, 8, 12, 7) {
        ok(v) => { pass = 0; }
        err(e) => {
            switch e {
                .BadKind => {}
                _ => { pass = 0; }
            }
        }
    }
    if !bundle_image_hash_matches(&agent, 0xAA55) { pass = 0; }
    if bundle_image_hash_matches(&agent, 0x55AA) { pass = 0; }
    switch bundle_validate_metadata_hash(&agent, .Agent, 1, 8, 12, 7, 0xAA55) {
        ok(v) => {}
        err(e) => { pass = 0; }
    }
    switch bundle_validate_metadata_hash(&agent, .Agent, 1, 8, 12, 7, 0x55AA) {
        ok(v) => { pass = 0; }
        err(e) => {
            switch e {
                .BadImageHash => {}
                _ => { pass = 0; }
            }
        }
    }

    let image_base: usize = (&g_bundle_image) as usize;
    let other_base: usize = (&g_bundle_other) as usize;
    unsafe {
        raw.store<u8>(phys(image_base + 0), 1);
        raw.store<u8>(phys(image_base + 1), 2);
        raw.store<u8>(phys(image_base + 2), 3);
        raw.store<u8>(phys(image_base + 3), 4);
        raw.store<u8>(phys(other_base + 0), 1);
        raw.store<u8>(phys(other_base + 1), 2);
        raw.store<u8>(phys(other_base + 2), 3);
        raw.store<u8>(phys(other_base + 3), 4);
    }
    let exact_hash: u64 = bundle_hash_bytes(image_base, 4);
    var exact_digest: BundleDigest = bundle_digest_bytes(image_base, 4);
    if !digest_is_sha256_01020304(&exact_digest) { pass = 0; }
    var exact: BundleHeader = bundle_header_init_for_image(.Agent, 10, 1, 41, 7, image_base, 4, 256);
    var exact_proof: BundleSignatureProof = bundle_signature_proof_mint(&sig_auth, &exact, true);
    switch bundle_verify_and_admit_image(&exact, .Agent, 1, 8, 12, 7, move exact_proof, image_base, 4) {
        ok(vb) => {
            if !verified_bundle_has_exact_bytes(&vb) { pass = 0; }
            if verified_bundle_image_base(&vb) != image_base { pass = 0; }
            if verified_bundle_image_len(&vb) != 4 { pass = 0; }
            if !verified_bundle_matches_image(&vb, image_base, 4) { pass = 0; }
            if verified_bundle_matches_image(&vb, other_base, 4) { pass = 0; }
            unsafe { raw.store<u8>(phys(image_base + 2), 9); }
            if verified_bundle_matches_image(&vb, image_base, 4) { pass = 0; }
            unsafe { raw.store<u8>(phys(image_base + 2), 3); }
            unsafe { forget_unchecked(vb); }
        }
        err(e) => { pass = 0; }
    }
    var rejected_proof: BundleSignatureProof = bundle_signature_proof_mint(&sig_auth, &exact, false);
    switch bundle_verify_and_admit_image(&exact, .Agent, 1, 8, 12, 7, move rejected_proof, image_base, 4) {
        ok(vb) => {
            pass = 0;
            unsafe { forget_unchecked(vb); }
        }
        err(e) => {
            switch e {
                .BadSignature => {}
                _ => { pass = 0; }
            }
        }
    }
    exact.image_digest.bytes[0] = exact.image_digest.bytes[0] ^ 1;
    var bad_digest_proof: BundleSignatureProof = bundle_signature_proof_mint(&sig_auth, &exact, true);
    switch bundle_verify_and_admit_image(&exact, .Agent, 1, 8, 12, 7, move bad_digest_proof, image_base, 4) {
        ok(vb) => {
            pass = 0;
            unsafe { forget_unchecked(vb); }
        }
        err(e) => {
            switch e {
                .BadImageHash => {}
                _ => { pass = 0; }
            }
        }
    }

    agent.signature_len = 0;
    switch bundle_validate_metadata(&agent, .Agent, 1, 8, 12, 7) {
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
    switch bundle_validate_metadata(&agent, .Agent, 1, 8, 12, 7) {
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
    switch bundle_validate_metadata(&agent, .Agent, 1, 8, 12, 7) {
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
    if rollback_mark_boot_failed(&rb, 0) { pass = 0; }
    var next_agent: BundleHeader = bundle_header_init_for_image(.Agent, 12, 1, 41, 7, image_base, 4, 256);
    switch bundle_validate_metadata_hash(&next_agent, .Agent, 1, 8, 13, 7, exact_hash) {
        ok(v) => {
            if rollback_active_version(&rb) != 10 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }
    var next_agent_proof: BundleSignatureProof = bundle_signature_proof_mint(&sig_auth, &next_agent, true);
    switch bundle_verify_and_admit_image(&next_agent, .Agent, 1, 8, 13, 7, move next_agent_proof, image_base, 4) {
        ok(vb) => {
            let verified_slot: usize = rollback_install_verified_candidate(&rb, move vb);
            if verified_slot != 1 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }
    rollback_mark_boot_success(&rb);
    if rollback_active_version(&rb) != 12 { pass = 0; }
    rb.active = 2;
    if rollback_state_valid(&rb) { pass = 0; }
    if rollback_install_candidate(&rb, 13) != 2 { pass = 0; }
    if rollback_active_version(&rb) != 0 { pass = 0; }

    var wd: Watchdog = uninit;
    watchdog_arm(&wd, 100, 10);
    if watchdog_expired(&wd, 109) { pass = 0; }
    if !watchdog_expired(&wd, 110) { pass = 0; }
    watchdog_pet(&wd, 111);
    if watchdog_expired(&wd, 120) { pass = 0; }
    if !watchdog_expired(&wd, 121) { pass = 0; }
    // Deadline crosses u64::MAX: no checked-overflow trap and expiry is based
    // on the modular elapsed interval, not ordered absolute samples.
    watchdog_arm(&wd, 0xFFFF_FFFF_FFFF_FFFC, 8);
    if watchdog_expired(&wd, 3) { pass = 0; }
    if !watchdog_expired(&wd, 4) { pass = 0; }

    var rr: RebootRecord = reboot_record(3, .Watchdog, 44);
    if rr.boot_epoch != 3 { pass = 0; }
    switch rr.reason {
        .Watchdog => {}
        _ => { pass = 0; }
    }
    if rr.detail != 44 { pass = 0; }

    var ctl: AgentControlState = agent_control(10);
    policy_apply_runtime_action(&ctl, .Throttle);
    switch ctl.lifecycle { .Throttled => {} _ => { pass = 0; } }
    if ctl.budget != 5 { pass = 0; }
    policy_apply_runtime_action(&ctl, .Revoke);
    switch ctl.lifecycle { .Revoked => {} _ => { pass = 0; } }
    if ctl.budget != 0 { pass = 0; }
    policy_apply_runtime_action(&ctl, .Throttle);
    switch ctl.lifecycle { .Revoked => {} _ => { pass = 0; } }
    policy_apply_runtime_action(&ctl, .Kill);
    switch ctl.lifecycle { .Revoked => {} _ => { pass = 0; } }

    var killed: AgentControlState = agent_control(10);
    policy_apply_runtime_action(&killed, .Kill);
    policy_apply_runtime_action(&killed, .Throttle);
    policy_apply_runtime_action(&killed, .Allow);
    switch killed.lifecycle { .Killed => {} _ => { pass = 0; } }
    if killed.budget != 0 { pass = 0; }

    if action_code(.Allow) != 0 { pass = 0; }
    if action_code(.Throttle) != 1 { pass = 0; }
    if action_code(.Revoke) != 2 { pass = 0; }
    if action_code(.Kill) != 3 { pass = 0; }

    signature_authority_revoke(move sig_auth);
    return pass;
}
