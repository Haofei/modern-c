#!/usr/bin/env python3
"""Empirical C-emission sweep over the spec conformance corpus.

For every tests/spec/*.mc fixture, drop the functions that carry an
EXPECT_ERROR comment (the intentional compile-error cases), then `emit-c` the
remaining valid declarations and compile-check the output with clang. The sweep
also rejects `/* unsupported ... */` placeholders, so a sema-accepted construct
cannot satisfy the gate by emitting placeholder C that happens to compile.

Usage:
    tools/toolchain/spec-emit-sweep.py [<mcc-binary> [<spec-dir>]]

Defaults: MCC_UNDER_TEST when set, otherwise zig-out/bin/mcc, tests/spec. Exit status is non-zero if any valid
fixture fails to emit or compile.
"""
import sys, os, re, glob, json, subprocess, tempfile, concurrent.futures
from spec_sweep_lib import valid_program  # shared comment-aware negative-fixture stripping

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
    "move_place.mc": "pure move-place sema fixture; stripping rejected move/index cases leaves checker-only indexed move-resource paths that are not a C-emission contract (phase=sema; E_USE_AFTER_MOVE/E_RESOURCE_* owned by spec_tests.zig)",
    "nesting_too_deep_reject.mc": "pure parser-depth diagnostic; top-level inline EXPECT_ERROR after the prototype semicolon cannot be chunk-isolated by the sweep (phase=parse; E_NESTING_TOO_DEEP owned by spec_tests.zig)",
    "private_import_reject.mc": "pure private-import diagnostic; stripping the rejected use leaves a relative support import outside the sweep temp sandbox (phase=sema; E_PRIVATE_IMPORT owned by spec_tests.zig)",
    "secret.mc": "checker-only Secret<T> hardening type has no C lowering (phase=sema; E_SECRET_* owned by spec_tests.zig)",
    "soundness_use_after_move.mc": "accept/reject cases share move-typed defs the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_USE_AFTER_MOVE owned by spec_tests.zig)",
    "soundness_conservative_overrejection.mc": "shared move-typed defs across accept/reject (phase=sema; E_USE_AFTER_MOVE owned by spec_tests.zig)",
    "soundness_opaque_declassify.mc": "accept/reject cases share opaque defs (phase=sema; E_OPAQUE_DECLASSIFY owned by spec_tests.zig)",
    "soundness_guard_opaque_reject.mc": "opaque private-field reject fixture; positive impl cannot be chunk-isolated (phase=sema; E_PRIVATE_FIELD owned by spec_tests.zig)",
    "soundness_orphan_impl_reject.mc": "orphan-impl reject fixture (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "traits_orphan_opaque_reject.mc": "pure compile_error fixture; residue emits a `static main` the sweep's -Wmain rejects (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "traits_orphan_nonopaque_reject.mc": "pure compile_error fixture with std import; residue cannot be chunk-isolated after EXPECT_ERROR stripping (phase=sema; E_ORPHAN_IMPL owned by spec_tests.zig)",
    "pointer_view_conversions.mc": "accept/reject pointer+view const-narrow cases share types the chunk-level EXPECT_ERROR strip cannot isolate (phase=sema; E_NO_IMPLICIT_POINTER_CONVERSION owned by spec_tests.zig; accept emit covered by tests/c_emit/pointer_views.mc + pointer_const_narrow.mc)",
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
    # `valid_program`, not a bare EXPECT_ERROR strip: a spec fixture writes a
    # callee it does not define as a bodyless `fn f(...);` prototype, which the
    # frontend keeps but MIR drops, so a call to it has no signature to render.
    # Normalizing it to `extern fn` -- exactly what the LLVM sweeps already do
    # -- makes the chunk a whole program again. Without it the sweep reports a
    # backend gap for something that is an artifact of its own stripping.
    program = valid_program(open(path).read())
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


