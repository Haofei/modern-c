# BearSSL (vendored)

- **Upstream:** <https://www.bearssl.org/git/BearSSL> (official repository)
- **Commit:** `7bea48e5e850ab4cafbe68d3765cdaba13a86d6f` (2026-04-06)
- **License:** MIT (see `LICENSE.txt`)

## What is kept

Only what is needed to build BearSSL into the bare-metal MC kernel:

- `src/` — the BearSSL C sources (294 `.c` files).
- `inc/` — the public headers (`bearssl*.h`).
- `LICENSE.txt` — the upstream MIT license.
- `freestanding-shim/string.h` — **added by us**, not upstream. A minimal
  freestanding `<string.h>` declaring `memcpy/memmove/memset/memcmp/strlen`,
  needed because the hosted `<string.h>` is unavailable under
  `--target=riscv64-unknown-elf -ffreestanding -nostdlib`. The definitions are
  provided by the kernel runtime (`kernel/drivers/virtio/bearssl_smoke_runtime.c`).

Upstream `tools/`, `test/`, `samples/`, `T0/`, `build/`, `mk/`, `conf/`, the
`Makefile`/`Doxyfile`/`README.txt` were dropped to keep the tree lean. They are
not needed to build/link/run BearSSL crypto freestanding; re-clone upstream if
`tools/brssl` is ever wanted.

## How it is built freestanding

Compiled with the kernel's riscv64 freestanding flags plus:

```
-DBR_USE_UNIX_TIME=0 -DBR_USE_WIN32_TIME=0 -DBR_USE_URANDOM=0 -DBR_USE_GETENTROPY=0
-I third_party/bearssl/freestanding-shim -I third_party/bearssl/inc -I third_party/bearssl/src
```

The `BR_USE_*=0` defines stop BearSSL pulling in any OS time/entropy source — the
MC kernel provides its own (virtio-rng + a build-epoch clock seam). All 294 `.c`
files compile cleanly; nothing in BearSSL was patched.

See `tools/tls/bearssl-smoke-test.sh` for the full build + QEMU smoke test.
