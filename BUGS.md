# modern-c (mc) — known compiler bugs

Found by a white-box audit of the compiler on **2026-06-10**, reproduced against `mcc` built
from commit `05ff744` (`zig-out/bin/mcc`). Every item below was reproduced; the HIGH items were
additionally re-verified by hand.

> **Resolution (2026-06-10):** all 9 items were re-verified against `mcc` and **fixed**. Each
> entry carries a `**FIXED:**` note describing the change. The full `zig build test` / `sweep` /
> `c-test` suites pass, and the HIGH soundness repros now error at `verify` (or emit correct C
> and run correctly, for MC-1/MC-5). New behaviour was confirmed with the same repro recipe below.

Run recipe used for all repros (run `mcc` from the repo root so `import "std/..."` resolves):

```sh
cd modern-c
MCC=zig-out/bin/mcc
$MCC check  file.mc                  # typecheck
$MCC verify file.mc                  # MIR verifier
$MCC emit-c file.mc [--profile=hosted]   # emit C
$MCC run-trap file.mc                # trap interpreter
clang -std=c11 emitted.c -lm -o out  # compile emitted C, then run
```

mc is sound by design (checked arithmetic), but three independent literal/operand/width
range-check holes (MC-2/3/4) each let an out-of-range or over-wide value slip past
`check`/`verify` into a **truncating** C emission, undermining the headline safety guarantee.
MC-1 (prefix precedence) silently miscomputes. The 142/142 zig-test suite misses all of these;
the blind spots are operator precedence and integer-literal boundary/width edges.

---

## HIGH

### MC-1 — Prefix operators bind looser than arithmetic/shift (silent wrong result)
- **Class:** wrong result (no error)
- **Source:** `src/parser.zig:773-794` (prefix/`unary` parse their operand with `parseExpr(14)`);
  the infix table `:1126-1148` gives `* / %` = 19, `+ -` = 17, `<< >>` = 15 — all ≥ 14.
- **Root cause:** every prefix operator (`-`, `~`, `!`, deref `*`, addr-of `&`) parses its operand
  at binding power 14, below all binary arithmetic/shift ops, so the binary op binds *into* the
  operand. `-a + b` parses as `-(a + b)` — the inverse of C.

```rust
// prec_neg.mc
export fn compute(a: i32, b: i32) -> i32 { return -a + b; }
```
```sh
$MCC check prec_neg.mc && $MCC verify prec_neg.mc        # both ok
$MCC emit-c prec_neg.mc > prec_neg.c
# driver: int main(){ printf("%d\n", compute(3,10)); }
clang -std=c11 prec_neg.c driver.c -o p && ./p           # prints -13
```
- **Expected:** `(-a) + b` = `7`. **Actual:** `-(a + b)` = `-13` (emits
  `mc_checked_neg_i32(mc_checked_add_i32(a,b))`). Also silently breaks the in-tree `neg_f64` test
  (`-a + bias`), and false-rejects valid `*p + b` (parsed `*(p+b)` → E_POINTER_ARITH_SINGLE_OBJECT).
- **Fix:** parse prefix operands at a binding power above all binary operators (≥ 21).
- **FIXED:** `src/parser.zig` — prefix/`unary`/deref/addr-of operands now parse at
  `prefix_operand_bp = 21` (above the max binary `left_bp` of 19). `-a + b` emits `(-a) + b`
  and the compiled C now returns `7`.

### MC-2 — Underscore-before-hexletter truncates the literal in the range check (unsound → miscompile)
- **Class:** soundness (false-accept) → runtime miscompile
- **Source:** `src/mir.zig:3613-3628` (`parseIntegerLiteral` breaks out of the digit loop at
  `_<letter>`), feeding `:3448-3457` / `:2368`; **duplicated** at `src/sema.zig:4711-4726`.
  Diverges from `src/eval.zig:869-879` (strips all `_`) and the C backend.
- **Root cause:** the verifier's literal parser stops at `_` followed by an alphabetic char
  (mistaking it for a type suffix), so `0xAB_C` (= 2748) is read as `0xAB` (= 171), which fits in
  `u8` → accepted. eval and emit-c read the full value, so the emitted C truncates.

```rust
// unsound.mc
export fn get() -> u8 { let x: u8 = 0xAB_C; return x; }
```
```sh
$MCC verify unsound.mc                       # accepted (the plain `2748` is correctly rejected)
$MCC emit-c unsound.mc | grep 'x ='          # uint8_t x = 0xABC;  -> clang truncates to 188
```
- **Expected:** `E_INTEGER_LITERAL_OUT_OF_RANGE` (same as `2748`). **Actual:** accepted; runtime
  value 188.
- **Fix:** strip *all* underscores before parsing magnitude in both `mir.zig:3618` and
  `sema.zig:4719`.
