#!/usr/bin/env python3
"""Contract lint: enforce the fixture-contract rules from docs/test-architecture.md.

This is a fast, tool-free static check (no mcc/clang/QEMU) that keeps the test
corpus honest, so the fixture-semantics rot the gates were fixed for cannot creep
back in. It checks:

  1. Every reject fixture under a `bad/` directory names the diagnostic it expects
     with an `EXPECT: E_CODE` line — so the gate can assert the *specific* code, not
     merely that compilation failed.

  2. Every fixture an emit/IR sweep lists in `OUT_OF_SCOPE` (a) still exists and
     (b) is legitimately not a codegen fixture: its `// SPEC: check=` is purely
     diagnostic (no `lower-*` fact) and its `phase=` declares no lowering phase.
     A fixture carrying a real `lower-*` check must never be allowlisted — that
     would hide a genuine emit regression.

  3. Every `tools/lib/host-tests.tsv` row points at a fixture file that exists, and
     an `entry`-mode row names an entry function in its `spec` column.

Usage: tools/test/contract-lint.py [<repo-root>]
Exit status is non-zero if any rule is violated.
"""
import glob
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")

# A `lower-*` check (or a lowering phase) marks a fixture as one whose codegen IS
# under test — it may not be allowlisted out of an emit sweep.
LOWER_CHECK_RE = re.compile(r"\blower[-_]")
LOWER_PHASE_RE = re.compile(r"\blower[-_]")

REJECT_GLOBS = [
    "tests/c_emit/bad/*.mc",
    "kernel/bad/*.mc",
    "demo/bad/*.mc",
]
SWEEP_FILES = [
    "tools/toolchain/spec-emit-sweep.py",
    "tools/toolchain/spec-llvm-sweep.py",
    "tools/toolchain/spec-llvm-obj-sweep.py",
    "tools/toolchain/llvm-opt-sweep.py",
]


def spec_header_value(text, key):
    """Return the joined `// SPEC: key=...` value(s) for a fixture, or ''."""
    vals = re.findall(r"//\s*SPEC:\s*" + re.escape(key) + r"=([^\n]*)", text)
    return ",".join(v.strip() for v in vals)


def check_reject_fixtures():
    errors = []
    n = 0
    for g in REJECT_GLOBS:
        for path in sorted(glob.glob(os.path.join(ROOT, g))):
            n += 1
            text = open(path).read()
            if not re.search(r"EXPECT:\s*[A-Z_]+", text):
                errors.append(f"{os.path.relpath(path, ROOT)}: reject fixture has no 'EXPECT: E_CODE' line")
    return n, errors


def parse_out_of_scope(path):
    """Extract the OUT_OF_SCOPE dict keys (fixture basenames) from a sweep script."""
    text = open(path).read()
    m = re.search(r"OUT_OF_SCOPE\s*=\s*\{(.*?)\}", text, re.S)
    if not m:
        return []
    return re.findall(r'"([^"]+\.mc)"\s*:', m.group(1))


def check_out_of_scope():
    errors = []
    n = 0
    for sweep in SWEEP_FILES:
        for name in parse_out_of_scope(os.path.join(ROOT, sweep)):
            n += 1
            fixture = os.path.join(ROOT, "tests/spec", name)
            rel = os.path.relpath(sweep, ROOT)
            if not os.path.exists(fixture):
                errors.append(f"{rel}: OUT_OF_SCOPE names '{name}', which does not exist in tests/spec/")
                continue
            text = open(fixture).read()
            checks = spec_header_value(text, "check")
            phase = spec_header_value(text, "phase")
            if LOWER_CHECK_RE.search(checks):
                errors.append(f"{rel}: OUT_OF_SCOPE '{name}' carries a lower-* check ({checks}) — a codegen fixture may not be allowlisted")
            elif LOWER_PHASE_RE.search(phase):
                errors.append(f"{rel}: OUT_OF_SCOPE '{name}' declares a lowering phase ({phase}) — a codegen fixture may not be allowlisted")
    return n, errors


def check_host_tests():
    errors = []
    n = 0
    tsv = os.path.join(ROOT, "tools/lib/host-tests.tsv")
    if not os.path.exists(tsv):
        return 0, []
    for line in open(tsv):
        if line.startswith("#") or not line.strip():
            continue
        cols = line.rstrip("\n").split("\t")
        if len(cols) < 3:
            errors.append(f"host-tests.tsv: malformed row: {line.strip()!r}")
            continue
        name, fixture, mode = cols[0], cols[1], cols[2]
        spec = cols[3] if len(cols) > 3 else ""
        n += 1
        if not os.path.exists(os.path.join(ROOT, fixture)):
            errors.append(f"host-tests.tsv: row '{name}' points at missing fixture '{fixture}'")
        if mode == "entry" and not spec.strip():
            errors.append(f"host-tests.tsv: entry-mode row '{name}' has no entry fn in its spec column")
    return n, errors


def main():
    all_errors = []
    rn, re_ = check_reject_fixtures(); all_errors += re_
    on, oe = check_out_of_scope(); all_errors += oe
    hn, he = check_host_tests(); all_errors += he

    print(f"contract-lint: {rn} reject fixtures, {on} out-of-scope entries, {hn} host-test rows checked")
    if all_errors:
        print(f"FAIL: {len(all_errors)} contract violation(s):")
        for e in all_errors:
            print(f"  {e}")
        return 1
    print("PASS: contract-lint — all fixture contracts well-formed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
