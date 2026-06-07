# MC Compiler — Remaining Work

## ⭐ Prototype goal — Network-card driver (Driver Library Profile, §28) — ✅ DONE (2026-06-07)

The first end-to-end prototype is a **DMA-capable network-card driver**, and it
**runs under QEMU**: `zig build nic-test` lowers `tests/qemu/nic_driver.mc` —
which composes the whole driver-library stack — to C, links it into a bare-metal
riscv64 image (`tests/qemu/nic_runtime.c` provides the single-core platform
hooks), runs it under `qemu-system-riscv64 -machine virt`, and confirms the frame
the driver "transmitted" (`NIC-TX-OK`) arrived at the emulated 16550 UART. One
`nic_transmit()` exercises DMA ownership, the TX ring, the lock guard, a
big-endian header, a barrier, and typed MMIO — and the linear `move` discipline
makes read-after-handoff / double-free / lock-left-held compile errors. In m0.

1. [x] **`std/sync` — locks + linear guards (§28.1)** — `SpinLock` + a `move`
   `Guard`/`IrqGuard` (release consumes it) over platform acquire/release
   primitives. Reject-tested (`E_RESOURCE_LEAK` on forgotten unlock,
   `E_USE_AFTER_MOVE` on double-unlock); runtime `zig build sync-test` (a guarded
   counter, lock balance preserved). `Mutex`/`RwLock`/`seqlock` are follow-ons.
2. [x] **`std/dma` — DMA ownership library (§18.2)** — cpu/device ownership as
   two distinct `move` types (`CpuBuffer`/`DeviceBuffer`); `alloc`/`free`/
   `clean_for_device`/`invalidate_for_cpu` (consume-and-return) + `cpu_addr`/
   `device_addr` borrows. Reading a device-owned buffer is a compile error (the
   borrow takes `*CpuBuffer`). Exercised by nic-test.
3. [x] **`std/ring` — generic descriptor ring (§28.2)** — `Ring<T>` (generic,
   fixed-16 capacity) with `push`/`front`/`pop`/`is_full`/`is_empty`/`len`.
   (A `comptime CAP` capacity awaits value type-parameters on generic structs.)
4. [x] **`std/endian` — byte order (§28.3)** — `swap_u16/u32/u64`, `to_be*`/
   `from_be*`/`to_le*`/`from_le*` pure `const fn`s (comptime-foldable); swap_u64
   runtime-verified. (Host assumed little-endian; a `__BYTE_ORDER__` variant is a
   follow-on.)
5. [x] **`std/time` — delays + ticks (§28.4)** — `read_ticks`/`elapsed` (wrap-
   correct over the `wrap` domain) / `timed_out` / `udelay` / `mdelay`.
6. [x] **`std/barrier` — memory barriers (§28.5)** — `mb`/`rmb`/`wmb`/`dma_wmb`
   as compiler barriers (inline-asm `"memory"` clobber); arch hardware fences are
   a per-target refinement.
7. [~] **`std/mmio` — register-field RMW + iomem copy (§28.6)** — deferred: MC's
   typed MMIO (§17) accesses registers as `Reg` fields via the struct path, so a
   generic `set_bits<R>(MmioPtr<R>, …)` over a bare register pointer does not fit
   the model (scalar `MmioPtr` is rejected). The driver does register RMW inline
   via typed MMIO; a typed bulk `iomem` copy could still be added later.
8. [x] **NIC driver prototype (§28.7)** — `tests/qemu/nic_driver.mc`, run under
   QEMU by `zig build nic-test` (in m0). Proves the libraries compose end-to-end.
9. [x] **Real virtio-net driver (virtio 1.x over virtio-mmio)** — **done**
   (2026-06-07). `tests/qemu/virtio_net.mc` is a faithful modern-virtio driver:
   typed MMIO register block (the real virtio-mmio layout), the device-init status
   handshake, `VIRTIO_F_VERSION_1` feature negotiation, a real **split virtqueue**
   (descriptor table / available ring / used ring) laid out as typed structs in
   DMA memory and accessed through pointers (bounds-checked), `std/barrier`
   ordering before the doorbell, and `std/endian` field writes. `zig build
   virtio-test` (in m0) runs it under `qemu-system-riscv64 -machine virt` with an
   attached `virtio-net-device` (modern, `force-legacy=false`): the device
   completes the handshake, **reaps the transmitted descriptor** (used ring
   advances), and a real **100-byte TX frame is captured in a pcap**. Required
   adding the typed memory-access primitives below (member/array access and
   `*mut`-field writes *through pointers*), so the vring is typed rather than raw.
   _Protocol correctness + DMA-ownership pass (2026-06-07, from an external
   review):_ `virtio_init` now **reads the device's offered features and accepts
   the intersection** (failing if a required bit is missing), **waits for
   `status == 0` after reset**, and sets **`STATUS_FAILED`** on any failure;
   `vq_setup` checks **`queue_num_max`** and negotiates the size; `vq_pop_used`
   reads the **used-ring `id`/`len`** (not just `used.idx`). Crucially, the queue
   API now takes **linear `move` DMA handles, not raw `addr/len`**:
   `vq_submit_tx(DeviceBuffer)` consumes the handle and returns it as the in-flight
   token, and the driver runs the full `alloc → clean_for_device → submit →
   reclaim → free` cycle — so read-after-handoff, double-submit, and
   submit-while-cpu-owned are compile errors. This required fixing a real
   type-checking gap: **distinct named structs are now non-interchangeable at call
   sites** (`E_NO_IMPLICIT_CONVERSION`) — previously all structs classified the
   same, so `CpuBuffer`/`DeviceBuffer` typestates were not enforced. Compile-fail
   regression `tests/spec/dma_ownership.mc`; still green under QEMU.
10. [x] **Driver ergonomics — language features + transport libraries** —
    **done** (2026-06-07). Refactored so the net-specific driver is ~12 lines and
    the virtio mechanics are reusable. Added: (a) **boolean `if`** (`if cond { … }
    [else …] / else if`) — desugars to a bool `switch` at parse time, reusing all
    its checking/CFG; deletes the `switch true/false` guard boilerplate. Fixture
    `tests/c_emit_bool_if.mc`. (b) **`@offset(N)` MMIO field attribute** — places
    registers at exact byte offsets (generated reserved padding), so a register
    block mirrors the datasheet without counting slots; offset-correctness
    `_Static_assert`-verified, offsets must increase. Fixture
    `tests/c_emit_mmio_offset.mc`. (c) **`std/virtio`** — the virtio-mmio transport
    (datasheet-clean `@offset` register map, `virtio_init` handshake + feature
    negotiation, `virtio_driver_ok`). (d) **`std/virtqueue`** — the split
    virtqueue: vring structs, `vq_setup` (absorbs the 64-bit-address low/high
    split), `vq_add_buf`/`vq_kick`/`vq_used_ready`/`vq_wait_used`, and a generic
    `bus_addr`. The driver now reads as the spec's numbered steps. (The generic
    `poll_until` from the sketch needs closures MC lacks, so the timeout is the
    concrete `vq_wait_used`; the research-tier shared-region vring type remains
    aspirational.) Also fixed the monomorphizer dropping `Field.offset`/`is_move`
    when cloning structs in a module with generics.
11. [x] **Typed-hardware demo suite (`demo/`)** — **done** (2026-06-07). Eight
    drivers, one per hardware class, each showing a different static contract:
    `uart` (register access permissions + `@offset`), `gpio` (pin capabilities),
    `timer` (linear typestate state machine), `irq` (interrupt lifecycle +
    `IrqOff` witness), `spi` (linear bus transaction), `virtio-blk` (DMA
    request/response ownership), `virtio-net` (the full driver, runs under QEMU),
    `framebuffer` (linear device-visible memory mapping). `zig build demo-test`
    (in m0) lowers all eight to compilable C; `demo/README.md` indexes them. The
    `framebuffer` pixel packing surfaced the `.cast` width-recovery fix (below).

This effort also fixed three C-backend bugs the driver work surfaced (below):
member access on a pointer base lowered as `.` instead of `->`; a checked op /
cast over a pointer deref (`p.* + 1`) and a wrap-domain value couldn't recover
their type.


Status snapshot of what is left to implement against `MC_0.6.1_Final_Design.md`,
beyond the MC-C0 surface that is already done. The full type-checking surface of
the core language spec is implemented, and every spec operation that produces a
value lowers to clang-checked C. What remains is one language feature, one
analysis pass, and several large runtime/toolchain subsystems.

Effort scale: **S** ≈ <1 day · **M** ≈ 1–3 days · **L** ≈ ~1–2 weeks ·
**XL** ≈ multi-week / architectural.

## Language features (bounded, finishable)

