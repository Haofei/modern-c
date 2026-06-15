#!/usr/bin/env python3
"""Empirical LLVM-emission sweep over the spec conformance corpus.

For every tests/spec/*.mc fixture, drop the functions/declarations that carry
an EXPECT_ERROR comment, normalize top-level `fn foo(...);` prototypes to
`extern fn foo(...);`, then `emit-llvm` the remaining valid declarations and
assemble the textual IR with llvm-as, and reject hidden optimizer-assumption
tokens that the LLVM appendix forbids outside proven verifier conditions.

The allowlist is intentionally empty now that the current spec corpus lowers to
assemblable LLVM IR. Any valid-spec LLVM failure fails the gate.

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

OUT_OF_SCOPE = {
    # (Empty — every in-scope spec fixture now emits assemblable LLVM IR. `move_diverge.mc`'s
    # `trap(...)`/`unreachable` abort statements in value-returning functions are now lowered by
    # the LLVM backend.)
}
FORBIDDEN_ASSUMPTIONS = ("nuw", "nsw", "nonnull", "noalias", "noundef", "poison", "inbounds", "undef", "fast", "nnan", "ninf", "nsz", "arcp", "contract", "afn")
FORBIDDEN_RE = re.compile(r"(^|[ ,(])(" + "|".join(FORBIDDEN_ASSUMPTIONS) + r")([ ,)]|$)")
REASSOC_RE = re.compile(r"(^|[ ,(])reassoc([ ,)]|$)")


def split_top_level(src):
    """Split source into top-level chunks by brace/semicolon at depth 0."""
    chunks, buf, depth = [], "", 0
    for c in src:
        buf += c
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                chunks.append(buf)
                buf = ""
        elif c == ";" and depth == 0:
            chunks.append(buf)
            buf = ""
    if buf.strip():
        chunks.append(buf)
    return chunks


def normalize_valid_chunk(chunk):
    if "EXPECT_ERROR" in chunk:
        return ""
    if chunk.strip().endswith(";") and re.search(r"(?m)^\s*fn\s+\w+\s*\(", chunk):
        return re.sub(r"(?m)^(\s*)fn\s+", r"\1extern fn ", chunk, count=1)
    return chunk


def valid_program(src):
    return "".join(normalize_valid_chunk(ch) for ch in split_top_level(src))


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
