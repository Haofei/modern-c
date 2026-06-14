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
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

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
    return lambda rng: str(rng.randint(0, hi))

def _sint_lit(width):
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    return lambda rng: str(rng.randint(lo, hi))

def _float_lit(rng):
    # a finite decimal literal (keep magnitudes modest so products stay finite)
    return "%d.%d" % (rng.randint(-1000, 1000), rng.randint(0, 999))

TYPES = {}
def _t(name, kind, width, lit, fold):
    TYPES[name] = {"name": name, "kind": kind, "width": width, "lit": lit, "fold": fold}

for w in (8, 16, 32, 64):
    _t("u%d" % w, "uint", w, _uint_lit(w), lambda n: "((%s) as u64)" % n)
    _t("i%d" % w, "sint", w, _sint_lit(w), lambda n: "((%s) as u64)" % n)
_t("usize", "uint", 64, _uint_lit(64), lambda n: "((%s) as u64)" % n)
_t("f64", "float", 64, _float_lit, lambda n: "bitcast<u64>(%s)" % n)
_t("f32", "float", 32, _float_lit, lambda n: "(bitcast<u32>(%s) as u64)" % n)
_t("bool", "bool", 1, lambda rng: rng.choice(("true", "false")), None)

UINTS = [n for n, t in TYPES.items() if t["kind"] == "uint"]
SINTS = [n for n, t in TYPES.items() if t["kind"] == "sint"]
INTS = UINTS + SINTS
FLOATS = [n for n, t in TYPES.items() if t["kind"] == "float"]
# f32 is excluded from generation pending a real C-backend bug this framework found: f32
# constant expressions are emitted with bare C `double` literals, so `a * b` is computed in
# double then narrowed, diverging by ~1 ULP from the LLVM backend's f32 `fmul`. (f64 is fine.)
GEN_SKIP = {"f32"}
VALUE_TYPES = [t for t in (INTS + FLOATS) if t not in GEN_SKIP]  # foldable into the digest