- [x] **Linear resource types (`move`) (§18.1)** — **done** (2026-06-07). The
  `move struct` qualifier (a contextual keyword, no lexer change), a per-function
  move/liveness pass (`Checker.checkMoveLinearity` / annex D.7) emitting
  `E_USE_AFTER_MOVE` (by-value use of a moved/borrowed-dead value) and
  `E_RESOURCE_LEAK` (a live `move` binding reaching function end); by-value moves,
  `&x`/`x.field` borrow, `defer` reserves. `move` is erased in the backend (zero
  runtime cost). The pass is a no-op unless the module declares `move` types.
  Fixtures: `tests/spec/move_linear.mc` (accept + `E_USE_AFTER_MOVE`/
  `E_RESOURCE_LEAK` rejects), runtime `zig build move-test` (erased handle links +
  runs). _Note: type-changing typestate transitions use distinct binding names
  (MC has no shadowing) and borrows use `&x`._

- [x] **Precise inline assembly (§23.2)** — done (2026-06-06), effort **M**.
  Precise asm with register/typed operands is now parsed, sema-validated, and
  lowered to compilable GCC/Clang extended asm (previously rejected with the now
  -removed `E_PRECISE_ASM_UNSUPPORTED`).
  - [x] Parse `asm precise volatile { "..." out("reg") name: T, in("reg") expr, clobber("...") }`
        — `AsmStmt` carries `outputs: []AsmOutput` / `inputs: []AsmInput`
        (register string, operand, type); `out`/`in`/`clobber` parsed in the asm
        block.
  - [x] Verify it appears inside an `#[unsafe_contract(precise_asm)]` region
        (`E_PRECISE_ASM_CONTRACT`) and in `unsafe` (`E_UNSAFE_REQUIRED`); sema
        also checks each output names a mutable local (`E_ASSIGN_TO_IMMUTABLE_LOCAL`
        / `E_UNKNOWN_IDENTIFIER`), type-checks input expressions, and validates
        operand types.
  - [x] Lower to C extended asm: `__asm__ [__volatile__]("…" : "=r"(out_local)… :
        "r"(in_expr)… : clobbers)`. Operands are wired in declared order (outputs
        `%0..`, then inputs) to match the template's positional operands; outputs
        bind their named local lvalue, inputs feed their value expression.
        Generic `"r"` constraints (no C-level physical-register names) keep the
        emission target-portable; the declared registers are trusted per the
        contract and preserved as an `MC_PRECISE_ASM` provenance comment.
  - [x] `tests/spec/inline_asm.mc` precise accept cases + `tests/c_emit_precise_asm.mc`
        fixture (volatile/non-volatile, single/multi input, with/without
        clobbers); covered by `zig build sweep` and `c-test`. Unit test
        "emits C for precise asm with operands" in `lower_c.zig`.

- [x] **Interrupt context `#[irq_context]` (§19.1)** — done (core); effort **M**.
  Implemented as a MIR-owned verifier pass that reuses the `#[no_lang_trap]`
  attribute + verifier pattern. Verifier-only; no special C lowering required.
  - [x] Parse the `#[irq_context]` attribute on functions.
  - [x] Verifier (annex D.6 Context Verifier): a `#[irq_context]` function may
    only call other `#[irq_context]` functions and non-blocking primitives.
    MIR rejects unproven direct/indirect callees with `E_IRQ_CONTEXT_CALL`,
    rejects known blocking/sleeping/allocating operations with
    `E_IRQ_CONTEXT_BLOCKING`, and accepts extern/internal `#[irq_context]`
    callees plus raw/MMIO/atomic primitive names, typed atomic receiver calls,
    and typed MMIO register receiver calls. `tests/spec/irq_context.mc`
    and `tests/c_emit_irq_context.mc` cover the D.6 diagnostics, MIR facts,
    and accepted C lowering paths.
  - [x] **`IrqOff` capability type for interrupts-disabled critical sections
    (§19.1)** — done. `IrqOff` is a recognized capability type: an operation that
    requires interrupts disabled takes a `cs: IrqOff` parameter, so it cannot be
    called without first obtaining the witness (e.g. from an arch
    `disable_interrupts() -> IrqOff`); the capability threads as a value and
    lowers to a 1-byte token (`uint8_t`) with no runtime effect. Fixture
    `tests/spec/irq_off.mc` (`check=irq-off-capability`, emits the
    `lower irq_off … witness=true` fact). Affine/move-only enforcement (the
    token cannot be duplicated or leaked) remains a deferred library-profile
    concern — promoting it to the core would require the linear type system MC
    deliberately avoids (same rationale as the DMA ownership profile).

- [x] **Compile-time fixed indexing `const_get<N>()` (§8.1, §20.1)** — done.
  `arr.const_get<N>()` now indexes fixed-length arrays at a compile-time-known
  `N`, requires `N < len(arr)` in sema, has the array element result type, emits
  a MIR `const_get` index instruction with no `Bounds` trap edge, is legal under
  `#[no_lang_trap]`, and lowers to direct C element access without
  `mc_check_index`.

- [x] **Mathematical checked reduction `reduce.sum_checked<T>` (§8.2)** — done
  (2026-06-06), effort **M**. A checked reduction whose semantics differ from
  stepwise checked addition: the sum is computed in a wide integer domain and
  `Overflow` is returned only if the *final* result does not fit `T`.
  - [x] Sema: `reduce.sum_checked<T>(xs: []const T) -> Result<T, Overflow>`
        (`Overflow` added as a known error type; classified `.result`). Validated
        as a builtin namespace member: integer type arg (`E_REDUCE_REQUIRES_INTEGER`),
        exactly one slice argument (`E_REDUCE_ARG_NOT_SLICE`, `E_CALL_ARG_COUNT`).
  - [x] Lower to C: a GCC/Clang statement-expression accumulates the slice in an
        `__int128`, then single-range-checks the final result into `T`, yielding
        the `Result<T, Overflow>` struct (`.is_ok`/`.payload`); the slice is bound
        once to avoid double evaluation. `Overflow` lowers to a `uint8_t`
        (payload-free) error marker like `ConversionError`.
  - [x] Fixtures: `tests/spec/reduce_sum_checked.mc` (accept + the three reject
        diagnostics) and `tests/c_emit_reduce_sum_checked.mc`
        (signed/unsigned/narrow/mutable-slice), plus a `lower_c` unit test.
        Green under sweep + c-test.
  - _Known limitation (pre-existing, not specific to this feature): applying `?`
    to the call in a local initializer hits the MIR verifier's
    `E_TRY_REQUIRES_RESULT_OR_NULLABLE` gap, which also affects `try_from(x)?`;
    tracked with the MIR Result-inference work, not here. Direct `return` of the
    Result works._
  - _Note: §8.4 (unsafe hot checked loop) is already expressible — its
    primitives (`#[unsafe_contract(no_overflow)]` + `unchecked.add`) exist; only
    the optimizer's value-range fact propagation from the contract is missing,
    which is tracked under the MIR/optimizer item, not here._

## Compiler analysis (medium, partly prose-defined)

- [x] **DMA/cache-coherence — core vs library boundary (§18)** — core **done**
  (2026-06-06), effort **M**. The core tracks a buffer's *access mode and
  coherence* and how DMA-descriptor/cache operations compose with the §17/§19
  ordering rules; ownership/lifetime stays a library profile (out of core).
  - [x] Documented (§18 summary): the DMA **primitive** = `DmaAddr` address class
        + typed `DmaBuf<T, coherence>` + typed `cache.clean`/`cache.invalidate`
        + `dma_addr()`/`as_slice()` bridge (spatial/representational facts,
        always enforced).
  - [x] Decided (§18): buffer *lifetime and ownership* are a **library profile**
        (move-only handles, temporal/linear facts), **not** a core compiler
        guarantee. The previously listed "ownership state machine per `DmaBuf`"
        is therefore out of core scope.
  - [x] Core: the typed cache ops and `DmaBuf` modes gate coherent vs
        noncoherent access correctly — `cache.clean`/`cache.invalidate` on a
        `.coherent` buffer is rejected (`E_DMA_CACHE_MODE`, MIR-native
        `dma_cache_mode` finding); on a non-`DmaBuf` argument rejected
        (`E_DMA_OPERATION`); `dma_addr()`/`as_slice()` accepted on both modes;
        `DmaAddr` is not convertible to `PAddr`/`VAddr` (D.4 address-class).
        Covered by `tests/spec/dma_cache.mc`.
  - [x] Core: **DMA-descriptor ordering composes with §17/§19.** A typed MMIO
        write whose value is a `buf.dma_addr()` is recognized as a DMA-descriptor
        handoff and emits a `dma_descriptor … composes_with=section17_mmio
        participants=ordinary,atomic,dma_descriptor,mmio` fact; `cache.clean`/
        `cache.invalidate` emit `dma_cache_order` barrier facts
        (`before_device_handoff`/`before_cpu_read`) and a `cache.clean` seen
        before a `.release` descriptor write emits the
        `cache_clean_before_release` ordering edge — the clean-for-device may not
        be moved after the handoff. Fixture `tests/spec/dma_ordering.mc`
        (check `dma-ordering-composition`); green under `zig build test` + sweep.
  - [x] **DMA ownership library (`std/dma`) over linear `move` handles
        (§18.2)** — **done** (2026-06-07). The cpu/device typestate is two
        distinct `move` types, `CpuBuffer` and `DeviceBuffer`: `alloc`/`free`,
        `clean_for_device`/`invalidate_for_cpu` (consume-and-return), and
        `cpu_addr`/`device_addr`/`cpu_len` borrows. Reading a device-owned buffer
        is a compile error (the CPU-view borrow takes `*CpuBuffer`); using a
        buffer after handoff is `E_USE_AFTER_MOVE`; dropping it un-freed is
        `E_RESOURCE_LEAK`. Exercised end-to-end by the demo NIC driver under QEMU
        (`zig build nic-test`). _(Modeled with two move types rather than a
        3-parameter `DmaBuf<T, coherence, owner>` because generic structs don't
        yet take value/owner type-parameters; the safety is identical.)_

