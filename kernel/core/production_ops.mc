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
    BadImageHash,
}

const BUNDLE_MAGIC: u32 = 0x4d43424e; // "MCBN"
const BUNDLE_FNV_OFFSET: u32 = 0x811c9dc5;
const BUNDLE_FNV_PRIME: u32 = 0x0100_0193;

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

// Opaque admission token for a bundle whose metadata and expected image digest
// have been checked together. The legacy metadata bridge can still create a
// token with no byte identity, but production-shaped admission must use
// `bundle_verify_and_admit_image`, which binds the exact byte range and digest
// consumed by the loader. The digest is still the FNV-era u64 image_hash bridge;
// the cryptographic secure-boot path must replace that with a real SHA-256
// digest over immutable storage bytes without weakening the token shape.
pub linear opaque struct VerifiedBundle {
    kind: BundleKind,
    version: u64,
    abi_version: u32,
    policy_version: u64,
    key_id: u32,
    image_hash: u64,
    image_base: usize,
    image_len: usize,
    exact_bytes: bool,
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

fn bundle_wrap_mul_u32(a: u32, b: u32) -> u32 {
    return (((a as u64) * (b as u64)) & 0x0000_0000_FFFF_FFFF) as u32;
}

fn bundle_fnv_step(h: u32, byte: u8) -> u32 {
    let mixed: u32 = h ^ (byte as u32);
    return bundle_wrap_mul_u32(mixed, BUNDLE_FNV_PRIME);
}

fn bundle_image_range_valid(base: usize, len: usize) -> bool {
    if len == 0 {
        return true;
    }
    let usize_max: usize = 0xFFFF_FFFF_FFFF_FFFF as usize;
    return base <= usize_max - len;
}

pub fn bundle_hash_bytes(base: usize, len: usize) -> u64 {
    var h: u32 = BUNDLE_FNV_OFFSET;
    var i: usize = 0;
    while i < len {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        h = bundle_fnv_step(h, b);
        i = i + 1;
    }
    return h as u64;
}

impl VerifiedBundle {
    fn admit(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32, expected_image_hash: u64) -> Result<VerifiedBundle, BundleError> {
        switch bundle_validate_metadata(h, expected_kind, expected_abi, min_version, max_version, trusted_key_id) {
            ok(v) => {}
            err(e) => { return err(e); }
        }
        if h.image_hash != expected_image_hash {
            return err(.BadImageHash);
        }
        return ok(.{
            .kind = h.kind,
            .version = h.version,
            .abi_version = h.abi_version,
            .policy_version = h.policy_version,
            .key_id = h.key_id,
            .image_hash = h.image_hash,
            .image_base = 0,
            .image_len = 0,
            .exact_bytes = false,
        });
    }

    fn admit_image(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32, image_base: usize, image_len: usize) -> Result<VerifiedBundle, BundleError> {
        switch bundle_validate_metadata(h, expected_kind, expected_abi, min_version, max_version, trusted_key_id) {
            ok(v) => {}
            err(e) => { return err(e); }
        }
        if !bundle_image_range_valid(image_base, image_len) {
            return err(.BadImageHash);
        }
        let actual_hash: u64 = bundle_hash_bytes(image_base, image_len);
        if h.image_hash != actual_hash {
            return err(.BadImageHash);
        }
        return ok(.{
            .kind = h.kind,
            .version = h.version,
            .abi_version = h.abi_version,
            .policy_version = h.policy_version,
            .key_id = h.key_id,
            .image_hash = h.image_hash,
            .image_base = image_base,
            .image_len = image_len,
            .exact_bytes = true,
        });
    }

    fn kind(v: *VerifiedBundle) -> BundleKind {
        return v.kind;
    }
    fn version(v: *VerifiedBundle) -> u64 {
        return v.version;
    }
    fn image_hash(v: *VerifiedBundle) -> u64 {
        return v.image_hash;
    }
    fn key_id(v: *VerifiedBundle) -> u32 {
        return v.key_id;
    }
    fn image_base(v: *VerifiedBundle) -> usize {
        return v.image_base;
    }
    fn image_len(v: *VerifiedBundle) -> usize {
        return v.image_len;
    }
    fn has_exact_bytes(v: *VerifiedBundle) -> bool {
        return v.exact_bytes;
    }
}

pub fn bundle_verify_and_admit_metadata(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32, expected_image_hash: u64) -> Result<VerifiedBundle, BundleError> {
    return VerifiedBundle.admit(h, expected_kind, expected_abi, min_version, max_version, trusted_key_id, expected_image_hash);
}

pub fn bundle_verify_and_admit_image(h: *BundleHeader, expected_kind: BundleKind, expected_abi: u32, min_version: u64, max_version: u64, trusted_key_id: u32, image_base: usize, image_len: usize) -> Result<VerifiedBundle, BundleError> {
    return VerifiedBundle.admit_image(h, expected_kind, expected_abi, min_version, max_version, trusted_key_id, image_base, image_len);
}

pub fn verified_bundle_kind(v: *VerifiedBundle) -> BundleKind {
    return VerifiedBundle.kind(v);
}

pub fn verified_bundle_version(v: *VerifiedBundle) -> u64 {
    return VerifiedBundle.version(v);
}

pub fn verified_bundle_image_hash(v: *VerifiedBundle) -> u64 {
    return VerifiedBundle.image_hash(v);
}

pub fn verified_bundle_key_id(v: *VerifiedBundle) -> u32 {
    return VerifiedBundle.key_id(v);
}

pub fn verified_bundle_has_exact_bytes(v: *VerifiedBundle) -> bool {
    return VerifiedBundle.has_exact_bytes(v);
}

pub fn verified_bundle_image_base(v: *VerifiedBundle) -> usize {
    return VerifiedBundle.image_base(v);
}

pub fn verified_bundle_image_len(v: *VerifiedBundle) -> usize {
    return VerifiedBundle.image_len(v);
}

pub fn verified_bundle_matches_image(v: *VerifiedBundle, image_base: usize, image_len: usize) -> bool {
    if !VerifiedBundle.has_exact_bytes(v) {
        return false;
    }
    if image_base != VerifiedBundle.image_base(v) {
        return false;
    }
    if image_len != VerifiedBundle.image_len(v) {
        return false;
    }
    if !bundle_image_range_valid(image_base, image_len) {
        return false;
    }
    return bundle_hash_bytes(image_base, image_len) == VerifiedBundle.image_hash(v);
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
    if r.active >= 2 || r.previous >= 2 {
        return false;
    }
    // The fallback must always name a previously admitted, bootable image.
    // Otherwise a damaged persistent record could "roll back" into Empty,
    // Booting, or Failed state.
    if r.slots[r.previous].state != .Good {
        return false;
    }
    // The active slot is either the known-good fallback itself or a candidate
    // currently being tried. Empty/Failed cannot be an active boot target.
    let active_state: SlotState = r.slots[r.active].state;
    return active_state == .Good || active_state == .Booting;
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

pub fn rollback_install_verified_candidate(r: *mut RollbackState, bundle: VerifiedBundle) -> usize {
    let exact: bool = VerifiedBundle.has_exact_bytes(&bundle);
    let version: u64 = VerifiedBundle.version(&bundle);
    unsafe { forget_unchecked(bundle); } // installation consumes the admission token
    if !exact {
        return 2; // metadata-only admission is not enough to install a boot candidate
    }
    return rollback_install_candidate(r, version);
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
    if max_failures == 0 {
        return false;
    }
    if r.slots[r.active].failed_boots != 0xFFFF_FFFF {
        r.slots[r.active].failed_boots = r.slots[r.active].failed_boots + 1;
    }
    if r.slots[r.active].failed_boots >= max_failures {
        r.slots[r.active].state = .Failed;
        r.active = r.previous;
        return true;
    }
    r.slots[r.active].state = .Booting;
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
    // Revoked and Killed are terminal. Later policy messages may be delayed or
    // duplicated, but they must never resurrect the subject.
    if s.lifecycle == .Revoked || s.lifecycle == .Killed {
        return;
    }
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