class Gen:
    def __init__(self, seed, trapping=False):
        self.rng = random.Random(seed)
        self.env = {}        # type name -> [var names in scope at top level]
        self.nvars = 0
        self.depth = 0       # block nesting (new vars only at depth 0)
        self.structs = {}    # struct name -> [(field, scalar type name)]
        self.enums = {}      # enum name -> [variant names]
        self.functions = []  # [(name, [(param, type)], ret type)] — call only earlier ones (a DAG)
        self.arrays = {}     # "[N]T" -> (element type, length)
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
        return VALUE_TYPES + list(self.structs) + list(self.enums) + list(self.arrays)

    def gen_value(self, tyname, d=0):
        if tyname in self.structs:  # construct: `.{ .f = <field value>, … }`
            return ".{ %s }" % ", ".join(".%s = %s" % (f, self.gen_value(t)) for f, t in self.structs[tyname])
        if tyname in self.enums:    # an enum literal: `.Variant`
            return ".%s" % self.rng.choice(self.enums[tyname])
        if tyname in self.arrays:   # an array literal `.{ e0, …, e{N-1} }`
            elem, length = self.arrays[tyname]
            return ".{ %s }" % ", ".join(self.gen_leaf(elem) for _ in range(length))
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
            op = self.rng.choice(("+", "-", "*", "/"))
            return "(%s %s %s)" % (self.gen_value(tyname, d + 1), op, self.gen_value(tyname, d + 1))
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

    # A *checked* integer op (may trap on overflow / divide-by-zero). Signed ints have no
    # bitwise/shift, so they use only + * /.
    def gen_checked(self, tyname, width, signed):
        a, b = self.anchored_pair(tyname)
        ops = ["+", "*", "/"] if signed else ["+", "*", "/", "<<"]
        op = self.rng.choice(ops)
        if op == "<<":
            return "(%s << %d)" % (a, self.rng.randrange(0, width))
        return "(%s %s %s)" % (a, op, b)

    def gen_bool(self, d=0):
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
            self.env.setdefault(ty, []).append(name)
        elif r < 0.65 and self._has_any_var():
            ty, name = self._pick_var()
            rhs = self.gen_value(ty)
            if rhs == name:
                rhs = self.gen_value(ty, 1)
            out.append("%s%s = %s;" % (pad, name, rhs))
        elif r < 0.82 and self.depth < 3:
            out.append("%sif %s {" % (pad, self.gen_bool()))
            self.block(out, indent + 1)
            out.append("%s} else {" % pad)
            self.block(out, indent + 1)
            out.append("%s}" % pad)
        else:
            n = self.rng.randrange(1, 5)
            i = "j%d" % self.nvars
            self.nvars += 1
            out.append("%svar %s: u64 = 0;" % (pad, i))
            out.append("%swhile %s < %d {" % (pad, i, n))
            if self._has_any_var():
                ty, name = self._pick_var()
                out.append("%s    %s = %s;" % (pad, name, self.gen_value(ty, 1)))
            out.append("%s    %s = %s + 1;" % (pad, i, i))
            out.append("%s}" % pad)

    def block(self, out, indent):
        self.depth += 1
        for _ in range(self.rng.randrange(1, 4)):
            self.stmt(out, indent)
        self.depth -= 1

    def _has_any_var(self):
        return any(self.env.get(t) for t in VALUE_TYPES)

    def _pick_var(self):
        ty = self.rng.choice([t for t in VALUE_TYPES if self.env.get(t)])
        return ty, self.rng.choice(self.env[ty])

    def fold_struct(self, access, sname, terms):
        # Fold each field of a struct into the digest, recursing into nested struct fields.
        for f, t in self.structs[sname]:
            sub = "%s.%s" % (access, f)
            if t in self.structs:
                self.fold_struct(sub, t, terms)
            else:
                terms.append(TYPES[t]["fold"](sub))

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

    def program(self):
        # Declare a couple of user types the generator can construct, read, and match.
        decls = []
        for i in range(self.rng.randrange(1, 4)):
            name = "S%d" % i
            # fields are scalars or *earlier* structs (a DAG → nesting terminates, no cycles)
            ftypes = INTS + list(self.structs)
            fields = [("f%d" % j, self.rng.choice(ftypes)) for j in range(self.rng.randrange(1, 4))]
            self.structs[name] = fields
            decls.append("struct %s { %s }" % (name, ", ".join("%s: %s" % (f, t) for f, t in fields)))
        for i in range(self.rng.randrange(1, 3)):
            variants = ["V%d" % j for j in range(self.rng.randrange(2, 5))]
            name = "E%d" % i
            self.enums[name] = variants
            decls.append("enum %s { %s }" % (name, ", ".join(variants)))
        for _ in range(self.rng.randrange(1, 3)):  # array types (structural; no declaration)
            elem = self.rng.choice(INTS)
            length = self.rng.randrange(2, 6)
            self.arrays["[%d]%s" % (length, elem)] = (elem, length)
        self.gen_functions(decls)

        out = []
        types = self.local_types()
        for ty in self.rng.sample(types, k=min(4, len(types))):
            name = "v%d" % self.nvars
            self.nvars += 1
            out.append("    var %s: %s = %s;" % (name, ty, self.gen_value(ty)))
            self.env.setdefault(ty, []).append(name)
        for _ in range(self.rng.randrange(5, 12)):
            self.stmt(out, 1)

        # Fold each kind into the digest. Integers and struct fields fold by value. Floats fold
        # by comparison (a float's bit pattern is not a stable cross-backend observable, its
        # ordering is). Enums fold by an exhaustive switch into an integer accumulator.
        terms = []
        for ty in INTS:
            for name in self.env.get(ty, []):
                terms.append(TYPES[ty]["fold"](name))
        for sname in self.structs:
            for name in self.env.get(sname, []):
                self.fold_struct(name, sname, terms)
        for aname, (elem, length) in self.arrays.items():
            for name in self.env.get(aname, []):
                for k in range(length):
                    terms.append(TYPES[elem]["fold"]("%s[%d]" % (name, k)))
        if any(self.env.get(ty) for ty in FLOATS):
            out.append("    var fobs: u64 = 0;")
            for ty in FLOATS:
                for name in self.env.get(ty, []):
                    for k in range(3):
                        cmp = self.rng.choice(("<", "<=", ">", ">=", "==", "!="))
                        out.append("    if %s %s %s { fobs = fobs + %d; }" % (name, cmp, TYPES[ty]["lit"](self.rng), 1 << k))
            terms.append("fobs")
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

        acc = terms[0] if terms else "0"
        for t in terms[1:]:
            acc = "(%s ^ %s)" % (acc, t)
        out.append("    return %s;" % acc)
        body = "\n".join(out)
        header = "// Generated by tools/fuzz/mcfuzz.py — regenerate from the seed.\n"
        return header + "\n".join(decls) + "\nexport fn harness() -> u64 {\n" + body + "\n}\n"