## Large subsystems (weeks, architectural)

- [x] **Full comptime execution (§22)** — **done** (2026-06-06), effort **L**.
  The comptime interpreter is complete: scalar/bool eval, `const fn` calls,
  `while`/`for`/`switch` control flow, comptime arrays + structs with mutation,
  named `const` globals, comptime parameters in both value and type-driving
  (monomorphization) forms, comptime↔type feedback (array lengths), reflection
  (`sizeof`/`alignof` via an ABI layout model validated against clang), and
  trap semantics (`E_COMPTIME_TRAP`). The three sub-items below are all complete:
  - [x] Tree-walking evaluator over typed AST/HIR — **done** for MC's comptime
        subset (scalars, `const fn` calls, `while`/`for`/`switch`, arrays +
        structs with mutation) —
        `eval.foldComptimeExpr`/`ComptimeScope` fold integer/bool literals,
        comptime `let`/`var` constant bindings, arithmetic, comparisons, and
        (short-circuiting) logical operators over the comptime block, with
        i128-overflow-safe arithmetic. **`const fn` calls** evaluate
        (`foldComptimeCall`/`foldComptimeFnBody`): a call to a `const fn` with
        constant arguments binds params and folds the body, bounded by a
        recursion fuel limit; sema exempts `const fn` calls from
        `E_COMPTIME_FORBIDS_RUNTIME_EFFECT` (only non-const/runtime calls are a
        forbidden effect). **Comptime control flow** in const-fn bodies is
        evaluated (`foldComptimeStmtSeq`/`foldComptimeWhile`/`foldComptimeForLoop`):
        `var` mutation, `while` *and* `for` loops with `break`/`continue` and a
        per-loop iteration fuel limit, and nested blocks — e.g. a Euclidean `gcd`
        and an array-summing `for` `const fn` both fold. **Comptime aggregate
        values** (`ComptimeValue.array`/`.@"struct"`): array literals (`.{…}`)
        fold to array values, indexing (`xs[i]`) folds with an out-of-bounds →
        `E_COMPTIME_TRAP`, `for x in xs` iterates them; struct literals
        (`.{ .field = … }`) fold to struct values with `.field` access — e.g. a
        `const fn rect_area(r) { return r.w * r.h; }` folds. **Comptime `switch`**
        (`foldComptimeSwitch`): a const fn dispatches on a constant subject via
        literal/`_` arms. **Comptime "memory"** (`foldComptimeAssign`):
        copy-on-write element/field stores (`a[i] = …` with out-of-bounds →
        `E_COMPTIME_TRAP`, `s.field = …`) let a const fn *build* aggregates —
        e.g. `make_squares()` fills `[4]usize` in a loop and folds. The
        tree-walking evaluator is now substantially complete for MC's comptime
        subset; only true pointer/aliasing comptime memory (which MC's comptime
        deliberately avoids) is out of scope.
  - [~] Comptime↔type feedback (comptime values as array lengths, etc.):
        **fixed-array lengths fold `const fn` results *and* named `const`
        globals** — `[align_up(3, 4)]u8` and `[MAX]u8` both validate and emit
        correctly. The folding helper (`comptimeUsizeValue`/`comptimeUsizeArrayLen`)
        is shared by all three array-length gates: sema (`parseArrayLen`/
        `checkType`), the MIR verifier (`addArrayLiteralShapeCheck`), and the C
        backend (`constArrayLenValue`), each threading a `const fn` registry and
        a folded-`const`-globals value map (`eval.collectConstGlobals` /
        `ComptimeScope.globals`). **Const globals** (`const NAME: T = …`) are a
        complete feature: parsed (`GlobalDecl.is_const`), comptime-const static
        initializer accepted (may reference earlier const globals, e.g.
        `DOUBLE = MAX * 2`), folded for array lengths + comptime asserts, and
        emitted as their folded C constant. Fixture `tests/spec/const_globals.mc`.
        **Comptime parameters** (`comptime CAP: usize`) are implemented for the
        value + comptime-assert form: the argument must fold to a compile-time
        constant (`E_COMPTIME_ARG_REQUIRED`), and the callee's `comptime { assert
        … }` blocks are re-checked with the parameter bound to that argument so a
        failure (e.g. `assert(is_power_of_two(CAP))` for a non-power-of-two)
        surfaces as `E_COMPTIME_TRAP` *at the call site* (`checkComptimeCallAsserts`
        / `foldComptimeBlockAt`). The parameter lowers to an ordinary C argument
        and the comptime block is elided. Fixture `tests/spec/comptime_params.mc`.
        **Comptime params that drive *types*** (e.g. `[N]u8` as an array length)
        now work via **monomorphization** (`src/monomorphize.zig`, run as a
        pre-sema AST pass in `parseModuleOrReport`): a function is *type-generic*
        if a comptime parameter appears in a type position; `transform` collects
        each call's instantiation (folding the comptime args), emits one
        specialized concrete function per distinct binding with the comptime
        parameters substituted everywhere (`[N]u8` → `[4]u8`, `N` → `4`) and
        removed from the signature, rewrites call sites to the mangled name
        (`zeros(4)` → `zeros__4()`), and drops the generic — so sema/MIR/backend
        see only ordinary concrete functions. **Crucially it is a no-op for
        modules with no type-generic function**, so the whole existing corpus is
        untouched. Mixed comptime+runtime params (`fill(comptime N, value)`) and
        multiple distinct instantiations (`zeros(4)` + `zeros(8)`) work. Coverage:
        unit tests in `monomorphize.zig`, `tests/c_emit_monomorphize.mc`
        (clang-checked), and `zig build mono-test` (specialized function linked +
        run, in `m0`).
        **User-defined generics** build on this: a `comptime T: type` parameter
        makes a function generic over a *type* (`fn max(comptime T: type, a: T,
        b: T) -> T`). The parser accepts the `type` meta-type, sema treats the
        type parameter as a valid type name throughout the signature/body and
        requires a *type* argument at call sites (`E_TYPE_ARG_REQUIRED`), and
        monomorphization substitutes the concrete type for `T` everywhere,
        emitting one specialized function per type argument (`max(u32, …)` →
        `max__u32`, `max(i32, …)` → `max__i32`). The `Subst` carries a value *or*
        a type name. Fixture `tests/c_emit_generics.mc`; runtime coverage in
        `zig build mono-test` (a generic `max` linked + run).
        **Generic structs** (`struct Name<T> { … }`) build on the same machinery:
        the parser accepts a `<T, …>` type-parameter list (`StructDecl.type_params`),
        sema treats the parameters as valid type names in the fields, and
        monomorphization scans type positions for `Name<U>` uses, generates one
        concrete `Name__U` struct per type argument (with `T` substituted in the
        field types), rewrites the uses, and drops the generic declaration — all
        to a fixed point, so generic structs and functions compose
        (`mk_pair(comptime T: type) -> Pair<T>`). This is the foundation for
        generic collections. Fixture `tests/c_emit_generic_structs.mc`; runtime
        coverage in `mono-test` (a `Pair<u32>` round-trip).
        **Generic collections** are now realized: `std/stack.mc` is a generic
        fixed-capacity `Stack<T>` with generic `push`/`get`/`len`/`is_empty`,
        imported and monomorphized per element type, verified end-to-end by
        `zig build stack-test` (linked + run). Building it fixed two array-backed
        struct bugs (below).
        **Reflection-as-comptime-value** (`sizeof(T)`/`alignof(T)`) now folds via
        an MC-side ABI layout model (`comptimeSizeOf`/`comptimeAlignOf`, wired
        into the comptime evaluator through a `ComptimeScope.reflect` callback):
        scalars, pointers, fixed arrays, closed enums (by repr), and plain structs
        whose fields share one alignment fold to the same value clang computes;
        anything order-dependent (mixed-alignment structs, field offsets) folds to
        `unknown` rather than risk an ABI mismatch. Validated by `zig build
        reflect-test`, which `_Static_assert`s the same `sizeof`/`_Alignof` against
        clang's real layout (in `m0`). The §22 comptime interpreter is now
        **complete**.
  - [x] Comptime trap / no-runtime-effect semantics: `foldComptimeBlock` in sema
        evaluates each `assert(...)` over the folded scope and reports
        `E_COMPTIME_TRAP` when the condition is provably false or the const eval
        itself traps (divide-by-zero, invalid shift) — superseding the old
        literal-`false`-only check. Non-constant conditions fold to `unknown`
        and are not diagnosed. No-runtime-effect rules
        (`E_COMPTIME_FORBIDS_RUNTIME_EFFECT`) were already enforced. Fixtures:
        new accept/reject cases in `tests/spec/comptime.mc` (true/false
        comparisons, const-binding assertions, divide-by-zero) plus a
        `foldComptimeExpr` unit test in `eval.zig`.

- [x] **Production typed MIR/CFG + verifier** — core milestone **done**
  (2026-06-06). `src/mir.zig` is the production MIR entry point used by
  `mcc verify` and `emit-c`: basic blocks, typed instruction categories, explicit
  trap blocks/edges, contract-region ids, and MIR verifier facts. The older
  `ir.zig` remains a compatibility fact collector for spec inspection.
  Scope of "done": the typed CFG exists and is authoritative, and the D.1–D.6
  verifiers run as real MIR passes (81 MIR-native diagnostics; every D-invariant
  *usage* check migrated — the only sema-resident D-codes left are
  declaration/type well-formedness that Annex B *places* in sema). Evidence: full
  unit suite green, `zig build sweep` (54 spec fixtures / 348 functions) green,
  and `zig build c-test` green. Two genuinely **open-ended** tails (deeper
  value-range optimizer *algebra* and lowering the C backend *uniformly from*
  MIR) are explicitly carved into their own follow-on items below and under tech
  debt — they are research/architecture tier, not blockers for this milestone.
  - [x] Basic-block CFG with typed instructions and explicit trap edges
        (Appendix B/E).
  - [x] D.1–D.6 verifiers as complete real passes over MIR (Appendix D, incl.
        D.6 Context Verifier for `#[irq_context]`). Current MIR verifies
        fallthrough, structural CFG invariants including block-id/index
        consistency, `#[no_lang_trap]` trap edges, matching unsafe-contract
        regions, strict `unsafe {}` context checks for raw store, MMIO map,
        opaque asm, and raw-many pointer dereference, D.1 duplicate switch cases for scalar/Result/enum/union
        patterns plus switch literal-pattern type validation, enum/union
        switch case validation, and closed-enum exhaustiveness,
        D.2 complete checked binary trap-edge emission for unsigned
        division/remainder divide-by-zero, signed division/remainder
        divide-by-zero plus min/-1 overflow, left/right-shift invalid-count,
        and left-shift shifted-out-bit overflow,
        D.2 invalid-representation trap edges for runtime non-null pointer
        and closed-enum representation checks, while raw-many pointer and
        `ptr.offset` representation facts remain non-trapping,
        D.4 direct address-class dereference/opaque-operation rules and
        address-class conversion mismatch checks, including DmaAddr to
        PAddr/VAddr diagnostics,
        D.1 assignment target mutability and const-view write checks,
        including casted const pointer/slice storage views,
        D.1 arithmetic-domain misuse checks for implicit domain mixing,
        domain division/remainder, forbidden bitwise operands, and forbidden
        ordered comparison (`< <= > >=`) on `wrap`/`serial`/`counter` (allowed on
        `sat`) across `wrap`/`sat`/`serial`/`counter` aliases,
        D.1 operator operand checks for unsigned negation, logical bool
        operands, and bitwise signed/bool/pointer/generic operand misuse,
        D.1 binary numeric compatibility checks for signed/unsigned integer
        mixing, implicit integer promotion, float/integer mixing, and f32/f64 mixing,
        D.5 representation checks for boundary-returned non-null pointers and
        closed enums, D.1 null-to-non-null and nullable-to-non-null pointer
        conversions at target-typed sites, target-typed return/local/assignment,
        direct-call argument, condition-site, `for` iterable, and index
        base/operand conversion checks for the MIR type classes it currently preserves (including
        pointer mutability/view, pointee, and `c_void` boundary rejection),
        explicit cast result types for conversion/nullability facts,
        target-typed integer literal range checks,
        typed MMIO `Reg`/`RegBits` access-mode checks for read/write receiver
        calls (with MIR `pass=mmio` facts and `E_MMIO_ACCESS_FORBIDDEN`),
        direct target-typed array/struct aggregate literal element/field
        conversion recursion and aggregate shape checks for locals, returns,
        assignments to named locals, and direct-call arguments, including
        type-alias-resolved aggregate targets and cast-wrapped aggregate literals,
        a conservative D.1 Result pass for invalid `?`, invalid if-let and
        Result-switch branch patterns, unhandled Result
        statements/defers/switch expression arms/locals/reassignment, including
        Result locals handled through switch arm bodies and aggregate literal
        elements/fields, and
        try-payload return type compatibility plus target-typed
        local/assignment/call-argument and aggregate-field payload
        compatibility, including pointer mutability/view
        rejection for `?` payloads where MIR preserves the pointer class,
        including cast-wrapped try payloads, plus
        call-context summaries. MIR type alias resolution also feeds checked integer
        classification and `wrap`/`sat` arithmetic-domain trap suppression,
        including explicit casts into arithmetic-domain aliases.
        D.5 now also emits typed-load representation checks for global/local
        identifier reads, if-let narrowed bindings, and struct-field
        projections of non-null pointers and closed enums; target-context
        representation checks cover closed-enum literals and address-of pointer
        producers in globals, locals, returns, assignments, aggregate
        elements/fields, and direct-call arguments; and the MIR verifier checks
        predecessor-path dominance for representation-sensitive returns plus
        explicit representation-use markers for globals, locals, assignments,
        aggregate literal elements/fields, and direct-call arguments. Nested
        member/index/deref expressions in target-typed aggregate fields/elements
        now also emit explicit D.5 representation-use markers, casts are
        transparent for target-context D.5 representation checks, and ordinary
        non-null pointer dereference bases now emit `deref_base` representation
        uses while raw-many unsafe deref remains non-trapping/non-consuming.
        Representation-sensitive binary operands now emit `binary_operand`
        representation-use markers, with closed-enum literals kept as intrinsic
        compile-time values until a target context materializes a checked enum
        value, and representation-sensitive switch subjects
        now emit `switch_subject` representation-use markers for control-flow
        dispatch. `try` unwrap payloads that produce representation-sensitive
        values now emit `try_unwrap` representation-use markers.
        Nested
        assignment target paths
        (`field`, deref, and index storage targets) now resolve target types in
        MIR for conversion and representation-use checks. MIR also preserves
        inferred local type expressions for aggregate copies, direct function
        returns, `?` payload unwrapping, and narrowed `if let`/`switch`
        bindings, and emits D.5 typed-load representation checks for
        representation-sensitive deref/index/member projections, including
        copied array/struct values and array/struct values returned from calls.
        The verifier now also matches representation-sensitive producers and
        uses by MIR value identity when the producer/use carries one, including
        pointer-producing call results and inferred raw-many pointer offsets,
        with regression coverage for predecessor-path dominance of matching
        and mismatched value identities.
        MIR also distinguishes indirect calls from known direct calls and
        conservatively rejects them in `#[no_lang_trap]`/`#[irq_context]`
        contexts unless a typed callee summary can prove the target; the D.6
        verifier now emits MIR verification facts for context-call findings,
        distinguishes known blocking IRQ calls from unproven callees, and
        recognizes typed atomic/MMIO receiver methods as IRQ-safe primitives.
        (Value-identity matching for representation checks is MIR-native and
        regression-tested; broader aggregate value identity through more complex
        nested copies keeps a sema backstop — carved into the "MIR optimizer
        depth" follow-on below, not a gap in the D.1–D.6 milestone.)
  - [x] Value-range fact propagation from `#[unsafe_contract(no_overflow)]`
        regions (§8.4): the escape-hatch *syntax* already works, but the
        optimizer benefit (assuming covered ops don't overflow and propagating
        the resulting ranges) needs the MIR. Current MIR records scoped
        `RangeFact` entries for semantic top-level `unchecked.add/sub/mul`
        covered by `no_overflow` (transparent grouping and top-level casts do
        not hide a top-level operation), including the target result type for return,
        local, assignment, direct-call argument, and target-typed aggregate
        element/field facts; C lowering now consumes matching MIR range facts
        for top-level `unchecked.add/sub/mul` return/local/assignment paths,
        including inferred `u32` locals and cast-wrapped scalar
        return/local/assignment values,
        direct-call argument `unchecked.add/sub/mul` range facts including
        cast-wrapped arguments, and
        target-typed aggregate return/local/assignment/call-argument element
        and field facts including cast-wrapped elements/fields, and nested
        binary-operand facts before emitting plain overflow-free C arithmetic.
        Regression coverage: `tests/c_emit_value_range.mc` (constant-operand
        elimination) and `tests/c_emit_mir_value_range_contract.mc` (no_overflow
        range-fact consumption across return/local/nested/cast/aggregate-field).
        Deeper optimizer consumption (value-range *algebra* and downstream
        propagation past the materializing site) is open-ended and carved into
        the "MIR optimizer depth" follow-on below — not a blocker for this
        milestone, since MC's grammar produces no integer-range guards to analyze
        beyond the constant + contract sources already handled (see GRAMMAR NOTE).
  - [x] D.2 precise trap classification for the scalar/domain builtins and
        floats: `trap_from` emits a real trap edge; `from`/`wrap_from`/`sat_from`/
        `from_mod`/`try_from`/`residue` and the serial/counter ops
        (`before`/`after`/`distance`/`compare`/`delta_mod`/`elapsed_*`) emit none;
        IEEE float `+ - * /` and unary `-` emit none. This removed a class of
        `#[no_lang_trap]` false positives (pure casts/float math wrongly rejected)
        and a false negative (`trap_from` wrongly allowed). Regression fixture:
        `tests/spec/no_lang_trap_conversions.mc`.
  - [x] sema/MIR consistency for this case: `mcc check` (sema) now also flags
        `trap_from` under `#[no_lang_trap]`, matching the MIR verifier. `mcc check`
        remains a lighter type-check pass overall (the MIR verifier is the
        authoritative trap/contract/representation/context verifier, run by
        `verify` and `emit-c`); fully aligning the two passes is open.
  - [x] D.1 ordered-comparison domain operand check migrated to a MIR-native pass
        (`E_ORDERED_ARITH_DOMAIN_OPERAND` on `wrap`/`serial`/`counter`). Fixture:
        `tests/spec/mir_domain_ordering.mc`.

  - [x] D.1/D.4 check migration batch (10 checks, sema-only → MIR-native passes):
        ordered-comparison (`E_ORDERED_ARITH_DOMAIN_OPERAND`), pointer
        arithmetic on single-object pointers (`E_POINTER_ARITH_SINGLE_OBJECT`),
        pointer/view ordering (`E_POINTER_ORDERING`), serial/counter/conversion
        operation legality (`E_SERIAL_OPERATION`/`E_COUNTER_OPERATION`/
        `E_CONVERSION_OPERATION`), `c_void` dereference + member access
        (`E_C_VOID_DEREF`/`E_C_VOID_NO_LAYOUT`), direct MMIO register
        assignment (`E_MMIO_DIRECT_ASSIGN`), and array-to-pointer decay
        (`E_ARRAY_TO_POINTER_DECAY`). MIR-native diagnostic codes: 63 → 72.

  - [x] **D-invariant *usage* check migration — second batch (10 checks):** the
        remaining D.1/D.4/D.5 usage checks now emit MIR-native findings with
        regression fixtures: `E_MMIO_ORDERING` (`tests/spec/mmio_ordering.mc`),
        `E_ATOMIC_OPERATION`/`E_ATOMIC_ORDERING` (`tests/spec/atomics.mc`),
        `E_DMA_OPERATION`/`E_DMA_CACHE_MODE` (`tests/spec/dma_cache.mc`),
        `E_BITCAST_TYPE` (`tests/spec/bitcast_aliasing.mc`),
        `E_ARRAY_TO_POINTER_DECAY`, `E_LOCAL_ADDRESS_ESCAPE`,
        `E_ENUM_RAW_REQUIRES_OPEN_ENUM`, and
        `E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION` (each via a `finding ->
        code` mapping plus a production site in `src/mir.zig`). MIR-native
        diagnostic codes: 72 → 81.

  - [x] **D-invariant *usage* check migration — complete.** All D.1/D.4/D.5
        *usage* checks (those that operate on MIR instructions/values/operations)
        are now MIR-native. The one previously-listed straggler,
        `E_MC_VOID_POINTER_FFI`, was re-examined and is **not** a usage check: it
        fires in `checkType` purely on the raw type-annotation *spelling* ("at a
        C-ABI opaque boundary you wrote MC `void` where `c_void` is required").
        MIR does not preserve that `void`-vs-`c_void` annotation spelling (types
        are resolved by then), so there is nothing for a MIR pass to operate on.
        It belongs to the declaration/type well-formedness family below — moved
        there — which the Annex B pipeline correctly places upstream of MIR.

  - NOTE (scoping per Annex B): `E_MC_VOID_POINTER_FFI`, `E_MMIO_REGBITS_TYPE`,
    `E_MMIO_REGISTER_WIDTH`, `E_MMIO_REGISTER_POSITION`, `E_MMIO_PTR_TARGET`,
    `E_MMIO_ACCESS_MODE`, and `E_DMA_BUF_MODE` are **declaration/type
    well-formedness**, which the spec pipeline (Annex B) places in the typed
    AST/HIR stage *upstream* of the MIR — they correctly stay in sema and are
    not MIR-verifier gaps.
  - [x] **Value-range optimizer — constant trap elimination + propagation**:
        a checked `+`/`-`/`*` whose exact result (computed in `i256`) fits the
        target type lowers to **plain C arithmetic**, no overflow helper. This
        covers literal operands *and* constants propagated through immutable
        (`let`) integer locals (`constIntValue`/`constLocalValue`/
        `constBinaryProvenNoOverflow` in `lower_c.zig`): e.g. `let x:u8 = 200;
        let z:u8 = x + 50;` emits `x + 50` plain. Runtime and possibly-
        overflowing operands stay checked. Fixture: `tests/c_emit_value_range.mc`.
  - GRAMMAR NOTE: the classic **dominating-comparison-guard lattice**
    (`if x < 100 { ... x + 1 ... }`) is **not expressible in MC** — the language
    has no plain `if cond { }`, only `if let` (optional/Result narrowing) and
    `while`/`for`/`switch`. So integer-range guards from boolean `if`s simply do
    not exist to analyze. The implemented constant-operand + constant-local
    propagation covers MC's compile-time-known value-range sources; the only
    remaining (niche) source is constant-bounded `while i < CONST` loop bodies,
    which also needs reassignment tracking. The value-range optimizer is thus
    materially complete for what MC's grammar can express.

- [ ] **MIR optimizer depth & uniform lowering (follow-on to the production
  MIR milestone)** — effort **XL** (large engineering, no functional gap). The
  production typed MIR/CFG + verifier milestone above is done; this is the
  architectural follow-on (doable, but a multi-week refactor with no user-facing
  behavior change — the current backend works):
  - [ ] **Broader aggregate value-identity in MIR**: move the remaining
    complex-nested-copy value-identity tracking off its sema backstop and onto
    MIR value ids (scalar/pointer/closed-enum identity is already MIR-native and
    regression-tested).
  - [ ] **Uniform lowering from MIR** (the real architectural XL): lower the C
    backend uniformly *from* the typed MIR instead of today's AST-shape
    special-case matching in `lower_c.zig`. Tracked in detail under tech debt
    ("C backend is special-case matching, not a uniform lowering"); listed here
    too because it is the structural endgame these passes enable.

- [x] **Broader C-backend conformance (core emission)** — effort **L**.
  Scope: `src/lower_c.zig` faithfully lowers every construct the front-end
  (parser + sema + MIR verifier) accepts and that declares a `lower-c` phase.
  As of the 2026-06-06 audit + empirical sweep this is **complete and
  evidenced**, with the standing caveat that it is a *living* target: each new
  language feature adds new lowering, and "no known reachable defect" means
  validated-by-sweep, not exhaustively proven (two earlier "closed" claims this
  cycle were later disproven by deeper probing, which is why the evidence below
  is empirical rather than asserted).

  Evidence: `tools/spec-emit-sweep.py` (run via `zig build sweep`, also part of
  the `m0` gate) strips the `EXPECT_ERROR` functions from all 54
  `tests/spec/*.mc` fixtures and `emit-c` + `clang -std=c11 -Wall -Wextra
  -Werror`'s the ~348 remaining valid functions — all compile, except the two
  documented out-of-scope items it allowlists (`dma_cache.mc` DmaBuf =
  library-profile per §18; `unsafe_context.mc`'s `mmio.map<T>(pa)?` lives in a
  `phase=sema` fixture, so C emission is not a declared target). The reachable
  feature gaps found this cycle are closed (sub-items below); 10 new
  `tests/c_emit_*.mc` fixtures lock them in.

  Bail-site classification (all 128 audited): ~100 are one-line defensive
  guard-rails — call/type-arg arity (`call.args.len != N`), type-class lookups
  (`typeName(...) orelse`, `checkedTypeSuffix`, `primitiveCTypeName`),
  struct/array shape lookups — that sema validates *before* emission, so they
  are unreachable for sema-accepted programs. Of the 27 bare bails, the
  reachable feature gaps are closed; the rest guard shapes sema/parser already
  reject (non-static global initializers `E_GLOBAL_INITIALIZER_NOT_STATIC`,
  if-let patterns other than optional/Result bindings `E_IF_LET_NARROW_PATTERN`,
  precise inline asm `E_PRECISE_ASM_UNSUPPORTED`).

  Out of scope for this item (not `lower_c.zig` gaps): language constructs MC
  deliberately omits or never specified — plain `if cond {}`
  (`MC_0.6.1_Final_Design.md`: "a deliberately narrow `if let` form"),
  function-pointer types, sub-slicing
  `a[i..j]`, switch range patterns (all rejected upstream in the parser/sema) —
  and library-profile types (serial/counter/DmaBuf, explicitly out of core
  conformance, §18). Lowering those would require front-end/language work and
  is tracked by their own items, not here.

- [ ] **C-backend conformance — ongoing maintenance.** As new language/library
  features land (Standard library, full comptime, precise inline asm, etc.),
  add their C lowering and a `tests/c_emit_*.mc` fixture; `zig build sweep`
  (`tools/spec-emit-sweep.py`, also in the `m0` gate) re-runs the spec-corpus
  emit+clang check to catch regressions. This is the perpetual tail of the
  item above.
  - [x] Aggregate typedef ordering: generated container typedefs (slices,
        arrays, `Result`) reference user structs, and structs embed those
        containers, so emitting them in a fixed category order produced
        forward-reference errors (`[]Packet`/`[4]Packet`/`struct { []Inner }`
        all failed `clang` with "unknown/incomplete type"). Now every user
        struct and tagged union is forward-declared up front (so pointer/slice
        references resolve), and arrays/structs/`Result`s/tagged-unions are
        emitted in dependency order (`emitOrderedAggregates`) so by-value
        embedding sees complete types. Array and `Result` typedefs are
        forward-declared too, so a slice of an array (`[][N]T`, element pointer
        `mc_array_..._N *`) resolves. Fixture
        `tests/c_emit_aggregate_ordering.mc`.
  - [x] Nested (multidimensional) array indexing `m[i][j]` over `[N][M]T` now
        lowers correctly: `arrayTypeForExpr` recurses through index bases so
        each dimension indexes its `.elems` member with its own bounds check
        (`m.elems[check(i,N)].elems[check(j,M)]`), instead of emitting an
        invalid `m.elems[..][j]`. Same fixture.
  - [x] Empirical spec-corpus sweep (2026-06-06): stripped the `EXPECT_ERROR`
        functions from all 54 `tests/spec/*.mc` fixtures and `emit-c` +
        `clang -Werror`'d the ~348 remaining valid functions. Found and fixed
        three reachable emission bugs (below); the only residual failures are
        `dma_cache.mc` (DmaBuf, explicitly library-profile/out-of-core, see §18
        above) and `unsafe_context.mc`'s `mmio.map<T>(pa)?` (a `phase=sema`
        fixture — C emission is not a declared target there).
  - [x] Signed-repr enums with negative discriminants (`enum E: i8 { n = -1 }`)
        now lower: the enum-value emitter handles unary negation, not just bare
        integer literals. Fixture `tests/c_emit_signed_enum.mc`.
  - [x] The explicit `wrapping.add(a, b)` builtin now lowers to plain C `+`
        (modular, no trap edge), matching `a + b` on `wrap<T>` operands;
        previously it emitted an undeclared `wrapping` identifier. Fixture
        `tests/c_emit_wrapping_builtin.mc`.
  - [x] `Result<void, E>` (e.g. `return ok(())`) now lowers: C has no `void`
        struct member, so a void Result payload uses a 1-byte placeholder and
        the unit value `()` stays `0`. Fixture `tests/c_emit_void_result.mc`.
  - [x] Character literals (`'x'`, `'\n'`, …) now lower to C — MC's escape set
        (`\\ \' \" \0 \n \r \t`) is a subset of C's, so the lexeme emits verbatim
        in returns, typed locals, and call arguments. Fixture
        `tests/c_emit_char_literals.mc`.
  - [x] Checked integer arithmetic assigned into a struct field or array
        element (`r.v = a + b`, `xs[0] = a * 2`) now lowers through the checked
        helper. The assignment path carries no target type for `.member`/`.index`
        targets, so `emitCheckedBinary/UnaryWithTarget` now decline (return false)
        on a null target instead of erroring, letting `emitExpr` infer the type
        from the operands. Fixture `tests/c_emit_checked_in_assignment.mc`.
  - [x] Checked integer arithmetic used as a comparison operand (e.g.
        `(a + b) == c`) now lowers through the checked helper instead of
        bailing: the targetless `emitExpr` binary path recovers the operand
        storage type via `numericExprTypeForEmission` and delegates to
        `emitCheckedBinaryWithTarget`, so the overflow trap edge survives.
        Covers add/sub/mul/div, signed/unsigned, nested, and logical
        connectives. The same recovery applies to targetless signed
        negation (`(-a) == b` → `mc_checked_neg_i32`), while wrap/sat
        negation stays plain. `numericExprTypeForEmission` also lets a bare
        numeric literal adopt its sibling operand's type, so `a + 1` resolves
        (e.g. `while (i + 1) < n`, `(a + 1) == a`).
        Fixture `tests/c_emit_checked_in_comparison.mc`.
  - [x] `?` (try) nested inside other expressions now lowers in more shapes:
        (a) `?` as a typed-local initializer in a non-`Result` function (unwrap
        with trap-on-err, not just the propagation case `emitResultTryExprLocalInit`
        previously required); (b) `?` inside an `ok(...)`/`err(...)` constructor
        argument (`return ok(a?)`, `return ok(dbl(a?))`) via a new
        `emitResultTryConstructorReturn`; (c) two `?` operands in one
        sub-expression (`ok(a? + b?)`) — fixed a short-circuit `or` in the
        `collectResultTryHoistsFor{Return,LocalInit}` binary/index cases that
        previously hoisted only the left operand's try. Fixture
        `tests/c_emit_try_in_expressions.mc`.
  - [x] String literals now lower to C. They require a target type (sema
        rejects targetless ones) and emit a C string literal cast to the target
        u8-pointer type (`*const u8` -> `(uint8_t const *)"…"`); MC's escape set
        is a subset of C's so the lexeme emits verbatim. This needed a MIR
        verifier change too: a string literal is a non-null pointer by
        construction, so `exprNeedsTargetRepresentationCheck` now treats it like
        `address_of`, emitting the dominating `representation_check` that
        discharges the `nonnull_pointer` obligation (previously the
        `return_value`/`call_arg` use tripped `E_REPRESENTATION_CHECK_MISSING`).
        Fixture `tests/c_emit_string_literals.mc`.
  - [x] Atomic locals (§19) now lower to C: an `atomic<T>` local becomes its
        plain payload object, `atomic.init(v)` becomes the initial value, and
        `obj.load/store/fetch_add(..., .ordering)` become
        `__atomic_load_n` / `__atomic_store_n` / `__atomic_fetch_add` on `&obj`
        with the mapped `__ATOMIC_*` order constant — matching the inspector's
        existing `atomics-lowering` facts. Previously only the inspector facts
        existed and emission bailed. Fixture `tests/c_emit_atomics.mc`.
  - [x] Generated C no longer `#include <string.h>`; internal struct/bitcast
        copies use `__builtin_memcpy` (the emitter already requires GCC/clang
        builtins via `__builtin_trap`). This stops libc fortify macros (e.g.
        macOS `#define memcpy(...) __memcpy_chk_func(...)`) from mangling user
        FFI declarations like `extern "C" fn memcpy(...)`, which previously
        broke `tests/c_emit_c_void_ffi.mc` under `clang -Werror`.

## Engineering tracks (large, low conceptual risk)

- [~] **Standard library** — effort **L+**, open-ended; the design doc does not
      fully specify one, so scoping is the hard part. _v0 landed_ — three pure,
      total modules of `export const fn`s that both **fold at comptime** (usable
      in `comptime { assert … }` / const globals) and are **linkable runtime
      symbols** (compile with `mcc-cc` to an object and link against application
      code):
      - `std/core.mc`: `min`/`max`/`clamp` (u32 + usize), `is_power_of_two`,
        `align_up`/`align_down`.
      - `std/bits.mc`: `count_ones`, `is_aligned`, `low_mask`, `is_single_bit`,
        `next_power_of_two`, `trailing_zeros`, `is_even`, `is_odd`.
      - `std/math.mc`: `gcd`, `lcm`, `pow_u32`, `ilog2`.
      - `std/ascii.mc`: `is_digit`/`is_upper`/`is_lower`/`is_alpha`/`is_alnum`/
        `is_whitespace`, `to_upper`/`to_lower`, `digit_value` (using char
        literals; landing this fixed a char-literal-in-checked-arithmetic
        C-backend bug, below).
      - `std/fmt.mc`: integer formatting — `format_u32` (renders a u32 to a fixed
        decimal digit buffer + length, no libc) and `digit_char`. Landing this
        fixed a serious `break`/`continue`-inside-`switch`-inside-loop
        miscompilation (below).
      - `std/stack.mc`: a generic `Stack<T>` collection (runtime `stack-test`).
      - **Driver-library profile (§28)** added for the NIC prototype:
        `std/sync` (locks + linear guards), `std/dma` (DMA ownership),
        `std/ring` (generic ring buffer), `std/endian` (byte order),
        `std/time` (ticks/delays), `std/barrier` (memory barriers) — see the
        Prototype-goal section at the top.
      Verified by `zig build std-test` (`tools/std-test.sh`, in `m0`): compiles
      the core modules, links them against a C driver, and runs value checks
      (plus the per-library link/run tests sync-test / move-test / stack-test and
      the integration nic-test).
      Landing this surfaced and fixed two real bool-`switch` bugs (below).
      A **module/import system** now consumes it ergonomically (see Package
      manager / toolchain). Still open: the broader library scope (collections,
      slices, formatting, allocators).
- [~] **Package manager / toolchain / releases** — effort **L+**, plumbing, not
      language work. _Toolchain driver landed:_ `tools/mcc-cc.sh` (the `mcc-cc`
      driver) lowers an MC module to C and invokes clang to produce a linkable
      object — host or cross-target (e.g. `--target=riscv64-unknown-elf`) via
      passthrough flags. Verified end-to-end by `zig build cc-test`
      (`tools/mcc-cc-test.sh`, also in `m0`): an MC module compiles to an object,
      links against a C driver, and runs with the right result.
      _Module system landed:_ `import "path";` declarations are expanded by
      textual inclusion in `src/loader.zig`. **Path resolution (2026-06-07):** an
      *explicitly-relative* path (`./foo.mc`, `../bar.mc`, absolute) resolves
      against the importing file's directory; a *rooted* path (e.g.
      `std/sync.mc`) is resolved by walking up the importer's ancestor
      directories (then the cwd) to the first existing match — so
      `import "std/sync.mc"` works from any depth in a project without
      `../../` prefixes (the driver/library files use this). The merged source is
      the root file first (so its line numbers are preserved) followed by each
      transitively-imported file once (deduped), with the `import` statements
      blanked in place. `import` is recognized lexically, so no parser/sema/
      backend changes were needed; the C backend now forward-declares every
      defined function so cross-file / out-of-order calls resolve under
      `-Werror` (regression `tests/c_emit_forward_decl.mc`). Resolved paths are
      canonicalized (`std.fs.path.resolve`), so a file reached via different
      relative paths (a diamond import) is included exactly once. Verified by
      `zig build import-test` (a module that diamond-imports a sibling via two
      different paths plus `std/core`, compiled/linked/run; in `m0`).
      _Package manager landed:_ `tools/mcc-pkg.sh` reads a declarative
      `mcpkg.txt` manifest (`name`/`version`/`entry`/`output` + a `[deps]`
      section). `mcc-pkg build` resolves and version-checks dependencies, then
      lowers the entry module (whose `import`s pull in package-local modules and
      dependencies) to a linkable object via `mcc-cc`; `mcc-pkg deps` prints the
      resolved dependency graph; `mcc-pkg info` prints the manifest.
      **Dependency resolution**: each `[deps]` entry is `name = path@version`;
      mcc-pkg locates the dependency package, **verifies its manifest version
      matches** the requested one (failing the build on a missing dep or version
      mismatch). Verified by `zig build pkg-test` (`tests/pkg/`: a manifest with a
      `mathlib@0.1.0` dependency + a package-local module + a std dependency,
      whose `deps` resolves, `build` produces an object with all three packages'
      symbols, and which links/runs; in `m0`). Still open (all local /
      in-project, no external service needed): semver range matching (today
      exact-version), release packaging (archive a built package), an
      `mcc`-native `build` subcommand, and richer import semantics (namespacing,
      visibility, cross-file diagnostics with original line numbers — today
      imported-file errors report into the combined source).
