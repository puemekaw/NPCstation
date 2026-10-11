"""End-to-end HTTP/protocol and planner recovery tests, no GPU or Ollama needed."""

from copy import deepcopy
from contextlib import contextmanager
import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from bridge import BridgeServer, FakePlanner, OllamaPlanner, Planner, ProtocolError, action, validate_action, validate_request


def entity(target_id, name, kind, distance, *, held=False, visible=True):
    return {"id": target_id, "name": name, "kind": kind, "distance": distance,
            "held": held, "visible": visible, "pickable": kind == "item" and visible and not held,
            "position": {"x": 10, "y": 10, "z": 1}}


def request_payload(command="bring me that wrench", agent="crew-1", session="round-1"):
    return {"protocol_version": 1, "session_id": session, "agent_id": agent,
            "decision_id": "decision-1", "revision": 1,
            "observation": {"self": {"name": "NPC 1", "job": "Assistant", "empty_hands": 2},
                            "entities": [entity("person-1", "Player", "mob", 4),
                                         entity("item-1", "wrench", "item", 3)],
                            "events": [], "directive": {"id": 1, "speaker_id": "person-1", "text": command},
                            "last_result": None}}


@contextmanager
def running_server(planner, workers=2):
    with BridgeServer(("127.0.0.1", 0), planner, workers) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}"
        finally:
            server.shutdown()
            thread.join(timeout=5)


def post(url, payload):
    request = Request(url + "/v1/decision", data=json.dumps(payload).encode(),
                      headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=5) as response:
        return json.load(response)


