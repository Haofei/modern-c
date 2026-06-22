#!/usr/bin/env python3
"""LLVM object-output sweep over the checked C-emission fixture corpus.

Every tests/c_emit/*.mc fixture is expected to pass `mcc check`, emit LLVM IR,
and compile to a non-empty object file with llc. This complements
llvm-c-emit-sweep.py: llvm-as proves the textual IR is valid, while this gate
proves the covered broad fixture surface survives LLVM object lowering.

Usage:
    tools/toolchain/llvm-c-obj-sweep.py [<mcc-binary> [<fixture-glob> [<out-dir>]]]

Defaults: zig-out/bin/mcc, tests/c_emit/*.mc, zig-out/llvm-c-obj-sweep.
"""
import glob
import os
import subprocess
import sys


def first_error(stderr):
    return next((l for l in stderr.splitlines() if "error:" in l), stderr.splitlines()[0] if stderr else "?").strip()


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/mcc"
    pattern = sys.argv[2] if len(sys.argv) > 2 else "tests/c_emit/*.mc"
    out_dir = sys.argv[3] if len(sys.argv) > 3 else "zig-out/llvm-c-obj-sweep"

    if subprocess.run(["sh", "-c", "command -v llc >/dev/null 2>&1"]).returncode != 0:
        print("SKIP: llvm-c-obj-sweep (llc not found)")
        return 0

    os.makedirs(out_dir, exist_ok=True)
    failures = []
    fixtures = sorted(glob.glob(pattern))
    for path in fixtures:
        name = os.path.basename(path)
        stem = os.path.splitext(name)[0]
        out_path = os.path.join(out_dir, stem + ".o")

        check = subprocess.run([mcc, "check", path], capture_output=True, text=True)
        if check.returncode != 0:
            failures.append((name, "CHECK", first_error(check.stderr)))
            continue

        # emit-llvm embeds no target triple, so llc would otherwise inherit the host
        # default (aarch64 in the arm64 dev container) and fail to assemble the inline asm
        # the precise-asm fixtures carry — a host-dependent result. Pin one deterministic
        # triple; the fixtures' valid asm is x86-64 and non-asm fixtures emit neutral IR.
        # (Same fix as spec-llvm-obj-sweep.py.)
        compile_obj = subprocess.run(
            ["tools/toolchain/mcc-llvm-cc.sh", path, "-o", out_path, "-mtriple=x86_64-unknown-none"],
            env={**os.environ, "MCC": mcc},
            capture_output=True,
            text=True,
        )
        if compile_obj.returncode != 0:
            failures.append((name, "LLC", first_error(compile_obj.stderr)))
            continue
        if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
            failures.append((name, "OBJECT", "empty or missing object output"))

    print(f"c_emit fixtures compiled to LLVM objects: {len(fixtures)}")
    if failures:
        print(f"FAIL: {len(failures)} c_emit fixture(s) did not compile to LLVM objects:")
        for name, kind, message in failures:
            print(f"  [{kind}] {name}: {message}")
        return 1
    print("PASS: all c_emit fixtures compile to LLVM object files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
