#!/usr/bin/env python3
"""mcref — a reference interpreter for the MC unsigned-integer core (G1).

The C-vs-LLVM differential oracles share the whole MC frontend, so a bug in the *shared*
frontend — the constant-folder, the MIR verifier, the domain (wrap/sat) semantics — is invisible
to them: both backends compute the same wrong answer and "agree". This module closes that blind
spot with an INDEPENDENT evaluator.

Design: a single typed AST is rendered two ways —
  * `.render()` emits MC source (compiled and run through a real backend), and
  * `.eval()`   evaluates the *same* AST in pure Python to the expected u64 digest.
Comparing the two catches any divergence in the shared frontend.

Soundness over coverage. The generator emits ONLY constructs the interpreter models exactly:
  * unsigned integer types only (u8/u16/u32/u64/usize) — so `as u64` is unambiguous zero-extension
    and there is no signed-conversion semantic to guess;
  * the `wrap<uN>` (modular) and `sat<uN>` (clamping) domains;
  * only provably trap-free operations (wrapping.add, bitwise, shift-right by a constant < width,
    modular `wrap_from`, and the domains' own arithmetic) — so a runtime trap is necessarily a
    real compiler bug, never a generator artifact;
  * if/else, a bounded counter `while`, and a conditional early return.
Anything outside this core is simply never generated, so the interpreter is never asked to model a
semantic it isn't certain of, and it cannot emit a false finding.
"""
import random

REF_TYPES = {}  # name -> (width, kind)  kind in {"plain","wrap","sat"}
for _w in (8, 16, 32, 64):
    REF_TYPES["u%d" % _w] = (_w, "plain")
    REF_TYPES["wrap<u%d>" % _w] = (_w, "wrap")
    REF_TYPES["sat<u%d>" % _w] = (_w, "sat")
REF_TYPES["usize"] = (64, "plain")

PLAIN = [n for n, (_w, k) in REF_TYPES.items() if k == "plain"]
WRAP = [n for n, (_w, k) in REF_TYPES.items() if k == "wrap"]
SAT = [n for n, (_w, k) in REF_TYPES.items() if k == "sat"]


def _mask(w):
    return (1 << w) - 1


def _fold(name, rt):
    """The u64 fold of a value, matching mcfuzz's digest fold for these types."""
    w, k = REF_TYPES[rt]
    if k == "plain":
        return "((%s) as u64)" % name
    return "((u%d.wrap_from(%s)) as u64)" % (w, name)


class RetSignal(Exception):
    def __init__(self, val):
        self.val = val


# ---- expressions: each node has .render() -> MC source and .eval(env) -> int in [0, 2^w) ----
class Lit:
    def __init__(self, val, rt):
        self.val, self.rt = val, rt

    def render(self):
        return str(self.val)

    def eval(self, env):
        return self.val


class Var:
    def __init__(self, name, rt):
        self.name, self.rt = name, rt

    def render(self):
        return self.name

    def eval(self, env):
        return env[self.name]


class WAdd:  # wrapping.add — modular add, trap-free, plain uint only
    def __init__(self, a, b, rt):
        self.a, self.b, self.rt = a, b, rt

    def render(self):
        return "wrapping.add(%s, %s)" % (self.a.render(), self.b.render())

    def eval(self, env):
        return (self.a.eval(env) + self.b.eval(env)) & _mask(REF_TYPES[self.rt][0])


class Bitwise:  # & | ^ — trap-free, plain uint only
    def __init__(self, op, a, b, rt):
        self.op, self.a, self.b, self.rt = op, a, b, rt

    def render(self):
        return "(%s %s %s)" % (self.a.render(), self.op, self.b.render())

    def eval(self, env):
        x, y = self.a.eval(env), self.b.eval(env)
        return {"&": x & y, "|": x | y, "^": x ^ y}[self.op]


class Shr:  # >> by a constant amount < width — trap-free
    def __init__(self, a, k, rt):
        self.a, self.k, self.rt = a, k, rt

    def render(self):
        return "(%s >> %d)" % (self.a.render(), self.k)

    def eval(self, env):
        return self.a.eval(env) >> self.k