class BridgeTests(unittest.TestCase):
    def test_fetch_round_trip_uses_actual_results(self):
        payload = request_payload()
        with running_server(FakePlanner()) as url:
            reply = post(url, payload)
            self.assertEqual(reply["action"], action("move_to", "item-1"))
            for key in ("session_id", "agent_id", "decision_id", "revision"):
                self.assertEqual(reply[key], payload[key])
            observation = payload["observation"]
            observation["entities"][1]["distance"] = 1
            payload["decision_id"] = "decision-2"
            reply = post(url, payload)
            self.assertEqual(reply["action"], action("pick_up", "item-1"))
            observation["entities"][1].update(held=1, pickable=0)  # Real DM boolean encoding
            payload["decision_id"] = "decision-3"
            reply = post(url, payload)
            self.assertEqual(reply["action"], action("move_to", "person-1"))
            observation["entities"][0]["distance"] = 1
            payload["decision_id"] = "decision-4"
            reply = post(url, payload)
            self.assertEqual(reply["action"], action("drop", "item-1"))
            observation["entities"][1].update(held=0, pickable=1)
            observation["last_result"] = {"decision_id": "decision-4", "type": "drop", "status": "success"}
            payload["decision_id"] = "decision-5"
            self.assertEqual(post(url, payload)["action"]["type"], "say")
            payload["decision_id"] = "decision-6"
            self.assertEqual(post(url, payload)["action"], action("wait", seconds=10))

    def test_failed_pickup_does_not_report_delivery_or_loop(self):
        payload = request_payload()
        payload["observation"]["entities"][1]["distance"] = 1
        planner = FakePlanner()
        self.assertEqual(planner.decide(payload)["type"], "pick_up")
        payload["observation"]["last_result"] = {
            "decision_id": "decision-1", "type": "pick_up", "status": "failure", "detail": "No empty hand."}
        payload["decision_id"] = "decision-2"
        reply = planner.decide(payload)
        self.assertIn("No empty hand", reply["text"])
        self.assertNotIn("Delivered", reply["text"])
        self.assertEqual(planner.decide(payload)["type"], "wait")

    def test_lost_item_aborts_fetch(self):
        payload = request_payload()
        planner = FakePlanner()
        planner.decide(payload)
        payload["observation"]["entities"].pop()
        self.assertIn("lost track", planner.decide(payload)["text"])

    def test_new_instruction_resets_task_and_crew_memories_are_isolated(self):
        planner = FakePlanner()
        fetch = request_payload()
        planner.decide(fetch)
        follow = request_payload("follow me", agent="crew-2")
        self.assertEqual(planner.decide(follow)["type"], "follow")
        self.assertEqual(planner.decide(fetch)["type"], "move_to")
        fetch["revision"] += 1
        fetch["observation"]["directive"] = {"id": 2, "speaker_id": "person-1", "text": "stop"}
        self.assertEqual(planner.decide(fetch)["type"], "stop")
        restarted_round = request_payload("follow me", session="round-2")
        self.assertEqual(planner.decide(restarted_round)["type"], "follow")

    def test_radio_command_does_not_reveal_requester_location(self):
        payload = request_payload("follow me")
        payload["observation"]["entities"][0].update(visible=0, distance=None, position=None)
        self.assertIn("come into view", FakePlanner().decide(payload)["text"])

    def test_unknown_targets_and_executable_actions_are_rejected(self):
        observation = request_payload()["observation"]
        candidates = [action("move_to", "[0x123456]"), action("call_proc", "/mob/proc/say"),
                      action("drop", "item-1"), action("wait", seconds=100),
                      action("say", text=";secret radio message"), action("follow", "item-1")]
        for candidate in candidates:
            with self.subTest(candidate=candidate), self.assertRaises(ProtocolError):
                validate_action(candidate, observation)

    def test_bad_observation_returns_400_and_server_recovers(self):
        with running_server(FakePlanner()) as url:
            bad = request_payload()
            bad["observation"]["directive"]["speaker_id"] = []
            with self.assertRaises(HTTPError) as caught:
                post(url, bad)
            self.assertEqual(caught.exception.code, 400)
            self.assertEqual(post(url, request_payload())["action"]["type"], "move_to")

    def test_bad_model_action_returns_502_and_releases_slot(self):
        class BrokenOnce(Planner):
            def __init__(self):
                super().__init__()
                self.broken = True

            def decide(self, payload):
                if self.broken:
                    self.broken = False
                    return {"type": "teleport"}
                return action("wait", seconds=10)

        with running_server(BrokenOnce(), workers=1) as url:
            with self.assertRaises(HTTPError) as caught:
                post(url, request_payload())
            self.assertEqual(caught.exception.code, 502)
            self.assertEqual(post(url, request_payload())["action"]["type"], "wait")

    def test_slow_model_has_bounded_concurrency_and_does_not_block_health(self):
        class SlowPlanner(Planner):
            entered = threading.Event()
            release = threading.Event()

            def decide(self, payload):
                self.entered.set()
                self.release.wait(timeout=5)
                return action("wait", seconds=10)

        planner = SlowPlanner()
        with running_server(planner, workers=1) as url:
            first_results = []
            thread = threading.Thread(target=lambda: first_results.append(post(url, request_payload())))
            thread.start()
            try:
                self.assertTrue(planner.entered.wait(timeout=2))
                with urlopen(url + "/health", timeout=2) as response:
                    self.assertEqual(json.load(response)["status"], "ok")
                with self.assertRaises(HTTPError) as caught:
                    post(url, request_payload(agent="crew-2"))
                self.assertEqual(caught.exception.code, 503)
            finally:
                planner.release.set()
                thread.join(timeout=5)
            self.assertEqual(len(first_results), 1)

    def test_ollama_uses_native_schema_and_checks_model_output(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        captured = []

        class OllamaStub(BaseHTTPRequestHandler):
            def do_POST(self):
                captured.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
                reply = {"message": {"content": json.dumps(action("move_to", "invented-item"))}}
                body = json.dumps(reply).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), OllamaStub) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                planner = OllamaPlanner("test-model", f"http://127.0.0.1:{server.server_port}")
                with self.assertRaises(ProtocolError):
                    planner.decide(request_payload())
                path, body = captured[0]
                self.assertEqual(path, "/api/chat")
                self.assertEqual(body["format"]["type"], "object")
                self.assertFalse(body["stream"])
                self.assertEqual(len(body["messages"]), 2)
                self.assertEqual(body["model"], "test-model")
            finally:
                server.shutdown()
                thread.join(timeout=5)

    def test_request_bounds_and_loopback_only(self):
        bad = deepcopy(request_payload())
        bad["observation"]["entities"] *= 65
        with self.assertRaises(ProtocolError):
            validate_request(bad)
        with self.assertRaises(ValueError):
            BridgeServer(("0.0.0.0", 0), FakePlanner())
        with self.assertRaises(ValueError):
            OllamaPlanner("test", "http://example.com:11434")


if __name__ == "__main__":
    unittest.main()

