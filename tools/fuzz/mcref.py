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


class RefGen:
    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.scope = {}   # name -> rt (declared top-level vars, in scope for the whole body)
        self.order = []   # declaration order of foldable vars
        self.n = 0

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
        return self

    def source(self):
        lines = ["// Generated by tools/fuzz/mcref.py — reference-interpreter oracle (G1)."]
        lines.append("export fn harness() -> u64 {")
        for s in self.stmts:
            lines += s.render(1)
        terms = [_fold(n, self.scope[n]) for n in self.order]
        acc = terms[0] if terms else "0"
        for t in terms[1:]:
            acc = "(%s ^ %s)" % (acc, t)
        lines.append("    return %s;" % acc)
        lines.append("}")
        return "\n".join(lines) + "\n"

    def evaluate(self):
        """The reference u64 the program must return. Returns an int in [0, 2^64)."""
        env = {}
        try:
            for s in self.stmts:
                s.eval(env)
        except RetSignal as r:
            return r.val & _mask(64)
        acc = 0
        for n in self.order:
            acc ^= (env[n] & _mask(64))
        return acc & _mask(64)


if __name__ == "__main__":
    import sys
    g = RefGen(int(sys.argv[1]) if len(sys.argv) > 1 else 1).build()
    sys.stdout.write(g.source())
    sys.stderr.write("// reference value: %d\n" % g.evaluate())
