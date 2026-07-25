#!/usr/bin/env python3

import importlib.util
import json
import unittest
from collections import deque
from pathlib import Path


SCRIPT = Path(__file__).with_name("qmp-hotplug.py")
SPEC = importlib.util.spec_from_file_location("qmp_hotplug", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
qmp_hotplug = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qmp_hotplug)


class FakeSocket:
    def __init__(self) -> None:
        self.requests: list[dict] = []

    def sendall(self, payload: bytes) -> None:
        self.requests.append(json.loads(payload))


class FakeReader:
    def __init__(self, messages: list[dict]) -> None:
        self.messages = deque(json.dumps(message) + "\n" for message in messages)

    def readline(self) -> str:
        return self.messages.popleft() if self.messages else ""


def client_with(messages: list[dict]):
    client = qmp_hotplug.QmpClient.__new__(qmp_hotplug.QmpClient)
    client.socket = FakeSocket()
    client.reader = FakeReader(messages)
    client.next_id = 1
    client.events = deque()
    client.responses = {}
    return client


class QmpOrderingTests(unittest.TestCase):
    def test_event_before_response_is_queued(self) -> None:
        client = client_with(
            [
                {"event": "DEVICE_DELETED", "data": {"device": "vrngdev"}},
                {"return": {}, "id": 1},
            ]
        )
        client.execute("device_del", {"id": "vrngdev"})
        client.wait_for_device_deleted("vrngdev")
        self.assertEqual([], list(client.events))

    def test_response_before_event_is_read_by_waiter(self) -> None:
        client = client_with(
            [
                {"return": {}, "id": 1},
                {"event": "DEVICE_DELETED", "data": {"device": "vrngdev"}},
            ]
        )
        client.execute("device_del", {"id": "vrngdev"})
        client.wait_for_device_deleted("vrngdev")

    def test_unrelated_messages_do_not_steal_target_response(self) -> None:
        client = client_with(
            [
                {"event": "RESET", "data": {}},
                {"return": {"other": True}, "id": 99},
                {"event": "DEVICE_DELETED", "data": {"device": "other"}},
                {"event": "DEVICE_DELETED", "data": {"device": "vrngdev"}},
                {"return": {}, "id": 1},
            ]
        )
        client.execute("device_del", {"id": "vrngdev"})
        client.wait_for_device_deleted("vrngdev")
        self.assertEqual({"other": True}, client.responses[99]["return"])
        self.assertEqual(["RESET", "DEVICE_DELETED"], [event["event"] for event in client.events])

    def test_command_ids_are_unique(self) -> None:
        client = client_with([{"return": {}, "id": 1}, {"return": {}, "id": 2}])
        client.execute("first")
        client.execute("second")
        self.assertEqual([1, 2], [request["id"] for request in client.socket.requests])


if __name__ == "__main__":
    unittest.main()
