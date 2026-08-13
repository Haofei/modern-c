#!/usr/bin/env python3

import importlib.util
import json
import unittest
from collections import deque
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("qmp_hotplug.py")
SPEC = importlib.util.spec_from_file_location("qmp_hotplug", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
qmp_hotplug = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(qmp_hotplug)


class FakeSocket:
    def __init__(self, reader=None, connect_error=None) -> None:
        self.requests: list[dict] = []
        self.reader = reader
        self.closed = False
        self.timeouts: list[float] = []
        self.connect_error = connect_error

    def sendall(self, payload: bytes) -> None:
        self.requests.append(json.loads(payload))

    def settimeout(self, timeout: float) -> None:
        self.timeouts.append(timeout)

    def connect(self, _path: str) -> None:
        if self.connect_error is not None:
            raise self.connect_error

    def makefile(self, *_args, **_kwargs):
        assert self.reader is not None
        return self.reader

    def close(self) -> None:
        self.closed = True


class FakeReader:
    def __init__(self, messages: list[dict]) -> None:
        self.messages = deque(json.dumps(message) + "\n" for message in messages)
        self.closed = False

    def readline(self) -> str:
        return self.messages.popleft() if self.messages else ""

    def close(self) -> None:
        self.closed = True


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

    def test_continuous_unrelated_traffic_obeys_absolute_deadline(self) -> None:
        client = client_with([{"event": "RESET", "data": {}}] * 10)
        ticks = iter([0.0, 0.1, 0.2, 0.6])
        with mock.patch.object(qmp_hotplug.time, "monotonic", side_effect=lambda: next(ticks)):
            with self.assertRaises(TimeoutError):
                client.execute("query-status", timeout=0.5)

    def test_event_queue_is_bounded(self) -> None:
        client = client_with([])
        client.events.extend(
            {"event": "RESET", "data": {}}
            for _ in range(qmp_hotplug.MAX_BUFFERED_MESSAGES)
        )
        with self.assertRaisesRegex(RuntimeError, "bounded capacity"):
            client._dispatch({"event": "RESET", "data": {}})

    def test_constructor_negotiates_and_close_is_idempotent(self) -> None:
        reader = FakeReader(
            [
                {"QMP": {"version": {}}},
                {"return": {}, "id": 1},
            ]
        )
        sock = FakeSocket(reader)
        with mock.patch.object(qmp_hotplug.QmpClient, "_connect", return_value=sock):
            client = qmp_hotplug.QmpClient(Path("/unused"))
        self.assertEqual("qmp_capabilities", sock.requests[0]["execute"])
        client.close()
        client.close()
        self.assertTrue(reader.closed)
        self.assertTrue(sock.closed)

    def test_constructor_failure_closes_partial_resources(self) -> None:
        reader = FakeReader([{"not_qmp": True}])
        sock = FakeSocket(reader)
        with mock.patch.object(qmp_hotplug.QmpClient, "_connect", return_value=sock):
            with self.assertRaisesRegex(RuntimeError, "invalid QMP greeting"):
                qmp_hotplug.QmpClient(Path("/unused"))
        self.assertTrue(reader.closed)
        self.assertTrue(sock.closed)

    def test_connect_retries_a_stale_socket_path(self) -> None:
        stale = FakeSocket(connect_error=ConnectionRefusedError())
        live = FakeSocket()
        with (
            mock.patch.object(
                qmp_hotplug.socket, "socket", side_effect=[stale, live]
            ),
            mock.patch.object(qmp_hotplug.time, "sleep"),
        ):
            connected = qmp_hotplug.QmpClient._connect(
                Path("/stale-qmp.sock"), qmp_hotplug.operation_deadline(1.0)
            )
        self.assertIs(live, connected)
        self.assertTrue(stale.closed)


if __name__ == "__main__":
    unittest.main()
