#!/usr/bin/env python3
"""Regression tests for tools/dev-gates.py routing contracts."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
from collections.abc import Sequence


ROOT = pathlib.Path(__file__).resolve().parents[2]
DEV_GATES = ROOT / "tools" / "dev-gates.py"


def fail(message: str) -> None:
    print(f"FAIL: dev-gates-test - {message}", file=sys.stderr)
    sys.exit(1)


def load_dev_gates():
    spec = importlib.util.spec_from_file_location("dev_gates", DEV_GATES)
    if spec is None or spec.loader is None:
        fail(f"cannot load {DEV_GATES.relative_to(ROOT)}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def assert_gates(module, paths: Sequence[str], expected: Sequence[str]) -> None:
    gates, checks, _ = module.select_gates(list(paths))
    if gates != list(expected):
        fail(f"{', '.join(paths)} gates {gates!r}, expected {list(expected)!r}")
    if checks:
        fail(f"{', '.join(paths)} checks {checks!r}, expected no focused shell checks")


def assert_checks(module, paths: Sequence[str], expected: Sequence[str]) -> None:
    gates, checks, _ = module.select_gates(list(paths))
    if gates:
        fail(f"{', '.join(paths)} gates {gates!r}, expected no zig gates")
    if checks != list(expected):
        fail(f"{', '.join(paths)} checks {checks!r}, expected {list(expected)!r}")


def assert_route(module, paths: Sequence[str], expected_gates: Sequence[str], expected_checks: Sequence[str]) -> None:
    gates, checks, _ = module.select_gates(list(paths))
    if gates != list(expected_gates):
        fail(f"{', '.join(paths)} gates {gates!r}, expected {list(expected_gates)!r}")
    if checks != list(expected_checks):
        fail(f"{', '.join(paths)} checks {checks!r}, expected {list(expected_checks)!r}")


def main() -> None:
    module = load_dev_gates()

    assert_gates(
        module,
        ["src/layout.zig"],
        ["test", "diagnostics-reference-test", "diagnostic-code-inventory-test"],
    )
    assert_gates(module, ["src/sema_tests.zig"], ["test"])
    assert_gates(
        module,
        ["src/sema.zig"],
        [
            "test",
            "diagnostics-reference-test",
            "diagnostic-code-inventory-test",
            "bad-diagnostics-test",
            "c-test",
            "diff-backend",
        ],
    )
    assert_gates(
        module,
        ["src/parser.zig"],
        [
            "test",
            "diagnostics-reference-test",
            "diagnostic-code-inventory-test",
            "diagnostics-test",
            "bad-diagnostics-test",
        ],
    )
    assert_checks(module, ["docs/compiler-production-readiness.md"], ["git diff --check"])
    assert_route(
        module,
        ["docs/diagnostics.md"],
        ["diagnostics-reference-test", "diagnostic-code-inventory-test", "bad-diagnostics-test"],
        ["git diff --check"],
    )
    assert_route(
        module,
        ["README.md", "src/ast.zig"],
        ["test", "diagnostics-reference-test", "diagnostic-code-inventory-test"],
        ["git diff --check"],
    )
    assert_gates(module, ["tests/spec/value_optionals.mc"], ["test", "sweep", "llvm-sweep"])
    assert_gates(module, ["tests/spec/nullability.mc"], ["test"])
    assert_gates(module, ["tests/spec/does-not-exist.mc"], ["test"])
    assert_gates(module, ["tools/dev-gates.py"], ["dev-gates-test"])
    assert_gates(module, ["tools/toolchain/dev-gates-test.py"], ["dev-gates-test"])
    assert_gates(module, ["tools/test/contract-lint.py"], ["test-lint"])
    assert_gates(module, ["tools/toolchain/bad-diagnostics-test.py"], ["bad-diagnostics-test"])
    assert_gates(module, ["tools/toolchain/diff-backend.sh"], ["diff-backend"])
    assert_gates(module, ["tools/toolchain/diagnostics-test.sh"], ["diagnostics-test"])
    assert_gates(module, ["tools/toolchain/mcc-cli-test.sh"], ["mcc-cli-test"])
    assert_gates(module, ["tools/toolchain/install-layout-test.sh"], ["install-layout-test"])
    assert_gates(module, ["tools/toolchain/path-remap-test.sh"], ["path-remap-test"])
    assert_gates(module, ["tools/toolchain/fmt-test.sh"], ["fmt-test"])
    assert_gates(module, ["tools/toolchain/mcc-symbols-test.sh"], ["mcc-symbols-test"])
    assert_gates(module, ["tools/toolchain/std-api-docs.py"], ["std-api-docs-test"])
    assert_gates(module, ["tools/toolchain/vendoring-test.py"], ["vendoring-test"])
    assert_gates(module, ["tools/toolchain/third-party-licenses-test.py"], ["third-party-licenses-test"])
    assert_gates(module, ["tools/toolchain/spec-emit-sweep.py"], ["test-lint", "sweep"])
    assert_gates(module, ["tools/toolchain/spec-llvm-sweep.py"], ["test-lint", "llvm-sweep"])
    assert_gates(module, ["tools/toolchain/spec-llvm-obj-sweep.py"], ["test-lint", "llvm-spec-obj-sweep"])
    assert_gates(module, ["tools/toolchain/llvm-opt-sweep.py"], ["test-lint", "llvm-opt-sweep"])
    assert_gates(
        module,
        ["tools/toolchain/spec_sweep_lib.py"],
        ["test-lint", "sweep", "llvm-sweep", "llvm-spec-obj-sweep", "llvm-opt-sweep"],
    )
    assert_gates(module, ["tools/toolchain/llvm-c-emit-sweep.py"], ["llvm-c-sweep"])
    assert_gates(module, ["tools/toolchain/llvm-c-obj-sweep.py"], ["llvm-c-obj-sweep"])

    print("PASS: dev-gates-test - routing contracts are stable")


if __name__ == "__main__":
    main()