- **FIXED:** both `parseIntegerLiteral` copies (`src/mir.zig`, `src/sema.zig`) now strip every
  `_` and parse the full magnitude (matching the C backend and `eval.zig`). `0xAB_C` is read as
  `2748` and rejected; `0x20_u8` and `1_000` still behave correctly.

### MC-3 — Out-of-range literal as a binary operand is never range-checked, then truncated (unsound)
- **Class:** soundness — defeats checked arithmetic
- **Source:** `src/sema.zig:2496` (`checkIntegerLiteralInitializer` only runs in
  init/return/arg/struct/array contexts), `:1539-1595` (binary arm checks no literal operand),
  `:2945-2953` (`checkCheckedIntegerBinaryOperands` returns early for `int_literal`).
- **Root cause:** `let x: u8 = 300` is rejected, but `x * 300` (x:u8) is not — the binary arm never
  range-checks the literal operand, so emit-c stores `uint8_t mc_tmp1 = 300;` (clang truncates to
  44) *before* the overflow check runs.

```rust
// finding_b.mc
export fn defeats_check() -> u8 { let x: u8 = 5; let y: u8 = x * 300; return y; }
```
- **Expected:** `E_INTEGER_LITERAL_OUT_OF_RANGE` (or a trap). **Actual:** accepted;
  `mc_checked_mul_u8(5, 44)` returns 220 instead of erroring on `5 * 300`.
- **Fix:** run `checkIntegerLiteralInitializer` on binary operands against the operation's context
  type.
- **FIXED:** `src/sema.zig` — the binary arm now calls `checkBinaryLiteralOperandRange`, which
  range-checks each literal operand against the other operand's checked-integer bounds for
  arithmetic, comparison, and `& | ^`. `x * 300` (x:u8) and `x < 300` are now rejected.

