// kernel/lib/supervisor — a static service supervisor (MINIX reincarnation-server style).
// Services register at boot with a declarative manifest: their privileges (allowed IPC peers
// and kernel calls) and policy (restart, scheduling) are DATA, not scattered hand-coded
// checks. The supervisor tracks each service's state and restarts failed *non-core* services
// per policy. This is the foundation for pluggable user-space OS services.

import "std/mask.mc";
import "kernel/lib/registry.mc";

const SVC_MAX: usize = 8;

pub enum RestartPolicy {
    Never,     // a core service: failure is fatal, do not restart
    OnFailure, // restart automatically if it fails
}

pub enum SvcState {
    Registered, // known, not yet started
    Running,
    Failed,     // crashed; eligible for restart per its policy
    Stopped,    // intentionally stopped
}

pub enum SvcError {
    Full,
    NotFound,
    Fatal,          // a core (Never) service failed; not restartable
    DepUnsatisfied, // a service's declared dependency is missing or forms a cycle
}

// Declarative service manifest: identity, endpoint, privileges, and policy as data.
pub struct ServiceManifest {
    name_key: u32,          // service-name hash / id (also the registry lookup key)
    endpoint: u32,          // the service's IPC endpoint (pid) once started
    allowed_ipc: Mask32,    // peers this service may message (least privilege)
    allowed_kcalls: Mask32, // kernel calls this service may invoke
    restart: RestartPolicy,
    priority: u32,          // scheduling policy hint
}

struct ServiceEntry {
    manifest: ServiceManifest,
    spawn: closure() -> u32, // (re)spawn this service, returning its new endpoint (pid)
    state: SvcState,
    restarts: u32, // how many times it has been restarted
    present: bool,
}

pub struct Supervisor {
    services: [SVC_MAX]ServiceEntry,
    // Per-service dependency: the name_key of a service that must be Running first (0 = none).
    // Kept parallel to `services` so the manifest stays unchanged.
    deps: [SVC_MAX]u32,
    count: usize,
}

pub fn supervisor_init(sup: *mut Supervisor) -> void {
    var i: usize = 0;
    while i < SVC_MAX {
        sup.services[i].present = false;
        sup.deps[i] = 0;
        i = i + 1;
    }
    sup.count = 0;
}

// Declare that the service at `idx` depends on the service named `dep_name_key` — it will not be
// started until that dependency is Running. `dep_name_key == 0` clears the dependency.
pub fn supervisor_set_dep(sup: *mut Supervisor, idx: usize, dep_name_key: u32) -> Result<bool, SvcError> {
    if idx >= sup.count {
        return err(.NotFound);
    }
    sup.deps[idx] = dep_name_key;
    return ok(true);
}

// Start all registered services in dependency order: a service is spawned (its closure invoked
// for a fresh endpoint) and marked Running only once its declared dependency is Running. Repeats
// until no further progress; any service still Registered then has a missing or cyclic
// dependency (`DepUnsatisfied`). Returns the number of services started.
pub fn supervisor_start_ordered(sup: *mut Supervisor) -> Result<usize, SvcError> {
    var started: usize = 0;
    var progress: bool = true;
    while progress {
        progress = false;
        var i: usize = 0;
        while i < sup.count {
            if sup.services[i].present {
                if sup.services[i].state == .Registered {
                    let dep: u32 = sup.deps[i];
                    var ready: bool = dep == 0;
                    if !ready {
                        switch supervisor_find(sup, dep) {
                            ok(di) => {
                                if sup.services[di].state == .Running {
                                    ready = true;
                                }
                            }
                            err(e) => {
                                return err(.DepUnsatisfied); // depends on an unregistered service
                            }
                        }
                    }
                    if ready {
                        let sp: closure() -> u32 = sup.services[i].spawn;
                        sup.services[i].manifest.endpoint = sp();
                        sup.services[i].state = .Running;
                        started = started + 1;
                        progress = true;
                    }
                }
            }
            i = i + 1;
        }
    }
    // Anything still Registered could not be ordered: a dependency cycle (or an unstartable dep).
    var j: usize = 0;
    while j < sup.count {
        if sup.services[j].present {
            if sup.services[j].state == .Registered {
                return err(.DepUnsatisfied);
            }
        }
        j = j + 1;
    }
    return ok(started);
}

pub fn supervisor_count(sup: *mut Supervisor) -> usize {
    return sup.count;
}