- [x] **Hardware MMIO execution tests** — done (2026-06-06), effort **M**. A
      typed-MMIO MC program (`tests/qemu/uart_mmio.mc`: a 16550 `Uart16550` and an
      `export fn uart_putc` doing a `.release` `thr.write`) is lowered to C,
      linked into a bare-metal riscv64 image (`tests/qemu/runtime.c` +
      `virt.ld`), and run under `qemu-system-riscv64 -machine virt`; the harness
      (`tools/qemu-mmio-test.sh`, `zig build qemu-test`, also in `m0`) asserts the
      emulated UART at `0x1000_0000` actually received the bytes written through
      the MMIO lowering. Self-skips when a riscv cross-toolchain or QEMU is
      absent, so it never breaks toolchain-light environments.

## Known implementation issues / tech debt

From an external static review; each verified against the code.

- [x] **Typed memory access through pointers (the DMA-region bridge)** — added
      for the virtio-net driver's split virtqueue, so a memory-mapped structure at
      a runtime address is *typed* (and array indexing is bounds-checked) rather
      than raw `raw.store`/offset arithmetic. Three fixes let `*Struct` pointers
      compose with the existing member/array machinery: (1) the MIR `memberType`
      and the C backend `structTypeNameForExpr` now resolve a struct field through
      a pointer base (`q.field` / `q.arr[i]` over `q: *Virtq`); (2) `q.field = …`
      / `q.arr[i] = …` through a `*mut` pointer is permitted — both the sema and
      MIR `immutableValueStorageBase` checks treated the immutable pointer
      *binding* as immutable storage, ignoring that the pointee is mutable (a
      `*const` pointer is still rejected by `constStorageBase`); (3) a checked op
      over a pointer-deref recovers its type (`numericExprTypeForEmission` `.deref`
      case). With these, `q.desc[i].addr = …` lowers to bounds-checked
      `q->desc.elems[i].addr = …`. Exercised by `zig build virtio-test`.