# Fixtures whose kept chunk the C backend cannot emit today. This is the same
# mechanism c-test uses (docs/backend-expected-failures.json): each entry
# records the reason it fails, the sweep asserts it still fails for that
# reason, and the gate fails if one starts passing or fails differently. The
# list can only shrink deliberately, and a NEW failure is never mistaken for
# standing debt.
#
# Distinct from OUT_OF_SCOPE above, which is about the fixture's contract --
# a chunk the EXPECT_ERROR strip cannot isolate -- not about a backend gap.
MANIFEST_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "docs", "backend-expected-failures.json",
)


def load_expected_failures():
    with open(MANIFEST_PATH, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    entries = {}
    for entry in manifest.get("sweep", []):
        entries[entry["fixture"]] = entry
    return entries


def failure_matches(entry, kind, message):
    return entry["stage"] == kind and entry["reason"] in message


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else (os.environ.get("MCC_UNDER_TEST") or "zig-out/bin/mcc")
    spec_dir = sys.argv[2] if len(sys.argv) > 2 else "tests/spec"

    fixtures = sorted(glob.glob(os.path.join(spec_dir, "*.mc")))
    expected = load_expected_failures()
    failures, oos_failures, swept, kept_fns = [], [], len(fixtures), 0
    fixed, unlisted = [], []
    jobs = int(os.environ.get("JOBS") or (os.cpu_count() or 4))
    workers = max(1, min(jobs, len(fixtures))) if fixtures else 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for name, kept, failure in ex.map(lambda p: sweep_one(mcc, p), fixtures):
            kept_fns += kept
            if failure:
                (oos_failures if name in OUT_OF_SCOPE else failures).append(failure)
            elif name in expected:
                fixed.append(name)
            elif name in OUT_OF_SCOPE:
                # The allowlist gets the same discipline as the manifest: an
                # entry that has started passing is standing debt that is no
                # longer owed, and leaving it in place quietly excuses the
                # fixture from the gate forever after.
                unlisted.append(name)
    failures.sort()
    oos_failures.sort()

    # Split the in-scope failures into the ones this tree already knows about
    # and the ones it does not.
    known, unexpected, drifted = [], [], []
    for failure in failures:
        name, kind, message = failure
        entry = expected.get(name)
        if entry is None:
            unexpected.append(failure)
        elif failure_matches(entry, kind, message):
            known.append(failure)
        else:
            drifted.append(failure)

    print(f"spec fixtures swept: {swept}, valid functions checked: {kept_fns}")
    if oos_failures:
        print("known out-of-scope (allowlisted, not failing the gate):")
        for n, k, m in oos_failures:
            print(f"  [{k}] {n}: {m}\n        reason: {OUT_OF_SCOPE[n]}")
    if known:
        print(f"known backend gaps (docs/backend-expected-failures.json, {len(known)} fixture(s)):")
        for n, k, m in known:
            print(f"  [{k}] {n}: {m}\n        reason: {expected[n]['note']}")

    status = 0
    if unexpected:
        print(f"FAIL: {len(unexpected)} in-scope fixture(s) did not emit/compile:")
        for n, k, m in unexpected:
            print(f"  [{k}] {n}: {m}")
        status = 1
    if drifted:
        print(f"FAIL: {len(drifted)} known-failing fixture(s) now fail differently; update docs/backend-expected-failures.json:")
        for n, k, m in drifted:
            print(f"  [{k}] {n}: {m}\n        recorded: [{expected[n]['stage']}] {expected[n]['reason']}")
        status = 1
    if fixed:
        print(f"FAIL: {len(fixed)} fixture(s) listed as known-failing now emit; remove their entries from docs/backend-expected-failures.json:")
        for n in sorted(fixed):
            print(f"  {n}")
        status = 1
    if unlisted:
        print(f"FAIL: {len(unlisted)} allowlisted out-of-scope fixture(s) now emit; remove their OUT_OF_SCOPE entries:")
        for n in sorted(unlisted):
            print(f"  {n}")
        status = 1
    if status != 0:
        return status
    print(f"PASS: all in-scope spec fixtures emit compilable C ({len(known)} known backend gaps still failing for their recorded reason)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
