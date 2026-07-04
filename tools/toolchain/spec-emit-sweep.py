#!/usr/bin/env python3
"""Empirical C-emission sweep over the spec conformance corpus.

For every tests/spec/*.mc fixture, drop the functions that carry an
EXPECT_ERROR comment (the intentional compile-error cases), then `emit-c` the
remaining valid declarations and compile-check the output with clang. The sweep
also rejects `/* unsupported ... */` placeholders, so a sema-accepted construct
cannot satisfy the gate by emitting placeholder C that happens to compile.

Usage:
    tools/toolchain/spec-emit-sweep.py [<mcc-binary> [<spec-dir>]]

Defaults: zig-out/bin/mcc, tests/spec. Exit status is non-zero if any valid
fixture fails to emit or compile.
"""
import sys, os, re, glob, subprocess, tempfile, concurrent.futures
from spec_sweep_lib import strip_expect_error  # shared comment-aware negative-fixture stripping

# Fixtures excluded from the C-emit sweep, each mapped to the reason it is not a
# C-emission fixture in the first place. Every entry is a phase=sema / phase=parse
# DIAGNOSTIC fixture: its `check=` field is a sema diagnostic (E_*), never a
# `lower-c` check, so its full accept+reject contract is owned authoritatively by
# the spec-metadata harness (src/spec_tests.zig), not by C emission. Such a fixture
# cannot pass a blanket emit sweep because its positive ("accept") declarations
# either use checker-only types that have no C lowering (Secret/Rights), or share
# opaque/move type definitions with their EXPECT_ERROR ("reject") twins that the
# chunk-level strip cannot separate. Allowlisting them aligns this supplementary
# sweep with the declared per-fixture contract; it removes no coverage (spec_tests.zig
# already validates each one). A fixture carrying a real `lower-c` check must NEVER
# be added here — that would hide a genuine emit regression.
OUT_OF_SCOPE = {
    "error_from_ambiguous.mc": "pure compile_error fixture; module-level ambiguity check the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_AMBIGUOUS_ERROR_CONVERSION owned by spec_tests.zig)",
    "error_from_malformed.mc": "pure compile_error fixture; malformed-decl check the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_INVALID_ERROR_FROM owned by spec_tests.zig)",
    "import_not_found_reject.mc": "pure import-loader diagnostic; top-level inline EXPECT_ERROR after the import semicolon cannot be chunk-isolated by the sweep (phase=parse; E_IMPORT_NOT_FOUND owned by spec_tests.zig)",
    "import_outside_sandbox_reject.mc": "pure import-loader diagnostic; top-level inline EXPECT_ERROR after the import semicolon cannot be chunk-isolated by the sweep (phase=parse; E_IMPORT_OUTSIDE_SANDBOX owned by spec_tests.zig)",
    "monomorphization_limits.mc": "pure compile_error fixture; polymorphic-recursion limit check the chunk-level EXPECT_ERROR strip cannot isolate (phase=parse,sema; E_MONOMORPHIZATION_LIMIT owned by spec_tests.zig)",
    "monomorphize_pattern_type_mentions.mc": "pure sema diagnostic; stripping the rejected generic body leaves its caller dangling (phase=parse,sema; E_NO_IMPLICIT_CONVERSION owned by spec_tests.zig)",
    "nesting_too_deep_reject.mc": "pure parser-depth diagnostic; top-level inline EXPECT_ERROR after the prototype semicolon cannot be chunk-isolated by the sweep (phase=parse; E_NESTING_TOO_DEEP owned by spec_tests.zig)",
    "private_import_reject.mc": "pure private-import diagnostic; stripping the rejected use leaves a relative support import outside the sweep temp sandbox (phase=sema; E_PRIVATE_IMPORT owned by spec_tests.zig)",
    "secret.mc": "checker-only Secret<T> hardening type has no C lowering (phase=sema; E_SECRET_* owned by spec_tests.zig)",
    "rights_monotonic.mc": "opaque-rights hardening type has no C lowering (phase=sema; E_PRIVATE_FIELD owned by spec_tests.zig)",
    "soundness_use_after_move.mc": "accept/reject cases share move-typed defs the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_USE_AFTER_MOVE owned by spec_tests.zig)",
    "soundness_conservative_overrejection.mc": "shared move-typed defs across accept/reject (phase=sema; E_USE_AFTER_MOVE owned by spec_tests.zig)",
    "soundness_opaque_declassify.mc": "accept/reject cases share opaque defs (phase=sema; E_OPAQUE_DECLASSIFY owned by spec_tests.zig)",
    "soundness_guard_opaque_reject.mc": "opaque private-field reject fixture; positive impl cannot be chunk-isolated (phase=sema; E_PRIVATE_FIELD owned by spec_tests.zig)",
    "soundness_orphan_impl_reject.mc": "orphan-impl reject fixture (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "traits_effect_sleep_in_atomic.mc": "effect-typed callees are EXPECT_ERROR-stripped, leaving dangling refs (phase=parse,sema; E_SLEEP_IN_ATOMIC owned by spec_tests.zig)",
    "traits_orphan_opaque_reject.mc": "pure compile_error fixture; residue emits a `static main` the sweep's -Wmain rejects (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "traits_orphan_nonopaque_reject.mc": "pure compile_error fixture with std import; residue cannot be chunk-isolated after EXPECT_ERROR stripping (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "pointer_view_conversions.mc": "accept/reject pointer+view const-narrow cases share types the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_NO_IMPLICIT_POINTER_CONVERSION owned by spec_tests.zig; accept emit covered by tests/c_emit/pointer_views.mc + pointer_const_narrow.mc)",
    "closure_typing.mc": "accept/reject closure typing cases share helper functions and globals; stripping rejected closure bodies leaves dangling references (phase=sema; E_CLOSURE_SIGNATURE_MISMATCH/E_LOCAL_ADDRESS_ESCAPE owned by spec_tests.zig; accept emit covered by tests/c_emit/global_closure.mc)",
    "reflection.mc": "reflection accept/reject cases include sema-only overflow layouts whose top-level declarations cannot be chunk-isolated by EXPECT_ERROR stripping (phase=parse,sema; E_REFLECTION_* owned by spec_tests.zig; accept emit covered by tests/c_emit/reflection.mc)",
}

# Compile the emitted C exactly as the MC kernel profile intends: a deterministic
# bare-metal ELF target, freestanding. Both flags are load-bearing for host independence:
#   --target=x86_64-unknown-none : pin an ELF target so target-specific attributes don't
#       diverge with the host. e.g. `section_attr.mc`'s plain section name is valid on ELF
#       but rejected on a Mach-O host (macOS/aarch64 requires `segment,section`) — the
#       host-dependent red this fixes. (Mirrors the obj/opt sweeps' x86_64-unknown-none.)
#   -ffreestanding : use the COMPILER's builtin <stdint.h>/<stddef.h>/… (the kernel profile
#       is freestanding) instead of the host libc's. Without it, a non-host target can't find
#       glibc's `bits/libc-header-start.h`, so the triple alone would break the Linux sweep.
SWEEP_TRIPLE = "x86_64-unknown-none"
CLANG = ["clang", "--target=" + SWEEP_TRIPLE, "-ffreestanding",
         "-std=c11", "-Wall", "-Wextra", "-Werror",
         # The harness keeps unused valid functions, so silence those two only.
         "-Wno-unused-parameter", "-Wno-unused-variable",
         "-fsyntax-only", "-x", "c", "-"]


# Emit + clang-check one fixture's valid (non-EXPECT_ERROR) declarations. Returns
# (name, kept-fn-count, failure-or-None). Each fixture is an independent subprocess
# chain, so the corpus fans out across cores (override with JOBS=N).
def sweep_one(mcc, path):
    name = os.path.basename(path)
    program = strip_expect_error(open(path).read())
    kept = len(re.findall(r"\bfn\s+\w+", program))

    with tempfile.NamedTemporaryFile("w", suffix=".mc", delete=False) as tmp:
        tmp.write(program)
        tmp_path = tmp.name
    try:
        emit = subprocess.run([mcc, "emit-c", tmp_path], capture_output=True, text=True)
    finally:
        os.unlink(tmp_path)

    if emit.returncode != 0:
        first = next((l for l in emit.stderr.splitlines() if "error:" in l), "?")
        return (name, kept, (name, "EMIT", first.strip()))
    unsupported = next((l for l in emit.stdout.splitlines() if "/* unsupported" in l), None)
    if unsupported is not None:
        return (name, kept, (name, "UNSUPPORTED", unsupported.strip()))
    clang = subprocess.run(CLANG, input=emit.stdout, capture_output=True, text=True)
    if clang.returncode != 0:
        first = next((l for l in clang.stderr.splitlines() if "error:" in l), "?")
        return (name, kept, (name, "CLANG", first.strip()))
    return (name, kept, None)


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/mcc"
    spec_dir = sys.argv[2] if len(sys.argv) > 2 else "tests/spec"

    fixtures = sorted(glob.glob(os.path.join(spec_dir, "*.mc")))
    failures, oos_failures, swept, kept_fns = [], [], len(fixtures), 0
    jobs = int(os.environ.get("JOBS") or (os.cpu_count() or 4))
    workers = max(1, min(jobs, len(fixtures))) if fixtures else 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for name, kept, failure in ex.map(lambda p: sweep_one(mcc, p), fixtures):
            kept_fns += kept
            if failure:
                (oos_failures if name in OUT_OF_SCOPE else failures).append(failure)
    failures.sort()
    oos_failures.sort()

    print(f"spec fixtures swept: {swept}, valid functions checked: {kept_fns}")
    if oos_failures:
        print("known out-of-scope (allowlisted, not failing the gate):")
        for n, k, m in oos_failures:
            print(f"  [{k}] {n}: {m}\n        reason: {OUT_OF_SCOPE[n]}")
    if failures:
        print(f"FAIL: {len(failures)} in-scope fixture(s) did not emit/compile:")
        for n, k, m in failures:
            print(f"  [{k}] {n}: {m}")
        return 1
    print("PASS: all in-scope spec fixtures emit compilable C")
    return 0


if __name__ == "__main__":
    sys.exit(main())
