// kernel/core/production_ops — production control-plane primitives.
//
// These are host-testable, data-oriented pieces behind the production checklist: bundle
// admission, rollback decision state, watchdog/reboot reason reporting, and policy actuation.
// Hardware-specific reset and crypto verification remain behind callers, but the kernel-visible
// state transitions are explicit and gated here.

import "std/math.mc";

pub enum BundleKind {
    Kernel,
    Policy,
    Agent,
}

pub enum BundleError {
    BadMagic,
    BadKind,
    BadAbi,
    BadVersion,
    BadSignature,
    WrongKey,
}

const BUNDLE_MAGIC: u32 = 0x4d43424e; // "MCBN"

pub struct BundleHeader {
    magic: u32,
    kind: BundleKind,
    version: u64,
    abi_version: u32,
    policy_version: u64,
    key_id: u32,
    image_hash: u64,
    signature_len: usize,
}

pub fn bundle_header_init(kind: BundleKind, version: u64, abi_version: u32, policy_version: u64, key_id: u32, image_hash: u64, signature_len: usize) -> BundleHeader {
    return .{
        .magic = BUNDLE_MAGIC,
        .kind = kind,
        .version = version,
        .abi_version = abi_version,
        .policy_version = policy_version,
        .key_id = key_id,
        .image_hash = image_hash,
        .signature_len = signature_len,
    };
}

fn bundle_kind_matches(actual: BundleKind, expected: BundleKind) -> bool {
    switch expected {
        .Kernel => {
            switch actual {
                .Kernel => { return true; }
                _ => { return false; }
            }
        }
        .Policy => {
            switch actual {
                .Policy => { return true; }
                _ => { return false; }
            }
        }
        .Agent => {
            switch actual {
                .Agent => { return true; }
                _ => { return false; }
            }
        }
    }
}

// Validate canonical bundle metadata only. Cryptographic verification is a
// separate primitive in kernel/crypto/rsa_verify.mc; the future opaque
// VerifiedBundle integration must bind its exact verified bytes to the loader.
// Callers cannot inject a `.Valid` enum into this metadata state machine.
pub fn bundle_validate_metadata(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32) -> Result<bool, BundleError> {
    if h.magic != BUNDLE_MAGIC {
        return err(.BadMagic);
    }
    if !bundle_kind_matches(h.kind, expected_kind) {
        return err(.BadKind);
    }
    if h.abi_version != expected_abi {
        return err(.BadAbi);
    }
    if h.version < min_version {
        return err(.BadVersion);
    }
    if h.version > max_version {
        return err(.BadVersion);
    }
    if h.key_id != trusted_key_id {
        return err(.WrongKey);
    }
    if h.signature_len == 0 {
        return err(.BadSignature);
    }
    return ok(true);
}

pub fn bundle_image_hash_matches(h: *BundleHeader, expected_hash: u64) -> bool {
    return h.image_hash == expected_hash;
}

pub enum SlotState {
    Empty,
    Installed,
    Booting,
    Good,
    Failed,
}

pub struct UpdateSlot {
    version: u64,
    state: SlotState,
    failed_boots: u32,
}

pub struct RollbackState {
    active: usize,
    previous: usize,
    slots: [2]UpdateSlot,
}

pub fn rollback_state_valid(r: *RollbackState) -> bool {
    return r.active < 2 && r.previous < 2;
}

pub fn rollback_init(r: *mut RollbackState, version: u64) -> void {
    r.active = 0;
    r.previous = 0;
    r.slots[0].version = version;
    r.slots[0].state = .Good;
    r.slots[0].failed_boots = 0;
    r.slots[1].version = 0;
    r.slots[1].state = .Empty;
    r.slots[1].failed_boots = 0;
}

pub fn rollback_install_candidate(r: *mut RollbackState, version: u64) -> usize {
    if !rollback_state_valid(r) {
        return 2; // invalid-slot sentinel; never index or subtract corrupt state
    }
    let candidate: usize = 1 - r.active;
    r.previous = r.active;
    r.active = candidate;
    r.slots[candidate].version = version;
    r.slots[candidate].state = .Booting;
    r.slots[candidate].failed_boots = 0;
    return candidate;
}

