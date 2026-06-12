#!/usr/bin/env python3
"""LLVM optimizer/verifier sweep over the broad backend corpus.

This gate keeps the backend policy check on emitted IR, then asks LLVM's
verifier and default O2 pipeline to accept every module, and finally proves the
optimized O2 result still lowers to an object file. Optimized IR may contain
facts inferred by LLVM itself, so hidden-assumption token scanning is applied to
the backend's emitted IR, not the optimizer's rewritten IR.

Usage:
    tools/toolchain/llvm-opt-sweep.py [<mcc-binary> [<spec-dir> [<c-emit-glob>]]]

Defaults: zig-out/bin/mcc, tests/spec, tests/c_emit/*.mc.
"""
import glob
import os
import re
import subprocess
import sys
import tempfile

FORBIDDEN_ASSUMPTIONS = (
    "nuw",
    "nsw",
    "nonnull",
    "noalias",
    "noundef",
    "poison",
    "inbounds",
    "undef",
    "fast",
    "nnan",
    "ninf",
    "nsz",
    "arcp",
    "contract",
    "afn",
)
FORBIDDEN_RE = re.compile(r"(^|[ ,(])(" + "|".join(FORBIDDEN_ASSUMPTIONS) + r")([ ,)]|$)")
REASSOC_RE = re.compile(r"(^|[ ,(])reassoc([ ,)]|$)")


def split_top_level(src):
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


def run_opt(ir, passes, *, emit=False):
    args = ["opt", f"-passes={passes}"]
    if emit:
        args.extend(["-S", "-o", "-"])
    else:
        args.append("-disable-output")
    return subprocess.run(
        args,
        input=ir,
        capture_output=True,
        text=True,
    )


def run_llc_object(ir):
    with tempfile.NamedTemporaryFile("w", suffix=".ll", delete=False) as tmp:
        tmp.write(ir)
        ll_path = tmp.name
    obj_path = f"{ll_path}.o"
    try:
        lowered = subprocess.run(
            ["llc", "-filetype=obj", ll_path, "-o", obj_path],
            capture_output=True,
            text=True,
        )
        if lowered.returncode != 0:
            return lowered
        if not os.path.exists(obj_path) or os.path.getsize(obj_path) == 0:
            lowered.returncode = 1
            lowered.stderr = "llc produced an empty object"
        return lowered
    finally:
        os.unlink(ll_path)
        if os.path.exists(obj_path):
            os.unlink(obj_path)


def check_module(mcc, label, source_path, source, extra_check=False):
    if extra_check:
        check = subprocess.run([mcc, "check", source_path], capture_output=True, text=True)
        if check.returncode != 0:
            return ("CHECK", first_error(check.stderr))

    with tempfile.NamedTemporaryFile("w", suffix=".mc", delete=False) as tmp:
        tmp.write(source)
        tmp_path = tmp.name
    try:
        emit = subprocess.run([mcc, "emit-llvm", tmp_path], capture_output=True, text=True)
    finally:
        os.unlink(tmp_path)

    if emit.returncode != 0:
        return ("EMIT", first_error(emit.stderr))

    forbidden = forbidden_assumption(emit.stdout, source)
    if forbidden:
        token, line_no, line = forbidden
        return ("ASSUMPTION", f"forbidden LLVM assumption token '{token}' at line {line_no}: {line}")

    verify = run_opt(emit.stdout, "verify")
    if verify.returncode != 0:
        return ("OPT-VERIFY", first_error(verify.stderr))

    o2 = run_opt(emit.stdout, "default<O2>", emit=True)
    if o2.returncode != 0:
        return ("OPT-O2", first_error(o2.stderr))

    lowered = run_llc_object(o2.stdout)
    if lowered.returncode != 0:
        return ("LLC-O2", first_error(lowered.stderr))

    return None


def main():
    mcc = sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/mcc"
    spec_dir = sys.argv[2] if len(sys.argv) > 2 else "tests/spec"
    c_emit_glob = sys.argv[3] if len(sys.argv) > 3 else "tests/c_emit/*.mc"

    if subprocess.run(["sh", "-c", "command -v opt >/dev/null 2>&1"]).returncode != 0:
        print("SKIP: llvm-opt-sweep (opt not found)")
        return 0
    if subprocess.run(["sh", "-c", "command -v llc >/dev/null 2>&1"]).returncode != 0:
        print("SKIP: llvm-opt-sweep (llc not found)")
        return 0

    failures = []
    spec_fixtures = sorted(glob.glob(os.path.join(spec_dir, "*.mc")))
    spec_functions = 0
    for path in spec_fixtures:
        source = valid_program(open(path).read())
        spec_functions += len(re.findall(r"\bfn\s+\w+", source))
        failure = check_module(mcc, os.path.basename(path), path, source)
        if failure:
            kind, message = failure
            failures.append((os.path.basename(path), kind, message))

    c_emit_fixtures = sorted(glob.glob(c_emit_glob))
    for path in c_emit_fixtures:
        source = open(path).read()
        failure = check_module(mcc, os.path.basename(path), path, source, extra_check=True)
        if failure:
            kind, message = failure
            failures.append((os.path.basename(path), kind, message))

    print(
        f"LLVM optimizer sweep: spec fixtures {len(spec_fixtures)} "
        f"({spec_functions} valid functions), c_emit fixtures {len(c_emit_fixtures)}"
    )
    if failures:
        print(f"FAIL: {len(failures)} LLVM module(s) failed optimizer verification:")
        for name, kind, message in failures:
            print(f"  [{kind}] {name}: {message}")
        return 1

    print("PASS: emitted LLVM modules pass hidden-assumption, verifier, O2 pipeline, and optimized object checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
