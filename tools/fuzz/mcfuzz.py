#!/usr/bin/env python3
"""mcfuzz — a type-directed fuzzing framework for the MC compiler.

Where the original string generators (mcgen.py / mcgen_move.py) hard-coded one shape over
wrap<u64>, this is a small *framework*:

  - a TYPE MODEL (the scalar type system: every int width signed/unsigned, f32/f64, bool),
    each type knowing how to produce a literal, which trap-free operations it supports, and
    how to fold a value of it into the u64 digest;
  - a TYPE-DIRECTED GENERATOR with a typing environment: gen_value(T) always yields a
    well-typed, trap-free expression of type T, so every generated program type-checks by
    construction;
  - pluggable ORACLES that decide pass/fail for a generated program:
      * differential — compile through BOTH backends, run, assert identical output (codegen /
        evaluation-order / ABI divergences);
      * sanitize     — compile the emitted C with UBSan and run (undefined behavior the C
        backend should never emit for safe MC).

Everything stays trap-free by construction (wrapping.add, masked shifts, modular conversions,
float ops that yield inf/NaN rather than trapping), so a difference is always a real bug, never
a trap. New type families (structs, enums, optionals, move resources) plug in as new entries in
the type model + generator handlers; new checks plug in as new oracles.

Usage:
  tools/fuzz/mcfuzz.py gen <seed>                       # print one program
  tools/fuzz/mcfuzz.py run [--count N] [--oracle X] [--start S] [--jobs J] [--mcc PATH]
        oracle: differential (default) | sanitize
"""
import argparse
import os
import random
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mcref  # noqa: E402  (reference interpreter for the `reference` oracle, G1)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
while ROOT != "/" and not os.path.exists(os.path.join(ROOT, "build.zig")):
    ROOT = os.path.dirname(ROOT)

TRAP_STUBS = "\n".join(
    "void mc_trap_%s(void){__builtin_trap();}" % t
    for t in ("Assert", "Bounds", "DivideByZero", "IntegerOverflow",
              "InvalidRepresentation", "InvalidShift", "NullUnwrap", "Unreachable")
) + "\n"

DRIVER = ('#include <stdint.h>\n#include <stdio.h>\n'
          'extern uint64_t harness(void);\n'
          'int main(void){ printf("%llu\\n", (unsigned long long)harness()); return 0; }\n')


# ----- type model -----
# kind: uint | sint | float | bool. width in bits. lit(rng) -> MC literal. fold(name) -> a u64
# expression reducing a value of this type to bits/magnitude.
def _uint_lit(width):
    hi = (1 << width) - 1
    # Bias toward representational corners (0, 1, max, max-1, the signed-split point) so checked
    # ops land on overflow edges far more often than a uniform draw would — most integer bugs
    # live at the boundaries, not in the bulk.
    corners = [0, 1, 2, hi, hi - 1, hi >> 1, (hi >> 1) + 1]
    return lambda rng: str(rng.choice(corners) if rng.random() < 0.3 else rng.randint(0, hi))

def _sint_lit(width):
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    corners = [lo, lo + 1, -1, 0, 1, hi, hi - 1]
    return lambda rng: str(rng.choice(corners) if rng.random() < 0.3 else rng.randint(lo, hi))

def _float_lit(rng):
    # a finite decimal literal (keep magnitudes modest so products stay finite)
    return "%d.%d" % (rng.randint(-1000, 1000), rng.randint(0, 999))

TYPES = {}
def _t(name, kind, width, lit, fold):
    TYPES[name] = {"name": name, "kind": kind, "width": width, "lit": lit, "fold": fold}

def _domain_fold(width):
    # A `sat<uN>`/`wrap<uN>` is observed by extracting its underlying unsigned value, then widening.
    return lambda n: "((u%d.wrap_from(%s)) as u64)" % (width, n)

_sat_fold = _domain_fold

for w in (8, 16, 32, 64):
    _t("u%d" % w, "uint", w, _uint_lit(w), lambda n: "((%s) as u64)" % n)
    _t("i%d" % w, "sint", w, _sint_lit(w), lambda n: "((%s) as u64)" % n)
    # Saturating arithmetic is a distinct *domain* (`sat<T>`, unsigned-only): `+ - *` saturate
    # instead of trapping or wrapping. Treated as its own value type so its operands never mix
    # with plain ints.
    _t("sat<u%d>" % w, "sat", w, _uint_lit(w), _domain_fold(w))
    # Wrapping arithmetic domain (`wrap<T>`, unsigned-only): `+ - *` and bitwise/`>>` wrap modulo
    # 2^N. Distinct lowering from the `wrapping.add` builtin, so it is its own value type.
    _t("wrap<u%d>" % w, "wrap", w, _uint_lit(w), _domain_fold(w))
_t("usize", "uint", 64, _uint_lit(64), lambda n: "((%s) as u64)" % n)
_t("f64", "float", 64, _float_lit, lambda n: "bitcast<u64>(%s)" % n)
_t("f32", "float", 32, _float_lit, lambda n: "(bitcast<u32>(%s) as u64)" % n)
_t("bool", "bool", 1, lambda rng: rng.choice(("true", "false")), None)

UINTS = [n for n, t in TYPES.items() if t["kind"] == "uint"]
SINTS = [n for n, t in TYPES.items() if t["kind"] == "sint"]
INTS = UINTS + SINTS
SATS = [n for n, t in TYPES.items() if t["kind"] == "sat"]
WRAPS = [n for n, t in TYPES.items() if t["kind"] == "wrap"]
FLOATS = [n for n, t in TYPES.items() if t["kind"] == "float"]
# f32 generation is enabled (A7). The C-backend bug it was blocked on — f32 constant
# expressions emitted with bare C `double` literals, computed in double then narrowed (~1 ULP
# off the LLVM f32 path) — is fixed (lower_c emitF32Expr suffixes f32 literals with `f`). Floats
# (f32 and f64) are folded by *comparison*, not bitcast, so NaN/inf observations stay stable.
GEN_SKIP = set()
VALUE_TYPES = [t for t in (INTS + FLOATS) if t not in GEN_SKIP]  # foldable into the digest


