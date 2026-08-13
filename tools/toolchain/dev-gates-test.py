#!/usr/bin/env python3
"""Regression tests for tools/dev-gates.py routing contracts."""

from __future__ import annotations

import importlib.util
import pathlib
import subprocess
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


def assert_gates_include(module, paths: Sequence[str], expected: Sequence[str]) -> None:
    gates, checks, _ = module.select_gates(list(paths))
    missing = [gate for gate in expected if gate not in gates]
    if missing:
        fail(f"{', '.join(paths)} gates {gates!r}, missing {missing!r}")
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
    assert_gates(
        module,
        ["src/diagnostic_explain.zig"],
        ["mcc-cli-test", "diagnostics-reference-test", "diagnostic-code-inventory-test"],
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
    assert_gates(
        module,
        ["src/async_lower.zig"],
        [
            "test",
            "diagnostics-reference-test",
            "diagnostic-code-inventory-test",
            "c-test",
            "diff-backend",
            "fuzz-async",
            "fuzz-corpus",
        ],
    )
    assert_checks(module, ["docs/README.md"], ["git diff --check"])
    docs_only = subprocess.run(
        [sys.executable, str(DEV_GATES), "docs/README.md"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=True,
    ).stdout
    if "zig build fast" in docs_only or "zig build m0" in docs_only:
        fail("docs-only dev-gates output should not recommend compiler confidence/truth gates")
    if "none for checks-only changes" not in docs_only:
        fail("docs-only dev-gates output should explain that compiler confidence gates are unnecessary")
    assert_route(
        module,
        ["docs/diagnostics.md"],
        ["diagnostics-reference-test", "diagnostic-code-inventory-test", "bad-diagnostics-test", "mcc-cli-test"],
        ["git diff --check"],
    )
    assert_route(module, ["CHANGELOG.md"], [], ["git diff --check"])
    assert_route(
        module,
        ["README.md", "src/ast.zig"],
        ["test", "diagnostics-reference-test", "diagnostic-code-inventory-test"],
        ["git diff --check"],
    )
    commands = module.focused_run_commands(
        ["test", "diagnostics-reference-test"],
        ["git diff --check"],
    )
    if commands != ["git diff --check", "zig build test diagnostics-reference-test --summary all"]:
        fail(f"focused run commands {commands!r}, expected shell checks then zig build gates")
    assert_gates(module, ["tests/spec/value_optionals.mc"], ["test", "sweep", "llvm-sweep"])
    assert_gates(module, ["tests/spec/nullability.mc"], ["test"])
    assert_gates(module, ["tests/spec/does-not-exist.mc"], ["test"])
    assert_gates(module, ["tools/dev-gates.py"], ["dev-gates-test"])
    assert_gates(module, ["tools/toolchain/dev-gates-test.py"], ["dev-gates-test"])
    assert_gates(module, ["tools/toolchain/move-unsupported-inventory.py"], ["move-unsupported-inventory-test"])
    assert_gates(module, ["tools/toolchain/move-place-identity-inventory.py"], ["move-place-identity-inventory-test"])
    assert_gates(module, ["tools/toolchain/move-cfg-skeleton-inventory.py"], ["move-cfg-skeleton-inventory-test"])
    assert_gates(module, ["tools/toolchain/move-dynamic-place-policy-inventory.py"], ["move-dynamic-place-policy-inventory-test"])
    assert_gates(module, ["tools/toolchain/move-pointer-pointee-boundary-inventory.py"], ["move-pointer-pointee-boundary-inventory-test"])
    assert_gates(module, ["tools/toolchain/move-projection-inventory.py"], ["move-projection-inventory-test"])
    assert_gates(module, ["src/sema_move.zig"], ["test", "diagnostics-reference-test", "diagnostic-code-inventory-test", "bad-diagnostics-test", "c-test", "diff-backend", "move-place-identity-inventory-test", "move-cfg-skeleton-inventory-test", "move-dynamic-place-policy-inventory-test", "move-pointer-pointee-boundary-inventory-test", "move-projection-inventory-test"])
    assert_gates(module, ["src/sema_model.zig"], ["test", "diagnostics-reference-test", "diagnostic-code-inventory-test", "bad-diagnostics-test", "c-test", "diff-backend", "move-cfg-skeleton-inventory-test", "move-dynamic-place-policy-inventory-test", "move-pointer-pointee-boundary-inventory-test", "move-projection-inventory-test"])
    assert_gates(module, ["tests/spec/move_place.mc"], ["test", "move-projection-inventory-test"])
    assert_route(
        module,
        ["tests/spec/bad/move_cfg_arrays_reject.mc"],
        ["move-unsupported-inventory-test"],
        ["git diff --check"],
    )
    assert_gates(module, ["tools/ci/pass-gates.py"], ["ci-pass-gates-test"])
    assert_gates(module, ["build/tiers.zig"], ["fast"])
    assert_gates(module, ["tools/m0-parallel.sh"], ["fast"])
    assert_gates(module, ["tools/fast-parallel.sh"], ["fast"])
    assert_gates(module, ["tools/test/contract-lint.py"], ["test-lint"])
    assert_gates(module, ["tools/toolchain/bad-diagnostics-test.py"], ["bad-diagnostics-test"])
    assert_gates(module, ["tools/toolchain/diff-backend.sh"], ["diff-backend"])
    assert_gates(
        module,
        ["tools/fuzz/mcfuzz.py"],
        [
            "fuzz",
            "fuzz-async",
            "fuzz-sanitize",
            "fuzz-asan",
            "fuzz-trap",
            "fuzz-trapsite",
            "fuzz-robust",
            "fuzz-failclosed",
            "fuzz-determinism",
            "fuzz-pipeline",
            "fuzz-artifacts",
            "fuzz-roundtrip",
            "fuzz-metamorphic",
            "fuzz-optlevel",
            "fuzz-floatbits",
            "fuzz-reference",
            "fuzz-corpus",
        ],
    )
    assert_gates(module, ["tools/fuzz/mcref.py"], ["fuzz-reference"])
    assert_gates(module, ["tools/fuzz/corpus/wrap_u16_mul.mc"], ["fuzz-corpus"])
    assert_gates(module, ["tools/fuzz/parser-fuzz.sh"], ["parser-fuzz-test"])
    assert_gates(module, ["tests/qemu/net/parser_fuzz_demo.mc"], ["parser-fuzz-test"])
    assert_gates(module, ["tools/lib/host-drivers/parser-fuzz-test.c"], ["parser-fuzz-test"])
    assert_gates(module, ["tools/toolchain/diagnostics-test.sh"], ["diagnostics-test"])
    assert_gates(module, ["tools/toolchain/mcc-cli-test.sh"], ["mcc-cli-test"])
    assert_gates(module, ["tools/toolchain/install-layout-test.sh"], ["install-layout-test"])
    assert_gates(module, ["tools/toolchain/path-remap-test.sh"], ["path-remap-test"])
    assert_gates(module, ["tools/toolchain/fmt-test.sh"], ["fmt-test"])
    assert_gates(module, ["tools/toolchain/mcc-symbols-test.sh"], ["mcc-symbols-test"])
    assert_gates(module, ["tools/toolchain/mcc-inspection-modules-test.sh"], ["mcc-inspection-modules-test"])
    assert_gates(module, ["tools/toolchain/mcc-list-tests-modules-test.sh"], ["mcc-list-tests-modules-test"])
    assert_gates(module, ["tools/toolchain/std-api-docs.py"], ["std-api-docs-test"])
    assert_gates(module, ["tools/toolchain/vendoring-test.py"], ["vendoring-test"])
    assert_gates(module, ["tools/toolchain/third-party-licenses-test.py"], ["third-party-licenses-test"])
    assert_gates(module, ["tools/toolchain/profile-manifest-test.py"], ["profile-manifest-test"])
    assert_gates(module, ["docs/profile-manifest.json"], ["profile-manifest-test"])
    assert_gates(module, ["docs/component-manifest.json"], ["profile-manifest-test", "vendoring-test"])
    assert_route(module, ["docs/scope-control-plan.md"], ["profile-manifest-test"], ["git diff --check"])
    assert_gates(module, ["docs/review-risk-register.yaml"], ["profile-manifest-test"])
    assert_gates(module, ["tools/toolchain/gate-manifest-test.py"], ["gate-manifest-test"])
    assert_gates(module, ["docs/gate-manifest.json"], ["gate-manifest-test"])
    assert_gates(module, ["tools/toolchain/lowering-coverage.sh"], ["lowering-coverage-inventory-test", "lowering-coverage"])
    assert_gates(module, ["tools/toolchain/lowering-coverage-inventory.py"], ["lowering-coverage-inventory-test", "lowering-coverage"])
    assert_gates(module, ["tools/toolchain/lowering-coverage-baseline.tsv"], ["lowering-coverage-inventory-test", "lowering-coverage"])
    assert_route(module, ["docs/lowering-coverage.md"], ["lowering-coverage-inventory-test", "lowering-coverage"], ["git diff --check"])
    assert_gates(module, ["tools/toolchain/semantic-facts-inventory.py"], ["semantic-facts-inventory-test"])
    assert_gates(module, ["tools/toolchain/architecture-boundary-inventory.py"], ["architecture-boundary-inventory-test"])
    assert_gates_include(module, ["src/backend.zig"], ["architecture-boundary-inventory-test"])
    assert_gates_include(module, ["src/lower_c_emitter.zig"], ["architecture-boundary-inventory-test"])
    assert_gates_include(module, ["src/lower_llvm.zig"], ["architecture-boundary-inventory-test"])
    assert_gates_include(module, ["src/type_syntax.zig"], ["architecture-boundary-inventory-test"])
    assert_route(module, ["docs/typed-semantic-facts.md"], ["semantic-facts-inventory-test", "mir-identity-inventory-test"], ["git diff --check"])
    assert_gates(module, ["tools/toolchain/compilation-session-inventory.py"], ["compilation-session-inventory-test"])
    assert_gates_include(module, ["src/main.zig"], ["compilation-session-inventory-test"])
    assert_route(module, ["docs/refactoring-plan.md"], ["compilation-session-inventory-test", "mir-identity-inventory-test"], ["git diff --check"])
    assert_gates(module, ["tools/toolchain/mir-identity-inventory.py"], ["mir-identity-inventory-test"])
    assert_gates_include(module, ["src/mir_model.zig"], ["test", "mir-identity-inventory-test"])
    assert_gates_include(module, ["src/mir.zig"], ["test", "mir-identity-inventory-test"])
    assert_gates_include(module, ["src/mir_tests.zig"], ["test", "mir-identity-inventory-test"])
    assert_gates(module, ["tools/toolchain/compiler-coverage.sh"], ["compiler-coverage"])
    assert_gates(module, ["tools/toolchain/compiler-coverage-baseline.tsv"], ["compiler-coverage"])
    assert_route(module, ["docs/compiler-coverage.md"], ["compiler-coverage"], ["git diff --check"])
    assert_gates(module, ["tools/toolchain/lowering-cov-instrument.py"], ["lowering-coverage", "compiler-coverage"])
    assert_route(
        module,
        ["tools/toolchain/mc-audit.sh"],
        ["unsafe-audit", "double-fetch-audit", "taint-audit", "capability-mint-audit"],
        ["bash tools/toolchain/mc-audit.sh --mode capability-mint --self-test 2>&1 | rg '^CAP-MINT '"],
    )
    assert_route(module, ["docs/unsafe-boundary.md"], ["unsafe-audit"], ["git diff --check"])
    assert_gates(module, ["tools/check/abi-consistency-test.sh"], ["abi-consistency-test"])
    assert_gates(module, ["tools/check/arch-emit-test.sh"], ["arch-emit-test"])
    assert_route(module, ["docs/std-api.md"], ["std-api-docs-test"], ["git diff --check"])
    assert_route(module, ["docs/vendoring.md"], ["vendoring-test"], ["git diff --check"])
    assert_route(module, ["THIRD-PARTY-LICENSES.md"], ["third-party-licenses-test"], ["git diff --check"])
    assert_gates(module, ["tools/toolchain/abi-test.sh"], ["abi-test"])
    assert_gates(module, ["tests/toolchain/abi_layout.mc"], ["abi-test"])
    assert_gates(module, ["tools/toolchain/asm-targets-test.sh"], ["asm-targets-test"])
    assert_gates(module, ["tests/toolchain/asm_targets.mc"], ["asm-targets-test"])
    assert_gates(module, ["tests/llvm/basic.mc"], ["llvm-test", "llvm-obj-test"])
    assert_gates(module, ["tools/toolchain/llvm-test.sh"], ["llvm-test"])
    assert_gates(module, ["tools/toolchain/llvm-obj-test.sh"], ["llvm-obj-test"])
    assert_gates(module, ["tools/toolchain/llvm-debug-test.sh"], ["llvm-debug-test"])
    assert_gates(module, ["tools/toolchain/llvm-std-test.sh"], ["llvm-std-test"])
    assert_gates(module, ["tools/toolchain/llvm-toolchain-test.sh"], ["llvm-toolchain-test"])
    assert_gates(module, ["tools/toolchain/llvm-runtime-test.sh"], ["llvm-runtime-test"])
    assert_gates(module, ["tools/toolchain/llvm-demo-test.sh"], ["llvm-demo-test"])
    assert_gates(module, ["tools/toolchain/llvm-kernel-test.sh"], ["llvm-kernel-test"])
    assert_gates(
        module,
        ["tools/toolchain/llvm-new-harness.sh"],
        ["llvm-test", "llvm-obj-test", "llvm-sweep", "llvm-c-obj-sweep"],
    )
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
    assert_gates(module, ["tools/mem/heap-bench.sh"], ["heap-bench", "llvm-heap-bench"])
    assert_gates(module, ["tools/proc/sched-bench.sh"], ["sched-bench", "llvm-sched-bench"])
    assert_gates(module, ["tools/mem/uaccess-bench.sh"], ["uaccess-bench", "llvm-uaccess-bench"])
    assert_gates(module, ["tools/arch/aarch64-test.sh"], ["aarch64-test", "llvm-aarch64-test"])
    assert_gates(module, ["tools/arch/qemu-mmio-test.sh"], ["qemu-test", "llvm-qemu-test"])
    assert_gates(module, ["tools/qemu/kernel-boot-lib.sh"], ["preflight", "riscv-qemu-validation"])
    assert_route(
        module,
        [".github/workflows/nightly-fuzz.yml"],
        [],
        ["git diff --check"],
    )
    assert_route(
        module,
        [".github/workflows/nightly-bench.yml"],
        [],
        ["git diff --check"],
    )
    assert_route(
        module,
        ["tools/ci/nightly-bench.py"],
        [],
        ["git diff --check"],
    )
    assert_route(
        module,
        ["tools/bench/nightly-baseline.tsv"],
        [],
        ["git diff --check"],
    )
    assert_gates(
        module,
        ["tools/toolchain/safe-release-parity.sh"],
        ["safe-release-parity"],
    )

    print("PASS: dev-gates-test - routing contracts are stable")


if __name__ == "__main__":
    main()