- [x] **Member access on a pointer base lowered as `.` not `->`** — found
      building the driver libraries (every borrow helper takes a `*Handle`):
      `b.field` over `b: *T` emitted `b.field` instead of `b->field`, which clang
      rejects. Fixed: the C backend now emits `->` when the member base is a
      pointer expression (`exprIsPointer`), `.` otherwise; MMIO/slice/array
      accesses keep their dedicated paths. Exercised by `std/dma`/`std/sync`
      borrows (nic-test) and the host-emit check.
- [x] **Checked op / cast over a pointer-deref or wrap value couldn't recover
      its type** — `p.* + 1` (over `p: *u32`) and `(wrap_value) as u64` bailed
      with `UnsupportedCEmission` in a targetless position, because
      `numericExprTypeForEmission` had no `.deref` case and the wrap subtraction
      wasn't reachable through a target. Fixed the `.deref` recovery (via
      `derefPointeeType`); the wrap-in-cast case is worked around by binding to a
      typed local first. Exercised by `std/sync`'s `counter.* + delta` and
      `std/time`'s `elapsed`. _Follow-up (2026-06-07):_ added the `.cast` case too,
      so `(x as u32) << 8` and similar recover their width (a cast result is its
      target type) — found building the `framebuffer` demo's pixel packing.