class Gen:
    def __init__(self, seed, trapping=False, float_bits=False):
        self.rng = random.Random(seed)
        # float_bits mode (G4): restrict float ops to + - * (no `/`, so no inf/NaN from div) and
        # fold floats by *bitcast* instead of comparison, so the digest observes the exact float
        # bits — catching ~1-ULP cross-backend divergences the comparison fold hides.
        self.float_bits = float_bits
        # V3.3: in metamorph mode the memory-op generators (@offset structs / overlay unions /
        # slices) emit a *semantics-preserving* variant of the SAME layout/data observation — field
        # reorder with pinned @offset, overlay-read recomposition / position swap, equivalent index
        # expressions, slice-of-slice. Same seed -> identical RNG draws, so the only thing that
        # changes is HOW the (identical) bytes are observed; the digest must be unchanged. This
        # targets the memory-op lowering — the class that hid the overlay-read bug.
        self.metamorph = False
        self.env = {}        # type name -> [var names in scope at top level]
        self.nvars = 0
        self.depth = 0       # block nesting (new vars only at depth 0)
        self.structs = {}    # struct name -> [(field, scalar type name)]
        self.enums = {}      # closed enum name -> [variant names] (folded via exhaustive switch)
        self.open_enums = {} # open enum name -> [variant names] (`.raw()`-foldable; nests in aggregates)
        self.functions = []  # [(name, [(param, type)], ret type)] — call only earlier ones (a DAG)
        self.result_fns = []  # [(name, param type, ok type)] — Result<ok, u32> helpers (A1)
        self.agg_fns = []    # [(name, param type, return type)] — aggregate-by-value helpers (G3)
        self.arrays = {}     # "[N]T" -> (element type, length)
        self.tuples = {}     # "(T0, T1, …)" -> [element type names] (G14; structural, no decl)
        self._spk = None     # G14: ("SPk", elem type) struct-of-pointers, or None
        self._conv_w = None  # G13: uint width for the `type Wconv = wrap<uN>` conversion alias
        self._slice_helpers = set()  # G8: element types for which a `[]mut T` sum helper is declared
        self.aliases = {}    # alias name -> underlying int type (A11); transparent in use
        self.packed = {}     # packed-bits type name -> [bool field names] (G2 kernel surface)
        self.offset_structs = {}  # G15 kernel surface: mmio struct name -> [(field, regW, off)] (layout via sizeof/field_offset)
        self.overlays = {}   # G15 kernel surface: overlay-union name -> [(member, "u%d"|"[%d]u%d", isArray)]
        self.unions = {}     # G7: union name -> ([(caseName, intPayloadType)], emptyCaseName|None)
        self.immutable = set()  # binding names that are read-only (e.g. a `for x in …` element)
        # trapping mode: emit *checked* arithmetic (`+ * / <<`) whose operands are unconstrained,
        # so a program may trap (overflow / divide-by-zero). Under the differential's status
        # contract, both backends must then trap together — this exercises the trap-lowering
        # surface the trap-free mode skips. (Not for the sanitize oracle, where a trap is a
        # non-zero exit.)
        self.trapping = trapping

    # ---- expressions ----
    def gen_leaf(self, tyname):
        live = self.env.get(tyname, [])
        if live and self.rng.random() < 0.6:
            return self.rng.choice(live)
        return TYPES[tyname]["lit"](self.rng)

    # A pair (a, b) for a checked op: anchor at least one operand to a live variable so the C
    # emitter can type the op (two bare literals defeat its inference).
    def anchored_pair(self, tyname):
        live = self.env.get(tyname, [])
        a = self.rng.choice(live) if live else self.gen_leaf(tyname)
        b = self.gen_leaf(tyname)
        return a, b

    # Integer expressions are kept FLAT — every checked op (wrapping.add / bitwise / shift /
    # conversion) is a complete value with *leaf* operands (variables or literals), and is only
    # ever used as the RHS of a typed declaration/assignment. That guarantees the C emitter
    # always has the target type from the declaration and every operand is trivially typed,
    # which sidesteps a class of emit-c type-inference gaps this framework surfaced (a checked
    # op embedded where its type must be re-inferred — under a bitwise operand, a cast, or a
    # comparison — fails to lower while the LLVM backend lowers it fine). Floats nest freely,
    # since float ops carry no such target requirement.
    def local_types(self):
        return (VALUE_TYPES + SATS + WRAPS + list(self.aliases) + list(self.structs) + list(self.enums)
                + list(self.open_enums) + list(self.arrays) + list(self.tuples))

    def gen_value(self, tyname, d=0):
        if tyname in self.aliases:  # a type alias is transparent: value of the underlying type
            return self.gen_value(self.aliases[tyname], d)
        if tyname in self.structs:  # construct: `.{ .f = <field value>, … }`
            return ".{ %s }" % ", ".join(".%s = %s" % (f, self.gen_value(t)) for f, t in self.structs[tyname])
        if tyname in self.enums or tyname in self.open_enums:  # an enum literal: `.Variant`
            return ".%s" % self.rng.choice((self.enums.get(tyname) or self.open_enums[tyname]))
        if tyname in self.arrays:   # an array literal `.{ e0, …, e{N-1} }`
            elem, length = self.arrays[tyname]
            aggregate = elem in self.structs or elem in self.arrays or elem in self.open_enums
            gen = self.gen_value if aggregate else self.gen_leaf
            return ".{ %s }" % ", ".join(gen(elem) for _ in range(length))
        if tyname in self.tuples:   # G14: a tuple literal `(e0, e1, …)` (>= 2 elements)
            return "(%s)" % ", ".join(self.gen_value(et) for et in self.tuples[tyname])
        # Sometimes call a (earlier-declared) function returning this type. Args are leaves so
        # the call is type-clean; the DAG of functions guarantees termination.
        if d < 2 and self.functions and self.rng.random() < 0.3:
            cands = [fn for fn in self.functions if fn[2] == tyname]
            if cands:
                name, params, _ = self.rng.choice(cands)
                return "%s(%s)" % (name, ", ".join(self.gen_leaf(pt) for _, pt in params))
        ty = TYPES[tyname]
        kind = ty["kind"]
        if kind == "float":
            # Floats are observed by comparison (see program()), so `/` is fine now: `x / 0.0`
            # yields inf/NaN whose *ordering* is IEEE-defined and backend-stable (NaN compares
            # false to everything but `!=`), unlike its bit pattern.
            if d >= 3 or self.rng.random() < 0.4:
                return self.gen_leaf(tyname)
            # `/` can yield inf/NaN; exclude it in float_bits mode so results stay finite and
            # their exact bits are a stable cross-backend observable.
            ops = ("+", "-", "*") if self.float_bits else ("+", "-", "*", "/")
            op = self.rng.choice(ops)
            return "(%s %s %s)" % (self.gen_value(tyname, d + 1), op, self.gen_value(tyname, d + 1))
        if kind == "sat" or kind == "wrap":
            # `sat<uN>` clamps and `wrap<uN>` wraps; both are trap-free unsigned domains. Operands
            # must share the domain type, so combine only *live* vars of the same type; with none
            # yet in scope (the first such decl) fall back to a literal initializer. `sat` has no
            # bitwise; `wrap` adds bitwise/`>>` (all modular, no trap).
            live = self.env.get(tyname, [])
            if len(live) >= 1 and self.rng.random() < 0.6:
                ops = ("+", "-", "*") if kind == "sat" else ("+", "-", "*", "&", "|", "^")
                op = self.rng.choice(ops)
                return "(%s %s %s)" % (self.rng.choice(live), op, self.rng.choice(live))
            if kind == "wrap" and live and self.rng.random() < 0.3:
                return "(%s >> %d)" % (self.rng.choice(live), self.rng.randrange(0, ty["width"]))
            return self.gen_leaf(tyname)
        if self.rng.random() < 0.35:
            return self.gen_leaf(tyname)
        if kind == "uint":
            if self.trapping and self.rng.random() < 0.5:
                return self.gen_checked(tyname, ty["width"], signed=False)
            # Note: `<<` is a *checked* left shift that traps on value overflow (masking only the
            # amount prevents InvalidShift, not IntegerOverflow), so it is not trap-free and is
            # excluded; `>>` cannot overflow and stays.
            op = self.rng.choice(("wadd", "and", "or", "xor", "shr", "conv"))
            if op == "wadd":
                # Anchor with a variable: `wrapping.add(lit, lit)` emits `(lit + lit)` where the
                # C literals default to signed `int` (overflow UB even for an unsigned result);
                # `(uint_var + lit)` forces unsigned arithmetic by C's conversion rules.
                live = self.env.get(tyname, [])
                if not live:
                    return self.gen_leaf(tyname)
                return "wrapping.add(%s, %s)" % (self.rng.choice(live), self.gen_leaf(tyname))
            if op in ("and", "or", "xor"):
                sym = {"and": "&", "or": "|", "xor": "^"}[op]
                return "(%s %s %s)" % (self.gen_leaf(tyname), sym, self.gen_leaf(tyname))
            if op == "shr":
                return "(%s >> %d)" % (self.gen_leaf(tyname), self.rng.randrange(0, ty["width"]))
            # conv: narrow an int into this unsigned type, modular (source is a leaf so the cast
            # operand is trivially typed).
            candidates = [t for t in INTS if self.env.get(t)]
            if candidates and self.rng.random() < 0.7:
                src = self.rng.choice(candidates)
                srcval = self.rng.choice(self.env[src])
            else:
                src = self.rng.choice(UINTS)
                srcval = TYPES[src]["lit"](self.rng)
            return "%s.wrap_from(%s)" % (tyname, TYPES[src]["fold"](srcval))
        if kind == "sint":
            if self.trapping and self.rng.random() < 0.5:
                return self.gen_checked(tyname, ty["width"], signed=True)
            # signed ints forbid bitwise/shift. A signed wrapping.add must anchor its type with a
            # live variable: the emitter routes a typed signed add through the unsigned domain
            # (UB-free), but cannot type two bare literals, so anchor or fall back to a literal.
            live = self.env.get(tyname, [])
            if not live:
                return self.gen_leaf(tyname)
            return "wrapping.add(%s, %s)" % (self.rng.choice(live), self.gen_leaf(tyname))
        raise AssertionError(kind)

    # A *checked* integer op (may trap on overflow / divide-by-zero / underflow). Signed ints have
    # no bitwise/shift but allow checked negation (`-INT_MIN` traps); unsigned allow `<<`.
    def gen_checked(self, tyname, width, signed):
        a, b = self.anchored_pair(tyname)
        ops = ["+", "-", "*", "/", "neg"] if signed else ["+", "-", "*", "/", "<<"]
        op = self.rng.choice(ops)
        if op == "<<":
            return "(%s << %d)" % (a, self.rng.randrange(0, width))
        if op == "neg":
            return "(-%s)" % a
        return "(%s %s %s)" % (a, op, b)

    def gen_bool(self, d=0):
        if d < 2 and self.rng.random() < 0.25:  # short-circuit nesting (C8)
            op = self.rng.choice(("&&", "||"))
            return "(%s %s %s)" % (self.gen_bool(d + 1), op, self.gen_bool(d + 1))
        # A domain comparison (C3): sat supports ordering+equality, wrap equality only; both
        # operands must be live vars of the same domain (a domain value can't compare to a plain
        # int literal), so it needs two such vars in scope.
        dom = [t for t in SATS + WRAPS if len(self.env.get(t, [])) >= 2]
        if dom and d < 2 and self.rng.random() < 0.3:
            ty = self.rng.choice(dom)
            pool = self.env[ty]
            a, b = self.rng.choice(pool), self.rng.choice(pool)
            cmps = ("==", "!=") if TYPES[ty]["kind"] == "wrap" else ("<", "<=", ">", ">=", "==", "!=")
            return "(%s %s %s)" % (a, self.rng.choice(cmps), b)
        typed = [t for t in VALUE_TYPES if self.env.get(t)]
        if not typed:
            return self.rng.choice(("true", "false"))
        if d < 2 and self.rng.random() < 0.2:
            return "(!%s)" % self.gen_bool(d + 1)
        ty = self.rng.choice(typed)
        var = self.rng.choice(self.env[ty])  # one operand is a live variable so both backends
        # The other operand is another variable or a literal — both have an inferable type from
        # `var`. (A complex checked-arithmetic operand currently defeats the C emitter's
        # comparison type inference — a separate emit-c gap this framework surfaced.)
        pool = self.env[ty]
        if len(pool) > 1 and self.rng.random() < 0.5:
            other = self.rng.choice(pool)
        else:
            other = TYPES[ty]["lit"](self.rng)
        cmp = self.rng.choice(("<", "<=", ">", ">=", "==", "!="))
        if self.rng.random() < 0.5:
            return "(%s %s %s)" % (var, cmp, other)
        return "(%s %s %s)" % (other, cmp, var)

    def _u64_expr(self):
        # A deterministic u64 value: a live int var folded to u64, else a literal.
        ints = [t for t in INTS if self.env.get(t)]
        if ints:
            ty = self.rng.choice(ints)
            return TYPES[ty]["fold"](self.rng.choice(self.env[ty]))
        return str(self.rng.randrange(0, 1000))

    def _int_array_vars(self):
        # (live array var, element type) for arrays whose element is a plain int — iterable with
        # a usable scalar binding.
        out = []
        for tyname, (elem, _length) in self.arrays.items():
            if elem in INTS:
                for name in self.env.get(tyname, []):
                    out.append((name, elem))
        return out

    # ---- statements ----
    def stmt(self, out, indent):
        pad = "    " * indent
        can_decl = self.depth == 0
        r = self.rng.random()
        if can_decl and r < 0.45:
            ty = self.rng.choice(self.local_types())
            name = "v%d" % self.nvars
            self.nvars += 1
            out.append("%svar %s: %s = %s;" % (pad, name, ty, self.gen_value(ty)))
            self.env.setdefault(self.aliases.get(ty, ty), []).append(name)
        elif r < 0.65 and (self._has_any_var() or self._has_aggregate_var()):
            # Either a whole-scalar assignment or an in-place store into an aggregate leaf
            # (`s.f = …`, `a[i] = …`, `s.f[i][j] = …`) — the latter exercises lvalue/field-store
            # lowering that whole-variable assignment never reaches.
            if self._has_aggregate_var() and (not self._has_any_var() or self.rng.random() < 0.4):
                path, t = self._aggregate_lvalue()
                out.append("%s%s = %s;" % (pad, path, self.gen_value(t)))
            else:
                ty, name = self._pick_var()
                rhs = self.gen_value(ty)
                if rhs == name:
                    rhs = self.gen_value(ty, 1)
                out.append("%s%s = %s;" % (pad, name, rhs))
        elif r < 0.80 and self.depth < 3:
            out.append("%sif %s {" % (pad, self.gen_bool()))
            self.block(out, indent + 1)
            out.append("%s} else {" % pad)
            self.block(out, indent + 1)
            out.append("%s}" % pad)
        elif r < 0.84 and self.depth < 3 and self._live_enum_vars():
            # A `switch` in statement position with side-effecting arms — the construct that most
            # multiplies MIR block count (every arm is its own block), exercising control-flow
            # lowering the read-only digest switch never reaches. All-but-last variant explicit,
            # `_` wildcard last (valid for both closed and open enums).
            var, variants = self.rng.choice(self._live_enum_vars())
            out.append("%sswitch %s {" % (pad, var))
            for v in variants[:-1]:
                out.append("%s    .%s => {" % (pad, v))
                self.block(out, indent + 2)
                out.append("%s    }" % pad)
            out.append("%s    _ => {" % pad)
            self.block(out, indent + 2)
            out.append("%s    }" % pad)
            out.append("%s}" % pad)
        elif r < 0.88:
            # B3: a conditional early return (the harness otherwise has a single trailing return).
            out.append("%sif %s { return %s; }" % (pad, self.gen_bool(), self._u64_expr()))
        elif r < 0.93 and self.depth < 3 and self._int_array_vars():
            # B1: a `for x in <array>` loop with the element bound in the body.
            arr, elem = self.rng.choice(self._int_array_vars())
            x = "x%d" % self.nvars
            self.nvars += 1
            out.append("%sfor %s in %s {" % (pad, x, arr))
            self.env.setdefault(elem, []).append(x)
            self.immutable.add(x)  # the loop element is read-only
            self.block(out, indent + 1)
            self.env[elem].remove(x)
            self.immutable.discard(x)
            out.append("%s}" % pad)
        else:
            n = self.rng.randrange(1, 5)
            i = "j%d" % self.nvars
            self.nvars += 1
            out.append("%svar %s: u64 = 0;" % (pad, i))
            out.append("%swhile %s < %d {" % (pad, i, n))
            # Increment first so a `continue` can never skip it (no infinite loop). B2:
            # optionally break/continue (guarded), then the body.
            out.append("%s    %s = %s + 1;" % (pad, i, i))
            if self.rng.random() < 0.3:
                out.append("%s    if %s { break; }" % (pad, self.gen_bool()))
            if self.rng.random() < 0.3:
                out.append("%s    if %s { continue; }" % (pad, self.gen_bool()))
            if self._has_any_var():
                ty, name = self._pick_var()
                out.append("%s    %s = %s;" % (pad, name, self.gen_value(ty, 1)))
            out.append("%s}" % pad)

    def block(self, out, indent):
        self.depth += 1
        for _ in range(self.rng.randrange(1, 4)):
            self.stmt(out, indent)
        self.depth -= 1

    def _mutable(self, ty):
        return [v for v in self.env.get(ty, []) if v not in self.immutable]

    def _has_any_var(self):
        return any(self._mutable(t) for t in VALUE_TYPES)

    def _pick_var(self):
        ty = self.rng.choice([t for t in VALUE_TYPES if self._mutable(t)])
        return ty, self.rng.choice(self._mutable(ty))

    def _aggregate_types(self):
        return list(self.structs) + list(self.arrays)

    def _has_aggregate_var(self):
        return any(self.env.get(t) for t in self._aggregate_types())

    def _aggregate_lvalue(self):
        # Walk a live struct/array var down to a scalar (int / open-enum) leaf, returning
        # (lvalue path, leaf type). The struct/array nesting is a finite DAG, so the walk always
        # terminates at a leaf.
        cands = [(name, t) for t in self._aggregate_types() for name in self.env.get(t, [])]
        path, tyname = self.rng.choice(cands)
        while tyname in self.structs or tyname in self.arrays:
            if tyname in self.structs:
                f, tyname = self.rng.choice(self.structs[tyname])
                path = "%s.%s" % (path, f)
            else:
                elem, length = self.arrays[tyname]
                path, tyname = "%s[%d]" % (path, self.rng.randrange(length)), elem
        return path, tyname

    def _live_enum_vars(self):
        # (var name, variants) for every live closed- or open-enum variable, for switch subjects.
        out = []
        for table in (self.enums, self.open_enums):
            for ename, variants in table.items():
                for name in self.env.get(ename, []):
                    out.append((name, variants))
        return out

    def fold_type(self, access, tyname, terms):
        # Fold a value of any aggregate/scalar type into the digest, recursing through nested
        # structs and arrays down to scalar leaves.
        if tyname in self.structs:
            for f, t in self.structs[tyname]:
                self.fold_type("%s.%s" % (access, f), t, terms)
        elif tyname in self.arrays:
            elem, length = self.arrays[tyname]
            for k in range(length):
                self.fold_type("%s[%d]" % (access, k), elem, terms)
        elif tyname in self.tuples:  # G14: fold each element via `.i` access
            for i, et in enumerate(self.tuples[tyname]):
                self.fold_type("%s.%d" % (access, i), et, terms)
        elif tyname in self.open_enums:  # an open enum folds inline via `.raw()`
            terms.append("(%s.raw() as u64)" % access)
        else:
            terms.append(TYPES[tyname]["fold"](access))

    def gen_functions(self, decls):
        # A DAG of helper functions: each takes scalar params and returns a scalar, may call
        # *earlier* functions (no recursion → terminates), and harness then calls them. Exercises
        # parameter passing / calling convention / by-value ABI — the single-function shape missed.
        callable_types = [t for t in (INTS + FLOATS) if t not in GEN_SKIP]
        for i in range(self.rng.randrange(2, 5)):
            name = "fn%d" % i
            params = [("p%d" % j, self.rng.choice(callable_types)) for j in range(self.rng.randrange(1, 4))]
            ret = self.rng.choice(callable_types)
            saved_env, saved_depth = self.env, self.depth
            self.env, self.depth = {}, 1  # params visible; depth 1 suppresses new top-level decls
            for pn, pt in params:
                self.env.setdefault(pt, []).append(pn)
            ret_expr = self.gen_value(ret)
            self.env, self.depth = saved_env, saved_depth
            params_src = ", ".join("%s: %s" % (pn, pt) for pn, pt in params)
            decls.append("fn %s(%s) -> %s {\n    return %s;\n}" % (name, params_src, ret, ret_expr))
            self.functions.append((name, params, ret))

    def gen_result_functions(self, decls):
        # A1: `Result<T, u32>` helper functions returning ok(T)/err(u32) on a deterministic
        # condition; a later one may `?`-propagate an earlier helper's error (the shared error
        # type u32 makes propagation type-check). The harness folds them via switch.
        err_ty = "u32"
        for i in range(self.rng.randrange(0, 3)):
            name = "r%d" % i
            pt = self.rng.choice(INTS)
            ot = self.rng.choice(INTS)
            saved_env, saved_depth = self.env, self.depth
            self.env, self.depth = {pt: ["p"]}, 1
            lines = []
            if self.result_fns and self.rng.random() < 0.5:  # `?` propagation chain
                cname, cpt, cot = self.rng.choice(self.result_fns)
                lines.append("    let cv: %s = %s(%s)?;" % (cot, cname, self.gen_leaf(cpt)))
                self.env.setdefault(cot, []).append("cv")
            lines.append("    if %s { return err(%s); }" % (self.gen_bool(), TYPES[err_ty]["lit"](self.rng)))
            lines.append("    return ok(%s);" % self.gen_value(ot))
            self.env, self.depth = saved_env, saved_depth
            decls.append("fn %s(p: %s) -> Result<%s, %s> {\n%s\n}" % (name, pt, ot, err_ty, "\n".join(lines)))
            self.result_fns.append((name, pt, ot))

    def gen_aggregate_abi(self, decls):
        # G3: helper functions that pass/return aggregates by value (struct/array ABI), plus a
        # struct-field extractor (aggregate param -> scalar return). Called and folded by harness.
        aggs = list(self.structs) + list(self.arrays)
        for _ in range(self.rng.randrange(0, 2)):
            if not aggs:
                break
            t = self.rng.choice(aggs)
            name = "aggid%d" % self.nvars
            self.nvars += 1
            decls.append("fn %s(p: %s) -> %s {\n    return p;\n}" % (name, t, t))
            self.agg_fns.append((name, t, t))
        int_fields = [(s, f, ft) for s, fields in self.structs.items() for f, ft in fields if ft in INTS]
        if int_fields and self.rng.random() < 0.6:
            s, f, ft = self.rng.choice(int_fields)
            name = "aggget%d" % self.nvars
            self.nvars += 1
            decls.append("fn %s(p: %s) -> %s {\n    return p.%s;\n}" % (name, s, ft, f))
            self.agg_fns.append((name, s, ft))

    def gen_kernel_decls(self, decls):
        # G2 (kernel/driver surface): packed-bits register types — a struct of bool fields over an
        # integer storage word (no C bitfields; byte/bit storage lowering). Runnable and
        # deterministic, so the differential/sanitize/optlevel oracles all apply.
        for i in range(self.rng.randrange(0, 2)):
            store_w = self.rng.choice((8, 16, 32))
            nfields = self.rng.randrange(1, min(store_w, 5) + 1)
            fields = ["pf%d" % j for j in range(nfields)]
            name = "PB%d" % i
            self.packed[name] = (fields, store_w)
            decls.append("packed bits %s: u%d { %s }" % (name, store_w, ", ".join("%s: bool" % f for f in fields)))

    def gen_offset_overlay_decls(self, decls):
        # G15 (kernel/driver surface): the backend-divergent LAYOUT constructs where a latent
        # `comptimeStructLayout` (src/layout.zig) C/LLVM divergence hid.
        #
        # (a) Explicit `@offset(N)` MMIO register structs. MMIO structs are NOT host-runnable
        #     (volatile loads to fixed addresses), so the layout is observed PURELY through
        #     comptime folding the oracle can see: `sizeof(S)` (computed BY comptimeStructLayout)
        #     and `field_offset(S, .f)`. Offsets are monotonically non-decreasing (the language
        #     rejects overlap), but we deliberately stress the guard's boundary: tightly-packed
        #     adjacent fields (offset == running offset) and large gaps (reserved padding), with
        #     mixed widths so alignment-forwarding participates. Each observer is folded into the
        #     digest via a comptime helper fn, so both backends must agree on the layout.
        REGW = (8, 16, 32)
        for i in range(self.rng.randrange(0, 2)):
            name = "OFF%d" % i
            nf = self.rng.randrange(2, 5)
            fields = []
            off = 0
            for j in range(nf):
                w = self.rng.choice(REGW)
                sz = w // 8
                # Mode is irrelevant to layout; vary it for surface coverage.
                mode = self.rng.choice((".read", ".write", ".read_write"))
                if j == 0:
                    cur = 0
                else:
                    # tight (adjacent, offset == running) OR a gap; both keep monotonic order.
                    if self.rng.random() < 0.5:
                        cur = off                       # tightly packed: offset == running offset
                    else:
                        cur = off + self.rng.choice((sz, 8, 16, 64, 0x100))  # large/odd gap
                # round the chosen offset up so the field's natural alignment is respected
                if cur % sz != 0:
                    cur += sz - (cur % sz)
                fields.append(("of%d" % j, w, cur, mode))
                off = cur + sz
            self.offset_structs[name] = fields
            # V3.3 metamorphic (explicit @offset layout): an `@offset` mmio struct's `sizeof` and
            # field offsets are pinned by the offsets, not by source order — BUT the C backend
            # *requires* the field declarations to appear in ascending-offset order (`emit-c`
            # rejects a descending decl with UnsupportedCEmission, "offsets must increase"). A
            # reversed declaration order is therefore NOT a compilable variant; reversing it here
            # made the variant fail to compile, which the metamorphic oracle silently swallowed,
            # giving this transform ~zero coverage. We keep the field declaration order identical
            # in base and variant. The metamorphic difference is still exercised (compilably) by
            # running the digest body in a called helper plus the reversed final fold (see
            # program()), which re-exercises whole-program extraction / call-ABI / the layout
            # observers without ever emitting a struct the backend rejects.
            decl_fields = fields
            decls.append("extern mmio struct %s {\n%s\n}" % (
                name,
                "\n".join("    %s: Reg<u%d, %s> @offset(%d)," % (f, w, m, o) for f, w, o, m in decl_fields)))
            # Comptime observers folded into a u64 the digest reads. sizeof of the whole struct
            # plus the offset-of one chosen field (the last, which carries the accumulated layout).
            tgt = fields[-1][0]
            decls.append(
                "fn offobs_%s() -> u64 {\n"
                "    return ((sizeof(%s) as u64) ^ ((field_offset(%s, .%s) as u64) << 1));\n}"
                % (name, name, name, tgt))

        # (b) Overlay unions (byte-aliasing storage). These ARE host-runnable: construct, write the
        #     scalar member, read the aliased members back into the digest. Both backends must agree
        #     on the storage size and member aliasing.
        #
        #     READ FORMS (all now lowered on both backends — the prior limitation is removed): the
        #     overlay-member-read lowering was generalized so a bare read (`w.u`, `w.bytes[i]`,
        #     `w.halves[i]`) lowers wherever it appears — direct return AND any expression position
        #     (cast operand, initializer, arithmetic subexpression) — and a *non-byte* array view
        #     (`[N/2]u16`) now lowers for both read and write. We therefore read members DIRECTLY in
        #     expression position (no accessor-fn indirection) and exercise the non-byte u16 view,
        #     including a write-then-readback, so the generated surface pins the fixed path.
        HALF = {32: 2, 64: 4}
        for i in range(self.rng.randrange(0, 2)):
            name = "OV%d" % i
            w = self.rng.choice((32, 64))
            nbytes = w // 8
            nhalves = HALF[w]
            members = [("u", "u%d" % w, False),
                       ("bytes", "[%d]u8" % nbytes, True),
                       ("halves", "[%d]u16" % nhalves, True)]
            self.overlays[name] = (w, members)
            decls.append("overlay union %s {\n%s\n}" % (
                name, "\n".join("    %s: %s," % (m, t) for m, t, _a in members)))
            if self.metamorph:
                # V3.3 (overlay read in return position): a by-value helper that reads the `halves`
                # view member in *return* position. The metamorph body calls this instead of the
                # base's inline expression-position read; both forms must lower to the same value
                # (the overlay-read bug class was exactly a position-dependent member-read lowering).
                decls.append("fn ovhalf_%s(o: %s, i: usize) -> u64 {\n"
                             "    return (o.halves[i] as u64);\n}" % (name, name))

    def gen_offset_overlay_body(self, out):
        # G15: fold the @offset struct layouts (comptime) and the overlay-union reads (runtime).
        # V3.3: in metamorph mode each observation below is emitted in a semantics-preserving but
        # *structurally different* form so the digest is invariant under the memory-op transforms.
        for name, ofields in self.offset_structs.items():
            ov = "offv%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: u64 = offobs_%s();" % (ov, name))
            self._kernel_terms.append(ov)
            # V3.3 (sizeof/offset-of identities): a layout tautology that must hold in BOTH the base
            # and the variant — the last field's offset plus its width-in-bytes never exceeds the
            # struct's sizeof, i.e. `field_offset(S,.last) + sizeof(field) <= sizeof(S)`. We fold the
            # boolean (always 1) so any layout miscompile that broke the inequality flips the digest.
            lastf, lastw, _lo, _m = ofields[-1]
            idn = "offid%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: u64 = 0;" % idn)
            out.append("    if ((field_offset(%s, .%s) as u64) + %d) <= (sizeof(%s) as u64) "
                       "{ %s = 1; }" % (name, lastf, lastw // 8, name, idn))
            self._kernel_terms.append(idn)
        HALF = {32: 2, 64: 4}
        for name, (w, members) in self.overlays.items():
            nbytes = w // 8
            nhalves = HALF[w]
            vn = "ovv%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: %s = uninit;" % (vn, name))
            out.append("    %s.u = %d;" % (vn, self.rng.randrange(1, 1 << min(w, 32))))
            acc = "ovo%d" % self.nvars
            self.nvars += 1
            if not self.metamorph:
                # Base form: read the scalar member DIRECTLY in expression position (cast operand
                # inside an initializer / xor) — the generalized overlay-read lowering.
                out.append("    var %s: u64 = (%s.u as u64);" % (acc, vn))
            else:
                # V3.3 (overlay read equivalence): instead of reading the scalar `.u` directly,
                # recompose it from its byte-view — `u == sum(bytes[k] << 8*k)` for a fully-written
                # overlay. AND we read it in return-position (a helper) rather than expression
                # position. Both must agree with the base's direct expression-position read; a
                # mismatch is exactly the overlay-read bug class (member read lowering depending on
                # syntactic position / byte-vs-scalar view).
                rec = "ovrec%d" % self.nvars
                self.nvars += 1
                out.append("    var %s: u64 = 0;" % rec)
                for k in range(nbytes):
                    out.append("    %s = (%s | ((%s.bytes[%d] as u64) << %d));"
                               % (rec, rec, vn, k, k * 8))
                out.append("    var %s: u64 = %s;" % (acc, rec))
            for k in range(nbytes):
                out.append("    %s = (%s ^ ((%s.bytes[%d] as u64) << %d));"
                           % (acc, acc, vn, k, (k % 8) * 8))
            # Non-byte (`[N]u16`) view read in expression position.
            for k in range(nhalves):
                out.append("    %s = (%s ^ ((%s.halves[%d] as u64) << %d));"
                           % (acc, acc, vn, k, (k % 4) * 16))
            # Non-byte view write, then read back: overwrite one half and re-observe it.
            hidx = self.rng.randrange(0, nhalves)
            hval = self.rng.randrange(1, 1 << 16)
            out.append("    %s.halves[%d] = %d;" % (vn, hidx, hval))
            if not self.metamorph:
                out.append("    %s = (%s ^ ((%s.halves[%d] as u64) << 3));" % (acc, acc, vn, hidx))
            else:
                # V3.3 (overlay read equivalence, position swap): re-observe the just-written half
                # through a helper that takes the overlay by-pointer and returns the member in
                # return position — equivalent to the base's inline expression-position read.
                hv = "ovh%d" % self.nvars
                self.nvars += 1
                # Pass the (already-written) overlay BY VALUE; the helper reads .halves[i] in
                # return position. Return-position vs expression-position member read must agree.
                out.append("    var %s: u64 = ovhalf_%s(%s, %d);" % (hv, name, vn, hidx))
                out.append("    %s = (%s ^ (%s << 3));" % (acc, acc, hv))
            out.append("    %s = (%s ^ ((sizeof(%s) as u64) << 4));" % (acc, acc, name))
            self._kernel_terms.append(acc)

    def gen_kernel_body(self, out):
        # Atomics (G2): single-threaded `atomic<uN>` with init/store/fetch_add/fetch_sub/load.
        # Single-threaded so fully deterministic; the loaded values fold into the digest. Orderings
        # respect the spec (load: relaxed/acquire/seq_cst; store: relaxed/release/seq_cst; RMW:
        # acq_rel/seq_cst/relaxed). Deltas are kept small so fetch_add/sub stay finite.
        for _ in range(self.rng.randrange(0, 2)):
            w = self.rng.choice((32, 64))
            an = "at%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: atomic<u%d> = atomic.init(%d);" % (an, w, self.rng.randrange(0, 1000)))
            if self.rng.random() < 0.6:
                out.append("    %s.store(%d, .%s);" % (an, self.rng.randrange(0, 1000),
                                                       self.rng.choice(("relaxed", "release", "seq_cst"))))
            if self.rng.random() < 0.7:
                op = self.rng.choice(("fetch_add", "fetch_sub"))
                ov = "ato%d" % self.nvars
                self.nvars += 1
                out.append("    var %s: u%d = %s.%s(%d, .%s);" % (ov, w, an, op, self.rng.randrange(0, 100),
                                                                  self.rng.choice(("acq_rel", "seq_cst", "relaxed"))))
                self.env.setdefault("u%d" % w, []).append(ov)
            lv = "atl%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: u%d = %s.load(.%s);" % (lv, w, an, self.rng.choice(("relaxed", "acquire", "seq_cst"))))
            self.env.setdefault("u%d" % w, []).append(lv)
        # Packed-bits register vars: construct, optionally store a field, read fields into the digest.
        for pname, (fields, _w) in self.packed.items():
            if self.rng.random() < 0.5:
                continue
            vn = "pbv%d" % self.nvars
            self.nvars += 1
            ctor = ", ".join(".%s = %s" % (f, self.rng.choice(("true", "false"))) for f in fields)
            out.append("    var %s: %s = .{ %s };" % (vn, pname, ctor))
            if self.rng.random() < 0.5:
                f = self.rng.choice(fields)
                out.append("    %s.%s = %s;" % (vn, f, self.rng.choice(("true", "false"))))
            out.append("    var pbo_%s: u64 = 0;" % vn)
            for k, f in enumerate(fields):
                out.append("    if %s.%s { pbo_%s = (pbo_%s ^ %d); }" % (vn, f, vn, vn, 1 << k))
            self._kernel_terms.append("pbo_%s" % vn)

    def gen_byteview_body(self, decls, out, terms):
        # G12 / G8 (slices): a byte-view slice over a live *integer array* — contiguous and
        # fully initialized, so its byte representation has no padding/unspecified bytes and is
        # identical across backends (sound to observe). mem.as_bytes(&v) is the only
        # slice-construction form that lowers through both backends. Exercised two ways: a checked
        # reduction (reduce.sum_checked — the "hot checked reduction" path) and bounds-checked
        # slice indexing with `.len`. The reduction goes through a wrapper fn because switching
        # directly on the builtin call expression fails to lower.
        cands = [n for ty, (elem, _l) in self.arrays.items() if elem in INTS
                 for n in self.env.get(ty, [])]
        if not cands:
            return
        decls.append("fn bvsum(xs: []const u8) -> Result<u8, Overflow> {\n"
                     "    return reduce.sum_checked<u8>(xs);\n}")
        vn = self.rng.choice(cands)
        bv = "bv%d" % self.nvars; self.nvars += 1
        out.append("    let %s: []const u8 = mem.as_bytes(&%s);" % (bv, vn))
        rdo = "rdo%d" % self.nvars; self.nvars += 1
        out.append("    var %s: u64 = 0;" % rdo)
        out.append("    switch bvsum(%s) {" % bv)
        out.append("        ok(rv) => { %s = (rv as u64); }" % rdo)
        out.append("        err(eo) => { %s = 1; }" % rdo)
        out.append("    }")
        terms.append(rdo)
        it = "bvi%d" % self.nvars; self.nvars += 1
        sm = "bvs%d" % self.nvars; self.nvars += 1
        out.append("    var %s: u64 = 0;" % sm)
        out.append("    var %s: usize = 0;" % it)
        if not self.metamorph:
            out.append("    while %s < %s.len { %s = (%s ^ (%s[%s] as u64)); %s = %s + 1; }"
                       % (it, bv, sm, sm, bv, it, it, it))
        else:
            # V3.3 (slice/index equivalence on the byte-view): same elements, observed via a
            # full-range slice-of-slice and an equivalent index expression `(i + 1) - 1`. Must fold
            # to the identical sum as the base's direct `bv[i]` walk.
            #
            # NOTE: the slice HI bound must be a usize-typed *binding*, not the inline `bv.len`
            # field access. `bv[0..bv.len]` (inline `.len`) is rejected by the MIR verifier with
            # E_INDEX_NOT_USIZE — a real front-end wart where the `.len` field access in slice-hi
            # position is not typed as usize — so it made this variant fail to compile and the
            # oracle silently swallowed it. Binding `let bvn: usize = bv.len;` first and slicing
            # `bv[0..bvn]` is the equivalent, compilable form.
            bvn = "bvn%d" % self.nvars; self.nvars += 1
            bv2 = "bv2_%d" % self.nvars; self.nvars += 1
            out.append("    let %s: usize = %s.len;" % (bvn, bv))
            out.append("    let %s: []const u8 = %s[0..%s];" % (bv2, bv, bvn))
            out.append("    while %s < %s.len { %s = (%s ^ (%s[((%s + 1) - 1)] as u64)); %s = %s + 1; }"
                       % (it, bv2, sm, sm, bv2, it, it, it))
        terms.append(sm)

    def gen_unions(self, decls):
        # G7: safe tagged unions with payloads. Each case constructor (`uNcK(v)` / `uNe()`) is a
        # global name, so case names are made globally unique. Payloads are int-typed so every
        # switch arm folds to u64 cleanly. A per-union fold helper switches the value (payload arms
        # bind the value, the optional no-payload arm uses the dotted `.uNe`). Verified:
        # construct + pass-by-value + switch + fold lowers and agrees across both backends.
        for i in range(self.rng.randrange(0, 2)):
            name = "U%d" % i
            cases = [("u%dc%d" % (i, j), self.rng.choice(INTS))
                     for j in range(self.rng.randrange(2, 4))]
            empty = "u%de" % i if self.rng.random() < 0.5 else None
            lines = ["    %s: %s," % (cn, pt) for cn, pt in cases]
            if empty:
                lines.append("    %s," % empty)
            decls.append("union %s {\n%s\n}" % (name, "\n".join(lines)))
            arms = ["        %s(b) => { return %s; }" % (cn, TYPES[pt]["fold"]("b")) for cn, pt in cases]
            if empty:
                arms.append("        .%s => { return 7; }" % empty)
            decls.append("fn ufold_%s(s: %s) -> u64 {\n    switch s {\n%s\n    }\n}"
                         % (name, name, "\n".join(arms)))
            self.unions[name] = (cases, empty)

    def gen_union_body(self, out, terms):
        # G7: construct union values across the cases and fold each via its switch helper.
        for uname, (cases, empty) in self.unions.items():
            opts = list(cases) + ([(empty, None)] if empty else [])
            for _ in range(self.rng.randrange(1, 3)):
                cn, pt = self.rng.choice(opts)
                ctor = "%s()" % cn if pt is None else "%s(%s)" % (cn, self.gen_leaf(pt))
                uv = "uv%d" % self.nvars; self.nvars += 1
                out.append("    var %s: %s = %s;" % (uv, uname, ctor))
                fv = "ufv%d" % self.nvars; self.nvars += 1
                out.append("    var %s: u64 = ufold_%s(%s);" % (fv, uname, uv))
                terms.append(fv)

    def gen_conv_body(self, out, terms):
        # G13: cross-domain / representation conversions (C4). Exercises the explicit conversion
        # vocabulary the literal-initialized domain vars never hit: plain -> wrap (`W.from_mod`),
        # wrap -> plain (`.residue()`), and exact unsigned widening (`u64.from`). `from_mod` needs a
        # named type, so a `type Wconv = wrap<uN>;` alias is declared (see program()). All trap-free
        # and verified to agree across both backends + the reference interpreter.
        if self._conv_w is None:
            return
        cw = self._conv_w
        cp = "cp%d" % self.nvars; self.nvars += 1
        out.append("    var %s: %s = %s;" % (cp, cw, TYPES[cw]["lit"](self.rng)))
        wd = "wd%d" % self.nvars; self.nvars += 1
        out.append("    var %s: Wconv = Wconv.from_mod(%s);" % (wd, cp))
        rd = "rd%d" % self.nvars; self.nvars += 1
        out.append("    var %s: %s = %s.residue();" % (rd, cw, wd))
        terms.append(TYPES[cw]["fold"](rd))
        wide = "wide%d" % self.nvars; self.nvars += 1
        out.append("    var %s: u64 = u64.from(%s);" % (wide, cp))
        terms.append(wide)

    def gen_exprswitch_decls(self, decls):
        # G11: expression-`switch` in *return* position — `fn eswf_E(e: E) -> u64 { return switch e
        # { .V => k, … }; }`, exhaustive over the closed enum's variants.
        for name, variants in self.enums.items():
            arms = ", ".join(".%s => %d" % (v, (k + 1) * 7) for k, v in enumerate(variants))
            decls.append("fn eswf_%s(e: %s) -> u64 {\n    return switch e { %s };\n}" % (name, name, arms))

    def gen_exprswitch_body(self, out, terms):
        # G11: exercise both supported positions on each live closed-enum var — call the
        # return-form helper, and an initializer-form `var x: u64 = switch e { … }`.
        for name, variants in self.enums.items():
            for ev in self.env.get(name, []):
                cv = "eswc%d" % self.nvars; self.nvars += 1
                out.append("    var %s: u64 = eswf_%s(%s);" % (cv, name, ev))
                terms.append(cv)
                iv = "eswi%d" % self.nvars; self.nvars += 1
                arms = ", ".join(".%s => %d" % (v, (k + 1) * 13) for k, v in enumerate(variants))
                out.append("    var %s: u64 = switch %s { %s };" % (iv, ev, arms))
                terms.append(iv)

    def gen_slice_body(self, decls, out, terms):
        # G8 (full slices): a `[]mut T` view over a live integer array for a *general* element type
        # T (not just the byte-view u8 of G12). Array-slicing yields a mutable view because the
        # array is mutable (mut->const would need an explicit conversion), so we keep it `[]mut`.
        # Construction `a[lo..hi]`, bounds-checked indexing `s[i]`, `.len`, and passing `[]mut T` to
        # a helper fn all lower through both backends. The array's values are final at this point
        # (emitted after all stmts) so the view is a deterministic, backend-stable observable.
        cands = [(ty, elem, length) for ty, (elem, length) in self.arrays.items()
                 if elem in INTS and self.env.get(ty)]
        if not cands:
            return
        ty, elem, length = self.rng.choice(cands)
        vn = self.rng.choice(self.env[ty])
        lo = self.rng.randrange(0, max(1, length - 1))
        hi = self.rng.randrange(lo + 1, length + 1)
        sl = "sl%d" % self.nvars; self.nvars += 1
        out.append("    let %s: []mut %s = %s[%d..%d];" % (sl, elem, vn, lo, hi))
        it = "sli%d" % self.nvars; self.nvars += 1
        sm = "sls%d" % self.nvars; self.nvars += 1
        out.append("    var %s: u64 = 0;" % sm)
        out.append("    var %s: usize = 0;" % it)
        if not self.metamorph:
            out.append("    while %s < %s.len { %s = (%s ^ (%s[%s] as u64)); %s = %s + 1; }"
                       % (it, sl, sm, sm, sl, it, it, it))
        else:
            # V3.3 (slice/index equivalence): observe the SAME elements via a slice-of-slice over
            # the full sub-range (`sl[0..sln]`) rather than `sl` directly, AND through an
            # equivalent index expression (`(i + 0)`). Re-slicing the whole view and reindexing
            # must yield the identical element sequence — a divergence is a slice-base/length or
            # index-lowering miscompile.
            #
            # As with the byte-view re-slice above, the slice HI bound must be a usize-typed
            # *binding* (`let sln: usize = sl.len;`), not the inline `sl.len` field access, which
            # `emit-c` rejects with E_INDEX_NOT_USIZE.
            sln = "sln%d" % self.nvars; self.nvars += 1
            s2 = "sl2_%d" % self.nvars; self.nvars += 1
            out.append("    let %s: usize = %s.len;" % (sln, sl))
            out.append("    let %s: []mut %s = %s[0..%s];" % (s2, elem, sl, sln))
            out.append("    while %s < %s.len { %s = (%s ^ (%s[(%s + 0)] as u64)); %s = %s + 1; }"
                       % (it, s2, sm, sm, s2, it, it, it))
        terms.append(sm)
        if elem not in self._slice_helpers:  # one `[]mut T` sum helper per element type (param ABI)
            self._slice_helpers.add(elem)
            decls.append("fn slcsum_%s(xs: []mut %s) -> u64 {\n"
                         "    var a: u64 = 0;\n    var i: usize = 0;\n"
                         "    while i < xs.len { a = (a ^ (xs[i] as u64)); i = i + 1; }\n"
                         "    return a;\n}" % (elem, elem))
        cv = "slc%d" % self.nvars; self.nvars += 1
        out.append("    var %s: u64 = slcsum_%s(%s);" % (cv, elem, sl))
        terms.append(cv)

    def program(self, metamorph=False):
        # Declare a couple of user types the generator can construct, read, and match.
        self.metamorph = metamorph  # V3.3: gates the memory-op semantics-preserving transforms
        decls = []
        self._kernel_terms = []
        int_arrays = []
        for _ in range(self.rng.randrange(1, 3)):  # array types (int elements; structural, no decl)
            elem = self.rng.choice(INTS)
            length = self.rng.randrange(2, 6)
            key = "[%d]%s" % (length, elem)
            self.arrays[key] = (elem, length)
            int_arrays.append(key)
        for _ in range(self.rng.randrange(0, 2)):  # nested arrays `[N][M]T` over an int-array element
            if int_arrays:
                inner = self.rng.choice(int_arrays)
                length = self.rng.randrange(2, 4)
                self.arrays["[%d]%s" % (length, inner)] = (inner, length)
        for i in range(self.rng.randrange(1, 3)):  # open enums (raw()-foldable; nest in aggregates)
            variants = ["W%d" % j for j in range(self.rng.randrange(2, 5))]
            name = "O%d" % i
            self.open_enums[name] = variants
            decls.append("open enum %s: u8 { %s }" % (name, ", ".join(variants)))
        for i in range(self.rng.randrange(1, 4)):
            name = "S%d" % i
            # fields are scalars, arrays, open enums, or *earlier* structs (a DAG → nesting terminates)
            ftypes = INTS + list(self.arrays) + list(self.open_enums) + list(self.structs)
            fields = [("f%d" % j, self.rng.choice(ftypes)) for j in range(self.rng.randrange(1, 4))]
            self.structs[name] = fields
            decls.append("struct %s { %s }" % (name, ", ".join("%s: %s" % (f, t) for f, t in fields)))
        for _ in range(self.rng.randrange(0, 2)):  # arrays of aggregates (declared after structs exist)
            elems = list(self.structs) + list(self.open_enums)
            if elems:
                elem = self.rng.choice(elems)
                length = self.rng.randrange(2, 4)
                self.arrays["[%d]%s" % (length, elem)] = (elem, length)
        for _ in range(self.rng.randrange(0, 2)):  # G14: tuples, incl. tuples-of-aggregates
            pool = INTS + list(self.structs) + list(self.arrays) + list(self.open_enums)
            elems = [self.rng.choice(pool) for _ in range(self.rng.randrange(2, 4))]
            self.tuples["(%s)" % ", ".join(elems)] = elems
        for i in range(self.rng.randrange(1, 3)):
            variants = ["V%d" % j for j in range(self.rng.randrange(2, 5))]
            name = "E%d" % i
            self.enums[name] = variants
            if self.rng.random() < 0.4:  # A13: explicit `: u8` repr with custom discriminants
                vals = sorted(self.rng.sample(range(256), len(variants)))
                fields = ", ".join("%s = %d" % (v, val) for v, val in zip(variants, vals))
                decls.append("enum %s: u8 { %s }" % (name, fields))
            else:
                decls.append("enum %s { %s }" % (name, ", ".join(variants)))
        for i in range(self.rng.randrange(0, 2)):  # A11: type aliases over an int type
            u = self.rng.choice(INTS)
            name = "Alias%d" % i
            self.aliases[name] = u
            decls.append("type %s = %s;" % (name, u))
        self.gen_kernel_decls(decls)
        self.gen_offset_overlay_decls(decls)  # G15: explicit @offset structs + overlay unions
        self.gen_unions(decls)  # G7: tagged unions + per-union fold helpers
        self.gen_exprswitch_decls(decls)  # G11: return-form expression-switch helpers
        if self.rng.random() < 0.6:  # G13: a wrap-domain alias for from_mod/residue conversions
            self._conv_w = self.rng.choice(UINTS)
            decls.append("type Wconv = wrap<%s>;" % self._conv_w)
        self.gen_functions(decls)
        self.gen_result_functions(decls)
        self.gen_aggregate_abi(decls)
        if self.rng.random() < 0.5:  # G14: struct-of-pointers (field is `*T` into a stable global)
            spty = self.rng.choice(INTS)
            self._spk = ("SPk", spty)
            decls.append("global gspk: %s = %s;" % (spty, TYPES[spty]["lit"](self.rng)))
            decls.append("struct SPk { p: *%s }" % spty)

        recf_ty = None  # G10: a depth-bounded self-recursive function (sum 1..n)
        if self.rng.random() < 0.4:
            recf_ty = self.rng.choice(UINTS)
            decls.append("fn recf(n: %s) -> %s {\n    if n == 0 { return 0; }\n    return wrapping.add(n, recf(n - 1));\n}" % (recf_ty, recf_ty))

        use_generic = self.rng.random() < 0.5  # A8: comptime-generic identity fn (monomorphized per call type)
        if use_generic:
            decls.append("fn gid(comptime T: type, x: T) -> T {\n    return x;\n}")
        closure_ty = None  # A9: a capturing closure built with bind(&env, fn)
        if self.rng.random() < 0.4:
            closure_ty = self.rng.choice(UINTS)
            decls.append("struct ClEnv { base: %s }" % closure_ty)
            decls.append("global gclenv: ClEnv = .{ .base = %s };" % TYPES[closure_ty]["lit"](self.rng))
            decls.append("fn clfn(e: *ClEnv, x: %s) -> %s {\n    return wrapping.add(e.base, x);\n}" % (closure_ty, closure_ty))

        # D1: module-level globals — read/written/folded by the harness like locals, but they
        # lower through the race-tolerant load/store helpers (mc_race_load/store), a distinct path
        # from stack locals (and a historical source of C-backend bugs).
        for _ in range(self.rng.randrange(0, 3)):
            ty = self.rng.choice(INTS)
            name = "g%d" % self.nvars
            self.nvars += 1
            decls.append("global %s: %s = %s;" % (name, ty, TYPES[ty]["lit"](self.rng)))
            self.env.setdefault(self.aliases.get(ty, ty), []).append(name)
        for _ in range(self.rng.randrange(0, 2)):  # D4: const globals (named compile-time constants)
            ty = self.rng.choice(INTS)
            name = "c%d" % self.nvars
            self.nvars += 1
            decls.append("const %s: %s = %s;" % (name, ty, TYPES[ty]["lit"](self.rng)))
            self.env.setdefault(self.aliases.get(ty, ty), []).append(name)
            self.immutable.add(name)  # a const is read-only
        opt_targets = []  # A3: globals to take `?*T` pointers to (stable storage, not stack locals)
        for _ in range(self.rng.randrange(0, 2)):
            ty = self.rng.choice(INTS)
            gname = "gp%d" % self.nvars
            self.nvars += 1
            decls.append("global %s: %s = %s;" % (gname, ty, TYPES[ty]["lit"](self.rng)))
            opt_targets.append((gname, ty))

        out = []
        types = self.local_types()
        for ty in self.rng.sample(types, k=min(4, len(types))):
            name = "v%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: %s = %s;" % (name, ty, self.gen_value(ty)))
            self.env.setdefault(self.aliases.get(ty, ty), []).append(name)
        for ty in self.tuples:  # G14: always instantiate one var per declared tuple type, folded below
            name = "v%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: %s = %s;" % (name, ty, self.gen_value(ty)))
            self.env.setdefault(ty, []).append(name)
        if use_generic:  # A8: call the generic identity fn, instantiating it per type
            for _ in range(self.rng.randrange(0, 3)):
                ty = self.rng.choice(INTS)
                name = "gv%d" % self.nvars
                self.nvars += 1
                out.append("    var %s: %s = gid(%s, %s);" % (name, ty, ty, self.gen_value(ty)))
                self.env.setdefault(self.aliases.get(ty, ty), []).append(name)
        if recf_ty:  # G10: call the recursive fn with a small bound, fold the result
            name = "rv%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: %s = recf(%d);" % (name, recf_ty, self.rng.randrange(0, 7)))
            self.env.setdefault(recf_ty, []).append(name)
        for name, pt, rt in self.agg_fns:  # G3: call aggregate-by-value helpers, fold the result
            vn = "av%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: %s = %s(%s);" % (vn, rt, name, self.gen_value(pt)))
            self.env.setdefault(self.aliases.get(rt, rt), []).append(vn)
        if closure_ty:  # A9: build a capturing closure and call it; fold the result
            name = "clr%d" % self.nvars
            self.nvars += 1
            out.append("    let clf: closure(%s) -> %s = bind(&gclenv, clfn);" % (closure_ty, closure_ty))
            out.append("    var %s: %s = clf(%s);" % (name, closure_ty, TYPES[closure_ty]["lit"](self.rng)))
            self.env.setdefault(closure_ty, []).append(name)
        optionals = []  # A3: nullable pointers, read via `if let` narrowing
        plainptrs = []  # A4: non-nullable `*T` pointers, read by direct deref
        for gname, ty in opt_targets:
            pname = "p%d" % self.nvars
            self.nvars += 1
            if self.rng.random() < 0.5:
                init = "&%s" % gname if self.rng.random() < 0.6 else "null"
                out.append("    var %s: ?*%s = %s;" % (pname, ty, init))
                optionals.append((pname, ty))
            else:
                out.append("    var %s: *%s = &%s;" % (pname, ty, gname))
                plainptrs.append((pname, ty))
        self.gen_kernel_body(out)  # G2: atomics + packed-bits register vars
        self.gen_offset_overlay_body(out)  # G15: @offset-layout (comptime) + overlay-union reads
        for _ in range(self.rng.randrange(5, 12)):
            self.stmt(out, 1)

        # Fold each kind into the digest. Integers and struct fields fold by value. Floats fold
        # by comparison (a float's bit pattern is not a stable cross-backend observable, its
        # ordering is). Enums fold by an exhaustive switch into an integer accumulator.
        terms = []
        for ty in INTS + SATS + WRAPS:
            for name in self.env.get(ty, []):
                terms.append(TYPES[ty]["fold"](name))
        for tyname in list(self.structs) + list(self.arrays) + list(self.tuples):
            for name in self.env.get(tyname, []):
                self.fold_type(name, tyname, terms)
        for ename in self.open_enums:  # standalone open-enum vars fold inline via `.raw()`
            for name in self.env.get(ename, []):
                terms.append("(%s.raw() as u64)" % name)
        terms.extend(self._kernel_terms)  # G2: packed-bits field observations
        if optionals or plainptrs:  # A3/A4: fold pointer reads into the digest
            out.append("    var pobs: u64 = 0;")
            for pname, ty in optionals:  # A3: if-let narrowing
                out.append("    if let q = %s {" % pname)
                out.append("        pobs = (pobs ^ %s);" % TYPES[ty]["fold"]("q.*"))
                out.append("    } else {")
                out.append("        pobs = (pobs ^ 12345);")
                out.append("    }")
            for pname, ty in plainptrs:  # A4: direct deref of a non-nullable pointer
                out.append("    pobs = (pobs ^ %s);" % TYPES[ty]["fold"]("%s.*" % pname))
            terms.append("pobs")
        if self.result_fns:  # A1: fold each Result helper by matching ok/err
            out.append("    var robs: u64 = 0;")
            for name, pt, ot in self.result_fns:
                out.append("    switch %s(%s) {" % (name, self.gen_leaf(pt)))
                # XOR accumulation: the ok/err payloads can be arbitrary values, so a checked `+`
                # would overflow u64 and trap. XOR observes both arms without overflow.
                out.append("        ok(v) => { robs = (robs ^ %s); }" % TYPES[ot]["fold"]("v"))
                out.append("        err(e) => { robs = (robs ^ %s ^ 1000); }" % TYPES["u32"]["fold"]("e"))
                out.append("    }")
            terms.append("robs")
        if any(self.env.get(ty) for ty in FLOATS):
            if self.float_bits:
                # G4: observe exact float bits (results are finite — no `/`), catching ~1-ULP
                # cross-backend divergences the comparison fold hides.
                for ty in FLOATS:
                    for name in self.env.get(ty, []):
                        terms.append(TYPES[ty]["fold"](name))
            else:
                out.append("    var fobs: u64 = 0;")
                for ty in FLOATS:
                    for name in self.env.get(ty, []):
                        for k in range(3):
                            cmp = self.rng.choice(("<", "<=", ">", ">=", "==", "!="))
                            out.append("    if %s %s %s { fobs = fobs + %d; }" % (name, cmp, TYPES[ty]["lit"](self.rng), 1 << k))
                terms.append("fobs")
        self.gen_byteview_body(decls, out, terms)  # G12: byte-view reduction + slice indexing
        self.gen_slice_body(decls, out, terms)  # G8: general `[]mut T` slice construction + ABI
        self.gen_union_body(out, terms)  # G7: construct + switch-fold tagged union values
        self.gen_conv_body(out, terms)  # G13: cross-domain conversions (from_mod/residue/widening)
        self.gen_exprswitch_body(out, terms)  # G11: expression-switch (return + initializer forms)
        if self._spk is not None:  # G14: construct the struct-of-pointers and fold via field deref
            _, spty = self._spk
            out.append("    var spv: SPk = .{ .p = &gspk };")
            terms.append(TYPES[spty]["fold"]("spv.p.*"))
        if self.rng.random() < 0.5:  # G14: an array of Result<T, u32>, each element folded by switch
            arty = self.rng.choice(INTS)
            arn = self.rng.randrange(2, 4)
            elems = ["ok(%s)" % self.gen_leaf(arty) if self.rng.random() < 0.5
                     else "err(%s)" % TYPES["u32"]["lit"](self.rng) for _ in range(arn)]
            out.append("    var arres: [%d]Result<%s, u32> = .{ %s };" % (arn, arty, ", ".join(elems)))
            out.append("    var arobs: u64 = 0;")
            for k in range(arn):
                out.append("    switch arres[%d] {" % k)
                out.append("        ok(v) => { arobs = (arobs ^ %s); }" % TYPES[arty]["fold"]("v"))
                out.append("        err(e) => { arobs = (arobs ^ %s ^ 7); }" % TYPES["u32"]["fold"]("e"))
                out.append("    }")
            terms.append("arobs")
        if any(self.env.get(e) for e in self.enums):
            out.append("    var eobs: u64 = 0;")
            for ename, variants in self.enums.items():
                for name in self.env.get(ename, []):
                    out.append("    switch %s {" % name)
                    for k, v in enumerate(variants[:-1]):
                        out.append("        .%s => { eobs = eobs + %d; }" % (v, k + 1))
                    out.append("        _ => { eobs = eobs + %d; }" % len(variants))
                    out.append("    }")
            terms.append("eobs")

        # Metamorph (G16): XOR is commutative+associative, so folding the terms in reverse order
        # must give the identical digest — a second semantics-preserving transform (on top of the
        # body-in-helper) that re-orders the final reduction.
        fold_terms = list(reversed(terms)) if metamorph else terms
        acc = fold_terms[0] if fold_terms else "0"
        for t in fold_terms[1:]:
            acc = "(%s ^ %s)" % (acc, t)
        out.append("    return %s;" % acc)
        body = "\n".join(out)
        header = "// Generated by tools/fuzz/mcfuzz.py — regenerate from the seed.\n"
        if metamorph:
            # Semantics-preserving variant: the digest body runs in a non-exported helper that
            # `harness` calls (so it must produce the identical result). Exercises whole-program
            # extraction / call-ABI / inlining differently from the inline body.
            return (header + "\n".join(decls) + "\nfn mc_meta_body() -> u64 {\n" + body
                    + "\n}\nexport fn harness() -> u64 {\n    return mc_meta_body();\n}\n")
        return header + "\n".join(decls) + "\nexport fn harness() -> u64 {\n" + body + "\n}\n"


