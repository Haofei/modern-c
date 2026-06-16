# C undefined-behavior class matrix (C backend) — S0.3

The C backend lowers MC to C, so it can **inherit C's undefined behavior** unless each UB
class is explicitly handled. This document is the audited, fixture-verified record of how MC
handles each C UB category in the emitted C: **statically forbidden**, **checked + traps**, or
**defined away at emit** (and, where it relies on a compiler flag rather than an MC check, it
says so plainly — that honesty is the point of this audit).

Three handling kinds:

- **Forbidden** — the front-end rejects the program; the UB can never be emitted.
- **Checked + trap** — the emitted C inserts an explicit guard that calls a `mc_trap_*`
  helper (`__builtin_trap()`) before the UB would occur.
- **Defined away** — the emit idiom is already well-defined C (e.g. `memcpy`-reinterpret,
  plain unsigned arithmetic), optionally backed by a **UB-defining compiler flag**.

The trap helpers live in the runtime prelude in `src/lower_c.zig` (`mc_trap_IntegerOverflow`,
`mc_trap_DivideByZero`, `mc_trap_InvalidShift`, `mc_trap_Bounds`, `mc_trap_NullUnwrap`, …),
each a `MC_NORETURN` wrapper over `__builtin_trap()`.

## How the LLVM backend differs

The LLVM backend (`src/lower_llvm.zig`) emits LLVM IR directly and **largely sidesteps C UB**:
it does not go through the C abstract machine, so strict-aliasing, sequence-point, and
provenance UB classes are *C-backend-only* concerns (rows marked **C-only** below). The
**arithmetic/bounds/null traps are shared**: both backends emit the same `mc_trap_*` checks
(the LLVM backend references the trap helpers externally; the C backend inlines them). So the
checked rows hold on both backends, and the per-row fixtures run identically on both (verified
by `zig build diff-backend`).

## UB-defining emit flags

Applied to the emitted MC C in `tools/toolchain/mcc-cc.sh` (host object path) and in the
kernel-image cc path `tools/proc/kmain-test.sh` (`CFLAGS`). These are **defense in depth**, not
the semantic foundation — MC's own checks/forbids already cover the cases below; the flags
harden the residual inherited-C surface and pin down the one idiom (raw MMIO) that genuinely
relies on a flag. They match the spec's recommended defensive flags
(`docs/spec/MC_0.7_Final_Design.md`, "Recommended defensive flags").

| Flag | Why | Load-bearing? |
|---|---|---|
| `-fno-strict-aliasing` | `raw.load/store<T>` and the MMIO helpers cast `uintptr_t -> volatile T*` (access through an incompatible type) for hardware-register access. `bitcast<T>` and overlay-union access already use `__builtin_memcpy` reinterpret (alias-safe), so only the raw-register path depends on this. | **Yes**, for the raw-register / MMIO path (the only type-punned pointer deref MC emits). |
| `-fno-delete-null-pointer-checks` | Stops the optimizer from assuming a prior dereference proved a pointer non-null and deleting a later guard. In freestanding code a raw address may legitimately be `0`. | Defensive (MC traps null-unwrap via `mc_trap_NullUnwrap`). |
| `-fwrapv` | Defines signed overflow as two's-complement wrap. | **No — not load-bearing.** MC traps signed overflow via `__builtin_{add,sub,mul}_overflow` *before* any wrap, and **forbids** `wrap<T>`/`sat<T>` on signed types (`E_ARITH_DOMAIN_UNSIGNED`), and routes even `wrapping.add` on signed operands through the unsigned domain (`(int32_t)((uint32_t)a + (uint32_t)b)`). So no un-trapped signed overflow is ever emitted; this flag only removes a residual optimizer assumption. **Verified it does not mask the overflow trap** (the trap still fires with `-fwrapv` on). |

`-ffreestanding` / `-fno-builtin` (also spec-recommended) are already present on the kernel-image
cc path.

## The matrix

Each row cites the MC mechanism and has a per-row fixture under `tests/qemu/hardening/` wired
into `tools/lib/host-tests.tsv` (so `zig build sanitize` runs it under ASan+UBSan and
`zig build diff-backend` runs it through both backends). Fixtures stay inside the **defined**
range so the guard is present but does not fire (a fired trap would abort and fail the
sanitizer gate — which is the guard doing its job); the trapping case for each checked row was
verified separately (see "Trap verification").

