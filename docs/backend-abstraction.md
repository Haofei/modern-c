# Backend abstraction

`src/backend.zig` defines the backend entry interface: the seam where `mcc`
selects a code-generation target and asks it to lower an already verified
program. Concrete built-ins are registered in `src/backend_registry.zig`, which
is the composition root allowed to import `src/lower_c.zig` and
`src/lower_llvm.zig`.

The important current boundary is:

```text
parse/sema/MIR build
        │
        ▼
mir.verifyBuiltMir + mir.validateLoweringAdmission
        │
        ▼
backend.VerifiedProgram
        │
        ├── C backend
        └── LLVM backend
```

Backends should not receive a raw `ast.Module` through the registry interface.
Legacy helper functions still exist for tests and compatibility, but the CLI
artifact paths build `VerifiedProgram` before invoking the selected backend.

## What it abstracts

This is the entry seam only:

- backend selection by registry name (`"c"`, `"llvm"`),
- top-level verified-program-to-artifact lowering, and
- optional source-map emission for backends that support it.

It does not unify statement, expression, type, ABI, or debug-info emission.
Those remain private implementation details of each lowerer.

## Current contract

The key types live in `src/backend.zig`.

```zig
pub const LowerOptions = struct {
    profile: Profile,
    source_path: ?[]const u8,
    target_arch: TargetArch = .riscv64,
    checks: Checks = .{},
    stub_asm: bool = false,
    reporter: ?*diagnostics.Reporter = null,
    source_sha256: ?Sha256Digest = null,
    compiler_version: ?[]const u8 = null,
    toolchain_identity: ?[]const u8 = null,
    linux_kernel: bool = false,
};

pub const LowerError = std.mem.Allocator.Error || error{
    UnsupportedCEmission,
    UnsupportedLlvmEmission,
    InvalidMirTargetTypeFacts,
    InvalidMirCallTargetFacts,
    InvalidMirConstGetFacts,
    InvalidMirIntegerFacts,
    InvalidMirRepresentationFacts,
    StaleMirTargetTypeFacts,
    GeneratedTypeNameCollision,
    LayoutStructNotFound,
    LayoutUnresolved,
    InternalLoweringFailure,
};

pub const Backend = struct {
    name: []const u8,
    artifact_ext: []const u8,
    supports_profiles: bool,
    ctx: ?*anyopaque,

    lowerFn: *const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        program: VerifiedProgram,
        declarations: LegacyDeclarationSlice,
        out: *std.ArrayList(u8),
        opts: LowerOptions,
    ) LowerError!void,

    emitMapFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        program: VerifiedProgram,
        source_map: SourceMapMechanicsView,
        out: *std.ArrayList(u8),
        generated_artifact: []const u8,
        opts: LowerOptions,
    ) LowerError!void = null,
};
```

`Backend.lower` and `Backend.emitMap` are thin vtable calls over those function
pointers. The registry functions are in `src/backend_registry.zig`:

```zig
pub fn all() [2]backend.Backend;
pub fn byName(name: []const u8) ?backend.Backend;
```

## VerifiedProgram

`VerifiedProgram` is the only code-generation input accepted by a registered
backend. Construction performs MIR admission first:

- `mir.verifyBuiltMir`,
- `mir.validateLoweringAdmission`,
- source-spelling validation against MIR symbol identities.

It then exposes:

- `source_spelling`: MIR-owned spelling by typed symbol id.

A transitional declaration slice still exists as `LegacyDeclarationSlice`, but
it is passed as an explicit legacy backend parameter rather than stored on
`VerifiedProgram`. It is narrower than giving the backend a full `ast.Module`,
but it is not the final semantic boundary. Source-map row enumeration still uses
`SourceMapMechanicsView`, but it is passed only to the `emit-map` path rather
than stored on `VerifiedProgram`. New backend work should prefer MIR identities
and typed facts and should avoid adding new semantic decisions to syntax-backed
views.

## Error boundary

The registry interface returns `backend.LowerError`, not `anyerror`. C and LLVM
lowerers still contain internal helper functions with wider error sets, but
their adapter functions map those errors through `backend.lowerErrorFromAny`.

This keeps the core seam auditable:

- expected unsupported lowering remains a typed backend error,
- MIR-fact admission failures remain distinct,
- OOM is preserved,
- unexpected adapter leaks collapse to `InternalLoweringFailure`.

## How `main.zig` dispatches

The CLI artifact paths follow the same shape:

1. parse source,
2. build MIR,
3. construct `backend.VerifiedProgram`,
4. look up a backend with `backend_registry.byName`,
5. call `Backend.lower` or `Backend.emitMap`,
6. publish artifact metadata.

Current command behavior:

- `emit-c` uses the C backend (`"c"`) with C profile/check options.
- `build` uses the C backend in hosted profile, then invokes clang.
- `emit-map` lowers C first, then calls the C backend source-map hook.
- `emit-llvm` uses the LLVM backend (`"llvm"`) with target/debug/runtime options.

All artifact commands pass the same source digest and sanitized/remapped source
path into `LowerOptions`, so generated artifacts and metadata use the same
source identity.

## Adding a backend

1. Implement `src/lower_<name>.zig`.
2. Expose a constructor:

   ```zig
   const backend_mod = @import("backend.zig");

   pub fn mcBackend() backend_mod.Backend {
       return .{
           .name = "<name>",
           .artifact_ext = ".<ext>",
           .supports_profiles = false,
           .ctx = null,
           .lowerFn = backendLower,
       };
   }
   ```

3. Make `backendLower` accept `backend.VerifiedProgram` plus the explicit
   transitional `LegacyDeclarationSlice`, then return `backend.LowerError!void`.
4. Register the backend in `src/backend_registry.zig`.
5. Add CLI dispatch in `src/main.zig` if it needs a first-class command.

If the backend needs source-map output, provide `emitMapFn`; otherwise leave it
null.

## Shared lowerer inputs

These modules are legitimate shared inputs for backend work:

- `mir.zig`: typed MIR, facts, verifier/admission.
- `mir_facts_view.zig`: transitional query layer for facts not yet indexed by
  stable typed ids.
- `layout.zig`: layout calculation shared by semantic and backend code.
- `eval.zig`: compile-time constant evaluation.
- `numeric.zig`: numeric literal and arithmetic helpers.
- `string_literal.zig`: canonical decoded string bytes.

`ast_query.zig` may be used for remaining syntax-shape compatibility helpers,
but it should not become a new semantic authority. The long-term direction is
for C/LLVM/native backends to consume typed MIR facts mechanically.