class Conv:  # tyname.wrap_from(<u64 source>) — modular conversion, trap-free
    def __init__(self, rt, src_u64_render, src_u64_val):
        self.rt, self._r, self._v = rt, src_u64_render, src_u64_val

    def render(self):
        return "%s.wrap_from(%s)" % (self.rt, self._r)

    def eval(self, env):
        return self._v(env) & _mask(REF_TYPES[self.rt][0])


class DomBin:  # wrap/sat domain arithmetic, operands share the domain type
    def __init__(self, op, a, b, rt):
        self.op, self.a, self.b, self.rt = op, a, b, rt

    def render(self):
        return "(%s %s %s)" % (self.a.render(), self.op, self.b.render())

    def eval(self, env):
        w, k = REF_TYPES[self.rt]
        m = _mask(w)
        x, y = self.a.eval(env), self.b.eval(env)
        if k == "wrap":
            return {"+": (x + y) & m, "-": (x - y) & m, "*": (x * y) & m,
                    "&": x & y, "|": x | y, "^": x ^ y}[self.op]
        # sat: clamp to [0, max]
        if self.op == "+":
            return min(x + y, m)
        if self.op == "-":
            return max(x - y, 0)
        return min(x * y, m)  # "*"


class DomShr:  # wrap >> constant
    def __init__(self, a, k, rt):
        self.a, self.k, self.rt = a, k, rt

    def render(self):
        return "(%s >> %d)" % (self.a.render(), self.k)

    def eval(self, env):
        return self.a.eval(env) >> self.k


class Cmp:  # comparison -> bool
    def __init__(self, op, a, b):
        self.op, self.a, self.b = op, a, b

    def render(self):
        return "(%s %s %s)" % (self.a.render(), self.op, self.b.render())

    def eval(self, env):
        x, y = self.a.eval(env), self.b.eval(env)
        return {"<": x < y, "<=": x <= y, ">": x > y, ">=": x >= y,
                "==": x == y, "!=": x != y}[self.op]


class BoolBin:  # && / ||
    def __init__(self, op, a, b):
        self.op, self.a, self.b = op, a, b

    def render(self):
        return "(%s %s %s)" % (self.a.render(), self.op, self.b.render())

    def eval(self, env):
        if self.op == "&&":
            return self.a.eval(env) and self.b.eval(env)
        return self.a.eval(env) or self.b.eval(env)


# ---- statements: .render(indent) -> [lines], .eval(env) may raise RetSignal ----
class Decl:
    def __init__(self, name, rt, expr):
        self.name, self.rt, self.expr = name, rt, expr

    def render(self, ind):
        return ["%svar %s: %s = %s;" % ("    " * ind, self.name, self.rt, self.expr.render())]

    def eval(self, env):
        env[self.name] = self.expr.eval(env)


class Assign:
    def __init__(self, name, expr):
        self.name, self.expr = name, expr

    def render(self, ind):
        return ["%s%s = %s;" % ("    " * ind, self.name, self.expr.render())]

    def eval(self, env):
        env[self.name] = self.expr.eval(env)


class If:
    def __init__(self, cond, then, els):
        self.cond, self.then, self.els = cond, then, els

    def render(self, ind):
        pad = "    " * ind
        lines = ["%sif %s {" % (pad, self.cond.render())]
        for s in self.then:
            lines += s.render(ind + 1)
        lines.append("%s} else {" % pad)
        for s in self.els:
            lines += s.render(ind + 1)
        lines.append("%s}" % pad)
        return lines

    def eval(self, env):
        for s in (self.then if self.cond.eval(env) else self.els):
            s.eval(env)


class While:
    def __init__(self, counter, bound, body):
        self.counter, self.bound, self.body = counter, bound, body

    def render(self, ind):
        pad = "    " * ind
        lines = ["%svar %s: u64 = 0;" % (pad, self.counter),
                 "%swhile %s < %d {" % (pad, self.counter, self.bound),
                 "%s    %s = %s + 1;" % (pad, self.counter, self.counter)]
        for s in self.body:
            lines += s.render(ind + 1)
        lines.append("%s}" % pad)
        return lines

    def eval(self, env):
        env[self.counter] = 0
        while env[self.counter] < self.bound:
            env[self.counter] += 1  # increment-first, matching the rendered loop
            for s in self.body:
                s.eval(env)