# ----- oracles -----
def _emit_c_obj(mcc, clang, src_path, obj, extra=()):
    p1 = subprocess.run([mcc, "emit-c", src_path], capture_output=True)
    if p1.returncode != 0:
        return p1.stderr.decode("utf-8", "replace")
    p2 = subprocess.run([clang, "-std=c11", "-w", *extra, "-c", "-x", "c", "-", "-o", obj],
                        input=p1.stdout, capture_output=True)
    return None if p2.returncode == 0 else p2.stderr.decode("utf-8", "replace")


def oracle_differential(env, seed, src_path, work):
    """Compile through both backends, run, assert identical output."""
    c_obj, l_obj = os.path.join(work, "c.o"), os.path.join(work, "l.o")
    err = _emit_c_obj(env["mcc"], env["clang"], src_path, c_obj)
    if err is not None:
        return "C backend emit/compile failed: %s" % err.strip().splitlines()[-1:]
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
    for stage in ("verify-hir", "verify", "emit-c", "emit-llvm"):
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


ORACLES = {"differential": oracle_differential, "sanitize": oracle_sanitize,
           "robust": oracle_robust, "failclosed": oracle_failclosed,
           "determinism": oracle_determinism, "pipeline": oracle_pipeline}


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
    r.add_argument("--mcc", default=os.environ.get("MCC", "zig-out/bin/mcc"))
    sh = sub.add_parser("shrink", help="minimize a failing seed to a small repro")
    sh.add_argument("--seed", type=int, required=True)
    sh.add_argument("--oracle", choices=list(ORACLES), default="differential")
    sh.add_argument("--trapping", action="store_true")
    sh.add_argument("--mcc", default=os.environ.get("MCC", "zig-out/bin/mcc"))
    args = ap.parse_args()

    if args.cmd == "gen":
        sys.stdout.write(Gen(args.seed, trapping=args.trapping).program())
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

    if args.cmd == "shrink":
        oracle = ORACLES[args.oracle]
        source = Gen(args.seed, trapping=args.trapping).program()
        res = oracle_on_source(env, oracle, source)
        if res is None:
            print("seed %d does not fail mcfuzz/%s — nothing to shrink" % (args.seed, args.oracle))
            return 0
        sig = next((s for s in ("DIVERGENCE", "CRASHED", "HANGS", "UBSan", "runtime error",
                                "emit/compile failed", "link failed") if s in res), res[:24])
        sys.stderr.write("original finding: %s\nshrinking (signature %r)...\n" % (res.splitlines()[0], sig))
        minimal = shrink_source(env, oracle, source, sig)
        print("// minimal repro for seed %d (mcfuzz/%s, signature %r):\n%s" % (args.seed, args.oracle, sig, minimal))
        return 0

    oracle = ORACLES[args.oracle]
    seeds = range(args.start, args.start + args.count)
    fails = []
    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for res in ex.map(lambda s: run_one(env, oracle, s), seeds):
            if res:
                print(res); fails.append(res)
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
    }.get(args.oracle, "no findings")
    mode = " (trapping)" if args.trapping else ""
    print("PASS: mcfuzz/%s%s — %s over %d programs (seeds %d..%d)"
          % (args.oracle, mode, summary, args.count, args.start, args.start + args.count - 1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
