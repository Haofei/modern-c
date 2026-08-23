#!/usr/bin/env python3

import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / "tools/toolchain/fallback-census-report.py"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: fallback-census-report-test - {message}")


def load_report_module():
    spec = importlib.util.spec_from_file_location("fallback_census_report", REPORT)
    if spec is None or spec.loader is None:
        fail("cannot load report module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def record(name: str, call_targets=None):
    value = {
        "backend": "c",
        "status": "fallback",
        "fn": name,
        "blocks": 1,
        "term": "return",
        "ret": "binary",
        "traps": 0,
        "cleanup": False,
        "instrs": "call_target,return_value",
    }
    if call_targets is not None:
        value["call_targets"] = call_targets
    return value


def main() -> None:
    report = load_report_module()

    # Missing data from pre-call_targets JSONL is the same stable empty set.
    if report.signature(record("old")) != report.signature(record("old", "")):
        fail("old JSONL without call_targets is not backward compatible")

    # Distinct builtin families must no longer collapse during de-duplication.
    phys = record("same", "phys")
    wrapping = record("same", "wrapping_add")
    summary = report.summarize_backend([phys, wrapping])
    if summary["total"] != 2 or summary["fallback"] != 2:
        fail(f"call_targets did not participate in signature: {summary!r}")

    output = io.StringIO()
    with redirect_stdout(output):
        report.report_backend("c", [phys, wrapping])
    text = output.getvalue()
    if ":: phys" not in text or ":: wrapping_add" not in text:
        fail(f"fine ranking omitted call_targets: {text!r}")

    print(
        "PASS: fallback-census-report-test - call-target families are stable, "
        "distinct, visible, and old JSONL remains compatible"
    )


if __name__ == "__main__":
    main()