// Register a service by manifest + a spawn closure (how to (re)spawn it, returning the new
// endpoint). Returns its index, or Full.
pub fn supervisor_register(sup: *mut Supervisor, m: ServiceManifest, spawn: closure() -> u32) -> Result<usize, SvcError> {
    var i: usize = 0;
    while i < SVC_MAX {
        if !sup.services[i].present {
            sup.services[i].manifest = m;
            sup.services[i].spawn = spawn;
            sup.services[i].state = .Registered;
            sup.services[i].restarts = 0;
            sup.services[i].present = true;
            sup.count = sup.count + 1;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.Full);
}

// Find a registered service's index by its name key.
pub fn supervisor_find(sup: *mut Supervisor, name_key: u32) -> Result<usize, SvcError> {
    var i: usize = 0;
    while i < SVC_MAX {
        if sup.services[i].present {
            if sup.services[i].manifest.name_key == name_key {
                return ok(i);
            }
        }
        i = i + 1;
    }
    return err(.NotFound);
}

// Resolve a service's endpoint by name (discovery for clients).
pub fn supervisor_lookup(sup: *mut Supervisor, name_key: u32) -> Result<u32, SvcError> {
    switch supervisor_find(sup, name_key) {
        ok(i) => {
            return ok(sup.services[i].manifest.endpoint);
        }
        err(e) => {
            return err(.NotFound);
        }
    }
}

pub fn supervisor_state(sup: *mut Supervisor, idx: usize) -> SvcState {
    if idx < sup.count {
        return sup.services[idx].state;
    }
    return .Stopped;
}

pub fn supervisor_restarts(sup: *mut Supervisor, idx: usize) -> u32 {
    if idx < sup.count {
        return sup.services[idx].restarts;
    }
    return 0;
}

// Declarative privileges, queryable from the manifest (data, not scattered checks): the
// allowed-IPC and allowed-kcall masks a privilege check would consult, and the endpoint.
pub fn supervisor_endpoint(sup: *mut Supervisor, idx: usize) -> u32 {
    if idx < sup.count {
        return sup.services[idx].manifest.endpoint;
    }
    return 0;
}
pub fn supervisor_allowed_ipc(sup: *mut Supervisor, idx: usize) -> u32 {
    if idx < sup.count {
        return mask32_raw(&sup.services[idx].manifest.allowed_ipc);
    }
    return 0;
}
pub fn supervisor_allowed_kcalls(sup: *mut Supervisor, idx: usize) -> u32 {
    if idx < sup.count {
        return mask32_raw(&sup.services[idx].manifest.allowed_kcalls);
    }
    return 0;
}

// Mark a service as started (Running).
pub fn supervisor_start(sup: *mut Supervisor, idx: usize) -> Result<bool, SvcError> {
    if idx >= sup.count {
        return err(.NotFound);
    }
    sup.services[idx].state = .Running;
    return ok(true);
}

// Record that a service crashed.
pub fn supervisor_mark_failed(sup: *mut Supervisor, idx: usize) -> Result<bool, SvcError> {
    if idx >= sup.count {
        return err(.NotFound);
    }
    sup.services[idx].state = .Failed;
    return ok(true);
}

// Actually respawn a service: invoke its spawn closure for a fresh endpoint, point the
// manifest at it, and update the registry (drop the dead endpoint's entries, register the new
// one under the service name) so clients resolve the new incarnation.
fn respawn_entry(p: *mut ServiceEntry, reg: *mut Registry) -> void {
    let old_ep: u32 = p.manifest.endpoint;
    let sp: closure() -> u32 = p.spawn;
    let new_ep: u32 = sp();
    p.manifest.endpoint = new_ep;
    p.state = .Running;
    p.restarts = p.restarts + 1;
    registry_unregister_endpoint(reg, old_ep);
    switch registry_add(reg, p.manifest.name_key, new_ep, 0) {
        ok(s) => {}
        err(e) => {}
    }
}

// Restart one failed service if its policy permits (respawning it and updating the registry);
// Fatal for a core (Never) service.
pub fn supervisor_restart(sup: *mut Supervisor, idx: usize, reg: *mut Registry) -> Result<bool, SvcError> {
    if idx >= sup.count {
        return err(.NotFound);
    }
    let p: *mut ServiceEntry = &sup.services[idx];
    let policy: RestartPolicy = p.manifest.restart;
    switch policy {
        .Never => {
            return err(.Fatal); // core service: not restartable
        }
        .OnFailure => {
            respawn_entry(p, reg);
            return ok(true);
        }
    }
}

// Supervise: respawn every Failed service whose policy is OnFailure (updating the registry);
// return how many were restarted. Core (Never) services that have failed are left Failed.
pub fn supervisor_tick(sup: *mut Supervisor, reg: *mut Registry) -> usize {
    var restarted: usize = 0;
    var i: usize = 0;
    while i < sup.count {
        let p: *mut ServiceEntry = &sup.services[i];
        if p.state == .Failed {
            let policy: RestartPolicy = p.manifest.restart;
            switch policy {
                .Never => {}
                .OnFailure => {
                    respawn_entry(p, reg);
                    restarted = restarted + 1;
                }
            }
        }
        i = i + 1;
    }
    return restarted;
}