class EarlyRet:
    def __init__(self, cond, val_render, val_eval):
        self.cond, self._r, self._v = cond, val_render, val_eval

    def render(self, ind):
        return ["%sif %s { return %s; }" % ("    " * ind, self.cond.render(), self._r)]

    def eval(self, env):
        if self.cond.eval(env):
            raise RetSignal(self._v(env) & _mask(64))


# ---------------------------------------------------------------------------
# V3.1: memory-layout + switch-family constructs.
#
# These are the constructs with SEPARATE per-backend lower_c / lower_llvm code paths
# (offset/overlay reads, the switch families) — the class where the overlay-read miscompile
# hid because the C-vs-LLVM differential oracle was blind to it (both backends agreed and were
# wrong). The reference oracle is the only one that sees a SHARED-frontend bug, so we model each
# of these constructs in pure Python from an INDEPENDENT layout/semantics ground truth (not by
# re-asking the compiler) and fold the result into the harness digest. A divergence between the
# compiled output and this independent value is therefore a real miscompile.
#
# All modeled little-endian: the reference oracle compiles+runs through the C backend on the
# little-endian host, matching mcfuzz's existing overlay folding (`u == sum(bytes[k] << 8*k)`).

def _align_up(x, a):
    return (x + a - 1) // a * a