# ----- oracles -----
def _first_error(text):
    """The first `… error: …` line (with its E_ code), else a short prefix."""
    return next((l.strip() for l in text.splitlines() if "error:" in l), text.strip()[:120])


def _emit_c_obj(mcc, clang, src_path, obj, extra=()):
    p1 = subprocess.run([mcc, "emit-c", src_path], capture_output=True)
    if p1.returncode != 0:
        return p1.stderr.decode("utf-8", "replace")
    p2 = subprocess.run([clang, "-std=c11", "-w", *extra, "-c", "-x", "c", "-", "-o", obj],
                        input=p1.stdout, capture_output=True)
    return None if p2.returncode == 0 else p2.stderr.decode("utf-8", "replace")


def oracle_differential(env, seed, src_path, work):
    """Compile through both backends, run, assert identical output."""
    return _differential_compare(env, src_path, work)


def _differential_compare(env, src_path, work):
    c_obj, l_obj = os.path.join(work, "c.o"), os.path.join(work, "l.o")
    err = _emit_c_obj(env["mcc"], env["clang"], src_path, c_obj)
    if err is not None:
        # Status comparison (rss contract): the MIR verifier runs ahead of *both* backends, so a
        # verifier rejection fails C and LLVM identically — that is consistent, not a divergence.
        # Only a backend that rejects what the *other* accepts is a real C-vs-LLVM bug.
        if subprocess.run([env["mcc"], "emit-llvm", src_path], capture_output=True).returncode != 0:
            return None
        return "C backend emit/compile failed (LLVM accepted): %s" % _first_error(err)
    p = subprocess.run(["bash", os.path.join(ROOT, "tools/toolchain/mcc-llvm-cc.sh"), src_path, "-o", l_obj],
                       capture_output=True, env={**os.environ, "MCC": env["mcc"], "LLC": env["llc"]})
    if p.returncode != 0:
        return "LLVM backend emit/compile failed"
    drv, ts = os.path.join(work, "d.c"), os.path.join(work, "ts.c")
    open(drv, "w").write(DRIVER); open(ts, "w").write(TRAP_STUBS)
    link = env["link_flags"]
    c_app, l_app = os.path.join(work, "c.app"), os.path.join(work, "l.app")
    if subprocess.run([env["clang"], *link, "-w", drv, c_obj, "-lm", "-o", c_app], capture_output=True).returncode != 0:
        return "C link failed"
    if subprocess.run([env["clang"], *link, "-w", drv, ts, l_obj, "-lm", "-o", l_app], capture_output=True).returncode != 0:
        return "LLVM link failed"
    co = subprocess.run([c_app], capture_output=True)
    lo = subprocess.run([l_app], capture_output=True)
    # rss-testgen's contract: compare the success/failure *status*, and the stdout only when
    # both succeed. A program that traps (overflow, div-by-zero, …) on one backend must trap on
    # the other — but the exact trap mechanism/exit code differs (the C backend inlines its
    # traps; the LLVM side links __builtin_trap stubs), so we compare "exited 0" not the code.
    c_ok, l_ok = (co.returncode == 0), (lo.returncode == 0)
    if c_ok != l_ok:
        return "BACKEND DIVERGENCE (one trapped, one did not): C=(rc=%d) LLVM=(rc=%d)" % (co.returncode, lo.returncode)
    if c_ok and co.stdout != lo.stdout:
        return "BACKEND DIVERGENCE (output): C=%r LLVM=%r" % (co.stdout.strip(), lo.stdout.strip())
    return None


