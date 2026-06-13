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

# No valid spec fixtures are currently excluded from the lower-C sweep.
OUT_OF_SCOPE = set()

CLANG = ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
         # The harness keeps unused valid functions, so silence those two only.
         "-Wno-unused-parameter", "-Wno-unused-variable",
         "-fsyntax-only", "-x", "c", "-"]


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


def strip_expect_error(src):
    return "".join(ch for ch in split_top_level(src) if "EXPECT_ERROR" not in ch)


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
            print(f"  [{k}] {n}: {m}")
    if failures:
        print(f"FAIL: {len(failures)} in-scope fixture(s) did not emit/compile:")
        for n, k, m in failures:
            print(f"  [{k}] {n}: {m}")
        return 1
    print("PASS: all in-scope spec fixtures emit compilable C")
    return 0


if __name__ == "__main__":
    sys.exit(main())