### MC-4 — Bitwise `& | ^` accept mismatched-width unsigned operands, silently narrowing (unsound)
- **Class:** soundness — miscompile, data loss
- **Source:** `src/sema.zig:1563-1565` (`checkCheckedIntegerBinaryOperands` gated to
  arithmetic/comparison, not bitwise), `:2988` (`checkBitwiseOperatorOperands` validates each
  operand individually, never width-matches), `:3841` (`mergeArithmetic` returns the first
  operand's type).
- **Root cause:** `+ - * /` require matching operand types, but `& | ^` skip that helper. With the
  narrow operand on the left, `mergeArithmetic` yields the narrow type, matching a narrow target.

```rust
// finding_a.mc
export fn truncates_u64() -> u8 {
    let wide: u64 = 0x1_0000_0001;
    let lo: u8 = 1;
    let r: u8 = lo | wide;     // emits  uint8_t r = (lo | wide);  -> high bits dropped
    return r;
}
```
- **Expected:** `E_NO_IMPLICIT_INTEGER_PROMOTION` (as `u8 + u64` correctly gets). **Actual:**
  accepted; result `1` (upper 32 bits lost).
- **Fix:** call `checkCheckedIntegerBinaryOperands` for `& | ^` as well.
- **FIXED:** `src/sema.zig` — the binary arm now also runs `checkCheckedIntegerBinaryOperands`
  for `bit_and`/`bit_or`/`bit_xor` (shifts excluded, since a shift count is not width-matched).
  `lo | wide` (u8 | u64) now errors `E_NO_IMPLICIT_INTEGER_PROMOTION`; same-width `a | b` is fine.

### MC-5 — emit-c rejects valid float arithmetic over members / derefs / casts
- **Class:** miscompile (valid program won't emit)
- **Source:** `src/lower_c.zig:5500` (`exprResolvesToFloat`); error raised at `:3451` via the binary
  arm `:3442-3451` and `emitExprWithTarget` `:4248-4252`.
- **Root cause:** `exprResolvesToFloat` only recognizes a float operand when it is a float literal,
  a float-typed local/param ident, a local float-array index, or a float-returning call — it has no
  arm for `.member`, `.deref`, `.cast`, or global float idents (all hit `else => false`). So
  `binaryIsFloat` is false, the integer path runs, and `checkedHelperParts(.add,"f64")` returns
  null → `error.UnsupportedCEmission`.

```rust
// float_member.mc
struct Vec2 { x: f64, y: f64 }
export fn sum(v: Vec2) -> f64 { return v.x + v.y; }
```
- **Expected:** emits `return v.x + v.y;`. **Actual:** `verify` ok, `emit-c` → `UnsupportedCEmission`.
  Blocks vectors, matrices, dot products, int→float conversion. (The OR-heuristic is sound because
  the checker forbids mixed int/float, so this is purely false-reject.)
- **Fix:** add `.member` / `.deref` / `.cast` / global-ident arms to `exprResolvesToFloat`.
- **FIXED:** `src/lower_c.zig` — `exprResolvesToFloat` gained `.member` (via `operandEmitType`,
  which also resolves global idents), `.deref` (via `derefPointeeType`), and `.cast` (target
  type) arms. `v.x + v.y`, `*p + *q`, and `n as f64 + 1.0` now emit correct float arithmetic.

---

## MEDIUM

### MC-6 — Const-generic literal is mangled by its raw lexeme (`Buf<0x10>` ≠ `Buf<16>`)
- **Source:** `src/monomorphize.zig:517-520` (`rewriteGenericStruct` mangles a literal type-arg from
  its raw lexeme).
- `Buf<0x10>` → `Buf__0x10` while `Buf<16>` / folded `Buf<N>` → `Buf__16` — distinct, incompatible
  structs. Valid `first(0x10, b)` is rejected (`E_NO_IMPLICIT_CONVERSION`) and duplicate structs are
  emitted. Other paths use the canonical `{d}` form.
- **Fix:** append `allocPrint("{d}", value)` at `:520`.
- **FIXED:** `src/monomorphize.zig` — the integer-literal const-generic arm now mangles from the
  parsed value's canonical `{d}` form, so `Tag<u32, 0x10>`, `Tag<u32, 16>`, and a folded
  `Tag<u32, N>` all name one instance. The previously-rejected cross-form call now type-checks.

### MC-7 — Comptime `~` is not masked to the operand width
- **Source:** `src/eval.zig:755-758` (`foldComptimeUnary .bit_not` does `~v` on i128, no width mask;
  compare the runtime path `:842-844`).
- The comptime evaluator works in i128 and never masks to the declared width, so `~x` for
  `x: u32 = 0` folds to `-1` instead of `0xFFFFFFFF`. `assert(~zero == 0xFFFFFFFF)` is wrongly
  rejected (`E_COMPTIME_TRAP`) and diverges from the runtime result (true). Hits the canonical
  register-mask identity that std/kernel code relies on.
- **Fix:** mask the comptime result to the operand width, as the runtime path does.
- **FIXED:** `src/eval.zig` — `ComptimeScope` now tracks the declared bit-width of bound names
  (const-fn params, comptime locals), and `foldComptimeUnary`'s `.bit_not` masks `~v` to the
  operand's width (folding to `.unknown` when the width is unknown rather than guessing).
  `~zero == 0xFFFFFFFF` (u32) is now true; `~zero == 5` still traps; `align_up`'s `& ~(a-1)`
  still folds.

---

## LOW

### MC-8 — A cast in a `const` global initializer is rejected
- **Source:** `src/sema.zig:4480-4495` (`isStaticGlobalInitializer` has no cast arm) and
  `src/eval.zig:355-376` (`foldComptimeExpr` has no cast arm); rejection at `src/sema.zig:806-807`.
- `const G: u32 = 0 as u32;` → `E_GLOBAL_INITIALIZER_NOT_STATIC`, while `const G: u32 = 0;` and the
  same cast inside a local `let` are accepted. Also affects `(5 as u32) & 0xFF`, `(0xFF as u32) << 2`,
  `~(0 as u32)`.
- **Fix:** add a cast arm to both the static-initializer recognizer and the comptime folder.
- **FIXED:** `src/eval.zig` `foldComptimeExpr` gained a `.cast` arm (via `comptimeCastValue`,
  which applies C truncation/sign-extension to T's width) and `src/sema.zig`
  `isStaticGlobalInitializer` gained a `.cast` arm. `const G: u32 = 0 as u32`, `(5 as u32) & 0xFF`,
  `(0xFF as u32) << 2`, and `~(0 as u32)` all type-check and emit the correct constant.

### MC-9 — `run-trap` interpreter panics (SIGABRT) on integer widths ≥ 128 / signed width 0
- **Source:** `src/eval.zig:105-117` (`IntInfo.min/max/contains`), `:854-867` (`intInfo`).
- `intInfo` string-parses `u<N>` / `i<N>` with no validation that N ∈ {8,16,32,64}. `max()` does
  `1 << bits` (overflows i128 for bits ≥ 128); `min()` does `1 << (bits-1)` (underflows for `i0`).
  A `u128` / `i128` / `i0` fixture aborts `mcc` with a Zig panic (exit 134) instead of a clean
  diagnostic. The surrounding code already has `error.UnsupportedRunTrapFixture` for this case.
- **Fix:** validate the width in `intInfo`; return `error.UnsupportedRunTrapFixture` for
  N ∉ {8,16,32,64}.
- **FIXED:** `src/eval.zig` — `intInfo` now returns `error.UnsupportedRunTrapFixture` for any
  width ∉ {8,16,32,64}. A `u128` / `i128` / `i0` run-trap fixture exits with a clean error
  (exit 1) instead of a Zig panic (exit 134); valid u8/16/32/64 fixtures are unaffected.