def _ubsan_runtime_available():
    """True if clang can LINK a trivial program with -fsanitize=undefined. Some toolchains ship
    clang without the compiler-rt sanitizer runtime for the host arch (e.g. Ubuntu clang on arm64),
    so the sanitize oracle's link always fails — an unsupported environment, not a code finding."""
    import tempfile, shutil
    clang = os.environ.get("CLANG", "clang")
    d = tempfile.mkdtemp()
    try:
        c = os.path.join(d, "p.c")
        open(c, "w").write("int main(void){return 0;}\n")
        return subprocess.run(
            [clang, "-fsanitize=undefined", "-fno-sanitize-recover=all", c, "-o", os.path.join(d, "p")],
            capture_output=True).returncode == 0
    except Exception:
        return False
    finally:
        shutil.rmtree(d, ignore_errors=True)


def oracle_sanitize(env, seed, src_path, work):
    """Compile the emitted C with UBSan and run; any report is a finding."""
    obj = os.path.join(work, "c.o")
    san = ["-fsanitize=undefined", "-fno-sanitize=function", "-fno-sanitize-recover=all"]
    err = _emit_c_obj(env["mcc"], env["clang"], src_path, obj, extra=san)
    if err is not None:
        return "C backend emit/compile failed"
    drv = os.path.join(work, "d.c"); open(drv, "w").write(DRIVER)
    app = os.path.join(work, "app")
    if subprocess.run([env["clang"], *env["link_flags"], "-w", *san, drv, obj, "-lm", "-o", app],
                      capture_output=True).returncode != 0:
        return "link failed"
    r = subprocess.run([app], capture_output=True, env={**os.environ, "UBSAN_OPTIONS": "halt_on_error=1"})
    msg = (r.stdout + r.stderr).decode("utf-8", "replace")
    if "runtime error" in msg or r.returncode not in (0,):
        return "UBSan: %s" % (next((l for l in msg.splitlines() if "runtime error" in l), "abort rc=%d" % r.returncode))
    return None


