#!/usr/bin/env python3
"""Append wall-clock command timing to a CSV file."""

import argparse
import csv
import subprocess
import time
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=Path)
parser.add_argument("--label", required=True)
parser.add_argument("command", nargs=argparse.REMAINDER)
args = parser.parse_args()
command = args.command[1:] if args.command[:1] == ["--"] else args.command
start = time.perf_counter_ns()
completed = subprocess.run(command)
elapsed = time.perf_counter_ns() - start
new_file = not args.output.exists()
with args.output.open("a", newline="") as stream:
    writer = csv.writer(stream)
    if new_file:
        writer.writerow(("label", "wall_ns", "exit_code"))
    writer.writerow((args.label, elapsed, completed.returncode))
raise SystemExit(completed.returncode)
