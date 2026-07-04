# QuickJS-NG (vendored)

- **Upstream:** <https://github.com/quickjs-ng/quickjs> (QuickJS-NG repository)
- **Recorded version:** `0.15.1`, from `QJS_VERSION_MAJOR/MINOR/PATCH` in
  `quickjs.h`.
- **Recorded tag:** `v0.15.1`.
- **Recorded commit:** `fd0a0210b7be00957751871e7e01b8291268fc29`.
- **Source archive:** <https://github.com/quickjs-ng/quickjs/archive/refs/tags/v0.15.1.tar.gz>.
- **Archive SHA-256:**
  `c4e813951b7c46845096a948e978c620b11ab4cf5fd622ca09c727ec31f42623`.
- **License:** MIT (see `LICENSE`)

## What is kept

Only the engine files needed by the confined QuickJS app path are kept:

- `quickjs.c`, `libregexp.c`, `libunicode.c`, and `dtoa.c`.
- Public/internal headers required by those translation units, including
  `quickjs.h`, `quickjs-libc.h`, `quickjs-opcode.h`, `quickjs-atom.h`,
  `quickjs-c-atomics.h`, `libregexp*.h`, `libunicode*.h`, `dtoa.h`,
  `cutils.h`, and `list.h`.
- Generated builtin tables required by the engine sources.
- `LICENSE`.

Upstream command-line tools, examples, tests, build-system files, documentation,
and generated tables not referenced by this subset were dropped.

## Local modifications

All retained files match upstream tag `v0.15.1` at
`fd0a0210b7be00957751871e7e01b8291268fc29` except `quickjs.h`.

The local `quickjs.h` patch narrows two GNU-like visibility macros for the
freestanding/static build:

- `JS_EXTERN` uses default visibility only when both `BUILDING_QJS_SHARED` and
  `QUICKJS_NG_CC_GNULIKE` are defined.
- `JS_MODULE_EXTERN` uses default visibility only when both
  `QUICKJS_NG_MODULE_BUILD` and `QUICKJS_NG_CC_GNULIKE` are defined.

This keeps the confined-agent static build from exporting all QuickJS symbols
only because the compiler is GNU-like. The local build otherwise adapts QuickJS
through compiler flags and the all-MC libc/runtime.

## How it is built and used

`tools/user/build-qjs.sh` compiles the four QuickJS translation units into cached
objects for the selected confined-agent target. The script is used by the
QuickJS QEMU gates and receives the caller's freestanding flags, including the
`third_party/quickjs` include path.

The engine is linked into confined user-mode QuickJS hosts such as
`examples/apps/qjs_agent.c`, `examples/apps/qjs_async_agent.c`, and the
architecture-specific QuickJS agent gates. It runs against the all-MC libc and
vendored openlibm rather than the upstream hosted `qjs` CLI environment.
