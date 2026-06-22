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
import concurrent.futures
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

# emit-llvm emits no target triple, so llc would inherit the host default (aarch64 in
# the arm64 dev container) and fail to assemble the precise-asm fixtures' inline asm.
# Pin one deterministic triple (their valid asm is x86-64; non-asm IR is neutral).
OBJ_TRIPLE = "x86_64-unknown-none"

# Same contract as spec-llvm-sweep.py's OUT_OF_SCOPE (kept in parity): phase=sema
# DIAGNOSTIC spec fixtures (check= is an E_* code, never a lower-* fact) owned by
# src/spec_tests.zig, not by codegen. A fixture with a real lower-* check may never be
# added here. (Only spec fixtures match these names; c_emit fixtures are never keyed.)
OUT_OF_SCOPE = {
    "soundness_address_class_cast.mc": "checker-only address-class cast has no IR lowering (phase=sema; owned by spec_tests.zig)",
    "soundness_use_after_move.mc": "accept/reject cases share move-typed defs the strip cannot isolate (phase=sema; owned by spec_tests.zig)",
    "soundness_conservative_overrejection.mc": "shared move-typed defs across accept/reject (phase=sema; owned by spec_tests.zig)",
    "soundness_opaque_declassify.mc": "accept/reject cases share opaque defs (phase=sema; owned by spec_tests.zig)",
    "soundness_guard_opaque_reject.mc": "opaque private-field reject fixture; positive impl cannot be chunk-isolated (phase=sema; owned by spec_tests.zig)",
    "soundness_orphan_impl_reject.mc": "orphan-impl reject fixture (phase=sema; owned by spec_tests.zig)",
    "traits_effect_sleep_in_atomic.mc": "effect-typed callees are EXPECT_ERROR-stripped, leaving dangling refs (phase=parse,sema; owned by spec_tests.zig)",
}


def split_top_level(src):
    """Comment/string-aware split into top-level chunks by brace/semicolon at depth 0:
    punctuation inside a `//` or `/* */` comment or a string/char literal is literal
    text. Kept identical to spec-emit-sweep.py."""
    chunks, buf, depth = [], "", 0
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            j = src.find("\n", i)
            j = n if j == -1 else j + 1
            buf += src[i:j]; i = j; continue
        if c == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            j = n if j == -1 else j + 2
            buf += src[i:j]; i = j; continue
        if c == '"' or c == "'":
            q = c; buf += c; i += 1
            while i < n:
                d = src[i]; buf += d; i += 1
                if d == "\\" and i < n:
                    buf += src[i]; i += 1; continue
                if d == q:
                    break
            continue
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
        i += 1
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
            ["llc", "-mtriple=" + OBJ_TRIPLE, "-filetype=obj", ll_path, "-o", obj_path],
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


# One unit of work: emit + verify + O2 + lower one fixture. Each call is its own
# subprocess chain, so the corpus fans out across cores (override with JOBS=N).
# Returns (basename, spec-function-count, failure-or-None); failures are collected
# and sorted by the caller so parallel ordering does not perturb the report.
def sweep_one(mcc, path, is_spec):
    name = os.path.basename(path)
    if is_spec:
        source = valid_program(open(path).read())
        fn_count = len(re.findall(r"\bfn\s+\w+", source))
        failure = check_module(mcc, name, path, source)
    else:
        source = open(path).read()
        fn_count = 0
        failure = check_module(mcc, name, path, source, extra_check=True)
    return (name, fn_count, failure)


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

    spec_fixtures = sorted(glob.glob(os.path.join(spec_dir, "*.mc")))
    c_emit_fixtures = sorted(glob.glob(c_emit_glob))
    tasks = [(p, True) for p in spec_fixtures] + [(p, False) for p in c_emit_fixtures]

    failures = []
    spec_functions = 0
    jobs = int(os.environ.get("JOBS") or (os.cpu_count() or 4))
    workers = max(1, min(jobs, len(tasks))) if tasks else 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        results = ex.map(lambda t: sweep_one(mcc, t[0], t[1]), tasks)
        for name, fn_count, failure in results:
            spec_functions += fn_count
            if failure:
                kind, message = failure
                failures.append((name, kind, message))
    oos_failures = [f for f in failures if f[0] in OUT_OF_SCOPE]
    failures = [f for f in failures if f[0] not in OUT_OF_SCOPE]
    failures.sort()
    oos_failures.sort()

    print(
        f"LLVM optimizer sweep: spec fixtures {len(spec_fixtures)} "
        f"({spec_functions} valid functions), c_emit fixtures {len(c_emit_fixtures)}"
    )
    if oos_failures:
        print("known out-of-scope fixtures (allowlisted, not failing the gate):")
        for name, kind, message in oos_failures:
            print(f"  [{kind}] {name}: {message}\n        reason: {OUT_OF_SCOPE[name]}")
    if failures:
        print(f"FAIL: {len(failures)} LLVM module(s) failed optimizer verification:")
        for name, kind, message in failures:
            print(f"  [{kind}] {name}: {message}")
        return 1

    print("PASS: emitted LLVM modules pass hidden-assumption, verifier, O2 pipeline, and optimized object checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
