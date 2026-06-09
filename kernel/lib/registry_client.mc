// kernel/lib/registry_client — the discovery side of the registry. A client (a service or
// userland) resolves a device-class or named endpoint by key, with typed errors, and can
// check availability before binding. Pairs with kernel/lib/registry (the registration
// side): registry.mc is the write API (drivers/services register), this is the read API
// (clients look up), so "find my dependency" lives in one place.

import "kernel/lib/registry.mc";

enum LookupError {
    Unavailable, // nothing registered for the key
}

// Resolve the endpoint registered for `key`, or Unavailable.
export fn lookup(reg: *mut Registry, key: u32) -> Result<u32, LookupError> {
    switch registry_find(reg, key) {
        ok(ep) => {
            return ok(ep);
        }
        err(e) => {
            return err(.Unavailable);
        }
    }
}

// True if some endpoint is registered for `key` (a readiness check before binding).
export fn available(reg: *mut Registry, key: u32) -> bool {
    switch registry_find(reg, key) {
        ok(ep) => {
            return true;
        }
        err(e) => {
            return false;
        }
    }
}