def _mutate(data, rng):
    """Corrupt valid source into (usually invalid) input that still reaches deep into the front
    end: byte flips, deletions, duplications, truncation, and ASCII-noise insertions."""
    b = bytearray(data)
    for _ in range(rng.randint(1, 12)):
        if not b:
            b = bytearray(b"fn main() {}")
        kind = rng.randrange(5)
        i = rng.randrange(len(b))
        if kind == 0:
            b[i] ^= 1 << rng.randrange(8)
        elif kind == 1:
            del b[i]
        elif kind == 2:
            b.insert(i, rng.randrange(256))
        elif kind == 3:
            b.insert(i, b[i])
        else:
            del b[i:]  # truncate
    return bytes(b)


def oracle_robust(env, seed, src_path, work):
    """Robustness: `mcc check` must never crash (signal) or hang on *any* input, even malformed.
    A clean accept or a clean diagnostic exit are both fine; a Zig panic / segfault / timeout is
    a front-end robustness bug. (rss-testgen's hostile/parse_check driver.)"""
    rng = random.Random((seed * 2654435761) & 0xFFFFFFFF)
    mutated = _mutate(open(src_path, "rb").read(), rng)
    mpath = os.path.join(work, "m.mc")
    open(mpath, "wb").write(mutated)
    try:
        r = subprocess.run([env["mcc"], "check", mpath], capture_output=True, timeout=15)
    except subprocess.TimeoutExpired:
        return "mcc check HANGS (>15s) on mutated input"
    if r.returncode < 0:  # killed by a signal: a crash, not a clean rejection
        return "mcc check CRASHED (signal %d) on mutated input" % (-r.returncode)
    return None


