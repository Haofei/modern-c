# C ABI & interop — practical reference

Operational rules for crossing the C boundary and keeping object symbols stable. The
normative spec is `docs/spec/MC_0.7_Final_Design.md` §24 (C ABI and FFI), §16
(address-space types) and §28.1 (symbol attributes); this page is the day-to-day
cheat-sheet plus the error codes you actually hit.

## Calling / exposing C

```mc
extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
extern struct Timespec { tv_sec: i64, tv_nsec: i64 }   // C-ABI struct layout
export fn mc_entry() -> u32 { ... }                     // C-ABI MC export
#[mc_abi]
export fn internal_pair(value: [2]u32) -> [2]u32 { ... } // same-backend only
```

- **`extern "C" fn …;`** — declare a C function MC may call. Parameter/return types must be
  in the compiler's target-classified C ABI allowlist.
- **`extern fn …;`** — declare an unresolved function using the active MC backend's
  internal ABI. This form is used by generated runtime/test seams and is not C ABI stable.
- **`export fn …`** — expose an MC definition with the target C ABI. Its signature is
  checked by the same allowlist as `extern "C"`.
- **`#[mc_abi] export fn …`** — expose a symbol using the active backend's private MC ABI.
  Caller and callee must use the same backend, target, and compiler version. This is not a
  C interoperability surface and C/LLVM representations are not required to match.
- **`extern struct`** — a struct whose layout matches the C ABI (no MC-chosen reordering).

The current C ABI allowlist covers `void` returns, scalar integers and enums, `bool`,
`f32`/`f64`, raw pointers, C strings, address-class scalar handles, and nullable raw
pointers. LLVM declarations, definitions, and direct calls carry the target-required
`signext`/`zeroext` attributes for narrow integer values.

Plain `fn(...) -> T` pointers carry the private MC calling convention. An explicit C
function or a variadic function cannot be converted to that pointer type. Call such
functions directly until the language has an ABI-qualified `extern "C" fn(...)` pointer
type whose convention and parameter attributes are part of type identity.

Unclassified by-value representations are rejected at explicit C ABI and default export
boundaries with `E_EXTERN_STRUCT_BY_VALUE`. The rejected set includes arrays, slices,
structs and unions, tagged value optionals, `Result`, closures, trait objects, function
pointers without a classified nested signature, and unknown generic wrappers. Use a
pointer/out parameter, or use `#[mc_abi]` only for a deliberately same-backend boundary.
An `extern struct` has C storage layout, but passing it by value remains rejected until
the selected target's aggregate calling convention is implemented.

`va_list` is compiler-managed cursor state, not a portable by-value C ABI type. It is
rejected in explicit C parameters and returns. C variadic declarations retain `...`
through sema and both backends; fixed arguments use the classified signature and tail
arguments are evaluated left to right and receive C default argument promotions.

## `c_void`, not MC `void`

`c_void` is the C opaque-object pointee (`void *` ⇒ `*mut c_void`). MC `void` is the unit/no-
value type and has **no** pointer form at the boundary.

| mistake | error |
|---|---|
| `*mut void` at an FFI boundary | `E_MC_VOID_POINTER_FFI` (use `c_void`) |
| `c_void` used as a value/storage type (sized, dereferenced) | `E_C_VOID_NO_LAYOUT` |

`c_void` pointers may be passed, compared, and converted only through explicit FFI
operations — never dereferenced.

## C strings

The normative boundary type is **`cstr`** (ABI-identical to `const char *`, non-null,
NUL-terminated; carries no length). **Status (v0.7): `cstr` is implemented** as a
distinct FFI C string type and lowers to the backend pointer type (`ptr` in LLVM).
String literals may initialize a `cstr`, be passed to `cstr` parameters, or be
returned from `cstr` functions when the surrounding type context is explicit. A string
literal still lowers to `*const u8` in a pointer context (`let s: *const u8 = "hi";`)
and to `[]const u8` in a slice context. Implicit conversions from ordinary pointers,
slices, `null`, or integers to `cstr` are rejected.

## Address-space types at the boundary (§16)

`UserPtr<T>`, `PhysPtr<T>`, `PAddr`, `VAddr`, `DmaAddr` are distinct opaque address
classes — they do not implicitly convert to or from raw integers or each other. Forging
one from an integer is `E_ADDRESS_CLASS_CAST`; construct through the typed constructor
(`pa`/`va`/`dma`/`mmio.map`) or, at a deliberate boundary, in an `unsafe` block (e.g.
`unsafe { p = a as UserPtr<u8>; }`, the kernel/core/uaccess.mc idiom). They lower to a
pointer-width integer in the ABI.

## Stable object symbols (§28.1)

By default an MC symbol's object name is its source name. Two attributes control the
boundary symbol without renaming the source:

- **`#[backend_name("Y")]`** — emit declaration `X` under object symbol `Y` (RSS/namespace
  isolation; lets two source `X`s coexist as distinct object symbols). A trait/inherent
  method and a `#[backend_name]` clash is `E_DUPLICATE_BACKEND_NAME`.
- **`#[origin("generated"|"copied"|"ported"|…)]`** — classify an FFI/boundary declaration
  so tooling can tell ported source from bound/generated/copied-runtime code.

Both backends (`emit-c`, `emit-llvm`) must agree on the emitted symbol; the `diff-backend`
gate enforces C-vs-LLVM agreement across the host fixtures.

## Trap ABI

Safety-check failures call the `mc_trap_*` family (`mc_trap_Assert`, `mc_trap_Bounds`,
`mc_trap_DivideByZero`, …). A freestanding/host link must provide these symbols; they
typically `__builtin_trap()` (an illegal instruction). `#[no_lang_trap]` forbids emitting
a language trap edge in a region (`E_NO_LANG_TRAP_EDGE`) for code that must not trap.

## Testing across the boundary

`#[test]` functions (see below) are ordinary `export fn name() -> u32` returning 1, so
the test runner links them exactly like any C-visible MC symbol:

```mc
#[test]
export fn round_trips() -> u32 { assert(parse(serialize(x)) == x); return 1; }
```

- `mcc list-tests <file>` enumerates `#[test]` functions.
- `tools/test/mc-test-runner.sh <mcc> <c|llvm> <file>` runs each process-isolated and
  reports pass/fail by name (a failing `assert` traps the child). Gated by `mc-test` /
  `llvm-mc-test` in `m0`.

## Quick error index

| code | cause |
|---|---|
| `E_MC_VOID_POINTER_FFI` | `void` pointer at an FFI boundary — use `c_void` |
| `E_C_VOID_NO_LAYOUT` | `c_void` used where a sized/dereferenceable type is needed |
| `E_ADDRESS_CLASS_CAST` | forging an address-class pointer from a non-address value |
| `E_DUPLICATE_BACKEND_NAME` | two declarations resolve to the same object symbol |
| `E_NO_LANG_TRAP_EDGE` | a trap edge emitted inside `#[no_lang_trap]` |
| `E_NO_IMPLICIT_CONVERSION` (`cstr`) | implicit pointer, slice, `null`, or integer conversion to `cstr` |
