#!/usr/bin/env python3
"""Empirical LLVM-emission sweep over the spec conformance corpus.

For every tests/spec/*.mc fixture, drop the functions/declarations that carry
an EXPECT_ERROR comment, normalize top-level `fn foo(...);` prototypes to
`extern fn foo(...);`, then `emit-llvm` the remaining valid declarations and
assemble the textual IR with llvm-as, and reject hidden optimizer-assumption
tokens that the LLVM appendix forbids outside proven verifier conditions.

The allowlist is restricted to checker-owned diagnostic fixtures whose
accept/reject shape cannot be chunk-isolated by the sweep. Any valid-spec LLVM
failure outside that documented set fails the gate.

Usage:
    tools/toolchain/spec-llvm-sweep.py [<mcc-binary> [<spec-dir>]]

Defaults: zig-out/bin/mcc, tests/spec.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile
from spec_sweep_lib import valid_program  # shared comment-aware negative-fixture stripping

# Same contract as spec-emit-sweep.py's OUT_OF_SCOPE (kept in parity): phase=sema /
# phase=parse DIAGNOSTIC fixtures whose `check=` is a sema diagnostic (E_*), never a
# `lower-*` check, so their accept+reject contract is owned by src/spec_tests.zig, not
# by backend emission. Their positive ("accept") declarations either use checker-only
# types with no IR lowering, or share opaque/move/address-class type definitions with
# their EXPECT_ERROR ("reject") twins that the chunk-level strip cannot separate. A
# fixture carrying a real `lower-*` check must NEVER be added here.
OUT_OF_SCOPE = {
    "error_from_ambiguous.mc": "pure compile_error fixture; module-level ambiguity check the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_AMBIGUOUS_ERROR_CONVERSION owned by spec_tests.zig)",
    "error_from_malformed.mc": "pure compile_error fixture; malformed-decl check the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_INVALID_ERROR_FROM owned by spec_tests.zig)",
    "import_not_found_reject.mc": "pure import-loader diagnostic; top-level inline EXPECT_ERROR after the import semicolon cannot be chunk-isolated by the sweep (phase=parse; E_IMPORT_NOT_FOUND owned by spec_tests.zig)",
    "import_outside_sandbox_reject.mc": "pure import-loader diagnostic; top-level inline EXPECT_ERROR after the import semicolon cannot be chunk-isolated by the sweep (phase=parse; E_IMPORT_OUTSIDE_SANDBOX owned by spec_tests.zig)",
    "monomorphization_limits.mc": "pure compile_error fixture; polymorphic-recursion limit check the chunk-level EXPECT_ERROR strip cannot isolate (phase=parse,sema; E_MONOMORPHIZATION_LIMIT owned by spec_tests.zig)",
    "monomorphize_pattern_type_mentions.mc": "pure sema diagnostic; stripping the rejected generic body leaves its caller dangling (phase=parse,sema; E_NO_IMPLICIT_CONVERSION owned by spec_tests.zig)",
    "nesting_too_deep_reject.mc": "pure parser-depth diagnostic; top-level inline EXPECT_ERROR after the prototype semicolon cannot be chunk-isolated by the sweep (phase=parse; E_NESTING_TOO_DEEP owned by spec_tests.zig)",
    "private_import_reject.mc": "pure private-import diagnostic; stripping the rejected use leaves a relative support import outside the sweep temp sandbox (phase=sema; E_PRIVATE_IMPORT owned by spec_tests.zig)",
    "pointer_view_conversions.mc": "accept/reject pointer+view const-narrow cases share types the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_NO_IMPLICIT_POINTER_CONVERSION owned by spec_tests.zig; accept emit covered by tests/c_emit/pointer_views.mc + pointer_const_narrow.mc)",
    "soundness_address_class_cast.mc": "checker-only address-class cast has no IR lowering (phase=sema; E_ADDRESS_CLASS_* owned by spec_tests.zig)",
    "soundness_use_after_move.mc": "accept/reject cases share move-typed defs the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_USE_AFTER_MOVE owned by spec_tests.zig)",
    "soundness_conservative_overrejection.mc": "shared move-typed defs across accept/reject (phase=sema; E_USE_AFTER_MOVE owned by spec_tests.zig)",
    "soundness_opaque_declassify.mc": "accept/reject cases share opaque defs (phase=sema; E_OPAQUE_DECLASSIFY owned by spec_tests.zig)",
    "soundness_guard_opaque_reject.mc": "opaque private-field reject fixture; positive impl cannot be chunk-isolated (phase=sema; E_PRIVATE_FIELD owned by spec_tests.zig)",
    "soundness_orphan_impl_reject.mc": "orphan-impl reject fixture (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "traits_effect_sleep_in_atomic.mc": "effect-typed callees are EXPECT_ERROR-stripped, leaving dangling refs (phase=parse,sema; E_SLEEP_IN_ATOMIC owned by spec_tests.zig)",
    "traits_orphan_opaque_reject.mc": "pure compile_error fixture; residue cannot be chunk-isolated after EXPECT_ERROR stripping (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "type_arg_and_trivial_drop_reject.mc": "pure compile_error fixture; stripping rejected declarations leaves only an unspecialized comptime-type helper template (phase=parse,sema; E_TRIVIAL_DROP_NOT_MOVE and E_TYPE_ARG_REQUIRED owned by spec_tests.zig)",
}
FORBIDDEN_ASSUMPTIONS = ("nuw", "nsw", "nonnull", "noalias", "noundef", "poison", "inbounds", "undef", "fast", "nnan", "ninf", "nsz", "arcp", "contract", "afn")
FORBIDDEN_RE = re.compile(r"(^|[ ,(])(" + "|".join(FORBIDDEN_ASSUMPTIONS) + r")([ ,)]|$)")
REASSOC_RE = re.compile(r"(^|[ ,(])reassoc([ ,)]|$)")


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

    failures, oos_failures, swept, kept_fns = [], [], 0, 0
    for path in sorted(glob.glob(os.path.join(spec_dir, "*.mc"))):
        name = os.path.basename(path)
        swept += 1
        program = valid_program(open(path).read())
        kept_fns += len(re.findall(r"\bfn\s+\w+", program))

        with tempfile.NamedTemporaryFile("w", suffix=".mc", delete=False) as tmp:
            tmp.write(program)
            tmp_path = tmp.name
        try:
            emit = subprocess.run([mcc, "emit-llvm", tmp_path], capture_output=True, text=True)
            bucket = oos_failures if name in OUT_OF_SCOPE else failures
            if emit.returncode != 0:
                bucket.append((name, "EMIT", first_error(emit.stderr)))
                continue
            forbidden = forbidden_assumption(emit.stdout, program)
            if forbidden:
                token, line_no, line = forbidden
                bucket.append((name, "ASSUMPTION", f"forbidden LLVM assumption token '{token}' at line {line_no}: {line}"))
                continue
            asm = subprocess.run(["llvm-as", "-o", os.devnull], input=emit.stdout, capture_output=True, text=True)
            if asm.returncode != 0:
                bucket.append((name, "LLVM-AS", first_error(asm.stderr)))
        finally:
            os.unlink(tmp_path)

    print(f"spec fixtures swept: {swept}, valid functions checked for LLVM: {kept_fns}")
    if oos_failures:
        print("known LLVM out-of-scope fixtures (allowlisted, not failing the gate):")
        for name, kind, message in oos_failures:
            print(f"  [{kind}] {name}: {OUT_OF_SCOPE[name]} ({message})")
    if failures:
        print(f"FAIL: {len(failures)} in-scope fixture(s) did not emit/assemble LLVM:")
        for name, kind, message in failures:
            print(f"  [{kind}] {name}: {message}")
        return 1
    print("PASS: all in-scope valid spec fixtures emit assemblable LLVM IR")
    return 0


if __name__ == "__main__":
    sys.exit(main())