class OffsetStruct:
    """An `extern mmio struct` with explicit `@offset(N)` fields. Observed PURELY through comptime
    folding (`sizeof`, `field_offset`) — not host-runnable (volatile MMIO), but the layout the
    comptime path computes is fully visible. Layout ground truth (verified empirically against the
    compiler): field_offset(.f) == the pinned offset; sizeof == align_up(last_off + last_width_bytes,
    max field alignment), where a Reg<uN,..> field has size and alignment N/8 bytes."""

    def __init__(self, name, fields):
        self.name = name
        self.fields = fields  # [(fname, width_bits, offset_bytes, mode)]

    def sizeof(self):
        _lf, lastw, lastoff, _m = self.fields[-1]
        align = max(w // 8 for _f, w, _o, _m in self.fields)
        return _align_up(lastoff + lastw // 8, align)

    def field_offset(self, fname):
        for f, _w, o, _m in self.fields:
            if f == fname:
                return o
        raise KeyError(fname)

    def decl(self):
        body = "\n".join("    %s: Reg<u%d, %s> @offset(%d)," % (f, w, m, o)
                         for f, w, o, m in self.fields)
        return "extern mmio struct %s {\n%s\n}" % (self.name, body)


class OverlayUnion:
    """An `overlay union` (byte-aliasing storage). Host-runnable: write the scalar member, read the
    aliased byte-view (`bytes[i]`) and non-byte-view (`halves[i]`) members back. Reinterpret ground
    truth (little-endian): bytes[k] = (u >> 8*k) & 0xff; halves[k] = (u >> 16*k) & 0xffff. Writing a
    half overwrites the corresponding 16-bit lane of the backing storage. sizeof == widest member
    == the scalar width in bytes."""

    def __init__(self, name, width_bits):
        self.name = name
        self.width = width_bits
        self.nbytes = width_bits // 8
        self.nhalves = width_bits // 16

    def decl(self):
        body = ("    u: u%d,\n    bytes: [%d]u8,\n    halves: [%d]u16,"
                % (self.width, self.nbytes, self.nhalves))
        return "overlay union %s {\n%s\n}" % (self.name, body)


class RefGen:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.scope = {}   # name -> rt (declared top-level vars, in scope for the whole body)
        self.order = []   # declaration order of foldable vars
        self.n = 0
        # V3.1: layout/switch-family constructs and the extra (decls, body, fold-terms) they emit.
        self.pre_decls = []      # top-level decl source emitted before harness()
        self.extra_body = []     # extra harness-body lines (rendered after the core stmts)
        self.extra_terms = []    # (varname, expected_u64) folded into the digest

    def _lit_val(self, w):
        m = _mask(w)
        corners = [0, 1, 2, m, m - 1, m >> 1, (m >> 1) + 1]
        return self.rng.choice(corners) if self.rng.random() < 0.4 else self.rng.randint(0, m)

    def _vars_of(self, rt):
        return [n for n, t in self.scope.items() if t == rt]

    def _leaf(self, rt):
        live = self._vars_of(rt)
        if live and self.rng.random() < 0.6:
            return Var(self.rng.choice(live), rt)
        return Lit(self._lit_val(REF_TYPES[rt][0]), rt)

    def _u64_source(self):
        # An expression of type u64 (rendered + a Python evaluator), used as a wrap_from source.
        ints = [n for n in self.scope if True]
        if ints and self.rng.random() < 0.7:
            name = self.rng.choice(ints)
            rt = self.scope[name]
            return _fold(name, rt), (lambda e, nm=name: e[nm])
        v = self.rng.randint(0, _mask(64))
        return str(v), (lambda e, val=v: val)

    def gen_expr(self, rt):
        w, k = REF_TYPES[rt]
        if k == "plain":
            choice = self.rng.choice(["leaf", "wadd", "bitwise", "shr", "conv"])
            if choice == "leaf":
                return self._leaf(rt)
            if choice == "wadd":
                live = self._vars_of(rt)
                if not live:
                    return self._leaf(rt)
                return WAdd(Var(self.rng.choice(live), rt), self._leaf(rt), rt)
            if choice == "bitwise":
                return Bitwise(self.rng.choice(["&", "|", "^"]), self._leaf(rt), self._leaf(rt), rt)
            if choice == "shr":
                return Shr(self._leaf(rt), self.rng.randrange(0, w), rt)
            r, v = self._u64_source()
            return Conv(rt, r, v)
        # wrap / sat domains: operands must share the domain type
        live = self._vars_of(rt)
        if len(live) >= 1 and self.rng.random() < 0.6:
            if k == "wrap":
                op = self.rng.choice(["+", "-", "*", "&", "|", "^"])
            else:
                op = self.rng.choice(["+", "-", "*"])
            return DomBin(op, Var(self.rng.choice(live), rt), Var(self.rng.choice(live), rt), rt)
        if k == "wrap" and live and self.rng.random() < 0.3:
            return DomShr(Var(self.rng.choice(live), rt), self.rng.randrange(0, w), rt)
        return self._leaf(rt)

    def gen_cond(self, d=0):
        if d < 2 and self.rng.random() < 0.25:
            return BoolBin(self.rng.choice(["&&", "||"]), self.gen_cond(d + 1), self.gen_cond(d + 1))
        # A comparison between two same-type operands. Plain uints may compare against a literal;
        # a *domain* value (wrap/sat) cannot compare to a plain int literal (E_OPERATOR_OPERAND),
        # so a domain comparison needs two live vars of that exact domain type. wrap supports only
        # equality; sat and plain support ordering too.
        types = list(dict.fromkeys(self.scope.values()))
        plain_cand = [t for t in types if REF_TYPES[t][1] == "plain" and self._vars_of(t)]
        dom_cand = [t for t in types if REF_TYPES[t][1] != "plain" and len(self._vars_of(t)) >= 2]
        use_dom = dom_cand and (not plain_cand or self.rng.random() < 0.4)
        if use_dom:
            rt = self.rng.choice(dom_cand)
            pool = self._vars_of(rt)
            a, b = Var(self.rng.choice(pool), rt), Var(self.rng.choice(pool), rt)
            ops = ["==", "!="] if REF_TYPES[rt][1] == "wrap" else ["<", "<=", ">", ">=", "==", "!="]
            return Cmp(self.rng.choice(ops), a, b)
        if not plain_cand:
            return Cmp("==", Lit(1, "u8"), Lit(1, "u8"))  # trivially-true fallback
        rt = self.rng.choice(plain_cand)
        pool = self._vars_of(rt)
        a = Var(self.rng.choice(pool), rt)
        if len(pool) > 1 and self.rng.random() < 0.5:
            b = Var(self.rng.choice(pool), rt)
        else:
            b = Lit(self._lit_val(REF_TYPES[rt][0]), rt)
        return Cmp(self.rng.choice(["<", "<=", ">", ">=", "==", "!="]), a, b)

    def _new(self, prefix="v"):
        name = "%s%d" % (prefix, self.n)
        self.n += 1
        return name

    def gen_block(self, depth):
        # Inside a nested block only assignments / nested ifs / early returns (no new top-level
        # decls), so the eval env stays flat — matching mcfuzz's depth-0 declaration rule.
        stmts = []
        for _ in range(self.rng.randrange(1, 3)):
            r = self.rng.random()
            if r < 0.55 and self.scope:
                rt = self.rng.choice(list(self.scope.values()))
                name = self.rng.choice(self._vars_of(rt))
                stmts.append(Assign(name, self.gen_expr(rt)))
            elif r < 0.75 and depth < 3:
                stmts.append(If(self.gen_cond(), self.gen_block(depth + 1), self.gen_block(depth + 1)))
            else:
                r2, v2 = self._u64_source()
                stmts.append(EarlyRet(self.gen_cond(), r2, v2))
        return stmts

    def build(self):
        stmts = []
        # initial declarations across the type families
        names = list(REF_TYPES)
        for rt in self.rng.sample(names, k=min(6, len(names))):
            name = self._new()
            stmts.append(Decl(name, rt, self.gen_expr(rt)))
            self.scope[name] = rt
            self.order.append(name)
        # a body of statements
        for _ in range(self.rng.randrange(5, 11)):
            r = self.rng.random()
            if r < 0.4 and self.scope:
                rt = self.rng.choice(list(self.scope.values()))
                name = self.rng.choice(self._vars_of(rt))
                stmts.append(Assign(name, self.gen_expr(rt)))
            elif r < 0.65:
                stmts.append(If(self.gen_cond(), self.gen_block(1), self.gen_block(1)))
            elif r < 0.8:
                counter = self._new("j")
                stmts.append(While(counter, self.rng.randrange(1, 5), self.gen_block(1)))
                # the counter is a live u64 var afterwards
                self.scope[counter] = "u64"
                self.order.append(counter)
            else:
                r2, v2 = self._u64_source()
                stmts.append(EarlyRet(self.gen_cond(), r2, v2))
        self.stmts = stmts
        self.gen_constructs()
        return self

    # ---- V3.1: offset / overlay / switch-family constructs -------------------------------------
    def gen_constructs(self):
        """Generate the divergence-prone layout + switch-family constructs into a self-contained
        helper `ref_extra() -> u64`. The helper has NO early returns and is always fully evaluated,
        so its value is observed on every harness path (the core's early-return XORs it in too). For
        each construct we compute the expected u64 from an INDEPENDENT Python model (layout/reinterpret/
        switch semantics) — never by re-asking the compiler — and fold it into the digest."""
        self.gen_offset_structs()
        self.gen_overlays()
        self.gen_switch_families()

    def gen_offset_structs(self):
        REGW = (8, 16, 32)
        for i in range(self.rng.randrange(1, 3)):
            name = "OFF%d" % self.n
            self.n += 1
            nf = self.rng.randrange(2, 5)
            fields = []
            off = 0
            for j in range(nf):
                w = self.rng.choice(REGW)
                sz = w // 8
                mode = self.rng.choice((".read", ".write", ".read_write"))
                if j == 0:
                    cur = 0
                elif self.rng.random() < 0.5:
                    cur = off                       # tightly packed: offset == running offset
                else:
                    cur = off + self.rng.choice((sz, 8, 16, 64, 0x100))  # large/odd gap
                if cur % sz != 0:                   # respect the field's natural alignment
                    cur += sz - (cur % sz)
                fields.append(("of%d" % j, w, cur, mode))
                off = cur + sz
            s = OffsetStruct(name, fields)
            self.pre_decls.append(s.decl())
            # comptime observers: sizeof(S) and field_offset(S, .f) for every field, folded.
            self.pre_decls.append(
                "fn offobs_%s() -> u64 {\n    return %s;\n}"
                % (name, self._offset_fold_expr(s)))
            tn = "off_%s" % name
            self.extra_body.append("    var %s: u64 = offobs_%s();" % (tn, name))
            self.extra_terms.append((tn, self._offset_fold_val(s)))
            # Layout identity (must hold): field_offset(.last) + last_width_bytes <= sizeof(S).
            lastf, lastw, _lo, _m = fields[-1]
            idn = "offid_%s" % name
            self.extra_body.append("    var %s: u64 = 0;" % idn)
            self.extra_body.append(
                "    if ((field_offset(%s, .%s) as u64) + %d) <= (sizeof(%s) as u64) "
                "{ %s = 1; }" % (name, lastf, lastw // 8, name, idn))
            assert (s.field_offset(lastf) + lastw // 8) <= s.sizeof()
            self.extra_terms.append((idn, 1))

    def _offset_fold_expr(self, s):
        parts = ["(sizeof(%s) as u64)" % s.name]
        for k, (f, _w, _o, _m) in enumerate(s.fields):
            parts.append("((field_offset(%s, .%s) as u64) << %d)" % (s.name, f, (k + 1) * 4))
        return " ^ ".join(parts)

    def _offset_fold_val(self, s):
        v = s.sizeof() & _mask(64)
        for k, (f, _w, _o, _m) in enumerate(s.fields):
            v ^= (s.field_offset(f) << ((k + 1) * 4))
        return v & _mask(64)

    def gen_overlays(self):
        for i in range(self.rng.randrange(1, 3)):
            name = "OV%d" % self.n
            self.n += 1
            w = self.rng.choice((32, 64))
            o = OverlayUnion(name, w)
            self.pre_decls.append(o.decl())
            # Independent reinterpret model (little-endian).
            uval = self.rng.randrange(1, 1 << min(w, 32))
            bytes_ = [(uval >> (8 * k)) & 0xff for k in range(o.nbytes)]
            halves = [(uval >> (16 * k)) & 0xffff for k in range(o.nhalves)]
            vn = "ovv_%s" % name
            self.extra_body.append("    var %s: %s = uninit;" % (vn, name))
            self.extra_body.append("    %s.u = %d;" % (vn, uval))
            acc = "ovo_%s" % name
            exp = uval & _mask(64)
            # Scalar member read in expression position.
            self.extra_body.append("    var %s: u64 = (%s.u as u64);" % (acc, vn))
            # Byte-view reads (each lane shifted), exercising the byte-view lowering.
            for k in range(o.nbytes):
                self.extra_body.append("    %s = (%s ^ ((%s.bytes[%d] as u64) << %d));"
                                       % (acc, acc, vn, k, (k % 8) * 8))
                exp ^= (bytes_[k] << ((k % 8) * 8))
            # Non-byte (`[N]u16`) view reads in expression position.
            for k in range(o.nhalves):
                self.extra_body.append("    %s = (%s ^ ((%s.halves[%d] as u64) << %d));"
                                       % (acc, acc, vn, k, (k % 4) * 16))
                exp ^= (halves[k] << ((k % 4) * 16))
            # Non-byte view WRITE, then read back: overwrite one 16-bit lane, re-observe it.
            hidx = self.rng.randrange(0, o.nhalves)
            hval = self.rng.randrange(1, 1 << 16)
            self.extra_body.append("    %s.halves[%d] = %d;" % (vn, hidx, hval))
            self.extra_body.append("    %s = (%s ^ ((%s.halves[%d] as u64) << 3));"
                                   % (acc, acc, vn, hidx))
            exp ^= (hval << 3)
            # sizeof of the overlay (storage size == widest member == the scalar width in bytes).
            self.extra_body.append("    %s = (%s ^ ((sizeof(%s) as u64) << 4));" % (acc, acc, name))
            exp ^= (o.nbytes << 4)
            self.extra_terms.append((acc, exp & _mask(64)))

    def gen_switch_families(self):
        """The four switch families that have separate per-backend lowering: scalar (integer)
        switch, closed-enum expression-switch, Result<T,E> ok/err switch, and tagged-union switch
        (incl. a payloadless `nullable`-style empty arm). Each is exhaustive and folds to a u64 we
        compute independently."""
        self._gen_scalar_switch()
        self._gen_enum_switch()
        self._gen_result_switch()
        self._gen_union_switch()

    def _gen_scalar_switch(self):
        # `switch <u32 literal>` over explicit integer patterns + `_` wildcard, in stmt position.
        cases = sorted(self.rng.sample(range(0, 8), k=3))
        subj = self.rng.choice(cases + [99])  # may hit the wildcard
        vn = "scsw%d" % self.n
        self.n += 1
        self.extra_body.append("    var %s: u32 = %d;" % (vn, subj))
        out = "scswr%d" % self.n
        self.n += 1
        self.extra_body.append("    var %s: u64 = 0;" % out)
        self.extra_body.append("    switch %s {" % vn)
        for k, c in enumerate(cases):
            self.extra_body.append("        %d => { %s = %d; }" % (c, out, (k + 1) * 11))
        self.extra_body.append("        _ => { %s = 7; }" % out)
        self.extra_body.append("    }")
        exp = 7
        for k, c in enumerate(cases):
            if subj == c:
                exp = (k + 1) * 11
        self.extra_terms.append((out, exp))

    def _gen_enum_switch(self):
        # A closed enum + expression-`switch` in return position (helper) AND initializer position.
        ename = "RE%d" % self.n
        self.n += 1
        variants = ["V%d" % k for k in range(self.rng.randrange(2, 5))]
        self.pre_decls.append("enum %s {\n%s\n}" % (ename, "\n".join("    %s," % v for v in variants)))
        arms = ", ".join(".%s => %d" % (v, (k + 1) * 13) for k, v in enumerate(variants))
        self.pre_decls.append("fn eswf_%s(e: %s) -> u64 {\n    return switch e { %s };\n}"
                              % (ename, ename, arms))
        pick = self.rng.randrange(0, len(variants))
        ev = "esv%d" % self.n
        self.n += 1
        self.extra_body.append("    var %s: %s = .%s;" % (ev, ename, variants[pick]))
        # return-position helper
        rv = "esr%d" % self.n
        self.n += 1
        self.extra_body.append("    var %s: u64 = eswf_%s(%s);" % (rv, ename, ev))
        self.extra_terms.append((rv, (pick + 1) * 13))
        # initializer-position expression switch (different constants)
        arms2 = ", ".join(".%s => %d" % (v, (k + 1) * 17) for k, v in enumerate(variants))
        iv = "esi%d" % self.n
        self.n += 1
        self.extra_body.append("    var %s: u64 = switch %s { %s };" % (iv, ev, arms2))
        self.extra_terms.append((iv, (pick + 1) * 17))

    def _gen_result_switch(self):
        # A `Result<u32, u32>` helper, switched ok(v)/err(e) — the Result switch family.
        fn = "rfn%d" % self.n
        self.n += 1
        is_ok = self.rng.random() < 0.5
        okv = self.rng.randrange(0, 1 << 20)
        errv = self.rng.randrange(0, 1 << 20)
        body = "    return ok(%d);" % okv if is_ok else "    return err(%d);" % errv
        self.pre_decls.append("fn %s() -> Result<u32, u32> {\n%s\n}" % (fn, body))
        out = "rsw%d" % self.n
        self.n += 1
        self.extra_body.append("    var %s: u64 = 0;" % out)
        self.extra_body.append("    switch %s() {" % fn)
        self.extra_body.append("        ok(v) => { %s = (v as u64); }" % out)
        self.extra_body.append("        err(e) => { %s = ((e as u64) ^ 1000); }" % out)
        self.extra_body.append("    }")
        self.extra_terms.append((out, okv if is_ok else (errv ^ 1000)))

    def _gen_union_switch(self):
        # A tagged union with int-payload cases + a payloadless empty arm (the `nullable`-style
        # no-payload tag), folded via a switch helper.
        uname = "RU%d" % self.n
        self.n += 1
        ncases = self.rng.randrange(2, 4)
        cases = [("uc%d_%d" % (self.n, j), self.rng.choice([8, 16, 32, 64]))
                 for j in range(ncases)]
        empty = "ue%d" % self.n if self.rng.random() < 0.5 else None
        lines = ["    %s: u%d," % (cn, w) for cn, w in cases]
        if empty:
            lines.append("    %s," % empty)
        self.pre_decls.append("union %s {\n%s\n}" % (uname, "\n".join(lines)))
        arms = ["        %s(b) => { return (b as u64); }" % cn for cn, _w in cases]
        if empty:
            arms.append("        .%s => { return 7; }" % empty)
        self.pre_decls.append("fn ufold_%s(s: %s) -> u64 {\n    switch s {\n%s\n    }\n}"
                              % (uname, uname, "\n".join(arms)))
        # construct one value (case or empty) and fold it
        opts = list(cases) + ([(empty, None)] if empty else [])
        cn, w = self.rng.choice(opts)
        if w is None:
            ctor = "%s()" % cn
            exp = 7
        else:
            pv = self.rng.randrange(0, 1 << min(w, 32))
            ctor = "%s(%d)" % (cn, pv)
            exp = pv
        uv = "uv%d" % self.n
        self.n += 1
        self.extra_body.append("    var %s: %s = %s;" % (uv, uname, ctor))
        fv = "ufv%d" % self.n
        self.n += 1
        self.extra_body.append("    var %s: u64 = ufold_%s(%s);" % (fv, uname, uv))
        self.extra_terms.append((fv, exp))

    def _extra_value(self):
        """Independent u64 value the `ref_extra()` helper must return (XOR of all extra terms)."""
        acc = 0
        for _name, val in self.extra_terms:
            acc ^= (val & _mask(64))
        return acc & _mask(64)

    def source(self):
        lines = ["// Generated by tools/fuzz/mcref.py — reference-interpreter oracle (G1)."]
        # V3.1: top-level decls for the offset/overlay/switch-family constructs.
        for d in self.pre_decls:
            lines.append(d)
        # The unsigned-integer core, isolated in a helper so its early returns can't skip the
        # extra-construct observations (the C-vs-LLVM-blind layout/switch lowering).
        lines.append("fn ref_core() -> u64 {")
        for s in self.stmts:
            lines += s.render(1)
        terms = [_fold(n, self.scope[n]) for n in self.order]
        acc = terms[0] if terms else "0"
        for t in terms[1:]:
            acc = "(%s ^ %s)" % (acc, t)
        lines.append("    return %s;" % acc)
        lines.append("}")
        # V3.1: the offset/overlay/switch-family observations, always fully evaluated.
        lines.append("fn ref_extra() -> u64 {")
        lines += self.extra_body
        eterms = [n for n, _v in self.extra_terms]
        eacc = eterms[0] if eterms else "0"
        for t in eterms[1:]:
            eacc = "(%s ^ %s)" % (eacc, t)
        lines.append("    return %s;" % eacc)
        lines.append("}")
        lines.append("export fn harness() -> u64 {")
        lines.append("    return (ref_core() ^ ref_extra());")
        lines.append("}")
        return "\n".join(lines) + "\n"

    def evaluate(self):
        """The reference u64 the program must return. Returns an int in [0, 2^64)."""
        env = {}
        core = None
        try:
            for s in self.stmts:
                s.eval(env)
        except RetSignal as r:
            core = r.val & _mask(64)
        if core is None:
            core = 0
            for n in self.order:
                core ^= (env[n] & _mask(64))
        return (core ^ self._extra_value()) & _mask(64)


if __name__ == "__main__":
    import sys
    g = RefGen(int(sys.argv[1]) if len(sys.argv) > 1 else 1).build()
    sys.stdout.write(g.source())
    sys.stderr.write("// reference value: %d\n" % g.evaluate())
