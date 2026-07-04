# Backend abstraction

`src/backend.zig` defines the `Backend` interface: the seam at which `mcc`
selects a code-generation target and invokes top-level lowering. The two
built-in backends — the C emitter (`src/lower_c.zig`, `emit-c`/`emit-map`) and
the LLVM emitter (`src/lower_llvm.zig`, `emit-llvm`) — both register through
this interface. `src/main.zig` uses that registry for generic backend entry
points such as `emit-map`; the hot `emit-c` and `emit-llvm` CLI paths build and
verify MIR once, then call backend-specific prebuilt-MIR helpers so verification
and lowering consume the same MIR instance.

## What it abstracts (and what it does not)

This is the **entry seam** only:

- backend **selection** (registry lookup by name), and
- the top-level **`module -> textual artifact`** call (and, for the C backend,
  source-map emission).

It does **not** unify per-construct emission. How each statement, expression, or
type is rendered is still implemented privately inside each `lower_*.zig`
module. A new backend writes its own per-construct emission today; this
interface is just where it plugs into the CLI. Deeper sharing of emission logic
is a separate, incremental effort.

## The contract (`Backend`)

```zig
pub const LowerOptions = struct {
    profile: Profile,              // TARGET axis: kernel | hosted (honored iff supports_profiles)
    source_path: ?[]const u8,      // embedded in #line / !DILocation; null => backend default
    target_arch: TargetArch = .riscv64,
    checks: Checks = .{},          // build-safety + sanitizer axis:
                                   //   optimize, ksan, msan, csan
    stub_asm: bool = false,        // test-only inline-asm host stub mode
    reporter: ?*diagnostics.Reporter = null, // backend diagnostics become source-spanned
};

pub const Backend = struct {
    name: []const u8,           // CLI/registry id: "c", "llvm"
    artifact_ext: []const u8,   // ".c", ".ll"
    supports_profiles: bool,    // c=true, llvm=false
    ctx: *anyopaque,            // opaque per-backend state (built-ins: undefined)
    lowerFn: *const fn (ctx, allocator, ast.Module, *ArrayList(u8), LowerOptions) anyerror!void,
    emitMapFn: ?*const fn (ctx, allocator, ast.Module, *ArrayList(u8), Profile, []const u8) anyerror!void = null,

    pub fn lower(...) anyerror!void;        // calls lowerFn(ctx, ...)
    pub fn supportsEmitMap(self) bool;      // emitMapFn != null
    pub fn emitMap(...) anyerror!void;      // calls emitMapFn.?(ctx, ...)
};

pub fn byName(name: []const u8) ?Backend;   // registry lookup
pub fn all() [N]Backend;                    // all built-ins
```

Field/method rationale:

- **`name`** — the registry id used by `Backend.byName` and generic callers.
  Current CLI code uses it directly for `emit-map`; `emit-c` and `emit-llvm`
  use backend-specific prebuilt-MIR helpers after resolving their command-line
  options.
- **`artifact_ext`** — the conventional output extension; metadata a driver can
  use without knowing the backend.
- **`supports_profiles`** — the C backend has kernel/hosted profiles; the LLVM
  backend ignores `profile`. The flag lets callers reason about this instead of
  guessing. (The LLVM backend simply ignores `opts.profile`.)
- **`checks`** — the build-safety and sanitizer axis. `checks.optimize` selects
  SAFE (`--checks=all`, default) vs RELEASE (`--checks=elide-proven`);
  `checks.ksan`/`msan`/`csan` select the sanitizer instrumentation profiles.
- **`target_arch`** — backend ABI details that are architecture-shaped rather
  than import-shaped. LLVM uses it for target triple/data-layout and ABI details.
- **`stub_asm`** — test-only lowering mode for host-native execution of target
  inline assembly fixtures.
- **`reporter`** — lets backends report expected unsupported lowering as
  source-spanned diagnostics instead of raw backend errors.
- **`ctx` / `*anyopaque`** — the idiomatic Zig vtable shape. Built-in backends
  are stateless and pass `undefined`; a stateful backend can carry context
  without changing the interface.
- **`lowerFn` / `lower`** — the one mandatory operation: append the textual
  artifact for a module to `out`. C routes to `appendCProfileWithOptions`; LLVM
  routes to `appendLlvmCheckedReport`. Those compatibility paths build MIR
  internally and then call the `*WithMir` emitters. The CLI `emit-c` and
  `emit-llvm` paths bypass that extra build by calling `appendCProfileWithMir` /
  `appendLlvmCheckedMir` after `main.zig` has built and verified MIR once.
- **`emitMapFn` / `supportsEmitMap` / `emitMap`** — optional source-map
  capability. Only the C backend supplies it (`emit-map`); LLVM leaves it null
  rather than faking an unsupported artifact.

## How `main.zig` dispatches

The CLI surface is unchanged. There are two entry styles:

- `emit-c` builds optimized MIR once, verifies it with `mir.verifyBuiltMir`, then
  calls `lower_c.appendCProfileWithMir(.., checks, stub_asm, reporter)`.
- `emit-llvm` builds optimized MIR once, verifies it with `mir.verifyBuiltMir`,
  then calls `lower_llvm.appendLlvmCheckedMir(.., checks, stub_asm, target_arch,
  reporter)`.
- `emit-map` resolves the C backend and calls
  `backend.byName("c").?.emitMap(.., profile, path)`.
- Direct helper and test callers can still use `Backend.lower`; that route builds
  MIR internally via the backend's compatibility wrapper.

(`profile` is irrelevant to the LLVM backend, which ignores it.)

## Adding a native MC backend

1. Create `src/lower_<name>.zig` with the emission logic and a top-level entry
   `fn append<Name>(allocator, module, out, opts...) anyerror!void`.
2. Expose a constructor:
   ```zig
   const backend_mod = @import("backend.zig");
   pub fn mcBackend() backend_mod.Backend {
       return .{
           .name = "<name>",
           .artifact_ext = ".<ext>",
           .supports_profiles = false, // or true
           .ctx = undefined,
           .lowerFn = backendLower,    // thunks opts -> your entry fn
           // .emitMapFn = ...,        // only if you produce a source map
       };
   }
   ```
3. Register it in `builtins()` in `src/backend.zig`.
4. Add a CLI command in `src/main.zig`. If the backend lowers from MIR in the
   production path, mirror the current parse/sema/`mir.buildOpt`/
   `mir.verifyBuiltMir`/prebuilt-MIR pattern in `runEmitC` and `runEmitLlvm`.
   `.lower(...)` remains available for generic module-to-artifact callers and
   tests.

### Shared lowering helpers you can reuse

A new backend does not start from scratch. The middle end and these
backend-agnostic helpers are already shared by both existing backends:

- **`mir.zig`** — `mir.buildOpt(allocator, module, .{ .optimize })` builds the
  mid-level IR both backends lower from. `mir.verifyBuiltMir` validates an
  already-built module; `mir.verifyOpt` remains the compatibility helper that
  builds, verifies, and deinitializes MIR in one call.
- **`layout.zig`** — type sizes/alignment/struct layout (`scalarLayout`,
  `ComptimeStructLayout`, ...).
- **`eval.zig`** — compile-time constant evaluation.
- **`ast_query.zig`** — pure AST-shape queries (intrinsic/call classification,
  type-name helpers, byte-view/MMIO detection, ...).
- **`numeric.zig`** — numeric-literal parsing and alignment math.

Per-construct emission (the actual textual rendering) remains per-backend.
