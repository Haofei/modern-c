// BearSSL in-kernel crypto smoke test (Phase 1 TLS de-risking) -- placeholder.
//
// The smoke logic (SHA-256 vector check via BearSSL, the virtio-rng entropy
// driver, the clock seam, and the bare-metal entry point) is implemented in C in
// kernel/drivers/virtio/bearssl_smoke_runtime.c. It is C-only on purpose: BearSSL
// is C, the device glue is tiny, and keeping it in the runtime avoids any MC
// backend concerns for the de-risking phase. See tools/tls/bearssl-smoke-test.sh.
//
// This file exists so the smoke test has a home under tests/qemu/tls/ alongside
// the other QEMU demos; it carries no logic yet. The TLS bridge (next phase) will
// add the MC-side surface here.

fn bearssl_smoke_placeholder() -> i32 {
    return 0;
}
