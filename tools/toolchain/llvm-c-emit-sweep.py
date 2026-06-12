#!/usr/bin/env python3
"""LLVM-emission sweep over the checked C-emission fixture corpus.

Every tests/c_emit/*.mc fixture is expected to pass `mcc check`, emit textual
LLVM IR, assemble with llvm-as, and avoid hidden optimizer-assumption tokens
that the LLVM appendix forbids outside proven verifier conditions. This keeps
the broad C-backend fixture surface covered by the LLVM backend as a normal
build gate rather than an ad-hoc shell audit.

Usage:
    tools/toolchain/llvm-c-emit-sweep.py [<mcc-binary> [<fixture-glob>]]

Defaults: zig-out/bin/mcc, tests/c_emit/*.mc.
"""
import glob
import os
import re
import subprocess
import sys

FORBIDDEN_ASSUMPTIONS = ("nuw", "nsw", "nonnull", "noalias", "noundef", "poison", "inbounds")
FORBIDDEN_RE = re.compile(r"(^|[ ,(])(" + "|".join(FORBIDDEN_ASSUMPTIONS) + r")([ ,)]|$)")


def first_error(stderr):
    return next((l for l in stderr.splitlines() if "error:" in l), stderr.splitlines()[0] if stderr else "?").strip()


def forbidden_assumption(ir):
    for line_no, line in enumerate(ir.splitlines(), 1):
        match = FORBIDDEN_RE.search(line)
        if match:
            return match.group(2), line_no, line.strip()
    return None


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/mcc"
    pattern = sys.argv[2] if len(sys.argv) > 2 else "tests/c_emit/*.mc"

    failures = []
    fixtures = sorted(glob.glob(pattern))
    for path in fixtures:
        name = os.path.basename(path)
        check = subprocess.run([mcc, "check", path], capture_output=True, text=True)
        if check.returncode != 0:
            failures.append((name, "CHECK", first_error(check.stderr)))
            continue

        emit = subprocess.run([mcc, "emit-llvm", path], capture_output=True, text=True)
        if emit.returncode != 0:
            failures.append((name, "EMIT", first_error(emit.stderr)))
            continue

        forbidden = forbidden_assumption(emit.stdout)
        if forbidden:
            token, line_no, line = forbidden
            failures.append((name, "ASSUMPTION", f"forbidden LLVM assumption token '{token}' at line {line_no}: {line}"))
            continue

        asm = subprocess.run(["llvm-as", "-o", os.devnull], input=emit.stdout, capture_output=True, text=True)
        if asm.returncode != 0:
            failures.append((name, "LLVM-AS", first_error(asm.stderr)))

    print(f"c_emit fixtures checked for LLVM: {len(fixtures)}")
    if failures:
        print(f"FAIL: {len(failures)} c_emit fixture(s) did not emit/assemble LLVM:")
        for name, kind, message in failures:
            print(f"  [{kind}] {name}: {message}")
        return 1
    print("PASS: all c_emit fixtures emit assemblable LLVM IR")
    return 0


if __name__ == "__main__":
    sys.exit(main())