pub fn rollback_mark_boot_success(r: *mut RollbackState) -> void {
    if !rollback_state_valid(r) {
        return;
    }
    r.slots[r.active].state = .Good;
    r.slots[r.active].failed_boots = 0;
}

pub fn rollback_mark_boot_failed(r: *mut RollbackState, max_failures: u32) -> bool {
    if !rollback_state_valid(r) {
        return false;
    }
    if r.slots[r.active].failed_boots != 0xFFFF_FFFF {
        r.slots[r.active].failed_boots = r.slots[r.active].failed_boots + 1;
    }
    r.slots[r.active].state = .Failed;
    if r.slots[r.active].failed_boots >= max_failures {
        r.active = r.previous;
        return true;
    }
    return false;
}

pub fn rollback_active_version(r: *mut RollbackState) -> u64 {
    if !rollback_state_valid(r) {
        return 0;
    }
    return r.slots[r.active].version;
}

pub enum RebootReason {
    PowerOn,
    Clean,
    Watchdog,
    Panic,
    UpdateRollback,
}

pub struct RebootRecord {
    boot_epoch: u64,
    reason: RebootReason,
    detail: u32,
}

pub struct Watchdog {
    armed: bool,
    deadline_tick: u64,
    last_pet_tick: u64,
    timeout_ticks: u64,
}

pub fn watchdog_arm(w: *mut Watchdog, now: u64, timeout_ticks: u64) -> void {
    w.armed = true;
    w.last_pet_tick = now;
    w.timeout_ticks = timeout_ticks;
    w.deadline_tick = wrapping_add_u64(now, timeout_ticks);
}

pub fn watchdog_pet(w: *mut Watchdog, now: u64) -> void {
    if w.armed {
        w.last_pet_tick = now;
        w.deadline_tick = wrapping_add_u64(now, w.timeout_ticks);
    }
}

pub fn watchdog_expired(w: *mut Watchdog, now: u64) -> bool {
    if !w.armed {
        return false;
    }
    // Compare elapsed modular time rather than absolute samples. This remains
    // correct across one u64 wrap as long as the caller's timeout is within the
    // counter ambiguity window, which is the watchdog contract.
    return wrapping_sub_u64(now, w.last_pet_tick) >= w.timeout_ticks;
}

pub fn reboot_record(boot_epoch: u64, reason: RebootReason, detail: u32) -> RebootRecord {
    return .{ .boot_epoch = boot_epoch, .reason = reason, .detail = detail };
}

pub fn reboot_record_set(r: *mut RebootRecord, boot_epoch: u64, reason: RebootReason, detail: u32) -> void {
    r.boot_epoch = boot_epoch;
    r.reason = reason;
    r.detail = detail;
}

pub enum RuntimeAction {
    Allow,
    Throttle,
    Revoke,
    Kill,
}

pub enum AgentLifecycle {
    Running,
    Throttled,
    Revoked,
    Killed,
}

pub struct AgentControlState {
    lifecycle: AgentLifecycle,
    budget: u32,
}

pub fn agent_control(budget: u32) -> AgentControlState {
    return .{ .lifecycle = .Running, .budget = budget };
}

pub fn agent_control_init(s: *mut AgentControlState, budget: u32) -> void {
    s.lifecycle = .Running;
    s.budget = budget;
}

pub fn policy_apply_runtime_action(s: *mut AgentControlState, action: RuntimeAction) -> void {
    switch action {
        .Allow => {}
        .Throttle => {
            s.lifecycle = .Throttled;
            if s.budget > 1 {
                s.budget = s.budget / 2;
            }
        }
        .Revoke => {
            s.lifecycle = .Revoked;
            s.budget = 0;
        }
        .Kill => {
            s.lifecycle = .Killed;
            s.budget = 0;
        }
    }
}