- [x] **Inconsistent C-identifier mangling for fields named after C keywords** —
      surfaced by an external review (most of which was hallucinated, but this was
      real). Struct/MMIO field *declarations* routed through `cIdent` (which
      mangles C reserved words, `register` → `register_`), but member access
      (`p.register`), struct-literal fields (`.register = …`), and MMIO `->field`
      access emitted the raw name — so a field named after a C keyword produced a
      name mismatch / invalid C. Fixed: all four output sites (two member-access,
      two struct-literal) plus the MMIO field declarator and `MmioAccess.field`
      output now route through the same `cIdent` (the AST-side field lookups stay
      on the raw MC name). Regression `tests/c_emit_c_keyword_idents.mc`
      (`default`/`register`/`volatile` fields in a plain struct and an MMIO
      register, read/written/constructed). Matters for the driver libraries, whose
      register structs use hardware field names. _(Param-name mangling at MMIO
      `->` access is the same class and a candidate follow-up; not yet hit.)_
- [x] **Array-typed struct field access mis-emitted** — found building the
      generic `std/stack`: indexing an array-typed struct field (`s.items[i]`)
      emitted `s.items[i]` instead of `s.items.elems[i]` (array types lower to a
      `{ elems[] }` struct), and a checked op on a struct field / array element
      operand (`s.len + 1`) couldn't recover its type. Fixed: `arrayTypeForExpr`
      and `numericExprTypeForEmission` now resolve array/numeric struct-field
      member types via the struct registry, so `s.items[i]` → `s.items.elems[i]`
      and `s.len + 1` lowers through the checked helper. Regression: `std/stack`
      (`zig build stack-test`).
