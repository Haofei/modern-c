# Backend abstraction

`src/backend.zig` defines the `Backend` interface: the seam at which `mcc`
selects a code-generation target and invokes top-level lowering. The two
built-in backends — the C emitter (`src/lower_c.zig`, `emit-c`/`emit-map`) and
the LLVM emitter (`src/lower_llvm.zig`, `emit-llvm`) — both register through
this interface, and `src/main.zig` dispatches through it rather than calling the
backend modules directly.

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
    profile: Profile,          // TARGET axis: kernel | hosted (honored iff supports_profiles)
    optimize: bool,            // BUILD-SAFETY axis: false = SAFE (--checks=all, default,
                               //   keep every trap check), true = RELEASE
                               //   (--checks=elide-proven, drop only proven-dead checks).
                               //   Drives mir.buildOpt. See spec annex E.4 / D2.5.
    source_path: ?[]const u8,  // embedded in #line / !DILocation; null => backend default
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

- **`name`** — selected from the CLI command (`emit-c` -> `"c"`,
  `emit-llvm`/`emit-map` -> the matching backend) via `byName`.
- **`artifact_ext`** — the conventional output extension; metadata a driver can
  use without knowing the backend.
- **`supports_profiles`** — the C backend has kernel/hosted profiles; the LLVM
  backend ignores `profile`. The flag lets callers reason about this instead of
  guessing. (The LLVM backend simply ignores `opts.profile`.)
- **`ctx` / `*anyopaque`** — the idiomatic Zig vtable shape. Built-in backends
  are stateless and pass `undefined`; a stateful backend can carry context
  without changing the interface.
- **`lowerFn` / `lower`** — the one mandatory operation: append the textual
  artifact for a module to `out`. C routes to
  `appendCProfileWithSourcePath`, LLVM to `appendLlvmWithSourcePath`.
- **`emitMapFn` / `supportsEmitMap` / `emitMap`** — optional source-map
  capability. Only the C backend supplies it (`emit-map`); LLVM leaves it null
  rather than faking an unsupported artifact.

## How `main.zig` dispatches

The CLI surface is unchanged. The command handlers now resolve a backend and
invoke it through the interface:

- `emit-c`  -> `backend.byName("c").?.lower(.., .{ .profile, .optimize, .source_path = path })`
- `emit-map`-> `backend.byName("c").?.emitMap(.., profile, path)`
- `emit-llvm`-> `backend.byName("llvm").?.lower(.., .{ .profile = .kernel, .optimize, .source_path = path })`

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
4. Add a CLI command in `src/main.zig` that resolves the backend by name and
   calls `.lower(...)` (mirror `runEmitC`/`runEmitLlvm`).

### Shared lowering helpers you can reuse

A new backend does not start from scratch. The middle end and these
backend-agnostic helpers are already shared by both existing backends:

- **`mir.zig`** — `mir.buildOpt(allocator, module, .{ .optimize })` builds the
  mid-level IR both backends lower from; `mir.verifyOpt` validates it.
- **`layout.zig`** — type sizes/alignment/struct layout (`scalarLayout`,
  `ComptimeStructLayout`, ...).
- **`eval.zig`** — compile-time constant evaluation.
- **`ast_query.zig`** — pure AST-shape queries (intrinsic/call classification,
  type-name helpers, byte-view/MMIO detection, ...).
- **`numeric.zig`** — numeric-literal parsing and alignment math.

Per-construct emission (the actual textual rendering) remains per-backend.
