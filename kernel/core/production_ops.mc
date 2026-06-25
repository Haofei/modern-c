// kernel/core/production_ops — production control-plane primitives.
//
// These are host-testable, data-oriented pieces behind the production checklist: bundle
// admission, rollback decision state, watchdog/reboot reason reporting, and policy actuation.
// Hardware-specific reset and crypto verification remain behind callers, but the kernel-visible
// state transitions are explicit and gated here.

enum BundleKind {
    Kernel,
    Policy,
    Agent,
}

enum SignatureStatus {
    Valid,
    Missing,
    Bad,
    WrongKey,
}

enum BundleError {
    BadMagic,
    BadKind,
    BadAbi,
    BadVersion,
    BadSignature,
    WrongKey,
}

const BUNDLE_MAGIC: u32 = 0x4d43424e; // "MCBN"

struct BundleHeader {
    magic: u32,
    kind: BundleKind,
    version: u64,
    abi_version: u32,
    policy_version: u64,
    key_id: u32,
    image_hash: u64,
    signature_len: usize,
}

export fn bundle_header_init(kind: BundleKind, version: u64, abi_version: u32, policy_version: u64, key_id: u32, image_hash: u64, signature_len: usize) -> BundleHeader {
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

export fn bundle_validate(h: *BundleHeader, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32, sig: SignatureStatus) -> Result<bool, BundleError> {
    if h.magic != BUNDLE_MAGIC {
        return err(.BadMagic);
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
    switch sig {
        .Valid => { return ok(true); }
        .Missing => { return err(.BadSignature); }
        .Bad => { return err(.BadSignature); }
        .WrongKey => { return err(.WrongKey); }
    }
}

enum SlotState {
    Empty,
    Installed,
    Booting,
    Good,
    Failed,
}

struct UpdateSlot {
    version: u64,
    state: SlotState,
    failed_boots: u32,
}

struct RollbackState {
    active: usize,
    previous: usize,
    slots: [2]UpdateSlot,
}

export fn rollback_init(r: *mut RollbackState, version: u64) -> void {
    r.active = 0;
    r.previous = 0;
    r.slots[0].version = version;
    r.slots[0].state = .Good;
    r.slots[0].failed_boots = 0;
    r.slots[1].version = 0;
    r.slots[1].state = .Empty;
    r.slots[1].failed_boots = 0;
}

export fn rollback_install_candidate(r: *mut RollbackState, version: u64) -> usize {
    let candidate: usize = 1 - r.active;
    r.previous = r.active;
    r.active = candidate;
    r.slots[candidate].version = version;
    r.slots[candidate].state = .Booting;
    r.slots[candidate].failed_boots = 0;
    return candidate;
}

export fn rollback_mark_boot_success(r: *mut RollbackState) -> void {
    r.slots[r.active].state = .Good;
    r.slots[r.active].failed_boots = 0;
}

export fn rollback_mark_boot_failed(r: *mut RollbackState, max_failures: u32) -> bool {
    r.slots[r.active].failed_boots = r.slots[r.active].failed_boots + 1;
    r.slots[r.active].state = .Failed;
    if r.slots[r.active].failed_boots >= max_failures {
        r.active = r.previous;
        return true;
    }
    return false;
}

export fn rollback_active_version(r: *mut RollbackState) -> u64 {
    return r.slots[r.active].version;
}

enum RebootReason {
    PowerOn,
    Clean,
    Watchdog,
    Panic,
    UpdateRollback,
}

struct RebootRecord {
    boot_epoch: u64,
    reason: RebootReason,
    detail: u32,
}

struct Watchdog {
    armed: bool,
    deadline_tick: u64,
    last_pet_tick: u64,
    timeout_ticks: u64,
}

export fn watchdog_arm(w: *mut Watchdog, now: u64, timeout_ticks: u64) -> void {
    w.armed = true;
    w.last_pet_tick = now;
    w.timeout_ticks = timeout_ticks;
    w.deadline_tick = now + timeout_ticks;
}

export fn watchdog_pet(w: *mut Watchdog, now: u64) -> void {
    if w.armed {
        w.last_pet_tick = now;
        w.deadline_tick = now + w.timeout_ticks;
    }
}

export fn watchdog_expired(w: *mut Watchdog, now: u64) -> bool {
    if !w.armed {
        return false;
    }
    return now >= w.deadline_tick;
}

export fn reboot_record_set(r: *mut RebootRecord, boot_epoch: u64, reason: RebootReason, detail: u32) -> void {
    r.boot_epoch = boot_epoch;
    r.reason = reason;
    r.detail = detail;
}

enum RuntimeAction {
    Allow,
    Throttle,
    Revoke,
    Kill,
}

struct AgentControlState {
    running: bool,
    throttled: bool,
    revoked: bool,
    killed: bool,
    budget: u32,
}

export fn agent_control_init(s: *mut AgentControlState, budget: u32) -> void {
    s.running = true;
    s.throttled = false;
    s.revoked = false;
    s.killed = false;
    s.budget = budget;
}

export fn policy_apply_runtime_action(s: *mut AgentControlState, action: RuntimeAction) -> void {
    switch action {
        .Allow => {}
        .Throttle => {
            s.throttled = true;
            if s.budget > 1 {
                s.budget = s.budget / 2;
            }
        }
        .Revoke => {
            s.revoked = true;
            s.budget = 0;
        }
        .Kill => {
            s.killed = true;
            s.running = false;
            s.revoked = true;
            s.budget = 0;
        }
    }
}
