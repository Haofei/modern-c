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

FORBIDDEN_ASSUMPTIONS = ("nuw", "nsw", "nonnull", "noalias", "noundef", "poison")
FORBIDDEN_RE = re.compile(r"(^|[ ,(])(" + "|".join(FORBIDDEN_ASSUMPTIONS) + r")([ ,)]|$)")


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


def forbidden_assumption(ir):
    for line_no, line in enumerate(ir.splitlines(), 1):
        match = FORBIDDEN_RE.search(line)
        if match:
            return match.group(2), line_no, line.strip()
    return None


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/mcc"
    spec_dir = sys.argv[2] if len(sys.argv) > 2 else "tests/spec"
    out_dir = sys.argv[3] if len(sys.argv) > 3 else "zig-out/llvm-spec-obj-sweep"

    if subprocess.run(["sh", "-c", "command -v llc >/dev/null 2>&1"]).returncode != 0:
        print("SKIP: llvm-spec-obj-sweep (llc not found)")
        return 0

    os.makedirs(out_dir, exist_ok=True)
    failures, swept, kept_fns = [], 0, 0
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
            forbidden = forbidden_assumption(emit.stdout)
            if forbidden:
                token, line_no, line = forbidden
                failures.append((name, "ASSUMPTION", f"forbidden LLVM assumption token '{token}' at line {line_no}: {line}"))
                continue
            compile_obj = subprocess.run(["llc", "-filetype=obj", "-o", out_path], input=emit.stdout, capture_output=True, text=True)
            if compile_obj.returncode != 0:
                failures.append((name, "LLC", first_error(compile_obj.stderr)))
                continue
            if not os.path.exists(out_path) or os.path.getsize(out_path) == 0:
                failures.append((name, "OBJECT", "empty or missing object output"))
        finally:
            os.unlink(tmp_path)

    print(f"spec fixtures swept: {swept}, valid functions compiled to LLVM objects: {kept_fns}")
    if failures:
        print(f"FAIL: {len(failures)} valid spec fixture(s) did not compile to LLVM objects:")
        for name, kind, message in failures:
            print(f"  [{kind}] {name}: {message}")
        return 1
    print("PASS: all in-scope valid spec fixtures compile to LLVM object files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