# Statements that are *definitely* ill-typed: the checker must reject every one. (Each is
# inert if it somehow type-checked — it only reads/declares — so a false-accept is a pure
# soundness hole, not a crash.)
INVALIDATIONS = [
    ("    var mcfuzz_bad: bool = 12345;", "int literal assigned to bool"),
    ("    var mcfuzz_bad: u32 = 1.5;", "float literal assigned to int"),
    ("    var mcfuzz_bad: u32 = mcfuzz_undeclared_zzz;", "use of an undeclared identifier"),
    ("    var mcfuzz_bad: bool = true; var mcfuzz_bad: bool = false;", "duplicate local declaration"),
    ("    var mcfuzz_bad: u32 = (true + 1);", "arithmetic on a bool operand"),
    ("    mcfuzz_undeclared_fn(1, 2, 3);", "call of an undeclared function"),
    ("    var mcfuzz_bad: u8 = ((0 as usize) as UserPtr<u8>).*;", "kernel deref of a UserPtr (user/kernel trust boundary)"),
]


def oracle_failclosed(env, seed, src_path, work):
    """Fail-closed soundness: inject a definitely-invalid statement into a valid program and
    assert `mcc check` REJECTS it. A clean rejection is correct; *accepting* an ill-typed program
    is a soundness hole; a crash is a robustness bug. (rss-testgen's fail-closed driver.)"""
    rng = random.Random((seed * 40503) & 0xFFFFFFFF)
    inj, desc = rng.choice(INVALIDATIONS)
    source = open(src_path).read()
    marker = "export fn harness() -> u64 {\n"
    if marker not in source:
        return None
    bad = source.replace(marker, marker + inj + "\n", 1)
    bpath = os.path.join(work, "bad.mc")
    open(bpath, "w").write(bad)
    try:
        r = subprocess.run([env["mcc"], "check", bpath], capture_output=True, timeout=15)
    except subprocess.TimeoutExpired:
        return "mcc check HANGS on an invalid program (%s)" % desc
    if r.returncode < 0:
        return "mcc check CRASHED (signal %d) on an invalid program (%s)" % (-r.returncode, desc)
    if r.returncode == 0:
        return "SOUNDNESS: mcc check ACCEPTED an ill-typed program (%s)" % desc
    return None


