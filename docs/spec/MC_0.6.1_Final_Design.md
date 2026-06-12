# MC 0.6.1 Final Design

## A kernel-profile, Zig-like Modern C

**Status:** implementation-aligned design draft
**Version:** 0.6.1  
**Scope:** kernels, drivers, allocators, runtimes, freestanding systems code, boot code, and low-level libraries. The current implementation target is the verified C backend; LLVM is a deferred backend appendix, not part of the non-LLVM conformance target.

---

## Table of Contents

- [Part I — Core Semantic Specification](#part-i--core-semantic-specification)
  - [0. Thesis](#0-thesis)
  - [1. Trust Model](#1-trust-model)
  - [2. What MC Does Not Protect](#2-what-mc-does-not-protect)
  - [3. Core Values and Scalar Types](#3-core-values-and-scalar-types)
  - [4. `void` and `never`](#4-void-and-never)
  - [5. Arithmetic Domains](#5-arithmetic-domains)
  - [6. Bitwise Operations](#6-bitwise-operations)
  - [7. Indexing](#7-indexing)
  - [8. Hot Checked Arithmetic](#8-hot-checked-arithmetic)
  - [9. Pointers and Memory Views](#9-pointers-and-memory-views)
  - [10. Nullability](#10-nullability)
  - [11. Narrow Pattern Binding](#11-narrow-pattern-binding)
  - [12. Representation and Initialization](#12-representation-and-initialization)
  - [13. Enums and Representations](#13-enums-and-representations)
  - [14. Padding, Unions, and Byte Views](#14-padding-unions-and-byte-views)
  - [15. Aliasing](#15-aliasing)
  - [16. Address-Space Types](#16-address-space-types)
  - [17. MMIO](#17-mmio)
  - [18. DMA and Cache Coherence](#18-dma-and-cache-coherence)
  - [19. Atomics and Concurrency](#19-atomics-and-concurrency)
  - [20. Trap ABI and Boot Profile](#20-trap-abi-and-boot-profile)
  - [21. Errors and Cleanup](#21-errors-and-cleanup)
  - [22. Comptime and Reflection](#22-comptime-and-reflection)
  - [23. Inline Assembly](#23-inline-assembly)
  - [24. C ABI and FFI](#24-c-abi-and-ffi)
  - [25. Minimal Syntax Principles](#25-minimal-syntax-principles)
  - [26. Rationale Appendix](#26-rationale-appendix)
  - [27. Final Semantic Contract](#27-final-semantic-contract)
  - [28. Driver Library Profile (Network-Card Target)](#28-driver-library-profile-network-card-target)
- [Part II — Implementation and Conformance Annex](#part-ii--implementation-and-conformance-annex)
  - [A. Spec Layering](#a-spec-layering)
  - [B. Recommended Compilation Pipeline](#b-recommended-compilation-pipeline)
  - [C. Typed AST / HIR](#c-typed-ast--hir)
  - [D. Verifier](#d-verifier)
  - [E. MIR / Checked IR](#e-mir--checked-ir)
  - [F. Backend Independence](#f-backend-independence)
  - [G. C Backend Rationale](#g-c-backend-rationale)
  - [H. MC-C Backend Conformance](#h-mc-c-backend-conformance)
  - [I. MC-C Lowering Rules](#i-mc-c-lowering-rules)
  - [J. C Backend Verifier](#j-c-backend-verifier)
  - [K. Feature Admission Rule](#k-feature-admission-rule)
  - [L. MC-C Conformance Levels](#l-mc-c-conformance-levels)
  - [M. LLVM Backend Future](#m-llvm-backend-future)
  - [N. Debug Mapping](#n-debug-mapping)
  - [O. Final Implementation Contract](#o-final-implementation-contract)

---

# Part I — Core Semantic Specification

---

# 0. Thesis

**MC is a Zig-like kernel-profile language whose irreducible language-level departures are:**

1. **Build mode never changes program semantics.**
2. **Every unchecked optimizer assumption is confined to an explicitly marked `#[unsafe_contract]` region.**

Everything else—arithmetic-policy types, address-space types, typed MMIO, typed DMA, linear `move` resource handles, trap ABI, narrow compile-time reflection—is the standardized **kernel profile** rather than ad hoc library convention.

The kernel profile is organized as two layers:

```txt
Language primitives:
    Generic, compiler-verified machine contracts. The language defines and
    checks these and knows about no specific device:
        arithmetic domains, address spaces, MMIO, DMA and cache coherence,
        atomics, interrupt context, the trap ABI, narrow compile-time
        reflection, the inline-asm boundary, and the C ABI.

Device libraries:
    Concrete protocols and devices, written on top of the primitives and
    outside the language:
        PCIe, USB, NVMe, UART, SPI/I2C, Ethernet, SoC HALs, board support.
```

The point of standardizing the generic primitives is that a driver author does
not re-derive C's implicit rules—`volatile`, aliasing, overflow, barriers,
optimizer assumptions—for every device. A device library expresses a datasheet
and a driver state machine in terms of these primitives; the language stays
device-agnostic. (See annex section A.1.)

MC is not a memory-safe language. It is a language that makes the machine contract explicit.

The central promise is:

> **Ordinary program mistakes become compile errors, traps, or `Result` values. They do not become invisible optimizer assumptions.**

The central limitation is:

> **There is no general way to get exact checked arithmetic semantics, arbitrary hot loops, and zero per-operation cost without proof, a specialized reduction, or an unsafe contract.**

---

# 1. Trust Model

MC has three trust levels.

---

## 1.1 Safe MC

Safe MC contains ordinary language operations.

In Safe MC:

```txt
error = compile error / trap / Result
```

The compiler may not assume an error is impossible unless:

```txt
1. The program performed a check.
2. The value was constructed by a checked constructor.
3. The compiler can prove the error cannot occur.
```

Examples:

```mc
let x = a + b;        // checked arithmetic
let y = buf[i];       // bounds-checked indexing
let p = unwrap(maybe);
```

Possible failures:

```txt
IntegerOverflow
Bounds
NullUnwrap
InvalidRepresentation
DivideByZero
InvalidShift
Assert
Unreachable
```

These are defined language traps. They are not undefined behavior.

---

## 1.2 Strict Unsafe MC

Some operations cannot be verified by the language because they interact with hardware, address spaces, MMIO, DMA, raw memory, or assembly.

Example:

```mc
unsafe {
    let uart = mmio.map<Uart16550>(phys(0x1000_0000))?;
}
```

This means:

```txt
The language cannot prove that this physical address is really a UART.
```

It does **not** mean:

```txt
The compiler may assume arbitrary facts.
```

Strict unsafe MC allows target-defined machine effects but does not grant optimizer-license assumptions.

Examples:

```mc
unsafe { raw.store<u64>(addr, value); }
unsafe { mmio.map<T>(pa); }
unsafe { asm opaque volatile { "cli" clobber("memory") } }
```

These may fault, hang, reset the machine, corrupt hardware state, or interact with external devices. Those are machine effects, not language UB.

---

## 1.3 `#[unsafe_contract]` MC

Unchecked promises made to the optimizer must be explicitly quarantined.

Examples:

```mc
#[unsafe_contract(no_overflow)]
{
    sum = unchecked.add(sum, x);
}
```

```mc
#[unsafe_contract(noalias)]
{
    let a = compiler.assume_noalias_unchecked(p, n);
}
```

```mc
#[unsafe_contract(precise_asm)]
{
    asm precise volatile {
        "bsf %1, %0"
        out("rax") idx: u64,
        in("rbx") mask: u64,
        clobber("cc"),
    }
}
```

Inside an `#[unsafe_contract]` region, the compiler may use the stated assumption.

If the contract is false at runtime, behavior of the marked region is **region-scoped unspecified behavior**.

That means:

```txt
- The compiler may optimize the region using the contract.
- Values produced by the region may be arbitrary.
- Memory writes performed by the region may be arbitrary.
- Later code may observe those outputs and side effects.
- The violation does not license arbitrary transformations of unrelated code outside the region.
```

Region boundary rule:

```txt
Contract-only facts may be used for operations inside the marked region.
Values leaving the region become ordinary MC values.
If the contract was false, those values may be arbitrary ordinary values.
The backend must not attach persistent nonnull/noalias/nuw/nsw/noundef-style facts outside the region solely because of the contract.
Such facts must be stripped, scoped to the exact contracted operations, or re-established by a check/proof outside the region.
```

This is intentionally narrower than C-style global UB.

---

# 2. What MC Does Not Protect

MC does **not** protect against:

```txt
1. Use-after-free, except trivial local escape cases such as return &local.
2. Returning views/slices that borrow freed storage.
3. Double free, unless allocator/resource APIs add their own checks.
4. Data races; ordinary data races are bugs but not optimizer-license UB.
5. Deadlocks, priority inversion, interrupt reentrancy bugs.
6. Wrong physical addresses, wrong MMIO mappings, wrong device specifications.
7. DMA temporal/cache-coherence mistakes unless using a stricter typestate API.
8. Pre-handler traps during early boot; these may reset, fault, halt, or reboot the machine.
9. Incorrect inline asm in #[unsafe_contract] regions.
10. Incorrect unchecked noalias/compiler assumptions in #[unsafe_contract] regions.
11. UB or arbitrary behavior inside imported C/assembly code.
12. Constant-time or side-channel properties.
13. Direct residue arithmetic on wrap<T> values; use serial.* or counter.* APIs instead.
14. Branch-free checked arithmetic for arbitrary hot loops; use checked reductions, proofs, or unsafe contracts.
15. Identical debug/release trap instruction placement; parity is semantic, not structural.
16. Counter elapsed-time correctness when the true interval exceeds the counter ambiguity window.
```

The positive guarantee is narrower and stronger:

> **MC protects the language contract. Ordinary errors do not become hidden optimizer assumptions.**

---

# 3. Core Values and Scalar Types

MC has fixed-width scalar types.

```mc
bool

i8  i16  i32  i64  isize
u8  u16  u32  u64  usize

f32 f64

void
never
```

Rules:

```txt
No int / long / char ambiguity.
All integers have fixed width.
Signed integers are two's-complement.
usize/isize match pointer width.
bool is a distinct type.
```

There are no implicit runtime conversions.

```mc
let a: u32 = 10;
let b: u64 = a;              // compile error
let c: u64 = u64.from(a);    // explicit
```

Even safe widening is explicit.

```mc
let x: u16 = 255;
let y: u32 = u32.from(x);
```

Narrowing names the failure mode:

```mc
let a: u8 = u8.try_from(x)?;     // Result
let b: u8 = u8.trap_from(x);     // trap on range error
let c: u8 = u8.wrap_from(x);     // explicit modulo truncation
let d: u8 = u8.sat_from(x);      // explicit saturation
```

Integer literals are compile-time values and may be context-typed:

```mc
let x: u32 = 123;          // OK
let y: u8 = 300;           // compile error
let z: wrap<u8> = 300;     // compile error
```

To construct modulo values from out-of-range literals:

```mc
let z = wrap<u8>.from_mod(300);  // OK, explicit modulo
```

---

# 4. `void` and `never`

`void` is the unit return type. It carries no useful value.

```mc
fn init() -> void {
    return;
}
```

`never` is the bottom type. An expression of type `never` does not continue execution.

Examples:

```mc
trap(.Bounds)          // never
unreachable()          // never
return err(e)          // never
arch.halt_forever()    // never
```

`never` coerces to any expected type.

```mc
fn get_or_fail(x: ?u32) -> u32 {
    if let v = x {
        return v;
    } else {
        trap(.NullUnwrap);   // never coerces to u32 position
    }
}
```

`trap(kind)` has type `never`.

```mc
let x: u32 = trap(.Bounds);  // typechecks, never coerces to u32
```

`unreachable()` also has type `never`, but if execution reaches it, it traps:

```mc
unreachable();   // trap(.Unreachable)
```

A function declared `-> never` must not return normally.

```mc
fn halt() -> never {
    arch.halt_forever();
}
```

Falling off the end of a `-> never` function is a compile error.

---

# 5. Arithmetic Domains

Integer arithmetic policy is part of type identity.

MC has five arithmetic families.

```mc
checked<T>    // ordinary checked arithmetic; u32 is shorthand for checked<u32>
wrap<T>       // modular arithmetic
sat<T>        // saturating arithmetic
serial<T>     // sequence-number arithmetic
counter<T>    // free-running counter arithmetic
```

Same bits do not mean same type.

```mc
let a: u32 = 1;
let b: wrap<u32> = wrap<u32>.from(a);

a + b;        // compile error
```

No implicit policy mixing.

---

## 5.1 Checked Integers

Primitive integer types are checked by default.

```mc
let z = x + y;
```

Checked integer arithmetic operators:

```txt
+        addition
-        subtraction
*        multiplication
/        division
%        remainder
unary -  signed negation only
```

For `+`, `-`, and `*`, MC computes the mathematical integer result and traps if the result is outside the destination type's range.

```txt
overflow: trap(.IntegerOverflow)
```

Addition semantic lowering:

```txt
tmp, overflow = add_with_overflow(x, y)
if overflow: trap(.IntegerOverflow)
z = tmp
```

For `/` and `%`:

```txt
if divisor == 0: trap(.DivideByZero)
```

Signed division truncates toward zero.

Signed remainder satisfies:

```txt
a == (a / b) * b + (a % b)
abs(a % b) < abs(b)
sign(a % b) == sign(a), unless the remainder is zero
```

For signed checked integers:

```txt
min_value / -1: trap(.IntegerOverflow)
min_value % -1: trap(.IntegerOverflow)
unary -min_value: trap(.IntegerOverflow)
```

For unsigned checked integers, `/` and `%` cannot overflow after the zero-divisor check.

Unary `-` is not defined for unsigned checked integers. Use checked subtraction from zero or a wrapping type explicitly.

The compiler may remove the check only if it proves overflow impossible.

Debug/release parity is semantic:

```txt
Same abstract inputs produce same abstract outcomes.
Trap sites and number of trap instructions may differ.
Timing may differ.
```

---

## 5.2 Wrapping Integers

```mc
type HashWord = wrap<u32>;
```

Allowed:

```mc
a + b
a - b
a * b
a == b
a != b
a.residue()
```

Forbidden:

```mc
a < b
a <= b
a > b
a >= b
a / b
```

`residue()` exposes the raw modulo representative.

```mc
let raw: u32 = word.residue();
```

The name is intentionally awkward. It is for serialization, hashing, register writes, and explicit boundary crossing.

Suspicious patterns should warn:

```mc
if a.residue() < b.residue() { }          // warning
let dt = now.residue() - start.residue(); // warning
```

Use `serial<T>` or `counter<T>` instead.

---

## 5.3 Saturating Integers

```mc
type Level = sat<u8>;
```

Arithmetic saturates:

```mc
let a: sat<u8> = 250;
let b: sat<u8> = 20;

let c = a + b;     // 255
```

Ordering is allowed.

```mc
if c >= sat<u8>.from(200) {
    throttle();
}
```

Bitwise operations are forbidden on `sat<T>`.

---

## 5.4 Serial Numbers

Protocol sequence numbers are not plain wrapping integers.

```mc
type TcpSeq = serial<u32>;
```

Ordinary ordering is forbidden:

```mc
a < b;        // compile error
```

Use domain-specific operations:

```mc
TcpSeq.before(a, b)
TcpSeq.after(a, b)
TcpSeq.distance(a, b)
TcpSeq.compare(a, b) -> Result<Order, AmbiguousSerialOrder>
```

Serial ordering is valid only inside the protocol’s comparison window.

Bitwise operations are forbidden on `serial<T>`.

---

## 5.5 Free-Running Counters

Hardware counters, cycle counters, and jiffies use `counter<T>`.

```mc
type Ticks = counter<u64>;
```

MC deliberately does **not** provide a plain safe `elapsed(now, start)` that pretends to recover real time from two modular samples.

The fully defined operation is modular delta:

```mc
let d: wrap<u64> = Ticks.delta_mod(now, start);
```

To interpret it as elapsed time, the caller must supply an external temporal invariant.

```mc
let elapsed =
    Ticks.elapsed_assume_within(now, start, max_interval);
```

Meaning:

```txt
The caller asserts that the true elapsed interval is less than max_interval,
and max_interval is less than the ambiguity window.
```

This is not an optimizer contract. If false, the result may be logically wrong, but it does not give the compiler extra assumptions.

A checked helper may validate representability and local bounds:

```mc
Ticks.elapsed_bounded(now, start, max_interval)
    -> Result<Duration<u64>, AmbiguousCounterInterval>
```

But no API can recover true elapsed time from two modular samples if the counter may have wrapped multiple times.

Recommended kernel pattern:

```mc
type RawTicks = counter<u32>;
type KernelTime = u64;          // widened monotonic time

// Clock driver periodically widens RawTicks into KernelTime.
```

Use widened monotonic time for long sleeps and scheduler accounting.

Bitwise operations are forbidden on `counter<T>`.

---

# 6. Bitwise Operations

Bitwise operations are representation-level operations.

Supported operators:

```mc
&    bitwise and
|    bitwise or
^    bitwise xor
~    bitwise not
<<   left shift
>>   right shift
```

They are allowed only on:

```txt
1. unsigned checked integers: u8/u16/u32/u64/usize
2. wrap<unsigned integer>
3. explicit bits/flag types
```

They are forbidden on:

```txt
signed integers
sat<T>
serial<T>
counter<T>
bool
pointers
```

For signed bit manipulation, convert explicitly through an unsigned representation:

```mc
let raw: u32 = bitcast<u32>(x_i32);
let masked = raw & 0xff_u32;
let out: i32 = bitcast<i32>(masked);
```

---

## 6.1 Bitwise Operations on Unsigned Checked Integers

```mc
let x: u32 = a & b;
let y: u32 = ~x;
```

`&`, `|`, `^`, and `~` cannot overflow and do not trap.

Left shift on checked unsigned integers is checked:

```mc
let y = x << n;
```

Rules:

```txt
if n >= bit_width(x): trap(.InvalidShift)
if nonzero bits are shifted out: trap(.IntegerOverflow)
otherwise: logical left shift
```

Right shift on checked unsigned integers:

```txt
if n >= bit_width(x): trap(.InvalidShift)
otherwise: logical right shift
```

For truncating CPU-style shifts, use explicit bit operations:

```mc
let y = bits.shl_trunc(x, n)?;      // Result if n invalid
let z = bits.shl_masked(x, n);      // target/CPU-style masked shift
```

---

## 6.2 Bitwise Operations on `wrap<unsigned>`

For `wrap<uN>`, bitwise operations preserve the wrapping domain.

```mc
let x: wrap<u32> = ...;
let y: wrap<u32> = ...;

let z = x & y;       // wrap<u32>
let w = ~x;          // wrap<u32>
```

Left shift on `wrap<uN>` is modular/truncating:

```txt
if n >= bit_width(x): trap(.InvalidShift)
otherwise: logical shift and truncate to N bits
```

Masked shifts are still explicit:

```mc
let z = bits.shl_masked(x, n);
```

---

## 6.3 Explicit Bits and Flags

For hardware flags, protocol fields, and packed bit layouts, prefer named bit types.

```mc
packed bits UartLsr: u8 {
    data_ready: bool,
    overrun_error: bool,
    parity_error: bool,
    framing_error: bool,
    break_interrupt: bool,
    tx_empty: bool,
    tx_idle: bool,
    fifo_error: bool,
}
```

Then:

```mc
let status = uart.lsr.read(.acquire);

if status.tx_empty {
    uart.thr.write(ch, .release);
}
```

For raw masks, explicit comparison to `0` is required:

```mc
if (flags & TX_EMPTY) != 0_u32 {
    transmit();
}
```

This is forbidden:

```mc
if (flags & TX_EMPTY) {      // compile error: condition must be bool
    transmit();
}
```

Canonical rule:

```txt
Prefer named RegBits fields for hardware status.
If masking, compare explicitly to zero.
```

---

# 7. Indexing

Array and slice indices must be checked `usize`.

```mc
let buf: []mut u8 = ...;
let i: usize = ...;

buf[i];       // OK, bounds checked
```

Rejected:

```mc
let r: wrap<usize> = ...;
buf[r];              // compile error
```

Explicit projection is required:

```mc
buf[r.residue()];    // OK, then normal bounds check
```

For ring buffers, use a named projection:

```mc
type Cursor = wrap<u64>;

fn slot(cur: Cursor, comptime CAP: usize) -> usize {
    comptime assert(is_power_of_two(CAP));
    return usize.trap_from(cur.residue() & (CAP - 1));
}

buf[slot(head, CAP)] = item;
```

This makes the operation visible:

```txt
I am projecting a modular counter into this buffer's index space.
```

---

# 8. Hot Checked Arithmetic

MC has no magic answer for arbitrary branch-free checked arithmetic.

It provides three official idioms.

---

## 8.1 Exact Per-Operation Checked Loop

```mc
fn sum_checked_stepwise(xs: []const u32) -> Result<u32, Overflow> {
    var sum: u32 = 0;

    for x in xs {
        sum = checked.add(sum, x)?;
    }

    return ok(sum);
}
```

Semantics:

```txt
Overflow is detected at the exact addition where it occurs.
May cost one check per iteration.
Safe MC.
```

---

## 8.2 Mathematical Checked Reduction

```mc
fn sum_checked_reduce(xs: []const u32) -> Result<u32, Overflow> {
    return reduce.sum_checked<u32>(xs);
}
```

Semantics:

```txt
Compute the mathematical sum in an abstract integer domain.
Return Overflow if the final result does not fit u32.
```

This is not the same as stepwise checked addition.

Example:

```mc
let xs: []const i32 = .{ i32.max, 1, -1 };
```

Stepwise checked addition traps/errors at:

```mc
i32.max + 1
```

Mathematical reduction returns:

```mc
i32.max
```

Therefore these are different APIs.

`reduce.sum_checked` is restricted to integer types.

---

## 8.3 Floating-Point Reductions

Floating-point addition is not associative.

Therefore MC separates deterministic and fast reductions.

Deterministic left fold:

```mc
reduce.sum_left<f64>(xs)
```

Semantics:

```txt
Equivalent to source-order left fold.
Debug/release and target vector width may not change the result.
```

Fast reassociating reduction:

```mc
reduce.sum_fast<f64>(xs)
```

Semantics:

```txt
May reassociate.
May vectorize.
May produce target-dependent bit results.
Explicit opt-in only.
Build mode may not silently select this behavior.
```

No build mode may turn `sum_left` into `sum_fast`.

---

## 8.4 Unsafe Hot Checked Loop

For arbitrary branchless hot loops with an uncheckable proof:

```mc
fn hot_sum_assume_no_overflow(xs: []const u32) -> u32 {
    var sum: u32 = 0;

    #[unsafe_contract(no_overflow)]
    {
        for x in xs {
            sum = unchecked.add(sum, x);
        }
    }

    return sum;
}
```

Contract:

```txt
Within the region, the compiler may assume every unchecked arithmetic operation covered by no_overflow does not overflow.
It may propagate resulting value-range facts forward through values produced by the region.
If any covered operation overflows at runtime, the marked region has region-scoped unspecified behavior.
```

This is the sanctioned escape hatch.

---

# 9. Pointers and Memory Views

MC separates pointer concepts that C conflates.

```mc
*mut T          // non-null pointer to one mutable T
*const T        // non-null pointer to one const T

?*mut T         // nullable pointer
?*const T

[*]mut T        // raw many pointer, no length
[*]const T

[]mut T         // slice: pointer + length
[]const T

[N]T            // array, length in type
```

Arrays do not decay to pointers.

```mc
fn f(p: *mut u8) -> void { }

let buf: [256]u8 = zero;

f(buf);          // compile error
f(&buf[0]);      // OK
```

Single-object pointers have no arithmetic.

```mc
let p: *mut u32 = &x;
let q = p + 1;       // compile error
```

Use slice or raw many pointer for contiguous memory.

```mc
let s: []mut u32 = buffer[0..n];
s[i] = 123;          // bounds checked

let p: [*]mut u32 = s.ptr;
unsafe { p.offset(i).* = 123; }
```

---

# 10. Nullability

Ordinary pointers are non-null.

```mc
fn write(p: *mut u8) -> void {
    p.* = 1;
}
```

Nullable pointers are explicit.

```mc
fn find(id: u64) -> ?*mut Node;
```

Use requires handling:

```mc
let maybe = find(10);

if let p = maybe {
    p.value = 123;
} else {
    return err.NotFound;
}
```

`unwrap(maybe)` traps on null.

```mc
let p = unwrap(maybe);   // trap(.NullUnwrap) if null
```

---

# 11. Narrow Pattern Binding

MC does not have general pattern matching in `if`.

It has a deliberately narrow `if let` form for optional and `Result` narrowing only.

---

## 11.1 Optional Narrowing

```mc
if let p = maybe_ptr {
    use(p);          // p: non-null inner type
} else {
    handle_null();
}
```

If `maybe_ptr: ?T`, then inside the then-branch:

```mc
p: T
```

The binding is scoped to the then-branch.

This form does not destructure structs, arrays, tuples, or unions.

---

## 11.2 Result Narrowing

For `Result<T, E>`:

```mc
if let ok(v) = result {
    use(v);          // v: T
} else {
    handle_error();
}
```

Error binding is explicit:

```mc
if let err(e) = result {
    handle(e);       // e: E
} else {
    handle_ok();
}
```

To handle both sides with bindings, use `switch`:

```mc
switch result {
    .ok(v) => use(v),
    .err(e) => handle(e),
}
```

`switch` is the general matcher.  
`if let` is only narrowing sugar.

A boolean `if cond { … } else { … }` (and `else if`) is also available; it is
**sugar for a two-arm `switch` on the bool** (`true`/`false`) and carries no extra
semantics — same exhaustiveness and control-flow rules. It exists because the
`switch true/false` guard form is verbose for the common early-return check.

```mc
if x == 0 { return 10; }
if !ready { return 20; } else if x > 100 { return 30; }
```

---

# 12. Representation and Initialization

Ordinary variables must be initialized.

```mc
var x: i32;       // compile error
```

Explicit uninitialized storage:

```mc
var buf: [4096]u8 = uninit;
```

Uninitialized bytes are unspecified bytes.

```txt
Not UB.
Not poison.
Not optimizer magic.
```

Reading an unspecified byte through a byte view produces an arbitrary byte value for that read.

```txt
The value is not stable unless the byte has been written.
Two reads of the same unwritten byte may produce different byte values.
The read does not create optimizer facts.
```

Unspecified bytes may be copied, compared, or serialized only as bytes. If bytes are projected as a typed value, normal representation validation applies.

For typed initialization:

```mc
var x: MaybeUninit<Node> = uninit;
x.write(Node{ .value = 1, .next = null });

let node = x.assume_init();
```

`assume_init()` is shallow for aggregates.

Fields with invalid representations trap when projected/read.

```mc
let next = node.next; // validates optional pointer representation
let k = node.kind;    // validates closed enum representation
```

Compiler rule:

```txt
The compiler may assume a typed value representation is valid only if:
1. A representation check dominates the use.
2. A checked constructor produced the value.
3. The source is statically known to produce valid T.
```

This prevents lazy validation from becoming a hidden optimizer-license assumption.

---

# 13. Enums and Representations

Closed enum:

```mc
enum Irq: u8 {
    timer = 32,
    keyboard = 33,
}
```

Rules:

```txt
switch over closed enum must be exhaustive.
Integer-to-closed-enum conversion returns Result or traps.
Typed load of invalid closed-enum tag traps at load/projection point.
```

Open enum:

```mc
open enum DeviceState: u8 {
    idle = 0,
    busy = 1,
    error = 2,
}
```

Unknown values are preserved.

```mc
switch state {
    .idle => {},
    .busy => {},
    .error => {},
    _ => handle_unknown(state.raw()),
}
```

---

# 14. Padding, Unions, and Byte Views

Padding bytes are unspecified.

```txt
They may be observed through byte views.
They are not UB.
They are not poison.
They follow the same unstable unspecified-byte rule as uninitialized storage.
```

Struct equality compares fields, not padding.

Raw byte equality is explicit:

```mc
mem.bytes_equal(mem.as_bytes(&a), mem.as_bytes(&b))
```

MC has safe tagged unions and explicit overlay unions.

```mc
union Token {
    int: i64,
    ident: []const u8,
    eof,
}
```

Overlay union:

```mc
overlay union Word {
    u: u32,
    bytes: [4]u8,
}
```

Rules:

```txt
overlay union is fixed-size storage.
Writing a field defines the bytes covered by that field.
Other bytes are unspecified.
Reading byte fields exposes bytes, including unspecified bytes.
Reading non-byte fields traps if the target representation is invalid.
```

---

# 15. Aliasing

MC does not inherit C strict aliasing.

Default rule:

```txt
Raw pointers and slices may alias unless proven otherwise.
```

The compiler cannot assume that different pointer types do not alias.

For optimization, `noalias` must be constructed by proof or check.

```mc
let left, right = mem.split_noalias(buf, 0..2048, 2048..4096)?;
```

Unchecked noalias assumptions are not in strict MC.

```mc
#[unsafe_contract(noalias)]
{
    let a = compiler.assume_noalias_unchecked(p, n);
}
```

If false, the marked region has region-scoped unspecified behavior.

---

# 16. Address-Space Types

MC’s kernel profile treats address spaces as core types.

```mc
type VAddr;
type PAddr;
type UserAddr;
type MmioAddr;
type DmaAddr;

type UserPtr<T>;
type MmioPtr<T>;
type PhysPtr<T>;     // not directly dereferenceable
```

Ordinary pointers:

```mc
*mut T
```

mean current CPU virtual address space, directly dereferenceable.

Physical addresses cannot be dereferenced.

```mc
let pa: PAddr = phys(0x100000);
let x = pa.*;            // compile error
```

They must be mapped.

```mc
let page: *mut Page = vm.map<Page>(pa)?;
```

User pointers cannot be dereferenced.

```mc
fn sys_write(buf: UserPtr<const u8>, len: usize) -> Result<usize, Fault> {
    var tmp: [256]u8 = uninit;
    let n = min(len, tmp.len);

    user.copy_from(tmp[0..n], buf, n)?;
    return console.write(tmp[0..n]);
}
```

This is forbidden:

```mc
let x = buf.*;       // compile error
```

---

# 17. MMIO

MMIO is not ordinary volatile pointer arithmetic.

MMIO registers have typed access modes.

```mc
extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    ier: Reg<u8, .read_write>,
    fcr: Reg<u8, .write>,
    lcr: Reg<u8, .read_write>,
    lsr: RegBits<u8, UartLsr, .read>,
}
```

Registers are placed sequentially by default. For a register map with gaps, the
`@offset(N)` attribute pins a field at an exact byte offset — so the struct reads
like a datasheet's register table rather than counting reserved fields. Offsets
must increase; the compiler generates the reserved padding to reach each one.

```mc
extern mmio struct VirtioMmio {
    magic: Reg<u32, .read>             @offset(0x000),  // "virt"
    status: Reg<u32, .read_write>      @offset(0x070),
    queue_desc_low: Reg<u32, .write>   @offset(0x080),
}
```

Packed status bits:

```mc
packed bits UartLsr: u8 {
    data_ready: bool,
    overrun_error: bool,
    parity_error: bool,
    framing_error: bool,
    break_interrupt: bool,
    tx_empty: bool,
    tx_idle: bool,
    fifo_error: bool,
}
```

Mapping:

```mc
let uart: MmioPtr<Uart16550> =
    unsafe { mmio.map<Uart16550>(phys(0x1000_0000))? };
```

Access:

```mc
fn putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    while !uart.lsr.read(.acquire).tx_empty {
        cpu.pause();
    }

    uart.thr.write(ch, .release);
}
```

Forbidden:

```mc
uart.thr = ch;       // compile error
```

The access mode, width, ordering, and layout are part of the type.

MMIO ordering names are device-access ordering constraints, not ordinary atomic operations.

```txt
.relaxed:
    the access occurs exactly as specified, but creates no extra ordering with ordinary memory

.acquire on an MMIO read:
    later ordinary memory, atomic, DMA-descriptor, and MMIO operations may not be moved before the read

.release on an MMIO write:
    earlier ordinary memory, atomic, DMA-descriptor, and MMIO operations may not be moved after the write

.acq_rel:
    both acquire and release constraints for operations that read and write device state

.seq_cst:
    acquire + release plus the target's strongest available global device-ordering fence
```

These orders constrain both compiler reordering and target CPU/device reordering. A backend must emit target barriers when volatile access alone is insufficient.

For raw register masks:

```mc
let lsr = uart.raw_lsr.read(.acquire);

if (lsr & 0x20_u8) != 0_u8 {
    uart.thr.write(ch, .release);
}
```

But named bitfields are preferred.

---

# 18. DMA and Cache Coherence

DMA addresses are not physical addresses.

```mc
DmaAddr != PAddr
DmaAddr != VAddr
```

Coherent DMA:

```mc
let buf = dma.alloc<u8>(4096, .coherent)?;
defer dma.free(buf);

device.rx_desc.addr.write(buf.dma_addr());
device.rx_desc.len.write(u32.try_from(buf.len)?);
```

Non-coherent DMA:

```mc
let buf = dma.alloc<u8>(4096, .noncoherent)?;

cache.clean(buf);
device.start_dma(buf.dma_addr());

device.wait_irq();

cache.invalidate(buf);
let packet = buf.as_slice();
```

MC core enforces address-class correctness.

It does **not** automatically enforce temporal/cache-coherence correctness.

This bug remains possible in core MC:

```mc
device.wait_irq();
let packet = buf.as_slice();   // may be stale if invalidate was required
```

A stricter kernel profile uses ordinary `move` resource typestates around the
core DMA primitive:

```mc
move struct CpuBuffer { /* CPU-owned DMA allocation */ }
move struct DeviceBuffer { /* device-owned DMA allocation */ }
```

Example:

```mc
let cpu0 = dma.alloc(4096);                     // CpuBuffer

let dev = dma.clean_for_device(cpu0);          // DeviceBuffer
device.start_dma(dma.device_addr(&dev));

device.wait_irq();

let cpu1 = dma.invalidate_for_cpu(dev);        // CpuBuffer
let cpu_addr = dma.cpu_addr(&cpu1);
```

DMA-buffer ownership transfer of this kind requires **linear resource handles**.
MC provides these through the `move` type qualifier (section 18.1): the ownership
library exposes distinct `move` handles for CPU-owned and device-owned buffers,
so the example above is checked — `cpu0` is consumed by the handoff, CPU accessors
are defined only for `CpuBuffer`, and forgetting to free the reclaimed buffer is
a leak error. Ownership/lifecycle is therefore a **library profile expressed with
core `move` types**, not a separate ad-hoc convention.

**Summary — the DMA primitive vs the DMA library:**

```txt
DMA primitive (core, always enforced):
    DmaAddr address class       — DmaAddr != PAddr != VAddr; not CPU-dereferenceable
    DmaBuf<T, mode>             — coherence mode (.coherent/.noncoherent)
                                  carried in the type
    cache.clean / cache.invalidate — typed cache operations, not volatile pokes
    dma_addr() / as_slice()     — the device-address vs CPU-view bridge

DMA library (profile, built on the primitive + core `move` types):
    ownership / lifecycle       — CpuBuffer vs DeviceBuffer typestate over
                                  `move` (linear) handles, enforcing the
                                  temporal rule "clean before handoff, invalidate
                                  before CPU read, do not touch while device-owned,
                                  free exactly once"
```

The split follows the kind of fact. The primitive checks **spatial / representational** facts (which address space, which coherence mode) structurally and always. Ownership is a **temporal / linear** fact, enforced by the core `move` qualifier (section 18.1) and ordinary ownership-state types in the library.

---

## 18.1 Linear Resource Types (`move`)

Hardware resources — DMA buffers, interrupt-disabled witnesses, locks, device
handles — obey a **use-protocol** the compiler should enforce: a DMA buffer
handed to the device must not be read until it is handed back; a lock acquired
must be released exactly once; an `IrqOff` witness must not be duplicated. MC
expresses these with **linear `move` types**: a narrow, opt-in ownership
mechanism — *not* a general borrow checker (there are no borrows, lifetimes, or
aliasing analysis). It enforces exactly one rule kind: **a `move` value is used
linearly — consumed exactly once.**

A type is made linear with the `move` qualifier on its declaration:

```mc
move struct Lock { /* … */ }
move struct CpuBuffer { /* … */ }
move struct DeviceBuffer { /* … */ }
```

Semantics of a `move` value:

```txt
1. Consumed-on-use: passing a `move` value by value to a function, returning it,
   or assigning it to another binding *moves* it — the source binding is consumed
   and becomes dead. Using a dead binding is E_USE_AFTER_MOVE.

2. Linear (must-consume): a live `move` binding that reaches the end of its scope
   without being moved (consumed) is E_RESOURCE_LEAK. Every resource is released
   exactly once — no leaks, no double-free.

3. No aliasing: a `move` value has a single owner at any time; it cannot be
   copied. (`move` types therefore cannot be plain-`Copy` scalars.)
```

Typestate is expressed with ordinary type parameters: an operation consumes a
handle in one state and returns it in another, so the old state is unreachable
after the transition.

```mc
fn lock(l: Lock) -> Held;            // consumes the unlocked Lock, returns Held
fn unlock(h: Held) -> Lock;          // consumes Held, returns the Lock
```

`move` is a **compile-time** contract only: a `move` value lowers to its ordinary
representation with no runtime cost; the linearity is checked by a per-function
move/liveness pass (annex D) and erased. This keeps MC's stance — *explicit
machine contract, not memory safety*: `move` enforces **hardware ownership
protocols** for resource handles, and is deliberately *not* a whole-program
borrow/lifetime system.

---

## 18.2 DMA Ownership Library

The DMA ownership profile is a library built on the core `move` qualifier and the
DMA primitive. It models ownership with distinct `move` handles: `CpuBuffer` for
memory currently owned by the CPU and `DeviceBuffer` for memory handed to the
device.

```mc
move struct CpuBuffer {
    dev_addr: DmaAddr,
    cpu_addr: PAddr,
    len: usize,
}

move struct DeviceBuffer {
    dev_addr: DmaAddr,
    len: usize,
}

// Allocation yields a cpu-owned, linear handle. The handle must eventually be
// freed exactly once.
fn alloc(len: usize) -> CpuBuffer;
fn free(buf: CpuBuffer) -> void;                         // consumes the handle

// Cache transitions consume the handle and return it in the new owner state.
fn clean_for_device(buf: CpuBuffer) -> DeviceBuffer;
fn invalidate_for_cpu(buf: DeviceBuffer) -> CpuBuffer;

// Address accessors borrow; the CPU address exists only while cpu-owned.
fn device_addr(buf: *DeviceBuffer) -> DmaAddr;
fn cpu_addr(buf: *CpuBuffer) -> PAddr;
fn cpu_len(buf: *CpuBuffer) -> usize;
```

The current `std/dma.mc` implementation keeps these ownership handles in MC and
uses scalar platform hooks (`mc_dma_alloc_base`, `mc_dma_free_base`,
`mc_dma_clean_for_device_base`, and `mc_dma_invalidate_for_cpu_base`) at the C/LLVM
runtime boundary. This avoids making platform runtimes depend on by-value
aggregate ABI lowering while preserving the typed `CpuBuffer`/`DeviceBuffer`
protocol inside MC code.

Because the handle is linear, the §18 example is now fully enforced. Each
type-changing transition consumes the old handle and binds a **new** name (MC has
no name shadowing); a borrow uses `&handle`:

```mc
let cpu0 = dma.alloc(4096);                      // cpu-owned, linear
let dev = dma.clean_for_device(cpu0);            // cpu0 consumed; dev is device-owned
device.start_dma(dma.device_addr(&dev));         // &dev borrows, does not consume
device.wait_irq();
let cpu1 = dma.invalidate_for_cpu(dev);          // dev consumed; back to cpu-owned
let ptr = dma.cpu_addr(&cpu1);                   // OK only because cpu-owned
dma.free(cpu1);                                  // consumes cpu1; omitting this is E_RESOURCE_LEAK
```

The compiler rejects: reading a device-owned buffer (`cpu_addr` is not defined on
`DeviceBuffer`), using a buffer after it was moved into a transition
(`E_USE_AFTER_MOVE`), and dropping a buffer without freeing it
(`E_RESOURCE_LEAK`). A by-value argument moves; `&handle` borrows. The same
`move` mechanism gives `IrqOff`, locks, and device handles their single-owner /
use-once guarantees.

---

# 19. Atomics and Concurrency

Atomic operations are explicit.

```mc
var ticks: atomic<u64> = atomic.init(0);

ticks.fetch_add(1, .relaxed);

let ready = flag.load(.acquire);
flag.store(true, .release);
```

Memory orders:

```mc
.relaxed
.acquire
.release
.acq_rel
.seq_cst
```

Data races on ordinary memory are bugs, but not optimizer-license UB.

```txt
The compiler may not assume data races never happen.
Ordinary load/store do not provide synchronization semantics.
Atomic APIs are required for synchronization.
```

A data race is a pair of conflicting ordinary memory accesses that can occur concurrently without an intervening synchronization edge, where at least one access writes.

If an MC program has an ordinary data race:

```txt
The program is wrong.
The racing load result is target-defined.
The access may observe any representation made visible by a racing store, subject to target access-width rules.
The access may tear if the target does not provide atomicity for that access width and alignment.
No happens-before edge is created.
No optimizer assumption is created.
```

The compiler may still optimize ordinary memory, but not by using the premise that ordinary data races are impossible.

`volatile` is not atomic.

Volatile/MMIO means:

```txt
This access must happen as specified.
```

Atomic means:

```txt
This access participates in the concurrency memory model.
```

---

## 19.1 Interrupt Context

Interrupt context is part of a function's contract, like the trap profile. `#[irq_context]` marks a function that may run inside an interrupt service routine:

> A `#[irq_context]` function, and everything it calls, must be safe to run with interrupts disabled and without a thread context.

Rejected in `#[irq_context]`:

```mc
lock.acquire();          // may block / sleep
heap.alloc(n);           // may block / sleep on a slow path
device.wait_irq();       // blocks for an event
fs.read(path);           // unbounded blocking I/O
```

Allowed:

```mc
let s = status.read(.acquire);     // typed MMIO
flag.store(true, .release);        // atomic
ring.try_push(item);               // non-blocking
```

Propagation rule (mirrors `#[no_lang_trap]`):

```txt
A #[irq_context] function may call:
    - other #[irq_context] functions
    - non-blocking primitives (MMIO, atomics, raw stores, opaque asm)

It may not call:
    - functions not proven #[irq_context]
    - operations that block, sleep, or allocate from a blocking allocator
```

A critical section that requires interrupts to be disabled is expressed with a capability the operation takes, so the sequence cannot be written outside the section:

```mc
fn update(regs: *mut Regs, cs: IrqOff) -> void {
    // `cs: IrqOff` witnesses that interrupts are disabled here.
    regs.ctrl.write(...);
    regs.data.write(...);
}
```

`#[irq_context]` constrains what an ISR-callable function may **do**; it does not verify hardware **reentrancy** (an ISR re-entering shared state), which remains a target concern MC does not fully check (section 2).

Lowering: `#[irq_context]` is a verifier-only contract. It places no requirement on the emitted code beyond the calls it forbids, and does not by itself emit any interrupt-enable/disable instruction.

---

# 20. Trap ABI and Boot Profile

Language traps include:

```mc
trap(.Bounds)
trap(.NullUnwrap)
trap(.IntegerOverflow)
trap(.DivideByZero)
trap(.InvalidShift)
trap(.InvalidRepresentation)
trap(.Assert)
trap(.Unreachable)
```

Freestanding kernels provide handlers:

```mc
#[trap_handler]
fn kernel_trap(kind: TrapKind, frame: *mut TrapFrame) -> never;
```

Early handler:

```mc
#[early_trap_handler]
#[no_lang_trap]
fn early_trap(kind: TrapKind) -> never {
    arch.disable_interrupts();
    arch.halt_forever();
}
```

Before any trap handler is installed:

```txt
trap(.X) lowers to the target trap instruction.
If the target has no handler installed, the result is target-defined reset/fault/halt/reboot.
On x86, this may be a triple fault.
```

Therefore pre-handler boot code should be trap-free.

---

## 20.1 `#[no_lang_trap]`

`#[no_lang_trap]` is an IR-level guarantee:

> The compiler must not emit any language-trap edge from this function.

It is not a theorem-proving mode.

Rejected:

```mc
let z = a + b;       // checked add may trap
let x = buf[i];      // bounds check may trap
unwrap(ptr);         // may trap
assert(cond);        // may trap
unreachable();       // traps if reached
```

Allowed:

```mc
let y = wrapping.add(a, b);
raw.store<u64>(addr, value);
asm opaque volatile { ... }
```

Fixed compile-time access uses explicit const operations:

```mc
let x = arr.const_get<0>();     // OK if 0 < len(arr)
```

Boot entry:

```mc
#[naked]
#[no_lang_trap]
export fn boot_entry() -> never {
    asm opaque volatile {
        // set stack
        // build minimal page tables
        // install trap vector
        // jump to early_boot
    }
}
```

Distinction:

```txt
Language trap:
    bounds, overflow, invalid representation, unwrap failure, assert failure

Target fault:
    page fault, machine check, invalid MMIO, invalid physical address
```

`#[no_lang_trap]` forbids the first category, not the second.

---

# 21. Errors and Cleanup

MC uses `Result`, not exceptions and not global `errno`.

```mc
enum OpenError {
    not_found,
    denied,
    bad_path,
}

fn open(path: []const u8) -> Result<File, OpenError>;
```

Call:

```mc
let file = open(path)?;
```

`?` has fixed lowering:

```mc
let tmp = open(path);
switch tmp {
    .ok(v) => v,
    .err(e) => return err(e),
}
```

The error branch has type `never`, because `return err(e)` does not continue. The whole `?` expression has the success type.

No stack unwinding.  
No hidden allocation.  
No hidden runtime.

Lexical cleanup:

```mc
fn load_module(path: []const u8) -> Result<Module, LoadError> {
    let file = fs.open(path)?;
    defer file.close();

    let image = alloc.read_all(file)?;
    defer alloc.free(image);

    let module = parse_module(image)?;
    return ok(module);
}
```

`defer` is lexical only.

It does not prove lifetime safety.

This may still be wrong:

```mc
fn parse() -> Result<View, Error> {
    let image = alloc.read_all(file)?;
    defer alloc.free(image);

    let view = parse_view(image)?;
    return ok(view);     // may dangle if view borrows image
}
```

MC core does not have a borrow checker.

---

# 22. Comptime and Reflection

MC uses a narrow compile-time subset, not a full second language.

```mc
const fn align_up(x: usize, a: usize) -> usize {
    return (x + a - 1) & ~(a - 1);
}
```

Allowed:

```txt
integer/bool/unit/enum compile-time values
array/struct compile-time values
loops with compiler fuel limit
type parameters
layout reflection
```

Forbidden:

```txt
runtime pointer dereference
MMIO access
DMA allocation
I/O
inline asm
runtime heap allocation
```

Trap during const eval is a compile error.

Reflection:

```mc
sizeof(T)
alignof(T)
field_offset(T, .field)
field_type(T, .field)
bit_offset(T, .field)
repr_of(T)
```

Reflection must work over kernel profile types:

```mc
extern struct
extern mmio struct
packed struct
packed bits
safe tagged union
arrays and slices
Reg<T, access>
RegBits<T, Layout, access>
MmioPtr<T>
UserPtr<T>
PAddr
VAddr
DmaAddr
DmaBuf<T, mode>
```

Example:

```mc
comptime {
    assert(sizeof(Uart16550) == 5);
    assert(field_offset(Uart16550, .lsr) == 4);
}
```

Runtime hardware actions are forbidden at comptime:

```mc
comptime {
    let uart = mmio.map<Uart16550>(phys(0x1000_0000));  // compile error
}
```

---

# 23. Inline Assembly

MC has two assembly forms.

---

## 23.1 Opaque Assembly

```mc
asm opaque volatile {
    "cli"
    clobber("memory")
}
```

Properties:

```txt
Conservative.
May affect arbitrary machine state.
May read/write memory.
Cannot be deleted.
Cannot be reordered across memory clobber.
Does not grant optimizer assumptions.
Belongs to strict unsafe MC.
```

---

## 23.2 Precise Assembly

```mc
#[unsafe_contract(precise_asm)]
{
    asm precise volatile {
        "bsf %1, %0"
        out("rax") idx: u64,
        in("rbx") mask: u64,
        clobber("cc"),
    }
}
```

Properties:

```txt
Compiler trusts the declared inputs, outputs, and clobbers.
Incorrect constraints violate the unsafe contract.
Violation has region-scoped unspecified behavior.
```

---

# 24. C ABI and FFI

MC can call C ABI functions.

```mc
extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
```

But MC does not inherit C semantics.

`c_void` is the C opaque-object pointee type.

```txt
c_void is not MC void.
c_void has no size, alignment, fields, or valid dereference operation in MC.
Pointers to c_void may be passed, compared, and converted only through explicit FFI boundary operations.
```

C strings are explicit:

```mc
extern "C" fn strlen(s: cstr) -> usize;
```

Not:

```mc
extern "C" fn strlen(s: *const u8) -> usize;  // insufficient contract
```

C ABI structs are explicit:

```mc
extern struct Timespec {
    sec: i64,
    nsec: i64,
}
```

Rules:

```txt
MC can match C ABI.
MC does not inherit C UB.
UB inside C code remains outside MC's guarantee.
Boundary contracts must express nullability, alignment, ownership, and representation.
```

---

# 25. Minimal Syntax Principles

MC removes C constructs that create hidden behavior.

Removed:

```txt
implicit integer promotions
implicit signed/unsigned mixing
implicit pointer conversions
void* automatic conversion
array-to-pointer decay
function-to-pointer decay
assignment expressions
comma operator
++ / --
switch fallthrough
textual macro substitution
unsequenced expression behavior
```

Evaluation order is defined:

```txt
Function arguments evaluate left to right.
Binary operators evaluate left operand then right operand.
Assignment evaluates RHS, then LHS address, then stores.
&& and || short-circuit.
```

Conditions must be `bool`.

```mc
if ptr { }       // compile error
if n { }         // compile error

if ptr != null { }
if n != 0 { }
```

Boolean operators:

```mc
!a
a && b
a || b
```

are defined only for `bool`.

Bit tests require explicit comparison or named bitfields:

```mc
if (flags & TX_EMPTY) != 0_u32 {
    transmit();
}
```

Preferred for hardware registers:

```mc
if status.tx_empty {
    transmit();
}
```

---

# 26. Rationale Appendix

## 26.1 Why Not C?

C’s core problem is not merely lack of features. It is that many ordinary mistakes become undefined behavior, and modern optimizers may use that undefinedness as a global assumption.

MC’s rule is different:

```txt
The program can be wrong.
The compiler cannot pretend the wrong case is impossible unless the programmer explicitly signs an unsafe contract.
```

---

## 26.2 Why Not Rust?

Rust aims for general memory safety through ownership, borrowing, lifetimes, and stronger aliasing rules.

MC deliberately does not adopt borrowing, lifetimes, or whole-program aliasing analysis. It does provide one narrow, opt-in slice of ownership — the **linear `move` qualifier** (section 18.1) — but only to enforce *hardware resource use-protocols* (DMA buffer handoff, lock release, capability witnesses), not as a general memory-safety system.

MC is for code where the programmer often manipulates physical addresses, MMIO, raw memory, DMA buffers, interrupt state, page tables, and device-specific invariants that no general language can fully verify.

MC chooses:

```txt
less lifetime safety
more explicit machine modeling
smaller language core
```

---

## 26.3 Why Not Zig?

Much of MC is Zig-like: slices, explicit errors, defer, freestanding orientation, packed layout, and compile-time layout work.

The irreducible differences are:

```txt
1. Build mode may never change program semantics.
2. Unchecked optimizer assumptions are quarantined in #[unsafe_contract].
```

The kernel-profile additions—address-space types, typed MMIO, typed DMA, trap ABI, counter/serial arithmetic—could partly be library conventions in a sufficiently powerful systems language.

MC standardizes them because kernel code should not reinvent the hardware contract in every project.

---

# 27. Final Semantic Contract

MC’s final semantic contract can be summarized as:

```txt
Safe MC:
    no language-level UB
    errors are compile errors, traps, or Results

Strict unsafe MC:
    target-defined machine effects
    no extra optimizer assumptions

Unsafe-contract MC:
    unchecked optimizer assumptions
    region-scoped unspecified behavior if violated

Kernel profile:
    address spaces, MMIO, DMA, traps, counters, and boot constraints are first-class

Build modes:
    may change optimization
    may change code shape
    may change timing
    may not change abstract program meaning
```

MC does not make systems programming safe.

It makes the contract explicit enough that a kernel author can reason about where safety ends, where hardware begins, and where the optimizer is allowed to believe them.

---

# 28. Driver Library Profile (Network-Card Target)

The first conformance target for MC's library layer is a **DMA-capable network
card driver**. A NIC exercises every kernel primitive at once: BAR-mapped MMIO
registers, DMA descriptor rings plus packet buffers, completion interrupts,
locking against concurrent producers, memory ordering between descriptor writes
and the doorbell register, and network byte-order conversion. This section
specifies the library modules a NIC driver composes. Each is a thin, typed layer
over a core primitive (sections 16–19) plus the linear `move` qualifier
(section 18.1); none introduces new language semantics.

```txt
NIC driver  ──uses──▶  std/sync     locking + linear guards          (on §19 atomics + §18.1 move)
            ──uses──▶  std/ring     TX/RX descriptor rings           (on §22 generics)
            ──uses──▶  std/dma      packet buffers, ownership         (§18.2)
            ──uses──▶  std/endian   network/device byte order         (pure const fn)
            ──uses──▶  std/time     reset/link-up waits, timeouts      (on counter/serial domains)
            ──uses──▶  std/barrier  descriptor-vs-doorbell ordering    (on §17/§19 ordering)
            ──uses──▶  std/mmio     planned register-field RMW helpers  (on §17 MMIO)
            ──uses──▶  (core)       typed MMIO §17, IrqOff §19.1, irq_context
```

For a concrete device class, a second tier of libraries owns the **bus/device
protocol** so the device-specific driver stays tiny. The implemented virtio-net
driver, for example, is ~12 lines of net-specific logic over:

```txt
virtio-net  ──uses──▶  std/virtio     virtio-mmio transport: the @offset register
                                       map, the init status handshake, feature
                                       negotiation (generic across net/block/…)
            ──uses──▶  std/virtqueue   the split virtqueue: vring layout, queue
                                       setup, add_buf/kick/wait_used — the raw
                                       shared-ring access concentrated here
```

## 28.1 `std/sync` — Locks with Linear Guards

Locks are the second use of the linear `move` qualifier (after DMA). Acquiring a
lock yields a `move` (linear) `Guard`; releasing consumes it. The compiler then
rejects forgetting to unlock (`E_RESOURCE_LEAK`), double-unlock and
use-after-unlock (`E_USE_AFTER_MOVE`).

```mc
move struct Guard { /* witnesses the lock is held */ }

fn lock(l: *SpinLock) -> Guard;          // spins until acquired
fn unlock(g: Guard) -> void;             // consumes the guard, releases

// IRQ-safe variant: the guard also carries an IrqOff witness (§19.1), so the
// critical section is provably interrupt-free and re-enables on release.
move struct IrqGuard { /* held + interrupts disabled */ }
fn lock_irqsave(l: *SpinLock) -> IrqGuard;
fn unlock_irqrestore(g: IrqGuard) -> void;
```

The current prototype provides the `SpinLock` API above. Sleeping `Mutex`,
`RwLock`, and `seqlock` are planned library extensions. A NIC driver holds a
`SpinLock` (via `lock_irqsave`) around TX/RX ring updates shared between the
transmit path and the completion ISR.

## 28.2 `std/ring` — Generic Descriptor Ring

A NIC's TX and RX paths are bounded single-producer/single-consumer rings of
descriptors. `Ring<T, N>` is a generic (section 22) fixed-capacity ring:

```mc
struct Ring<T, N> { slots: [N]T, head: usize, tail: usize, count: usize }

fn ring_init(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> void;
fn ring_len(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> usize;
fn ring_is_empty(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> bool;
fn ring_is_full(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> bool;
fn ring_push(comptime T: type, comptime N: usize, r: *mut Ring<T, N>, x: T) -> bool;
fn ring_front(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> T;
fn ring_pop(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> T;
```

A `comptime N: usize` capacity makes the ring size a type parameter. The
current API mutates the ring in place; `ring_push` returns `false` when full,
while `ring_front` and `ring_pop` trap if the ring is empty. Descriptors carry
`DmaAddr` (section 18) for the buffer each slot points at.

## 28.3 `std/endian` — Byte Order

Device registers and on-wire packet headers have a fixed endianness; the host may
differ. Pure `const fn`s (comptime-foldable) convert explicitly — never an
implicit reinterpret:

```mc
export const fn swap_u16(x: u16) -> u16;
export const fn swap_u32(x: u32) -> u32;
export const fn swap_u64(x: u64) -> u64;
export const fn to_be32(x: u32) -> u32;     // host → big-endian (network order)
export const fn from_be32(x: u32) -> u32;
export const fn to_le32(x: u32) -> u32;     // host → little-endian (most devices)
export const fn from_le32(x: u32) -> u32;
```

## 28.4 `std/time` — Delays and Monotonic Ticks

Reset sequences, link-up polling, and DMA timeouts need bounded waits. Built on
the `counter`/`serial` arithmetic domains (which model tick wraparound):

```mc
type Ticks = wrap<u64>;

fn read_ticks() -> Ticks;                           // monotonic counter
fn elapsed(start: Ticks, now: Ticks) -> u64;         // wrap-correct difference
fn timed_out(start: Ticks, now: Ticks, limit: u64) -> bool;
fn poll_until(probe: fn() -> bool, timeout: u64) -> bool;
fn udelay(us: u32) -> void;                          // busy-wait microseconds
fn mdelay(ms: u32) -> void;
```

## 28.5 `std/barrier` — Memory Barriers

A descriptor must be fully written *before* the doorbell register is rung, and a
completion flag read *after* the interrupt. Explicit barriers expose the §17/§19
ordering primitives under driver-conventional names:

```mc
fn mb()  -> void;       // full barrier
fn rmb() -> void;       // load barrier
fn wmb() -> void;       // store barrier (descriptor writes before doorbell)
fn dma_wmb() -> void;   // DMA-visible store barrier
```

## 28.6 Planned `std/mmio` — Register-Field Helpers and IO-Memory Copy

The current prototype uses typed MMIO directly. A separate `std/mmio.mc` module
is not present yet. The planned helper layer is:

Thin helpers over typed MMIO (section 17): atomic read-modify-write of register
fields, and width-correct volatile copies to/from device memory (which a plain
`memcpy` would illegally coalesce or elide):

```mc
fn set_bits<R>(reg: MmioPtr<R>, mask: R) -> void;     // reg |= mask, RMW
fn clear_bits<R>(reg: MmioPtr<R>, mask: R) -> void;   // reg &= ~mask, RMW
fn modify_field<R>(reg: MmioPtr<R>, mask: R, value: R) -> void;
fn memcpy_toio(dst: MmioPtr<u8>, src: []u8) -> void;
fn memcpy_fromio(dst: []mut u8, src: MmioPtr<u8>) -> void;
```

## 28.7 Composition — the NIC Driver Shape

The transmit path composes the modules: take the lock, push a DMA-backed
descriptor onto the TX ring, order the writes, ring the doorbell.

```mc
fn transmit(dev: *Nic, frame: CpuBuffer) -> void {
    let owned = dma.clean_for_device(frame);        // §18.2: frame consumed, owned is DeviceBuffer
    let g = sync.lock_irqsave(&dev.lock);           // §28.1: linear IrqGuard
    let pushed = ring_push(Desc, TX_CAP, &dev.tx, make_desc(dma.device_addr(&owned))); // §28.2 + §18
    if !pushed { unreachable; }
    barrier.wmb();                                  // §28.5: descriptor before doorbell
    dev.doorbell.write(TX_KICK, .release);          // §17 typed MMIO
    enqueue_owned(dev, owned);                       // owned moved into the ring's pending list
    sync.unlock_irqrestore(g);                      // §28.1: consumes the guard
}
```

Every hazard a C NIC driver hits by convention is here a typed contract: a buffer
read after handoff, a lock left held, a descriptor write reordered past the
doorbell, or a host-endian value written to a big-endian field is a **compile
error**, not a runtime corruption.

---

# Part II — Implementation and Conformance Annex

This annex defines recommended implementation architecture and backend conformance requirements. It does not add new MC program semantics.

---

# A. Spec Layering

MC specification is divided into two layers:

```txt
1. Core Semantic Specification
   Defines the abstract meaning of MC programs.
   This is the language itself.

2. Implementation and Conformance Annex
   Defines recommended compiler pipeline, typed AST/HIR, verifier, MIR, backend constraints, and conformance profiles.
   This is implementation guidance and backend conformance policy.
```

Core principle:

> **MC semantics come from the MC core spec, not from C, LLVM, or any backend.**

Therefore:

```txt
Target C does not change MC semantics.
Target LLVM does not change MC semantics.
Build mode does not change MC semantics.
Backend lowering can only implement semantics, not define semantics.
```

If a backend-generated artifact behaves differently from the MC core semantics, that is a compiler bug, not a property of the MC program.

---

## A.1 Primitive and Library Layers

Orthogonal to the core/annex split, the kernel profile (section 0) separates two conformance layers:

```txt
Language primitives:
    Defined and verified by this spec. A conforming compiler MUST enforce them.
    arithmetic domains, address spaces, MMIO, DMA/cache coherence, atomics,
    interrupt context, trap ABI, compile-time reflection, inline-asm boundary,
    C ABI.

Device libraries:
    Built on the primitives, outside this spec. Conformance does NOT define them.
    PCIe, USB, NVMe, UART, SPI/I2C, Ethernet, SoC HAL, board support.
```

A guarantee the compiler enforces (a primitive) and an invariant a library asserts (a device convention) are different trust levels:

```txt
Primitive:   proven by the language; failure is a compiler bug.
Library:     asserted by the author; failure is a library bug, and where the
             assertion exceeds what the primitives prove it must be confined to
             an #[unsafe_contract] region.
```

The spec defines and conforms the primitive layer. Device libraries are the intended consumers of the primitives and the reason the primitive set exists; they are not part of language conformance.

---

# B. Recommended Compilation Pipeline

Recommended implementation pipeline:

```txt
MC Source
  ↓
Lexer / Parser
  ↓
Untyped AST
  ↓
Name Resolution
  ↓
Typed AST / HIR
  ↓
Core Verifier
  ↓
MIR / Checked IR
  ↓
MIR Verifier
  ↓
Backend Lowering
  ↓
Backend Verifier
  ↓
Target Artifact
```

Initial backend:

```txt
MC → verified C subset → gcc/clang → object file
```

Future backend:

```txt
MC → MIR → LLVM IR → object file
```

Important constraint:

> **All backends must lower from the same typed semantic representation or MIR.**

C backend and LLVM backend must not independently interpret MC source. That would create multiple MC dialects.

---

# C. Typed AST / HIR

Typed AST / HIR is the recommended frontend semantic representation.

A conforming implementation does not have to use a data structure literally named `Typed AST`, but it must have equivalent information:

```txt
1. Every expression has a determined type.
2. Every operator is resolved to explicit semantics.
3. Every possible language trap is marked.
4. Every unsafe and unsafe_contract region is marked.
5. Address-space types are preserved.
6. Arithmetic-domain types are preserved.
7. Result and optional narrowing are explicit.
```

Recommended typed expression form:

```txt
TypedExpr {
    kind: ExprKind,
    ty: Type,
    traps: TrapSet,
    safety: SafetyClass,
    span: SourceSpan,
}
```

Where:

```txt
TrapSet =
    {}
  | { Bounds }
  | { IntegerOverflow }
  | { DivideByZero }
  | { InvalidShift }
  | { InvalidRepresentation }
  | { NullUnwrap }
  | { Assert }
  | { Unreachable }
```

```txt
SafetyClass =
    Safe
  | UnsafeRequired
  | UnsafeContractRequired(kind)
  | TargetDefined
```

---

## C.1 Operators Are Semantic Nodes

Source `+` must not remain a generic `Add` node after type checking.

It must resolve to one of:

```txt
CheckedAddTrap
CheckedAddResult
WrappingAdd
SaturatingAdd
FloatAddStrict
FloatAddFast
```

Example:

```mc
let z = x + y;
```

If:

```mc
x: u32
y: u32
```

typed AST:

```txt
Binary {
    op: Add,
    semantics: CheckedAddTrap,
    ty: u32,
    traps: { IntegerOverflow }
}
```

If:

```mc
x: wrap<u32>
y: wrap<u32>
```

typed AST:

```txt
Binary {
    op: Add,
    semantics: WrappingAdd,
    ty: wrap<u32>,
    traps: {}
}
```

If:

```mc
x: sat<u8>
y: sat<u8>
```

typed AST:

```txt
Binary {
    op: Add,
    semantics: SaturatingAdd,
    ty: sat<u8>,
    traps: {}
}
```

Backend must not re-infer operator semantics.

---

## C.2 Index Expression

Source:

```mc
let x = buf[i];
```

typed AST:

```txt
Index {
    base: []T,
    index: usize,
    result: T,
    check: Bounds,
    traps: { Bounds }
}
```

If this node appears in `#[no_lang_trap]` code, the verifier must reject it unless it has already been lowered to an explicitly no-trap const/proven access form.

---

## C.3 Address-Space Expression

Address-space information must not be erased in the frontend.

Example:

```mc
let page: *mut Page = vm.map<Page>(pa)?;
```

semantic representation:

```txt
MapPhys {
    input: PAddr,
    output: *mut Page,
    result: Result<*mut Page, MapError>
}
```

Example:

```mc
user.copy_from(dst, src, n)?;
```

semantic representation:

```txt
UserCopyFrom {
    dst: []mut u8,
    src: UserPtr<const u8>,
    len: usize,
    result: Result<void, Fault>
}
```

This prevents `UserPtr<T>` from becoming a normal `T*` too early.

---

# D. Verifier

The MC verifier is part of the language definition, though it may be exposed as an independent tool.

Normative rule:

```txt
A program is not a valid MC program unless it passes the core verifier.
```

The verifier is not a linter, sanitizer, or optional static analyzer. It is the semantic validity checker.

Implementations may expose:

```sh
mc check kernel.mc
mc verify kernel.mc
mc emit-c kernel.mc
mc build kernel.mc
```

Suggested meanings:

```txt
mc check:
    parse + name resolution + typecheck

mc verify:
    parse + typecheck + core verifier

mc emit-c:
    verify + MIR lowering + C backend verification + emit C

mc build:
    verify + backend + system compiler/linker
```

---

## D.1 Core Verifier

Core verifier must check:

```txt
1. No implicit runtime conversion.
2. Arithmetic domains do not implicitly mix.
3. Conditions are bool.
4. Indices are checked usize.
5. Nullable values are explicitly handled.
6. Result values are explicitly handled or propagated by ?.
7. PAddr/UserPtr/MmioPtr/DmaAddr are not misused.
8. Reg access mode is respected.
9. Checked operations expose trap edges.
10. #[no_lang_trap] contains no language-trap edge.
11. unsafe operations appear only in unsafe context.
12. optimizer-contract operations appear only in #[unsafe_contract] context.
```

Example:

```mc
let a: wrap<u32> = 1;
let b: u32 = 2;
let c = a + b;
```

Diagnostic:

```txt
cannot add wrap<u32> and u32
```

Example:

```mc
if flags & MASK {
    transmit();
}
```

Diagnostic:

```txt
condition must be bool; compare against 0 or use a named bitfield
```

Example:

```mc
let p: UserPtr<const u8> = ...;
let x = p.*;
```

Diagnostic:

```txt
cannot directly dereference UserPtr; use user.load/user.copy_from
```

---

## D.2 Trap Verifier

Trap verifier marks all language trap edges:

```txt
checked arithmetic
bounds indexing
unwrap
division
shift
closed enum invalid representation
non-null pointer invalid representation
assert
unreachable
```

Ordinary functions may contain trap edges.

But:

```mc
#[no_lang_trap]
fn boot_entry() -> never {
    let z = a + b;
}
```

must be rejected because checked add may produce:

```txt
trap(.IntegerOverflow)
```

Definition:

```txt
After lowering to checked IR, a #[no_lang_trap] function must contain no language-trap edge.
```

It is not theorem-proving mode. If the compiler cannot eliminate the trap edge, it must reject the function.

---

## D.3 Unsafe Verifier

Unsafe verifier distinguishes:

```txt
Safe
Strict unsafe
Unsafe contract
```

Example:

```mc
unsafe {
    mmio.map<Uart>(pa)?;
}
```

is legal because this is a target-defined machine operation.

But:

```mc
unsafe {
    unchecked.add(a, b);
}
```

is illegal.

It must be:

```mc
#[unsafe_contract(no_overflow)]
{
    unchecked.add(a, b);
}
```

Rule:

```txt
unsafe permits machine operations.
unsafe_contract permits optimizer assumptions.
```

They are deliberately separate.

---

## D.4 Address-Space Verifier

Must reject:

```txt
PAddr direct dereference
UserPtr direct dereference
MmioPtr ordinary load/store
DmaAddr as PAddr
DmaAddr as VAddr
PhysPtr<T> ordinary dereference
```

Example:

```mc
let pa: PAddr = phys(0x100000);
let x = pa.*;
```

Diagnostic:

```txt
cannot dereference PAddr; map it into the current virtual address space first
```

Example:

```mc
let dma: DmaAddr = buf.dma_addr();
vm.map<Page>(dma);
```

Diagnostic:

```txt
DmaAddr is not PAddr
```

---

## D.5 Representation Verifier

Representation verifier does not prove all values are always valid.

It enforces that the compiler may not assume representation validity before one of the allowed conditions holds.

Rule:

```txt
The compiler may assume a typed value representation is valid only if:
1. A representation check dominates the use.
2. A checked constructor produced the value.
3. The source is statically known to produce valid T.
```

This especially affects C/LLVM lowering.

For example, non-null pointer metadata must not be generated before a dominating representation check exists.

---

## D.6 Context Verifier

The context verifier enforces execution-context contracts on the call graph, the same mechanism the trap verifier (section D.2) uses for `#[no_lang_trap]`.

`#[irq_context]` (section 19.1):

```txt
A #[irq_context] function may call only:
    - other #[irq_context] functions
    - non-blocking primitives (MMIO, atomics, raw stores, opaque asm)

A call to a function not proven #[irq_context], or to a blocking/sleeping/
blocking-allocating operation, must be rejected.
```

Like the trap verifier, this is a call-graph contract, not a theorem-proving mode: if the compiler cannot prove a callee satisfies the contract, it rejects the call.

---

## D.7 Linear (`move`) Verifier

The linear verifier (section 18.1) enforces single-use ownership of `move`-typed
values with a per-function move/liveness analysis over the lexical scope. It is
not a borrow checker — there are no borrows, lifetimes, or aliasing analysis.

```txt
For each binding of a `move` type:
    - moved when passed by value, returned, or assigned to another binding;
      a moved binding becomes dead.
    - using a dead binding is E_USE_AFTER_MOVE.
    - a live (unmoved) binding reaching the end of its scope is E_RESOURCE_LEAK
      (linear: every resource is consumed exactly once).
    - a `move` value cannot be copied/aliased (it has a single owner).
```

Conditional control flow joins conservatively: a binding is live after a join
only if it is live on every predecessor path; otherwise a later use is rejected.
`move` is erased after checking — it has no runtime representation or cost.

---

# E. MIR / Checked IR

Typed AST / HIR is used for frontend semantic checking. Backend should lower from MIR / Checked IR, not directly from source syntax.

MIR properties:

```txt
MIR is explicit control flow.
All traps are explicit.
All checks are explicit.
All evaluation order is explicit.
All unsafe regions are explicit.
All unsafe_contract regions are explicit.
```

---

## E.1 Checked Add MIR

MC:

```mc
let z = x + y;
```

MIR:

```txt
bb0:
    tmp, ov = add_overflow.u32 x, y
    br ov, bb_trap_overflow, bb1

bb_trap_overflow:
    trap IntegerOverflow

bb1:
    z = tmp
```

---

## E.2 Bounds Check MIR

MC:

```mc
let x = buf[i];
```

MIR:

```txt
bb0:
    ok = icmp_ult i, buf.len
    br ok, bb_load, bb_trap_bounds

bb_trap_bounds:
    trap Bounds

bb_load:
    ptr = gep buf.ptr, i
    x = load ptr
```

---

## E.3 Unsafe Contract MIR

MC:

```mc
#[unsafe_contract(no_overflow)]
{
    sum = unchecked.add(sum, x);
}
```

MIR:

```txt
contract_region R, kind = no_overflow:
    sum = unchecked_add_assume_no_overflow sum, x
end_contract_region R
```

Verifier rule:

```txt
unchecked_add_assume_no_overflow may appear only inside no_overflow contract region.
```

---

# F. Backend Independence

Backend may target:

```txt
C
LLVM IR
native machine code
another verified IR
```

Backend choice must not change MC semantics.

A conforming backend must preserve:

```txt
1. arithmetic-domain semantics
2. trap semantics
3. evaluation order
4. address-space restrictions
5. unsafe / unsafe_contract boundaries
6. no_lang_trap guarantee
7. Result / optional control-flow semantics
8. representation validation rules
9. aliasing rules
10. ordinary data-race semantics
11. debug/release semantic parity
```

Backend optimizations may change:

```txt
machine code shape
trap instruction location
number of redundant checks
timing
register allocation
layout of internal temporaries
```

Backend optimizations may not change:

```txt
abstract program result
whether a program traps/errors/succeeds for the same abstract inputs
the scope of unsafe_contract assumptions
```

---

# G. C Backend Rationale

The first backend targets C to reuse existing Linux/C systems tooling.

This includes:

```txt
gcc / clang
ld / lld
objdump
readelf
nm
gdb / lldb
perf
qemu
make / ninja / ccache
linker scripts
cross compilers
existing C ABI
existing boot and freestanding flows
```

Example pipeline:

```txt
kernel.mc
  ↓ mcc
kernel.mc.c
kernel.mc.h
kernel.mcmap
  ↓ clang/gcc
kernel.o
  ↓ ld/lld + linker script
kernel.elf
  ↓ qemu / bootloader
```

Generated files:

```txt
kernel.mc.c      generated C
kernel.mc.h      generated ABI header
kernel.mcmap     MC source / typed AST / MIR / generated C mapping
```

The purpose of target C is engineering leverage.

It is **not** to inherit C’s language model.

Core rule:

> **Generated C is a constrained target language, not the semantic source of MC.**

Short form:

> **Use the C toolchain. Do not inherit C semantics.**

---

# H. MC-C Backend Conformance

A backend claiming MC-C conformance must generate C that implements MC semantics without relying on C undefined behavior.

Generated C must not rely on:

```txt
signed overflow
unchecked out-of-bounds access
invalid shift
divide by zero
C data-race undefined behavior
strict aliasing
unspecified expression evaluation order
uninitialized typed object reads
C indeterminate values for MC-visible unspecified bytes
C bitfield layout
C union type-punning semantics
compiler-inferred nonnull assumptions
unverified restrict/noalias
```

Compiler flags may be used defensively, but MC correctness must not depend solely on them.

Recommended defensive flags:

```sh
-ffreestanding
-fno-strict-aliasing
-fno-builtin
-fno-delete-null-pointer-checks
-nostdlib
```

These flags are not the semantic foundation.  
The generated C itself must stay inside the MC-C verified subset.

---

# I. MC-C Lowering Rules

---

## I.1 Checked Arithmetic

MC:

```mc
let z = x + y;   // u32 checked
```

Must not lower to plain:

```c
uint32_t z = x + y;
```

because that wraps instead of trapping.

Correct lowering:

```c
uint32_t z;
if (__builtin_add_overflow(x, y, &z)) {
    mc_trap(MC_TRAP_INTEGER_OVERFLOW);
}
```

Portable fallback:

```c
if (UINT32_MAX - x < y) {
    mc_trap(MC_TRAP_INTEGER_OVERFLOW);
}
z = x + y;
```

Signed checked arithmetic must avoid C signed overflow entirely.

---

## I.2 Wrapping Arithmetic

MC:

```mc
let z: wrap<u32> = x + y;
```

May lower to unsigned modular arithmetic:

```c
uint32_t z = (uint32_t)(x + y);
```

`wrap<iN>` should either be forbidden in early profiles or represented internally through unsigned storage.

Baseline MC-C0 rule:

```txt
MC-C0 supports wrap/sat over the scalar integer storage types that the verifier
and C backend model explicitly. Signed storage must lower through checked or
unsigned-intermediate code paths that avoid C signed overflow.
```

---

## I.3 Saturating Arithmetic

MC:

```mc
let z: sat<u8> = a + b;
```

C lowering:

```c
uint16_t tmp = (uint16_t)a + (uint16_t)b;
uint8_t z = tmp > UINT8_MAX ? UINT8_MAX : (uint8_t)tmp;
```

Do not overflow first and repair later.

---

## I.4 Bounds Checks

MC:

```mc
let x = buf[i];
```

C lowering:

```c
if (i >= buf.len) {
    mc_trap(MC_TRAP_BOUNDS);
}
T x = buf.ptr[i];
```

The C indexing expression appears only after the bounds check.

---

## I.5 Shift

MC:

```mc
let y = x << n;
```

C shift count must be checked first:

```c
if (n >= 32) {
    mc_trap(MC_TRAP_INVALID_SHIFT);
}
```

For checked left shift, shifted-out bits must also be checked:

```c
if (x > (UINT32_MAX >> n)) {
    mc_trap(MC_TRAP_INTEGER_OVERFLOW);
}
y = x << n;
```

For CPU-style masked shift, MC source must use explicit API:

```mc
bits.shl_masked(x, n)
```

---

## I.6 Division

MC:

```mc
let q = a / b;
let r = a % b;
```

C lowering for signed division and remainder must check:

```c
if (b == 0) {
    mc_trap(MC_TRAP_DIVIDE_BY_ZERO);
}

if (a == INT32_MIN && b == -1) {
    mc_trap(MC_TRAP_INTEGER_OVERFLOW);
}

q = a / b;
r = a % b;
```

Unsigned division and remainder require the zero-divisor check but cannot overflow.

---

## I.7 Evaluation Order

MC defines left-to-right evaluation.

C backend should introduce temporaries.

MC:

```mc
foo(a(), b(), c());
```

C lowering:

```c
T1 t1 = a();
T2 t2 = b();
T3 t3 = c();
foo(t1, t2, t3);
```

Do not emit complex C expressions whose evaluation order would affect semantics.

---

## I.8 Uninitialized Storage

MC:

```mc
var buf: [4096]u8 = uninit;
```

May lower to raw C storage only while every C read of a byte is dominated by an MC write to that byte.

```c
uint8_t buf[4096];
```

If MC can observe an unwritten byte, the C backend must materialize an arbitrary byte value before the C read or route the read through a target-specific helper whose contract does not expose C indeterminate-value behavior.

The backend must not use C or LLVM `undef`, `poison`, or indeterminate values as the representation of MC unspecified bytes when those bytes can be observed by MC code.

Typed uninitialized objects must lower through byte storage.

MC:

```mc
var x: MaybeUninit<Node> = uninit;
```

C lowering:

```c
alignas(Node) unsigned char x_storage[sizeof(Node)];
```

Do not generate C code that reads an uninitialized typed `Node`.

---

## I.9 Bitcast and Aliasing

MC bitcast:

```mc
let y: u32 = bitcast<u32>(f32_value);
```

C lowering:

```c
uint32_t y;
memcpy(&y, &f32_value, sizeof(y));
```

Do not lower to:

```c
uint32_t y = *(uint32_t*)&f32_value;
```

Generated C should use:

```txt
memcpy
unsigned char storage
explicit helper functions
```

to avoid strict aliasing hazards.

---

## I.10 Non-Null Pointers

MC `*mut T` is non-null.

But C backend must not freely attach nonnull assumptions before validation.

If a C function returns a pointer that becomes MC `*mut T`:

```c
T* p = c_func();
if (p == NULL) {
    mc_trap(MC_TRAP_INVALID_REPRESENTATION);
}
```

Only after this check dominates the use may backend treat it as non-null for optimization.

---

## I.11 Overlay Union

MC overlay union must not lower to C union semantics.

MC:

```mc
overlay union Word {
    u: u32,
    bytes: [4]u8,
}
```

C lowering:

```c
typedef struct {
    alignas(4) unsigned char storage[4];
} Word;
```

Reading `u32`:

```c
uint32_t out;
memcpy(&out, word.storage, 4);
```

Reading bytes:

```c
uint8_t b0 = word.storage[0];
```

This implements MC byte-storage semantics instead of C union semantics.

---

## I.12 Packed Bits

MC packed bits must not lower to C bitfields.

MC:

```mc
packed bits UartLsr: u8 {
    tx_empty: bool,
}
```

C lowering:

```c
bool tx_empty = (raw & 0x20u) != 0;
```

C bitfield layout is not the semantic source.

---

## I.13 Atomics

MC atomics must lower through compiler/architecture atomic primitives.

Example:

```mc
flag.store(true, .release)
```

Possible C lowering:

```c
__atomic_store_n(&flag, true, __ATOMIC_RELEASE);
```

Memory order mapping must be explicit:

```txt
.relaxed  -> __ATOMIC_RELAXED
.acquire  -> __ATOMIC_ACQUIRE
.release  -> __ATOMIC_RELEASE
.acq_rel  -> __ATOMIC_ACQ_REL
.seq_cst  -> __ATOMIC_SEQ_CST
```

Do not lower atomics to ordinary volatile operations.

Ordinary MC loads and stores that may race must not be lowered to normal C accesses whose correctness depends on the C rule that data races are undefined.

A C backend must classify ordinary memory accesses before lowering:

```txt
local/proven non-racing:
    may lower to normal C loads/stores

possibly racing or externally modified:
    must lower through a race-tolerant target helper, volatile asm memory operation,
    suitable compiler intrinsic, or relaxed atomic-sized access that does not add synchronization
```

If the backend cannot prove an access is local and has no sound race-tolerant lowering for it, MC-C emission must fail.

This does not make ordinary races correct synchronization. It only prevents the C optimizer from using C data-race UB as a hidden MC optimizer assumption.

---

## I.14 MMIO

MC MMIO access:

```mc
uart.thr.write(ch, .release);
```

Must lower to an access of the specified:

```txt
width
access mode
ordering
volatility
address space
```

The backend must not merge, delete, widen, narrow, or reorder MMIO operations across the ordering constraints.

C lowering may use target-specific volatile helpers, compiler barriers, CPU fences, or inline asm barriers.

Volatile access alone is sufficient only for `.relaxed` on targets where it preserves the specified access width and count. For `.acquire`, `.release`, `.acq_rel`, and `.seq_cst`, the backend must emit whatever target barriers are required to preserve the MC ordering rule relative to ordinary memory, atomics, DMA descriptors, and other MMIO accesses.

---

## I.15 Inline Assembly

Opaque asm can lower to conservative compiler asm.

```mc
asm opaque volatile {
    "cli"
    clobber("memory")
}
```

C lowering may use GCC/Clang-style asm:

```c
__asm__ __volatile__("cli" ::: "memory");
```

Precise asm belongs only in:

```mc
#[unsafe_contract(precise_asm)]
```

and is target/compiler-specific.

---

# J. C Backend Verifier

The C backend must have its own verifier or equivalent proof obligation.

It checks that generated C does not contain:

```txt
1. unchecked signed arithmetic that may overflow
2. unchecked shift counts
3. unchecked division or remainder
4. unchecked array/pointer indexing for MC safe accesses
5. C union type punning for MC overlay union
6. C bitfields for MC packed bits
7. strict-aliasing-dependent pointer casts
8. unsequenced expressions
9. uninitialized typed reads
10. unverified restrict/noalias
11. premature nonnull assumptions
12. normal C accesses for possibly racing ordinary MC memory
13. C indeterminate-value reads for MC-visible unspecified bytes
14. MMIO orderings implemented with insufficient compiler or CPU/device barriers
```

This verifier is backend-specific.

A program can pass MC core verifier but fail MC-C backend verifier if the C backend does not yet support a feature soundly.

That is a backend limitation, not a change to MC semantics.

---

# K. Feature Admission Rule

No language feature is forbidden merely because the first backend targets C.

A feature may enter a conforming backend when it has:

```txt
1. Typed AST / HIR representation.
2. Core verifier rules.
3. MIR lowering.
4. Explicit trap / unsafe / unsafe_contract behavior.
5. Target backend lowering.
6. Backend verifier rule.
7. Tests covering semantic boundaries.
```

This replaces the weaker idea:

```txt
C backend cannot support advanced features.
```

with the stronger rule:

```txt
C backend supports any feature with sound lowering and verification.
```

Target C is not a design limitation.  
Unsound lowering is the limitation.

---

# L. MC-C Conformance Levels

The C backend defines staged conformance levels. These are implementation
profiles, not language dialects: an MC program has one semantic meaning, and a
backend either supports emitting that program or rejects it before code
generation.

---

## L.1 MC-C0: Baseline Trustworthy Backend

Supports:

```txt
fixed-width scalars
checked integer arithmetic
wrap/sat arithmetic domains
serial/counter arithmetic operations
scalar/domain conversion builtins
floating f32/f64 arithmetic
bool
arrays/slices
non-null/nullable pointers
Result
if let
switch
basic struct/enum
basic packed bits via mask/shift
overlay union via byte storage
Reg / RegBits via helpers
PAddr/VAddr/UserPtr/MmioPtr/DmaAddr as opaque wrappers
opaque asm
trap lowering
#[no_lang_trap] verifier
#[unsafe_contract] markers
narrow scalar/aggregate const globals, typed static global initializers, and
const-fn comptime folding
layout reflection for size/alignment/field offsets/bit offsets/repr,
including slices and tagged unions
C source-line hints and line-oriented .mcmap output, including global
initializer and deferred cleanup spans
```

---

## L.2 MC-C1: Kernel Backend Profile

Adds:

```txt
full packed layout via mask/shift
full typed MMIO
compiler builtin atomics / arch atomics
advanced address-space lowering
closed/open enum representation validation
typed DMA primitives: DmaAddr, DmaBuf, cache.clean/cache.invalidate
linear move checking for resource handles
field_type reflection in type-argument position
contract-scoped noalias assumptions
hosted profile for explicit fallible host I/O and libm float intrinsics
package manifests with recursive dependency/version checks
```

---

## L.3 MC-C2: Advanced Systems Profile

Adds:

```txt
library-scale DMA ownership protocols beyond the current `std/dma` move handles
precise asm per compiler/arch
full comptime reflection
advanced packed ABI validation
source/MIR-quality native debug tooling
```

MC-C0 and the implemented MC-C1 slice are the non-LLVM target for this
repository. MC-C2 work is intentionally larger than the current backend finish
line: it requires broader interpreter coverage and debugger-quality mapping
beyond `.mcmap`.

---

# M. LLVM Backend Future

The LLVM backend must use the same MIR as the C backend.

Current repository status: `emit-llvm` is an initial textual LLVM IR backend
slice. It runs after the same semantic and MIR verification gates as C emission,
and currently covers scalar functions, direct calls, checked integer arithmetic,
checked division/remainder, bool switch/if control flow with simple joins,
simple scalar locals, direct scalar assignment, simple `while` loops, and basic
pointer load/store operations. Scalar/pointer globals are supported for literal
and address-of-global initializers. Local fixed arrays of scalar elements support
array literals, checked indexing, element assignment, and element-address taking.
Plain local structs with scalar fields support literals, field load/store, and
field-address taking. Scalar fixed-array and scalar-struct globals support static
literals plus element/field access. Scalar aggregate function returns,
parameters, and direct calls are supported for fixed arrays and plain structs.
Nested fixed-array/struct element and field access works for the covered
aggregate subset, including materialized aggregate rvalues from direct calls
when indexing, field access, slicing, or array iteration needs an address. Core
slice values lower as `{ ptr, len }` values with checked indexing, `.len`,
const fixed-array access, direct returns/params, range slicing from arrays or
slices, mutable slice stores, pointer/slice identity, and direct call/local
array-or-slice indexing workflows.
Scalar `switch` lowering covers bool and integer subjects, including
multi-pattern literal arms and wildcard defaults. Core loop CFG covers `while`
and `for` over arrays/slices, including array-valued call results, with
loop-local bindings plus `break`/`continue`.
Scalar expression lowering covers integer casts, unsigned bitwise operations,
bitwise not, short-circuit boolean `&&`/`||`, and checked unsigned shifts with
invalid-count and shifted-out-bit traps, plus verified integer/enum coercions at
target-typed expression sites and fixed-layout scalar bitcasts.
Checked integer arithmetic includes signed unary negation with an `INT_MIN`
overflow trap.
Character literal lowering covers target-typed `u8` returns, locals, call
arguments, comparisons, escapes, and checked `u8` arithmetic.
String literal lowering covers target-typed `u8` pointers via private LLVM byte
constants with MC escape decoding for returns, locals, and call arguments.
Byte-view lowering covers `mem.as_bytes(&value)` as a const `u8` slice and
`mem.bytes_equal` as a length check plus byte loop.
Packed-bits lowering uses the declared integer representation for LLVM ABI,
global/static values, aliases, literals, and boolean field mask tests.
Accepted pure `comptime { ... }` blocks are omitted from runtime LLVM IR after
semantic checking.
Initialization lowering materializes observable `uninit` storage with concrete
zero values and lowers `MaybeUninit<T>.write/assume_init` through the payload
storage representation.
Opaque-address lowering represents `PAddr`/`VAddr` and `UserPtr<T>`/`PhysPtr<T>`
as `i64` and treats explicit representation-preserving casts to/from same-width
integer storage as no-op IR value conversions.
Floating-point scalar lowering covers `f32`/`f64` literals, globals, calls,
locals, arithmetic, comparison, and unary negation. Domain scalar lowering covers
`wrap<T>`/`sat<T>` payload representation, `serial<T>`/`counter<T>`/`Duration<T>`
scalar storage, `wrap` modular add/sub/mul/bitwise/shift and unary negation,
unsigned `sat` add/sub/mul, serial `before`/`after`/`distance`/`compare`,
counter `delta_mod`/`elapsed_assume_within`/`elapsed_bounded`, scalar conversion
calls `from`/`try_from`/`trap_from`/`sat_from`/`wrap_from`/`from_mod`,
`wrap.residue()`, and `wrapping.add`/`sub`/`mul`. Reduction lowering covers
integer `reduce.sum_checked<T>` with an `i128` accumulator and
`Result<T, Overflow>` result, plus floating `reduce.sum_left<T>` and
`reduce.sum_fast<T>`. Statement workflow covers
expression statements, void calls, `assert`, nested blocks, unsafe blocks, and
transparent unsafe-contract blocks. Unsafe-contract arithmetic lowering covers
`unchecked.add`/`sub`/`mul` as plain arithmetic after semantic contract
verification. The LLVM backend also lowers `trap(...)`,
`unreachable`, `never` functions, and `never` coercion in return position for
the covered trap kinds. Unsafe machine-operation lowering covers opaque address
classes, `phys(...)`, volatile `raw.load`/`raw.store`, `raw.ptr`, `cpu.pause()`,
opaque inline asm, unsafe-block raw stores, and raw-many pointer `.offset(...)`.
LLVM MMIO lowering covers `MmioPtr<T>` as a pointer ABI, `Reg`/`RegBits`
storage-width access, explicit `@offset(...)` register addressing, volatile
typed register reads/writes, `.acquire`/`.release` fences, irq-context MMIO
fixtures, and atomic operations through irq-context parameters and aliases.
DMA/IRQ marker lowering covers `DmaAddr`/`DmaBuf<T, mode>` as opaque
address-width values, `cache.clean`/`cache.invalidate` fences,
`dma_addr()`/`as_slice()` bridges, and `IrqOff` as a witness ABI value.
Linear `move` resource types lower through the ordinary struct ABI after the
shared sema move/liveness verifier proves single-use ownership. By-value move
uses are emitted as normal value transfers, and `drop(x)` evaluates and
discards its argument with no runtime linearity state.
Strict unsafe-context lowering includes `mmio.map<T>(pa)?` as a nullable
`MmioPtr<T>` address conversion with a null-unwrapping trap on the `?`.
Packed-bits lowering covers representation ABI, static/dynamic
literals, mask tests, and read-modify-write field updates. Overlay-union
lowering uses byte storage with typed scalar field writes, byte-array reads, and
field reflection. Tagged-union lowering covers aligned tag-plus-payload ABI,
constructors, direct calls/returns, locals, struct fields, and pattern switches
with payload bindings and wildcard fallback arms. Static global initializer
lowering covers string pointer arrays, constant address-of globals, and default
slice/Result/tagged-union zero initializers, plus closure/function-pointer
fields inside mutable globals. Defer lowering runs lexical cleanups in reverse
order before returns, block fallthrough, and loop `break`/`continue` exits.
Reflection lowering covers
`sizeof`/`alignof`, `repr_of`, field/bit offsets, MMIO wrapper layouts, and
`field_type(...)` in monomorphized type-argument position. Result `?`
propagation lowers to early `err(...)` returns in `Result`-returning functions,
and unsafe-contract noalias scopes lower `compiler.assume_noalias_unchecked(...)`
as a checked identity with pointer-to-address raw-store coercion. Pointer
address coercion also covers explicit pointer-to-`usize`/`isize` casts for
pointer-width integer interop. Precise asm lowering covers operand templates,
scalar output storage, input constraints, and declared clobbers. Alias and enum
lowering covers scalar, array,
raw-pointer, closed-enum, and open-enum representation cases, including enum
globals, calls, returns, arrays, struct fields, `.raw()`, integer casts to open
enums, enum switches over direct calls, and void switch expression arms.
Nullable pointer lowering covers nullable pointer ABI,
`null`, non-null-to-nullable widening, postfix `?` null-unwrapping traps,
nullable `if let`, and simple nullable switches.
Result lowering covers aggregate ABI, `ok(...)`/`err(...)` constructors,
`Result<void, E>` marker payloads, postfix `?` trap unwrap, `if let ok/err`
narrowing, and two-arm Result switches including wildcard fallback arms.
Atomic lowering covers `atomic<T>` scalar storage, `atomic.init`, `load`,
`store`, `fetch_add`, and `fetch_sub` with LLVM atomic memory orderings for
local and global atomics.
Function-pointer lowering covers `fn(...) -> T` values as opaque pointers,
static function-name initializers, copied function-pointer aggregate globals,
indirect calls through parameters, locals, globals, arrays, and struct fields,
plus function-pointer returns.
Aggregate assignment lowering covers `uninit` aggregate storage, whole
array/struct literal assignment, aggregate copies from nested elements/fields,
and nested aggregate stores through globals, arrays, and struct fields. Inferred
local lowering covers initializer-derived scalar, slice, array, and struct
storage for the covered backend subset. Aggregate layout coverage includes
structs containing arrays/slices, slices of structs/arrays, and nested array
indexing. Aggregate ABI coverage includes struct literals, array values,
generic struct monomorphizations, aggregate payloads inside Result values, and
comptime-parameter array specializations. Static aggregate global coverage
includes nested array/struct literals, scalar and function-pointer aggregate
global copies, plus const-folded `sizeof`/`alignof`/`field_offset` array
lengths and monomorphized generic layout reflection.
Iterable lowering covers arrays and slices from parameters, globals, nested
array rows, aggregate fields, direct-call aggregate fields, and direct-call
array/slice results.
LLVM debug metadata includes `source_filename`, compile-unit/file records,
function `DISubprogram` records, and statement-scoped line/column locations on
local initialization stores, direct assignment stores, aggregate literal/member
field stores, ordinary pointer/global/index loads and stores, `MaybeUninit`
writes, volatile raw/MMIO stores, atomic stores, precise asm output stores,
volatile raw/MMIO loads, atomic loads and read-modify-write operations, fences,
returns, calls, checked-arithmetic trap paths, inline asm, related runtime helper calls,
loop/break/continue branch terminators, switch/if-let dispatches,
nullable/Result/tagged-union and for-loop binding stores, aggregate rvalue and
tagged-union constructor materialization stores, tagged-union switch subject
stores and tag loads, and trap-path plus `?` propagation, short-circuit boolean,
and if-let join branch terminators for the covered backend subset, plus branch
terminators in compiler-expanded `mem.bytes_equal` and `reduce.*` helper loops.
The `zig build llvm-debug-test` gate compiles debug-rich LLVM fixtures to
objects and verifies `.debug_info`/`.debug_line`, producer/source-file metadata,
selected function DIEs, and representative source line/column rows across
calls, control flow, atomics/fences, and nullable/Result narrowing with
`llvm-dwarfdump`.
Valid `#[no_lang_trap]` functions lower when the shared verifier proves they
contain no language-trap edge; naked/boot-style opaque asm functions returning
`never` lower fallthrough as LLVM `unreachable`.
The LLVM toolchain driver `tools/toolchain/mcc-llvm-cc.sh` compiles textual IR
to linkable object files through `llc`, with representative object-output
coverage in `zig build llvm-obj-test`.
The `zig build llvm-debug-test` gate verifies DWARF source mappings in LLVM
objects after `llc` lowering.
The `zig build llvm-sweep` gate strips expected-reject declarations from the
spec corpus and verifies every in-scope valid spec fixture emits assemblable
LLVM IR. It also rejects hidden optimizer-assumption tokens
(`nuw`/`nsw`/`nonnull`/`noalias`/`noundef`/`poison`/`inbounds`/`undef` and
hidden fast-math flags, with `reassoc` allowed only for explicit
`reduce.sum_fast` floating reductions)
in the swept IR. The
current sweep has no allowlisted LLVM backend gaps. The
`zig build llvm-c-sweep` gate additionally verifies every current
`tests/c_emit` fixture emits assemblable LLVM IR under the same
assumption-token check, keeping the broad C-backend regression corpus covered
by LLVM emission. The `zig build llvm-spec-obj-sweep` gate compiles every
in-scope valid spec fixture to a non-empty LLVM object file with `llc`, and the
`zig build llvm-c-obj-sweep` gate compiles the current C-emission fixture set
to non-empty LLVM object files with `llc`.
The `zig build llvm-opt-sweep` gate applies the hidden-assumption policy to
emitted IR, runs LLVM `verify` and `default<O2>` pipeline checks over the valid
spec corpus and all current `tests/c_emit` fixtures, then lowers each optimized
O2 result to a non-empty object file with `llc`.
The `zig build llvm-cc-test`, `zig build llvm-move-test`, and
`zig build llvm-runtime-test` gates link and run LLVM-produced objects against C
drivers, including a linear `move` handle roundtrip through the LLVM ABI,
imported generic `std/stack`, `std/sync` guard, and fn-pointer runtime checks.
The `zig build llvm-toolchain-test` gate links and runs LLVM-built import/std
merge, monomorphization, and generic-struct modules, and verifies reflection
with `check` plus LLVM object lowering.
The `zig build llvm-std-test` gate additionally links LLVM-built
`std/{core,bits,math,ascii,fmt,addr}` objects into one host executable and runs
exported function checks.
The `zig build llvm-pkg-test` gate builds the package-manifest demo through
the LLVM object driver, links the resulting object, and runs it.
The `zig build llvm-demo-test` gate compiles the framebuffer/gpio/irq/spi/timer/uart
hardware demo drivers and the hosted elementwise demo through LLVM to non-empty
object files under the same hidden-assumption token check.
The `zig build llvm-kernel-test` gate compiles every non-bad `kernel/` module
through LLVM to assemblable IR and non-empty target objects, using a RISC-V
target for the main kernel modules and an x86-64 target for x86 arch modules.
The `zig build llvm-qemu-test`, `zig build llvm-trap-test`, `zig build
llvm-thread-test`, `zig build llvm-sched-test`, `zig build llvm-syscall-test`,
`zig build llvm-user-test`, `zig build llvm-process-test`, `zig build
llvm-elf-run-test`, `zig build llvm-fs-syscall-test`, `zig build
llvm-socket-syscall-test`, `zig build llvm-exec-test`, `zig build
llvm-vm-switch-test`, `zig build llvm-vmspace-test`, `zig build
llvm-vmctx-test`, `zig build llvm-sched-vm-test`, `zig build llvm-ipc-test`,
`zig build llvm-ipc2-test`, `zig build llvm-registry-test`, `zig build
llvm-timeout-test`, `zig build llvm-signal-test`, `zig build llvm-cap-test`,
`zig build llvm-restart-test`, `zig build llvm-heartbeat-test`, `zig build
llvm-privilege-test`, `zig build llvm-usched-test`, `zig build
llvm-paging-activate-test`, `zig build llvm-demand-test`, `zig build
llvm-mmap-test`, `zig build llvm-contain-test`, `zig build llvm-cow-test`, and
`zig build llvm-isolation-test`, `zig build llvm-block-server-test`, `zig build
llvm-fs-server-test`, `zig build llvm-net-server-test`, `zig build
llvm-rtc-test`, `zig build llvm-userserver-test`, `zig build
llvm-backtrace-test`, `zig build llvm-driver-test`, and `zig build
llvm-preempt-test`, `zig build llvm-smp-test`, `zig build
llvm-smp-lock-test`, `zig build llvm-ipi-test`, and `zig build
llvm-tcp-server-test` gates boot LLVM-lowered bare-metal RISC-V QEMU images for
typed MMIO, timer traps, cooperative context switching, round-robin scheduling,
syscall dispatch, U-mode entry, process lifecycle, ELF load/run, VFS syscalls,
socket syscalls, exec, `satp` address-space switching, per-process page tables,
context switches that swap address spaces, scheduler VM switching, IPC
request/reply, multi-slot IPC, registry lookup, IPC timeout, signal delivery,
capability-scoped server access, restart supervision, heartbeat liveness,
least-privilege gates, userspace-set scheduling policy, Sv39 activation,
demand paging, anonymous mmap, crash containment, copy-on-write, per-server MMU
isolation, user-mode block/filesystem/network servers, RTC MMIO, user-mode
server syscalls, backtrace symbolization, char-device driver dispatch, timer
preemption, SMP boot/sync, SMP ticket-lock mutual exclusion, inter-processor
interrupts, and a user-mode TCP passive-open server handshake.
The `zig build llvm-kmain-test` and `zig build llvm-kmain-net-test` gates boot
LLVM-lowered integrated RISC-V kernel images under QEMU; the network variant also
checks that QEMU captures the expected transmitted UDP payload.
The `zig build llvm-page-test`, `zig build llvm-heap-test`, and `zig build
llvm-paging-test` gates link and run LLVM-lowered host checks for the frame
allocator, kernel heap allocator, and Sv39 page-table map/translate helpers.
The `zig build llvm-hosted-demo-test` gate links and runs the hosted
elementwise demo through LLVM, libc, and libm, then verifies its binary
stdin/stdout `f32` round trip.
The `zig build llvm-host-suite-test` gate reuses every current data-driven host
test manifest row with each MC fixture compiled through LLVM, linked to the
existing C host driver, and run.
These LLVM IR, object, and link/run gates are included in the `zig build m0`
milestone gate.
It intentionally emits no hidden optimizer-assumption tokens outside proven
verifier conditions, and the broad LLVM sweep gates plus optimizer sweep
enforce that policy for
`nuw`/`nsw`/`nonnull`/`noalias`/`noundef`/`poison`/`inbounds`/`undef` and hidden
fast-math flags, except the explicit `reduce.sum_fast` floating-reduction
reassociation opt-in. Source/MIR-quality native debugger mapping remains future
debug-info work.

LLVM lowering examples:

Checked add:

```llvm
%pair = call {i32, i1} @llvm.uadd.with.overflow.i32(...)
%ov = extractvalue {i32, i1} %pair, 1
br i1 %ov, label %trap, label %cont
```

Wrapping add:

```llvm
%z = add i32 %a, %b
```

But:

```txt
Do not attach nuw/nsw unless proven or inside #[unsafe_contract(no_overflow)].
```

Nonnull metadata:

```txt
Only after representation check dominates use.
```

Noalias metadata:

```txt
Only from verified noalias construction or #[unsafe_contract(noalias)].
```

Contract-derived metadata:

```txt
May be attached only to the instructions, scopes, or values covered by the contract region.
Must not be emitted as persistent parameter, return, global, or call-site metadata outside the region unless re-established by an independent check/proof.
Must be stripped or ended at region exit when it exists only because of #[unsafe_contract].
```

LLVM `undef`, `poison`, `noundef`, `nonnull`, `noalias`, `nuw`, `nsw`, `inbounds`, and hidden fast-math flags are not allowed to become hidden semantic assumptions outside the MC verifier rules. The only current fast-math emission is `reassoc` for the explicit `reduce.sum_fast` floating-reduction opt-in.

LLVM is a backend, not a semantic source.

---

# N. Debug Mapping

C backend should generate mapping information:

```txt
MC source span
typed AST node id
MIR block id
generated C file/line
object symbol
```

Suggested output:

```txt
kernel.mcmap
```

Generated C should include source-line hints:

```c
#line 123 "kernel/sched.mc"
```

This allows Linux tooling to remain useful:

```txt
gdb
lldb
objdump
readelf
nm
perf
qemu traces
```

Long-term, native debug info may map directly from object code back to MC source and MIR.

---

# O. Final Implementation Contract

This annex adds no new MC program semantics.

It defines how conforming implementations preserve the existing semantics.

Final rule:

```txt
Core spec defines what MC means.
Verifier ensures the program belongs to the MC language.
MIR makes all checks and contracts explicit.
Backend implements MIR.
Backend verifier ensures target lowering does not reintroduce target-language UB.
```

For the first implementation:

```txt
Typed AST + verifier + MIR are mandatory engineering architecture.
Target C is chosen to reuse Linux/C systems tooling.
Generated C is a constrained target subset, not normal handwritten C.
LLVM can be added later under the same verifier/MIR contract.
```

Short form:

> **MC may target C, but MC is not C.  
> MC may target LLVM, but MC is not LLVM.  
> The verifier is what prevents the backend from becoming the language.**
