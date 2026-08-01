#!/usr/bin/env python3

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / "tools/toolchain/m0-timing-report.py"


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: m0-timing-report-test - {message}")


def main() -> None:
    with tempfile.TemporaryDirectory() as temp:
        directory = Path(temp)
        timings = directory / "timings.tsv"
        report = directory / "report.tsv"
        summary = directory / "summary.txt"
        timings.write_text("fast\t120\t0\nslow\t950\t0\nfailed\t400\t1\n")
        result = subprocess.run(
            [
                "python3", str(REPORT), "--input", str(timings), "--tsv", str(report),
                "--summary", str(summary), "--wall-ms", "500", "--outer-jobs", "4",
                "--inner-jobs", "1", "--top", "2",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            fail(result.stderr.strip())
        rows = report.read_text().splitlines()
        if rows[:3] != [
            "rank\tgate\telapsed_ms\tresult\tshare_of_gate_time_pct",
            "1\tslow\t950\t0\t64.63",
            "2\tfailed\t400\t1\t27.21",
        ]:
            fail(f"unexpected sorted report: {rows!r}")
        text = summary.read_text()
        if "effective_parallelism=2.94" not in text or "1\tslow\t950\t0\t64.63" not in text:
            fail(f"summary omits bottleneck data: {text!r}")
        if "3\tfast" in text:
            fail("--top did not limit the human report")
    print("PASS: m0-timing-report-test - stable sorted timing report preserves all gate rows")


if __name__ == "__main__":
    main()
