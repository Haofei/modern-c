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

Backends must not receive a raw `ast.Module` through the registry interface.
CLI artifact paths build `VerifiedProgram` before invoking the selected backend.

## What it abstracts

This is the entry seam only:

- backend selection by registry name (`"c"`, `"llvm"`),
- top-level verified-program-to-artifact lowering, and
- optional source-map emission for backends that support it.

It does not unify statement, expression, type, ABI, or debug-info emission.
Those remain private implementation details of each lowerer.

## Current contract

The backend vtable lives in `src/backend.zig`. Request options live in
`src/codegen_options.zig` and are re-exported by `backend.zig` for the existing
backend API.

```zig
pub const LowerOptions = struct {
    profile: Profile,
    source_path: ?[]const u8,
    target_arch: TargetArch = .riscv64,
    checks: Checks = .{},
    stub_asm: bool = false,
    reporter: ?*diagnostics.Reporter = null,
    source_sha256: ?artifact_model.Sha256Digest = null,
    compiler_version: ?[]const u8 = null,
    toolchain_identity: ?[]const u8 = null,
    linux_kernel: bool = false,
};

// Defined in src/lower_error.zig and re-exported by backend.zig.
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
        request: LowerRequest,
    ) LowerError!void,

    emitMapFn: ?*const fn (
        ctx: ?*anyopaque,
        allocator: std.mem.Allocator,
        request: EmitMapRequest,
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
backend. Its implementation lives in `verified_program.zig`; `backend.zig`
re-exports the type for the backend vtable. Construction performs MIR admission
first:

- `mir.verifyBuiltMir`,
- `mir.validateLoweringAdmission`,
- source-spelling validation against MIR symbol identities.

It then exposes:

- `checked`: the minimal syntax-free `CheckedProgram` callable/body table;
- `runtime_hooks`: MIR-owned facts for default trap/sanitizer hook suppression.

`CheckedProgram` is not a full Typed HIR. It contains no AST or expression tree;
typed MIR remains the only executable body representation.

Collected `EarlyDeclarationArtifacts` and
`declaration_artifacts.SourceMapArtifact` values remain a temporary mechanics
bridge for declaration ordering and source-map output. They are not semantic
authority and are not stored on `VerifiedProgram`. `driver_codegen_inputs.zig`
is the only driver-owned compatibility edge that may assemble those artifacts
next to `VerifiedProgram` construction; `main.zig` and backend lowerers must not
call declaration collectors directly.

Artifact envelope metadata is not owned by the backend seam. `.mcmeta` and `.mcmap` use `artifact_model.ArtifactBundle`; backend lowering only receives the source digest through `LowerOptions`.

## Error boundary

The registry interface returns `backend.LowerError`, not `anyerror`; the
concrete error set and mapping live in `lower_error.zig`. C and LLVM
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

## Backend scope

The current scope is the two built-in backends: checked C and textual LLVM IR.
Do not add another backend while the verified-program boundary, typed fact
schema, module identity, layout/ABI tables, and cleanup/control MIR authority
are still being narrowed. New lowering work should make the existing C/LLVM
backends more mechanical rather than introducing another consumer of transitional
facts.

## Shared lowerer inputs

These modules are legitimate shared inputs for backend work:

- `mir.zig`: typed MIR, facts, verifier/admission.
- `mir_facts_view.zig`: transitional query layer for facts not yet indexed by
  stable typed ids. Target-type source-span compatibility queries are
  current-function-only, so broad module scans cannot reappear hidden behind
  backend lookups.
- `layout.zig`: layout calculation shared by semantic and backend code.
- `eval.zig`: compile-time constant evaluation.
- `numeric.zig`: numeric literal and arithmetic helpers.
- `string_literal.zig`: canonical decoded string bytes.

`ast_query.zig` may be used for remaining syntax-shape compatibility helpers,
but it must not become a new semantic authority. The long-term direction is for
the two built-in backends to consume typed MIR facts mechanically.