- [x] **`break`/`continue` inside a `switch` inside a loop miscompiled** — a
      serious one, found while building `std/fmt`: MC lowered switches to C
      `switch`, so a `break` in a switch arm broke the *switch*, not the
      enclosing loop — the loop never terminated and trapped on a later bounds
      check (e.g. a digit-extraction `while … { switch … { … break; } }` looped
      forever). Fixed: each loop tracks whether its body has an own
      `break`/`continue` and emits labeled targets (`mc_break_N:`/`mc_continue_N:`),
      and `break`/`continue` lower to `goto` to the innermost loop's label, so
      they reach the loop through any intervening `switch`. Plain loops without
      break/continue are unchanged. Regression: `std/fmt`'s `format_u32`
      (exercised at runtime by `zig build std-test`).
- [x] **Char literal in checked arithmetic mis-emitted** — found while building
      `std/ascii`: a targetless `c - '0'` (e.g. inside a cast `(c - '0') as u32`
      or a switch arm) bailed with `UnsupportedCEmission`, because the C backend's
      operand-type recovery (`numericExprTypeForEmission` →
      `exprIsNumericLiteral`) treated only int/float literals as sibling-adopting,
      not char literals. Fixed: a char literal now adopts its sibling operand's
      integer storage type, so the checked-subtraction helper is emitted with the
      right width. Regression `tests/c_emit_char_arithmetic.mc`.