def oracle_determinism(env, seed, src_path, work):
    """Metamorphic: a deterministic compiler emits byte-identical output for the same input.
    Non-determinism (e.g. hashmap iteration order leaking into codegen) is a real compiler bug."""
    for stage in ("emit-c", "emit-llvm"):
        first = None
        for _ in range(3):
            r = subprocess.run([env["mcc"], stage, src_path], capture_output=True)
            if r.returncode != 0:
                break  # an emit failure is a different oracle's concern
            if first is None:
                first = r.stdout
            elif r.stdout != first:
                return "NON-DETERMINISTIC %s: same input, different bytes across runs" % stage
    return None


def oracle_pipeline(env, seed, src_path, work):
    """Internal consistency: every lowering/verification stage must succeed on a program `mcc
    check` accepted. A stage that errors (or crashes) on accepted source is an internal
    inconsistency — the exact class where the checker accepts a program a backend can't lower."""
    for stage in ("lower-hir", "verify-hir", "lower-mir", "verify", "lower-ir",
                  "facts", "emit-c", "emit-map", "emit-llvm"):
        try:
            r = subprocess.run([env["mcc"], stage, src_path], capture_output=True, timeout=20)
        except subprocess.TimeoutExpired:
            return "mcc %s HANGS on a check-accepted program" % stage
        if r.returncode < 0:
            return "mcc %s CRASHED (signal %d) on a check-accepted program" % (stage, -r.returncode)
        if r.returncode != 0:
            err = next((l for l in r.stderr.decode("utf-8", "replace").splitlines() if "error" in l.lower()), "")
            return "INTERNAL INCONSISTENCY: mcc %s rejected a check-accepted program: %s" % (stage, err.strip())
    return None


def _compile_run_c(env, src_path, work, tag, opt=None):
    """Emit C, compile (optionally at an -O level), link with the driver, run. Returns
    (returncode, stdout) or None if the emit/compile/link failed (a different oracle's concern)."""
    obj = os.path.join(work, tag + ".o")
    if _emit_c_obj(env["mcc"], env["clang"], src_path, obj, extra=((opt,) if opt else ())) is not None:
        return None
    drv = os.path.join(work, "d.c")
    open(drv, "w").write(DRIVER)
    app = os.path.join(work, tag + ".app")
    if subprocess.run([env["clang"], *env["link_flags"], "-w", drv, obj, "-lm", "-o", app], capture_output=True).returncode != 0:
        return None
    p = subprocess.run([app], capture_output=True)
    return (p.returncode, p.stdout)


def _compiles(env, src_path):
    """Does `src_path` pass `mcc check` AND `mcc emit-c`? Returns (True, "") if it compiles, else
    (False, first-error-line). Used by the metamorphic oracle to tell a *compile* divergence
    (base compiles, the semantics-preserving variant does not) apart from a run-time divergence."""
    chk = subprocess.run([env["mcc"], "check", src_path], capture_output=True)
    if chk.returncode != 0:
        return (False, "check: " + _first_error(chk.stderr.decode("utf-8", "replace")))
    ec = subprocess.run([env["mcc"], "emit-c", src_path], capture_output=True)
    if ec.returncode != 0:
        return (False, "emit-c: " + _first_error(ec.stderr.decode("utf-8", "replace")))
    return (True, "")


def oracle_metamorphic(env, seed, src_path, work):
    """Metamorphic: a semantics-preserving source transform must not change the result. The
    variant runs the digest body in a helper that harness() calls; same seed -> same body, so the
    output must be identical. A difference is a real codegen bug even when both backends agree.

    The base (`src_path`) is already `mcc check`-accepted by run_one(). The variant is built by a
    *semantics-preserving* transform, so it MUST compile too. A variant that fails to compile is a
    FINDING in its own right — either the transform is not actually compilable (a dead oracle, the
    bug this guards against) or it surfaced a real front-end divergence between two equivalent
    spellings. We therefore check compilability explicitly and fail on `base compiles but variant
    does not`, instead of silently returning None (which made the whole oracle dead)."""
    variant = os.path.join(work, "variant.mc")
    open(variant, "w").write(Gen(seed, trapping=env.get("trapping", False)).program(metamorph=True))
    var_ok, var_err = _compiles(env, variant)
    if not var_ok:
        # base is check-accepted (run_one guarantees it); a semantics-preserving variant that does
        # NOT compile is a real finding, not a pass.
        return ("METAMORPHIC COMPILE DIVERGENCE: base compiles but the semantics-preserving "
                "variant does NOT (%s) — the transform is non-compilable or the variant spelling "
                "exposes a front-end divergence" % var_err)
    base = _compile_run_c(env, src_path, work, "base")
    var = _compile_run_c(env, variant, work, "var")
    if base is None:
        return None  # base emit/compile/link failure is another oracle's concern
    if var is None:
        # The variant passed check+emit-c above, so a None here is a clang-compile or link failure
        # of the emitted C for the variant only — still a base-vs-variant divergence worth surfacing.
        return ("METAMORPHIC COMPILE DIVERGENCE: base's emitted C builds+links but the variant's "
                "does not — divergent C emission for a semantics-preserving variant")
    if base[0] != var[0]:
        return "METAMORPHIC DIVERGENCE (status): base rc=%d, helper-extracted rc=%d" % (base[0], var[0])
    if base[0] == 0 and base[1] != var[1]:
        return "METAMORPHIC DIVERGENCE (output): base=%r helper-extracted=%r" % (base[1].strip(), var[1].strip())
    return None


def oracle_optlevel(env, seed, src_path, work):
    """Compile the emitted C at -O0 and -O2 and compare. Generated MC is deterministic and the
    emitted C is UB-free, so the optimizer must not change the result. A divergence means
    optimization-sensitive UB the unoptimized build hides (or a backend codegen bug)."""
    o0 = _compile_run_c(env, src_path, work, "o0", opt="-O0")
    o2 = _compile_run_c(env, src_path, work, "o2", opt="-O2")
    if o0 is None or o2 is None:
        return None
    if o0[0] != o2[0]:
        return "OPT-LEVEL DIVERGENCE (status): -O0 rc=%d, -O2 rc=%d" % (o0[0], o2[0])
    if o0[0] == 0 and o0[1] != o2[1]:
        return "OPT-LEVEL DIVERGENCE (output): -O0=%r -O2=%r" % (o0[1].strip(), o2[1].strip())
    return None


def oracle_floatbits(env, seed, src_path, work):
    """Float bit-level differential (G4): regenerate the program in float_bits mode — floats use
    only + - * (finite results) and are folded by *bitcast* — and compare backends. Catches
    ~1-ULP f32/f64 divergences the comparison-based float fold hides (it's how the f32
    double-rounding bug manifested)."""
    src = os.path.join(work, "fb.mc")
    open(src, "w").write(Gen(seed, trapping=env.get("trapping", False), float_bits=True).program())
    if subprocess.run([env["mcc"], "check", src], capture_output=True).returncode != 0:
        return None  # generator soundness is the failclosed oracle's concern
    return _differential_compare(env, src, work)