| # | C UB class | MC handling | Mechanism (cite) | Fixture |
|---|---|---|---|---|
| 1 | **Signed integer overflow** | Checked + trap (default); modular form forbidden on signed | `i32 +` → `mc_checked_add_i32` → `__builtin_add_overflow` → `mc_trap_IntegerOverflow`. `wrap<T>`/`sat<T>` on signed → `E_ARITH_DOMAIN_UNSIGNED` (forbidden). `wrap<u32>` → plain unsigned `+` (defined). | `ub_signed_overflow.mc` |
| 2 | **Strict aliasing** (C-only) | Defined away (memcpy) + flag (MMIO) | `bitcast<T>` → `__builtin_memcpy` reinterpret (`mc_bitcast_memcpy`); overlay-union read/store → `__builtin_memcpy` byte-storage. Raw `raw.load/store<T>` + MMIO → `volatile T*` cast, covered by `-fno-strict-aliasing`. | `ub_strict_aliasing.mc` |
| 3 | **Out-of-bounds access** | Checked + trap | Every indexed access → `mc_check_index_usize(index, len)` → `mc_trap_Bounds` when `index >= len`. (Library idioms like `ByteBuf` additionally return a typed `OutOfBounds` error instead of trapping.) | `ub_out_of_bounds.mc` |
| 4 | **Shift ≥ width / negative shift** | Checked + trap | `u32 <<` → `mc_checked_shl_u32`: traps `mc_trap_InvalidShift` on count ≥ width, `mc_trap_IntegerOverflow` on value overflow; signed variant also traps on negative count. `wrap<u32> <<` → `mc_wrap_shl_u32`: still traps on count ≥ width, wraps the value. | `ub_shift.mc` |
| 5 | **Div-by-zero & INT_MIN/-1** | Checked + trap | `i32 /` `%` → `mc_checked_div_i32` / `mc_checked_mod_i32`: `mc_trap_DivideByZero` on `b==0`, `mc_trap_IntegerOverflow` on `a==INT_MIN && b==-1`. | `ub_div.mc` |
| 6 | **Null dereference** | Forbidden until narrowed; checked + trap on `?` | `?*mut T` cannot be dereferenced; `if let p = maybe` binds only on the non-null branch; postfix `maybe?` → `if (p == NULL) mc_trap_NullUnwrap();`. Flag `-fno-delete-null-pointer-checks`. | `ub_null_deref.mc` |
| 7 | **Uninitialized read** | Forbidden (must init); explicit `uninit` is unspecified-not-UB | Ordinary `var x: i32;` with no initializer is a compile error (spec §12). `var buf = uninit;` is allowed; its bytes are *unspecified, not UB* (no trap representations / poison) and must be written before read. | `ub_uninit.mc` |
| 8 | **Evaluation order / sequence points** (C-only) | Defined | Evaluation order is part of the language (args left-to-right; binary ops left-then-right; assignment RHS→LHS→store; `&&`/`||` short-circuit). The C backend lowers each subexpression to its own sequenced MIR temporary (`mc_tmp0`, `mc_tmp1`, …), so the emitted C has no unsequenced reads/writes. | `ub_eval_order.mc` |
| 9 | **Pointer provenance** (C-only) | Defined away / contained by address classes | `PAddr` (`std/addr.mc`) is an opaque address class; the only `usize<->PAddr` boundary is the explicit `pa()` / `pa_value()` pair, and `pa_offset` / `pa_diff` lower to plain `uintptr_t` arithmetic. The emitted C never relies on abstract-machine provenance of a forged pointer. | `ub_provenance.mc` |

### Related shared-data UB (covered elsewhere)

- **C data-race UB** — racy shared scalars lower through `mc_race_load_*` / `mc_race_store_*`
  (relaxed `__atomic_load`/`__atomic_store`), so a benign race is a defined relaxed atomic, not
  C data-race UB. (Covered by the sync/atomics suite, not a new row here.)

## Trap verification (honesty)

For each **checked + trap** row, the trapping case was built and run (outside the suite,
because a trap aborts the process) to confirm the guard actually fires — and that `-fwrapv`
does **not** mask the signed-overflow trap:

| Case | Result |
|---|---|
| `INT32_MAX + 1` (signed overflow) | **TRAPPED** (SIGTRAP) — even with `-fwrapv` on |
| `g[9]` on `[4]u32` (OOB) | **TRAPPED** (SIGTRAP) |
| `1u32 << 40` (shift ≥ width) | **TRAPPED** (SIGTRAP) |
| `5 / 0` (div-by-zero) | **TRAPPED** (SIGTRAP) |
| `INT32_MIN / -1` (signed div overflow) | **TRAPPED** (SIGTRAP) |

## Honesty notes — where MC relies on a flag, not a check

- **Strict aliasing (row 2)** is the one class where a *flag* (`-fno-strict-aliasing`) is
  load-bearing, and only for the raw-register / MMIO path (`uintptr_t -> volatile T*`). All
  reinterpretation that MC offers as a language feature (`bitcast`, overlay unions) is
  already alias-safe via `memcpy`, independent of the flag.
- **`-fwrapv` is not load-bearing.** It is pure defense in depth: MC traps signed overflow and
  forbids signed `wrap`/`sat`, so no signed-overflow UB is emitted. It is included only to
  remove a residual optimizer assumption and to match the spec's defensive-flag posture.
- **`-fno-delete-null-pointer-checks`** is defensive: MC's null handling is the
  forbid-until-narrowed rule plus the `?` trap; the flag just prevents the optimizer from
  eliding a guard after an earlier access.