- [x] **Bool `switch` on an expression mis-analyzed (subject not seen as bool)** —
      found while building `std/core`: `switch a < b { true => …, false => … }`
      (and `&&`/`||`/`!` subjects) tripped `E_RETURN_MISSING` in sema and
      `-Wswitch-bool`/`-Wreturn-type` in the C backend, because both sides only
      recognized a bool *variable*, not a bool-valued *expression*. Fixed:
      `exprResultType` (sema) and `exprIsBoolForEmission` (lower_c) now classify
      comparison/logical operators as `bool`, so such switches are exhaustive and
      lower to an `(int)`-cast subject with a trap `default`. Bool switches were
      previously sema-only fixtures (never C-emitted), so this path was untested;
      regression fixture `tests/c_emit_bool_switch.mc` now clang-checks it.
- [x] **`emit-c`/`lower-*`/`facts` wrote artifacts to stderr** — fixed: generated
      output now goes to stdout (`writeStdout` in `main.zig`); diagnostics/logs
      stay on stderr; `tools/check-generated-c.sh` updated to capture with `>`.
- [ ] **C backend is special-case matching, not a uniform lowering** — ~126
      `UnsupportedCEmission` bail sites; local-init tries ~a dozen shapes and
      falls back to defaulting untyped locals to `uint32_t`. This is the
      "production MIR/verifier" item: lower from a typed MIR uniformly. (Accurate.)
- [x] **`export` was parsed then discarded** — fixed: `FnDecl.exported` flag
      captured by the parser; the C emitter omits `static` for exported
      functions so `export fn boot_entry` is linkable. Fixture
      `tests/c_emit_export.mc`.
- [x] **No C identifier mangling/escaping** — fixed: `cIdent` in `lower_c.zig`
      rewrites C reserved words (`int` → `int_`, …) consistently at definitions
      and uses; identity for ordinary names. Fixture
      `tests/c_emit_keyword_idents.mc`. (User `mc_*`-prefixed names are left
      as-is to avoid clashing with the emitter's own temporaries — a narrow,
      documented edge.)
- [x] **Plain `struct` vs `extern struct` AST modeling** — fixed: the AST kind
      was renamed `.extern_struct` → `.struct_decl` (it carries all structs);
      the `abi` field is the documented ABI/extern discriminator, so the name no
      longer implies extern-only.
- [x] **Silent failures swallowed allocator errors** — fixed: sema sets an
      `oom` flag on any failed symbol-table put and surfaces `E_INTERNAL_OOM`
      instead of checking an incomplete table; HIR now propagates allocation
      errors with `try` instead of `catch {}`/`catch unreachable`.
- [x] **Compound-assignment tokens were lexed but never parsed** — fixed:
      removed the dead `+= -= *= /= %= &= |= ^= <<= >>=` production and token
      variants (not in the spec; no fixtures used them). `->`, `<=`, `>=`, `<<`,
      `>>`, `&&`, `||` are unaffected.
- [x] **`return` span covers only the `;`** — fixed: the parser now captures the
      `return` keyword token and joins it with the terminating `;`
      (`joinSpan(start, end.span)`), matching `break`/`continue`/`assert`/
      `assignment`. Diagnostics and source maps for `return` statements now span
      the whole statement. Regression: `return statement span covers the whole
      statement` in `parser.zig`.
- [x] **AST `Module.deinit` is a shallow free** — clarified with a doc comment:
      it frees only the top-level `decls` slice because the AST is arena-backed;
      it is not a recursive destructor.
- [x] **C backend relies on GCC/Clang builtins** (`__builtin_trap`,
      `__builtin_*_overflow`, `__atomic_*`, `__int128`) — documented as
      Clang/GCC-only in the README Requirements section.

Note: the review's "inferred globals are silently inconsistent" point is mostly
inaccurate — untyped globals are rejected in sema with `E_GLOBAL_REQUIRES_TYPE`
(parse-permissive, reject-in-sema), which is intentional, not a silent hole.

## Suggested order

1. ✅ **Precise inline assembly (§23.2)** — **done** (2026-06-06). Parsed,
   sema-validated, and lowered to compilable GCC/Clang extended asm with
   `out`/`in`/`clobber` operands; fixtures in `tests/spec/inline_asm.mc` +
   `tests/c_emit_precise_asm.mc`, green under sweep + c-test.
2. ✅ **DMA/cache-coherence core checks (§18)** — **done** (2026-06-06). The
   typed cache ops/`DmaBuf` modes gate coherent vs noncoherent access
   (`E_DMA_CACHE_MODE`/`E_DMA_OPERATION` + D.4 address-class), and DMA-descriptor
   handoff + cache barriers compose with the §17/§19 MMIO ordering rules
   (`dma_descriptor`/`dma_cache_order`/`cache_clean_before_release` facts);
   fixtures `tests/spec/dma_cache.mc` + `tests/spec/dma_ordering.mc`. Ownership is
   now a **planned** library over the new linear `move` types (see the
   "Linear resource types" + "DMA ownership library" items).
3. ✅ **`reduce.sum_checked<T>` (§8.2)** — **done** (2026-06-06). Wide-accumulate
   (`__int128`) + single range-check lowering to `Result<T, Overflow>`; fixtures
   in `tests/spec/reduce_sum_checked.mc` + `tests/c_emit_reduce_sum_checked.mc`,
   green under sweep + c-test.
4. **Full comptime interpreter (§22)** — effort **L**, _in progress_. The scalar
   const-evaluator, `const fn` call evaluation, comptime `while`/`for`-loop
   control flow (with fuel), comptime aggregate values (arrays + structs) with
   indexing/field access, comptime-trap semantics, named `const` globals, and
   comptime↔type feedback for `const fn`- and `const`-global-driven fixed-array
   lengths landed (`foldComptimeExpr`/`foldComptimeCall`/`foldComptimeWhile`/
   `foldComptimeForLoop`/`foldComptimeBlock`/`collectConstGlobals`, assert folding
   → `E_COMPTIME_TRAP`, and shared array-length folding across sema/MIR/C-backend);
   comptime parameters in both forms also landed — value + call-site
   comptime-assert (`E_COMPTIME_ARG_REQUIRED` + call-site assert re-checking) and
   **type-driving via monomorphization** (`src/monomorphize.zig`: per-call
   specialization of `[N]u8`-style type-generic functions, no-op for non-generic
   modules), and **reflection** (`sizeof`/`alignof` fold via an MC-side ABI
   layout model validated against clang by `reflect-test`). ✅ **The §22 comptime
   interpreter is now complete.**
5. **Production typed MIR/CFG + verifier** — ✅ **done** (core milestone,
   2026-06-06). Typed CFG + trap edges + D.1–D.6 verifier passes (81 MIR-native
   diagnostics, all usage checks migrated); unit suite + sweep + c-test green.
   What remains is the explicitly-carved **MIR optimizer depth & uniform
   lowering** follow-on (deeper value-range algebra, broader aggregate
   value-identity in MIR, and the architectural uniform-lowering-from-MIR goal) —
   open-ended/research tier, sequence it after the bounded language items above.
6. **⭐ Network-card driver prototype (Driver Library Profile, §28)** —
   _next up (spec added 2026-06-07)_. The forcing function for the library layer.
   In order: (a) **linear `move` types (§18.1)** — the qualifier + move/liveness
   verifier (`E_USE_AFTER_MOVE`/`E_RESOURCE_LEAK`), effort **M**; (b) **`std/sync`**
   locks + linear guards; (c) **`std/dma`** ownership handle; (d) **`std/ring`**
   generic descriptor ring; (e) **`std/endian`**, **`std/time`**, **`std/barrier`**,
   **`std/mmio`** helpers; (f) the **NIC driver** composing them against an
   emulated NIC under QEMU. See the "Prototype goal" section at the top for the
   full ordering. This makes every classic C-driver hazard (read-after-handoff,
   lock left held, descriptor reordered past the doorbell, host-endian write to a
   big-endian field) a compile error.
7. **Engineering tracks in parallel as needed**: Standard library (scoping is the
   hard part — design doc underspecifies it), package manager / toolchain.
   ✅ QEMU MMIO hardware tests — **done** (`zig build qemu-test`: typed MMIO runs
   on an emulated 16550 UART under qemu-system-riscv64).