def oracle_reference(env, seed, src_path, work):
    """Reference-interpreter oracle (G1): generate a program over the unsigned-integer core with
    `mcref`, which renders MC *and* evaluates the same AST in pure Python, then assert the compiled
    output equals the Python value. Unlike the C-vs-LLVM oracles this is an INDEPENDENT evaluator,
    so it catches shared-frontend bugs (constant-folder / verifier / wrap-sat domain semantics)
    where both backends agree but are wrong. Sound by construction: only unsigned types and
    trap-free ops are generated, so a trap or a mismatch is necessarily a real compiler bug."""
    g = mcref.RefGen(seed).build()
    src = os.path.join(work, "ref.mc")
    open(src, "w").write(g.source())
    if subprocess.run([env["mcc"], "check", src], capture_output=True).returncode != 0:
        return None  # a generator soundness slip is the failclosed oracle's concern, not a finding
    expected = g.evaluate()
    res = _compile_run_c(env, src, work, "ref")
    if res is None:
        return None  # emit/compile/link failure is another oracle's concern
    rc, out = res
    if rc != 0:
        return ("REFERENCE DIVERGENCE (trap): compiled program trapped (rc=%d) on a trap-free "
                "program; interpreter computed %d" % (rc, expected))
    got = out.strip()
    if got != str(expected).encode():
        return "REFERENCE DIVERGENCE (value): interpreter=%d compiled=%s" % (expected, got.decode("utf-8", "replace"))
    return None


ORACLES = {"differential": oracle_differential, "sanitize": oracle_sanitize,
           "robust": oracle_robust, "failclosed": oracle_failclosed,
           "determinism": oracle_determinism, "pipeline": oracle_pipeline,
           "metamorphic": oracle_metamorphic, "optlevel": oracle_optlevel,
           "floatbits": oracle_floatbits, "reference": oracle_reference}


def oracle_on_source(env, oracle, source):
    """Run an oracle on a raw source string; returns the finding message or None."""
    work = tempfile.mkdtemp()
    try:
        src = os.path.join(work, "p.mc")
        open(src, "w").write(source)
        return oracle(env, 0, src, work)
    finally:
        subprocess.run(["rm", "-rf", work])


def shrink_source(env, oracle, source, signature):
    """Delta-debug `source` to a minimal program that still fails the oracle with the same kind
    of finding (`signature` must stay in the message — so a divergence stays a divergence, not a
    reduction that merely fails to compile). Line-greedy: keep removing lines while the failure
    holds; repeat to fixpoint."""
    lines = source.split("\n")
    changed = True
    while changed:
        changed = False
        i = 0
        while i < len(lines):
            trial = lines[:i] + lines[i + 1:]
            res = oracle_on_source(env, oracle, "\n".join(trial))
            if res is not None and signature in res:
                lines = trial
                changed = True
            else:
                i += 1
    return "\n".join(lines)


def _seed_of(finding):
    m = re.search(r"seed=(\d+)", finding)
    return int(m.group(1)) if m else None


def run_one(env, oracle, seed):
    work = tempfile.mkdtemp()
    try:
        src = os.path.join(work, "p.mc")
        open(src, "w").write(Gen(seed, trapping=env.get("trapping", False)).program())
        chk = subprocess.run([env["mcc"], "check", src], capture_output=True)
        if chk.returncode != 0:
            return "FAIL seed=%d: mcc check rejected a generated program" % seed
        res = oracle(env, seed, src, work)
        if res is not None:
            return "FAIL seed=%d: %s (reproduce: tools/fuzz/mcfuzz.py gen %d)" % (seed, res, seed)
        return None
    finally:
        subprocess.run(["rm", "-rf", work])


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen"); g.add_argument("seed", type=int); g.add_argument("--trapping", action="store_true")
    r = sub.add_parser("run")
    r.add_argument("--count", type=int, default=int(os.environ.get("COUNT", "300")))
    r.add_argument("--start", type=int, default=1)
    r.add_argument("--oracle", choices=list(ORACLES), default="differential")
    r.add_argument("--trapping", action="store_true", help="emit checked arithmetic that may trap (differential only)")
    r.add_argument("--jobs", type=int, default=int(os.environ.get("JOBS", os.cpu_count() or 4)))
    default_mcc = os.environ.get("MCC_UNDER_TEST") or os.environ.get("MCC") or "zig-out/bin/mcc"
    r.add_argument("--mcc", default=default_mcc)
    rp = sub.add_parser("report", help="construct-coverage statistics over generated programs")
    rp.add_argument("--count", type=int, default=int(os.environ.get("COUNT", "300")))
    cp = sub.add_parser("corpus", help="replay the persisted regression corpus (fixed-bug repros)")
    cp.add_argument("--mcc", default=default_mcc)
    cp.set_defaults(trapping=False)
    sh = sub.add_parser("shrink", help="minimize a failing seed to a small repro")
    sh.add_argument("--seed", type=int, required=True)
    sh.add_argument("--oracle", choices=list(ORACLES), default="differential")
    sh.add_argument("--trapping", action="store_true")
    sh.add_argument("--mcc", default=default_mcc)
    args = ap.parse_args()

    if args.cmd == "gen":
        sys.stdout.write(Gen(args.seed, trapping=args.trapping).program())
        return 0

    if args.cmd == "report":  # G17: what fraction of seeds exercise each construct
        markers = [
            ("wrap domain", r"wrap<u"), ("sat domain", r"sat<u"),
            ("f32", r": f32"), ("f64", r": f64"),
            ("struct", r"^struct "), ("array", r"\[\d+\]"), ("nested array", r"\[\d+\]\[\d+\]"),
            ("closed enum", r"^enum "), ("open enum", r"open enum"), ("enum discriminant", r"^enum \w+: u8"),
            ("switch stmt", r"^\s+switch "), ("for-in", r"for \w+ in"),
            ("break", r"break;"), ("continue", r"continue;"), ("early return", r"if .* \{ return"),
            ("global", r"^global "), ("const global", r"^const "), ("type alias", r"^type "),
            ("Result/?", r"Result<"), ("? propagate", r"\)\?;"),
            ("nullable ptr", r"\?\*"), ("pointer", r"var \w+: \*"),
            ("generic fn", r"comptime T: type"), ("closure", r"bind\("),
            ("aggregate ABI", r"fn agg(id|get)"), ("&&/||", r"&&|\|\|"),
            ("atomic", r"atomic<u"), ("packed bits", r"^packed bits "),
            ("@offset struct", r"@offset\("), ("offset sizeof/field_offset", r"field_offset\("),
            ("overlay union", r"^overlay union "),
            ("tuple", r": \([^)]+, "), ("struct-of-ptr", r"struct SPk"), ("array-of-Result", r"\]Result<"),
            ("byte-view slice", r"mem\.as_bytes"), ("checked reduce", r"reduce\.sum_checked"),
            ("slice .len/index", r"\.len \{"),
            ("[]mut slice", r"\]mut \w+ = \w+\["), ("slice fn param", r"fn slcsum_"),
            ("tagged union", r"^union "), ("union switch-fold", r"fn ufold_"),
            ("domain conv", r"Wconv\.from_mod"), ("residue", r"\.residue\(\)"), ("widening from", r"u64\.from\("),
            ("expr-switch", r"= switch "), ("return-switch", r"return switch "),
        ]
        counts = {name: 0 for name, _ in markers}
        for s in range(1, args.count + 1):
            prog = Gen(s).program()
            for name, pat in markers:
                if re.search(pat, prog, re.M):
                    counts[name] += 1
        print("mcfuzz construct coverage over %d seeds:" % args.count)
        for name, _ in markers:
            c = counts[name]
            print("  %-18s %4d  (%3d%%)" % (name, c, 100 * c // args.count))
        return 0

    import shutil
    if not shutil.which(os.environ.get("CLANG", "clang")):
        print("SKIP: mcfuzz (clang not found)"); return 0
    if not shutil.which(os.environ.get("LLC", "llc")):
        print("SKIP: mcfuzz (llc not found)"); return 0
    env = {
        "mcc": args.mcc, "clang": os.environ.get("CLANG", "clang"), "llc": os.environ.get("LLC", "llc"),
        "link_flags": ["-no-pie"] if sys.platform.startswith("linux") else [],
        "trapping": args.trapping,
    }

    if args.cmd == "corpus":  # G17: persisted regression gates — each fixed-bug repro stays clean
        import glob
        files = sorted(glob.glob(os.path.join(ROOT, "tools/fuzz/corpus", "*.mc")))
        if not files:
            print("SKIP: mcfuzz/corpus (no corpus files)"); return 0
        checks = [("differential", oracle_differential)]
        if _ubsan_runtime_available():
            checks.append(("sanitize", oracle_sanitize))
        else:
            print("note: mcfuzz/corpus skipping sanitize oracle (UBSan runtime unavailable for this host arch)")
        fails = []
        for f in files:
            src = open(f).read()
            for oname, oracle in checks:
                res = oracle_on_source(env, oracle, src)
                if res is not None:
                    msg = "%s [%s]: %s" % (os.path.basename(f), oname, res)
                    print(msg); fails.append(msg)
        if fails:
            print("FAIL: mcfuzz/corpus — %d regression(s) over %d file(s)" % (len(fails), len(files)))
            return 1
        print("PASS: mcfuzz/corpus — %d historical-bug repro(s) stay clean (differential+sanitize)"
              % len(files))
        return 0

    if args.cmd == "shrink":
        oracle = ORACLES[args.oracle]
        source = Gen(args.seed, trapping=args.trapping).program()
        res = oracle_on_source(env, oracle, source)
        if res is None:
            print("seed %d does not fail mcfuzz/%s — nothing to shrink" % (args.seed, args.oracle))
            return 0
        # Prefer a specific compiler error code (E_…) as the signature so the shrinker keeps the
        # *same* failure and never over-reduces to a different one (e.g. a bare syntax error).
        m = re.search(r"E_[A-Z0-9_]+", res)
        sig = m.group(0) if m else next(
            (s for s in ("DIVERGENCE", "CRASHED", "HANGS", "UBSan", "runtime error",
                         "emit/compile failed", "link failed") if s in res), res[:24])
        sys.stderr.write("original finding: %s\nshrinking (signature %r)...\n" % (res.splitlines()[0], sig))
        minimal = shrink_source(env, oracle, source, sig)
        print("// minimal repro for seed %d (mcfuzz/%s, signature %r):\n%s" % (args.seed, args.oracle, sig, minimal))
        return 0

    oracle = ORACLES[args.oracle]
    if args.oracle == "sanitize" and not _ubsan_runtime_available():
        print("SKIP: mcfuzz/sanitize — UBSan runtime (compiler-rt) unavailable for this host arch")
        return 0
    seeds = range(args.start, args.start + args.count)
    fails, suspects = [], []
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for res in ex.map(lambda s: run_one(env, oracle, s), seeds):
            if res:
                # A wall-clock timeout is only proof of a hang if it reproduces with nothing
                # else competing for CPU. The fast lane oversubscribes the machine (several
                # fuzz oracles run at once, each with --jobs=cpu_count), so a merely-slow
                # `mcc check` can cross the 15s deadline. Defer HANGS findings to a serial
                # re-verify below; report every other (deterministic) finding immediately.
                if "HANGS" in res:
                    suspects.append(res)
                else:
                    print(res); fails.append(res)
    # Re-verify suspected hangs one at a time, pool drained, so a real infinite loop still
    # trips the deadline while a contention flake completes and is dropped (with a note).
    for res in suspects:
        seed = _seed_of(res)
        recheck = run_one(env, oracle, seed) if seed is not None else res
        if recheck and "HANGS" in recheck:
            msg = recheck + " [confirmed on serial re-verify]"
            print(msg); fails.append(msg)
        elif recheck:
            print(recheck); fails.append(recheck)  # reproduced as a *different* finding — still real
        else:
            print("seed=%s: timeout under parallel load did NOT reproduce serially — dropped as a contention flake" % seed)
    if fails:
        print("FAIL: mcfuzz/%s — %d finding(s) over %d programs" % (args.oracle, len(fails), args.count))
        return 1
    summary = {
        "differential": "C and LLVM agree",
        "sanitize": "emitted C is UBSan-clean",
        "robust": "mcc check never crashed/hung on mutated input",
        "failclosed": "mcc check rejected every ill-typed program (no soundness hole)",
        "determinism": "emit-c/emit-llvm are byte-deterministic",
        "pipeline": "every lowering/verify stage succeeds on check-accepted programs",
        "reference": "compiled output matches the independent Python interpreter",
    }.get(args.oracle, "no findings")
    mode = " (trapping)" if args.trapping else ""
    print("PASS: mcfuzz/%s%s — %s over %d programs (seeds %d..%d)"
          % (args.oracle, mode, summary, args.count, args.start, args.start + args.count - 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
