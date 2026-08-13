#!/usr/bin/env python3

import json
import socket
import sys
import time
from collections import deque
from pathlib import Path
from typing import Deque, Dict, Optional


if sys.version_info < (3, 10):
    raise SystemExit("modern-c qualification tools require Python 3.10 or newer")


TIMEOUT_SECONDS = 30
MAX_BUFFERED_MESSAGES = 1024


def operation_deadline(timeout: float = TIMEOUT_SECONDS) -> float:
    return time.monotonic() + timeout


def remaining_time(deadline: float, operation: str) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError(f"{operation} timed out")
    return remaining


def wait_for_marker(log: Path, marker: str, timeout: float = TIMEOUT_SECONDS) -> None:
    deadline = operation_deadline(timeout)
    offset = 0
    pending = ""
    while True:
        remaining_time(deadline, f"live log marker {marker!r}")
        try:
            with log.open("r", encoding="utf-8", errors="replace") as stream:
                stream.seek(offset)
                chunk = stream.read()
                offset = stream.tell()
        except FileNotFoundError:
            chunk = ""
        if chunk:
            combined = pending + chunk
            if marker in combined:
                return
            keep = max(len(marker) - 1, 0)
            pending = combined[-keep:] if keep else ""
        time.sleep(min(0.05, remaining_time(deadline, f"live log marker {marker!r}")))


class QmpClient:
    def __init__(self, path: Path, timeout: float = TIMEOUT_SECONDS) -> None:
        self.socket: Optional[socket.socket] = None
        self.reader = None
        self.next_id = 1
        self.events: Deque[dict] = deque()
        self.responses: Dict[object, dict] = {}
        deadline = operation_deadline(timeout)
        try:
            self.socket = self._connect(path, deadline)
            self.reader = self.socket.makefile("r", encoding="utf-8")
            greeting = self._read(deadline, "QMP greeting")
            if "QMP" not in greeting:
                raise RuntimeError(f"invalid QMP greeting: {greeting}")
            self.execute("qmp_capabilities", deadline=deadline)
        except BaseException:
            self.close()
            raise

    @staticmethod
    def _connect(path: Path, deadline: float) -> socket.socket:
        last_error: Optional[OSError] = None
        while True:
            remaining_time(deadline, f"QMP connection to {path}")
            candidate = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                candidate.settimeout(remaining_time(deadline, f"QMP connection to {path}"))
                candidate.connect(str(path))
                return candidate
            except OSError as error:
                last_error = error
                candidate.close()
                time.sleep(min(0.05, remaining_time(deadline, f"QMP connection to {path}")))
            if time.monotonic() >= deadline:
                raise TimeoutError(f"QMP connection to {path} failed: {last_error}")

    def _read(self, deadline: float, operation: str) -> dict:
        if self.socket is None or self.reader is None:
            raise RuntimeError("QMP client is closed")
        self.socket.settimeout(remaining_time(deadline, operation))
        try:
            line = self.reader.readline()
        except socket.timeout as error:
            raise TimeoutError(f"{operation} timed out") from error
        if not line:
            raise RuntimeError("QMP connection closed")
        message = json.loads(line)
        if not isinstance(message, dict):
            raise RuntimeError(f"invalid QMP message: {message!r}")
        return message

    def _dispatch(self, message: dict) -> None:
        if "event" in message:
            if len(self.events) >= MAX_BUFFERED_MESSAGES:
                raise RuntimeError("QMP event queue exceeded its bounded capacity")
            self.events.append(message)
            return
        if "id" not in message:
            raise RuntimeError(f"QMP response has no command id: {message}")
        if len(self.responses) >= MAX_BUFFERED_MESSAGES and message["id"] not in self.responses:
            raise RuntimeError("QMP response queue exceeded its bounded capacity")
        self.responses[message["id"]] = message

    def execute(
        self,
        command: str,
        arguments: Optional[dict] = None,
        timeout: float = TIMEOUT_SECONDS,
        deadline: Optional[float] = None,
    ) -> None:
        command_deadline = deadline if deadline is not None else operation_deadline(timeout)
        if self.socket is None:
            raise RuntimeError("QMP client is closed")
        command_id = self.next_id
        self.next_id += 1
        request = {"execute": command, "id": command_id}
        if arguments:
            request["arguments"] = arguments
        self.socket.settimeout(remaining_time(command_deadline, f"QMP {command}"))
        self.socket.sendall((json.dumps(request) + "\n").encode())
        while True:
            response = self.responses.pop(command_id, None)
            if response is None:
                self._dispatch(self._read(command_deadline, f"QMP {command}"))
                continue
            if "error" in response:
                raise RuntimeError(f"QMP {command} failed: {response['error']}")
            if "return" in response:
                return
            raise RuntimeError(f"invalid QMP response for {command}: {response}")

    def wait_for_device_deleted(
        self, device: str, timeout: float = TIMEOUT_SECONDS
    ) -> None:
        deadline = operation_deadline(timeout)
        while True:
            for index, response in enumerate(self.events):
                if response.get("event") != "DEVICE_DELETED":
                    continue
                if response.get("data", {}).get("device") == device:
                    del self.events[index]
                    return
            self._dispatch(self._read(deadline, f"DEVICE_DELETED for {device}"))

    def close(self) -> None:
        reader, self.reader = self.reader, None
        sock, self.socket = self.socket, None
        if reader is not None:
            reader.close()
        if sock is not None:
            sock.close()

    def __enter__(self) -> "QmpClient":
        return self

    def __exit__(self, _exc_type, _exc, _traceback) -> None:
        self.close()


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: qmp-hotplug.py QMP_SOCKET LIVE_LOG")
    qmp_path = Path(sys.argv[1])
    log_path = Path(sys.argv[2])
    with QmpClient(qmp_path) as client:
        wait_for_marker(log_path, "VRNG-LIVE: transport hot-unplug ready")
        client.execute("device_del", {"id": "vrngdev"})
        client.wait_for_device_deleted("vrngdev")
        wait_for_marker(log_path, "VRNG-LIVE: transport hot-unplug observed")
        wait_for_marker(log_path, "VRNG-LIVE: transport hot-unplug teardown checked")
        client.execute(
            "device_add",
            {"driver": "virtio-rng-pci", "rng": "rng0", "id": "vrngdev"},
        )


if __name__ == "__main__":
    main()
