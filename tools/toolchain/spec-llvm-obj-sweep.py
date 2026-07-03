#!/usr/bin/env python3
"""LLVM object-output sweep over the valid spec conformance corpus.

For every tests/spec/*.mc fixture, drop the functions/declarations that carry
an EXPECT_ERROR comment, normalize top-level `fn foo(...);` prototypes to
`extern fn foo(...);`, then `emit-llvm` the remaining valid declarations and
compile the textual IR to a non-empty object file with llc.

The sweep also rejects hidden optimizer-assumption tokens that the LLVM
appendix forbids outside proven verifier conditions, so it can stand alone as
an object-output gate for the valid spec corpus.

Usage:
    tools/toolchain/spec-llvm-obj-sweep.py [<mcc-binary> [<spec-dir> [<out-dir>]]]

Defaults: zig-out/bin/mcc, tests/spec, zig-out/llvm-spec-obj-sweep.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile
from spec_sweep_lib import valid_program  # shared comment-aware negative-fixture stripping

FORBIDDEN_ASSUMPTIONS = ("nuw", "nsw", "nonnull", "noalias", "noundef", "poison", "inbounds", "undef", "fast", "nnan", "ninf", "nsz", "arcp", "contract", "afn")
FORBIDDEN_RE = re.compile(r"(^|[ ,(])(" + "|".join(FORBIDDEN_ASSUMPTIONS) + r")([ ,)]|$)")
REASSOC_RE = re.compile(r"(^|[ ,(])reassoc([ ,)]|$)")

# emit-llvm emits no target triple, so llc would otherwise inherit the HOST default
# (e.g. aarch64 in the arm64 dev container) and fail to assemble the inline asm the
# precise-asm fixtures carry — a host-dependent result. Pin one triple so the object
# step is deterministic; the fixtures' valid asm is x86-64 and all non-asm fixtures
# emit target-neutral IR that assembles for any triple.
OBJ_TRIPLE = "x86_64-unknown-none"

# Same contract as spec-llvm-sweep.py's OUT_OF_SCOPE (kept in parity): phase=sema
# DIAGNOSTIC fixtures whose `check=` is a sema diagnostic (E_*), never a `lower-*`
# check, so their accept+reject contract is owned by src/spec_tests.zig, not by backend
# object emission. A fixture carrying a real `lower-*` check must NEVER be added here.
OUT_OF_SCOPE = {
    "error_from_ambiguous.mc": "pure compile_error fixture; module-level ambiguity check the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_AMBIGUOUS_ERROR_CONVERSION owned by spec_tests.zig)",
    "error_from_malformed.mc": "pure compile_error fixture; malformed-decl check the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_INVALID_ERROR_FROM owned by spec_tests.zig)",
    "monomorphization_limits.mc": "pure compile_error fixture; polymorphic-recursion limit check the chunk-level EXPECT_ERROR strip cannot isolate (phase=parse,sema; E_MONOMORPHIZATION_LIMIT owned by spec_tests.zig)",
    "pointer_view_conversions.mc": "accept/reject pointer+view const-narrow cases share types the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_NO_IMPLICIT_POINTER_CONVERSION owned by spec_tests.zig; accept emit covered by tests/c_emit/pointer_views.mc + pointer_const_narrow.mc)",
    "soundness_address_class_cast.mc": "checker-only address-class cast has no IR lowering (phase=sema; E_ADDRESS_CLASS_* owned by spec_tests.zig)",
    "soundness_use_after_move.mc": "accept/reject cases share move-typed defs the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_USE_AFTER_MOVE owned by spec_tests.zig)",
    "soundness_conservative_overrejection.mc": "shared move-typed defs across accept/reject (phase=sema; E_USE_AFTER_MOVE owned by spec_tests.zig)",
    "soundness_opaque_declassify.mc": "accept/reject cases share opaque defs (phase=sema; E_OPAQUE_DECLASSIFY owned by spec_tests.zig)",
    "soundness_guard_opaque_reject.mc": "opaque private-field reject fixture; positive impl cannot be chunk-isolated (phase=sema; E_PRIVATE_FIELD owned by spec_tests.zig)",
    "soundness_orphan_impl_reject.mc": "orphan-impl reject fixture (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "traits_effect_sleep_in_atomic.mc": "effect-typed callees are EXPECT_ERROR-stripped, leaving dangling refs (phase=parse,sema; E_SLEEP_IN_ATOMIC owned by spec_tests.zig)",
}


def first_error(stderr):
    return next((l for l in stderr.splitlines() if "error:" in l), stderr.splitlines()[0] if stderr else "?").strip()


def forbidden_assumption(ir, source):
    for line_no, line in enumerate(ir.splitlines(), 1):
        match = FORBIDDEN_RE.search(line)
        if match:
            return match.group(2), line_no, line.strip()
        if REASSOC_RE.search(line) and not ("fadd reassoc" in line and "reduce.sum_fast" in source):
            return "reassoc", line_no, line.strip()
    return None


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/mcc"
    spec_dir = sys.argv[2] if len(sys.argv) > 2 else "tests/spec"
    out_dir = sys.argv[3] if len(sys.argv) > 3 else "zig-out/llvm-spec-obj-sweep"

    if subprocess.run(["sh", "-c", "command -v llc >/dev/null 2>&1"]).returncode != 0:
        print("SKIP: llvm-spec-obj-sweep (llc not found)")
        return 0

    os.makedirs(out_dir, exist_ok=True)
    failures, oos_failures, swept, kept_fns = [], [], 0, 0
    for path in sorted(glob.glob(os.path.join(spec_dir, "*.mc"))):
        name = os.path.basename(path)
        stem = os.path.splitext(name)[0]
        out_path = os.path.join(out_dir, stem + ".o")
        swept += 1
        program = valid_program(open(path).read())
        kept_fns += len(re.findall(r"\bfn\s+\w+", program))

        with tempfile.NamedTemporaryFile("w", suffix=".mc", delete=False) as tmp:
            tmp.write(program)
            tmp_path = tmp.name
        try:
            emit = subprocess.run([mcc, "emit-llvm", tmp_path], capture_output=True, text=True)
            if emit.returncode != 0:
                failures.append((name, "EMIT", first_error(emit.stderr)))
                continue
            forbidden = forbidden_assumption(emit.stdout, program)
            if forbidden:
                token, line_no, line = forbidden
                failures.append((name, "ASSUMPTION", f"forbidden LLVM assumption token '{token}' at line {line_no}: {line}"))
                continue
            compile_obj = subprocess.run(["llc", "-mtriple=" + OBJ_TRIPLE, "-filetype=obj", "-o", out_path], input=emit.stdout, capture_output=True, text=True)
            if compile_obj.returncode != 0:
                failures.append((name, "LLC", first_error(compile_obj.stderr)))
                continue
            if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
                failures.append((name, "OBJECT", "empty or missing object output"))
        finally:
            os.unlink(tmp_path)

    oos_failures = [f for f in failures if f[0] in OUT_OF_SCOPE]
    failures = [f for f in failures if f[0] not in OUT_OF_SCOPE]

    print(f"spec fixtures swept: {swept}, valid functions compiled to LLVM objects: {kept_fns}")
    if oos_failures:
        print("known out-of-scope fixtures (allowlisted, not failing the gate):")
        for name, kind, message in oos_failures:
            print(f"  [{kind}] {name}: {message}\n        reason: {OUT_OF_SCOPE[name]}")
    if failures:
        print(f"FAIL: {len(failures)} valid spec fixture(s) did not compile to LLVM objects:")
        for name, kind, message in failures:
            print(f"  [{kind}] {name}: {message}")
        return 1
    print("PASS: all in-scope valid spec fixtures compile to LLVM object files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
