# QuickJS-NG (vendored)

- **Upstream:** <https://github.com/quickjs-ng/quickjs> (QuickJS-NG repository)
- **Recorded version:** `0.15.1`, from `QJS_VERSION_MAJOR/MINOR/PATCH` in
  `quickjs.h`.
- **Recorded commit:** unknown. No upstream commit, archive checksum, or tag file is
  present in this tree.
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

No local patch markers are present in the vendored QuickJS files. The local build
adapts QuickJS through compiler flags and the all-MC libc/runtime, not by editing
the engine sources.

Because the exact upstream commit is unknown, the next QuickJS re-vendor must
record the tag/commit and source archive checksum before replacing this tree.

## How it is built and used

`tools/user/build-qjs.sh` compiles the four QuickJS translation units into cached
objects for the selected confined-agent target. The script is used by the
QuickJS QEMU gates and receives the caller's freestanding flags, including the
`third_party/quickjs` include path.

The engine is linked into confined user-mode QuickJS hosts such as
`examples/apps/qjs_agent.c`, `examples/apps/qjs_async_agent.c`, and the
architecture-specific QuickJS agent gates. It runs against the all-MC libc and
vendored openlibm rather than the upstream hosted `qjs` CLI environment.
