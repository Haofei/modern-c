#!/usr/bin/env python3

import json
import socket
import sys
import time
from pathlib import Path


TIMEOUT_SECONDS = 30


def wait_for_path(path: Path) -> None:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise TimeoutError(f"QMP socket was not created: {path}")


def wait_for_marker(log: Path, marker: str) -> None:
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            if marker in log.read_text(errors="replace"):
                return
        except FileNotFoundError:
            pass
        time.sleep(0.05)
    raise TimeoutError(f"live log did not reach marker: {marker}")


class QmpClient:
    def __init__(self, path: Path) -> None:
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(TIMEOUT_SECONDS)
        self.socket.connect(str(path))
        self.reader = self.socket.makefile("r", encoding="utf-8")
        greeting = self._read()
        if "QMP" not in greeting:
            raise RuntimeError(f"invalid QMP greeting: {greeting}")
        self.execute("qmp_capabilities")

    def _read(self) -> dict:
        line = self.reader.readline()
        if not line:
            raise RuntimeError("QMP connection closed")
        return json.loads(line)

    def execute(self, command: str, arguments: dict | None = None) -> None:
        request = {"execute": command}
        if arguments:
            request["arguments"] = arguments
        self.socket.sendall((json.dumps(request) + "\n").encode())
        while True:
            response = self._read()
            if "error" in response:
                raise RuntimeError(f"QMP {command} failed: {response['error']}")
            if "return" in response:
                return

    def wait_for_device_deleted(self, device: str) -> None:
        while True:
            response = self._read()
            if response.get("event") != "DEVICE_DELETED":
                continue
            data = response.get("data", {})
            if data.get("device") == device:
                return

    def close(self) -> None:
        self.reader.close()
        self.socket.close()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: qmp-hotplug.py QMP_SOCKET LIVE_LOG")
    qmp_path = Path(sys.argv[1])
    log_path = Path(sys.argv[2])
    wait_for_path(qmp_path)
    client = QmpClient(qmp_path)
    try:
        wait_for_marker(log_path, "VRNG-LIVE: transport hot-unplug ready")
        client.execute("device_del", {"id": "vrngdev"})
        client.wait_for_device_deleted("vrngdev")
        wait_for_marker(log_path, "VRNG-LIVE: transport hot-unplug observed")
        client.execute(
            "device_add",
            {"driver": "virtio-rng-pci", "rng": "rng0", "id": "vrngdev"},
        )
    finally:
        client.close()


if __name__ == "__main__":
    main()
