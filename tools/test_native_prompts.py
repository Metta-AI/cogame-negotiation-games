"""Play a complete published episode through three players and real HTTP calls."""

import argparse
import hashlib
import json
import os
import re
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[1]


class Fixture(ThreadingHTTPServer):
    mode: str
    requests: list
    seen: set


class Handler(BaseHTTPRequestHandler):
    server: Fixture

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"])).decode()
        request = json.loads(body)
        seat = int(self.headers["X-Coworld-Player-Slot"])
        user = request["messages"][0]["content"]
        match, turn = map(
            int, re.search(r"MATCH (\d+) of \d+\. TURN (\d+)", user).groups()
        )
        key = (match, turn, seat)
        action = {
            "action": "accept" if "ACCEPT IS LEGAL NOW: yes" in user else "offer",
            "message": "native café 🦉",
            "notes": f"private-{seat}",
        }
        if action["action"] == "offer":
            action["take"] = {"books": 0, "hats": 0, "balls": 0}
        reply = json.dumps(action, ensure_ascii=False)
        if self.server.mode == "rejected" or (
            self.server.mode == "retry" and key not in self.server.seen
        ):
            reply = "invalid fixture reply"
        self.server.seen.add(key)
        response = json.dumps(
            {
                "id": str(uuid4()),
                "model": "fixture/served",
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 100, "output_tokens": 20},
                "content": [{"type": "text", "text": reply}],
            }
        ).encode()
        self.server.requests.append((body, response.decode()))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("X-Softmax-Llm-Call-Id", json.loads(response)["id"])
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("verifier", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--variant", choices=("standard", "sprint"), default="sprint")
    parser.add_argument("--wording", default="canonical")
    parser.add_argument(
        "--mode", choices=("accepted", "retry", "rejected"), default="accepted"
    )
    args = parser.parse_args()
    os.umask(0o077)
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()
    manifest = json.loads((ROOT / "coworld_manifest_template.json").read_text())
    config = next(
        v["game_config"] for v in manifest["variants"] if v["id"] == args.variant
    )
    config.update(
        seed=7,
        promptVariant=args.wording,
        promptSeed=3,
        tokens=[f"t{i}" for i in range(3)],
    )
    (output / "config.json").write_text(json.dumps(config))
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    fixture = Fixture(("127.0.0.1", 0), Handler)
    fixture.mode, fixture.requests, fixture.seen = args.mode, [], set()
    thread = Thread(target=fixture.serve_forever, daemon=True)
    thread.start()
    env = {
        **os.environ,
        "COGAME_HOST": "127.0.0.1",
        "COGAME_PORT": str(port),
        "COGAME_CONFIG_URI": (output / "config.json").as_uri(),
        "COGAME_RESULTS_URI": (output / "results.json").as_uri(),
        "COGAME_SAVE_REPLAY_URI": (output / "replay.json").as_uri(),
        "NEGOTIATION_CAPTURE_DIR": str(output / "private"),
        "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{fixture.server_port}",
        "COWORLD_LLM_MODEL": "fixture/validation",
        "PLAYER_PROMPT": "Maximize your own score before the turn limit.",
        "PLAYER_SCRIPTED": "",
    }
    processes, logs = [], []
    try:
        log = (output / "game.log").open("w")
        logs.append(log)
        processes.append(
            subprocess.Popen([args.game], cwd=ROOT, env=env, stdout=log, stderr=log)
        )
        for _ in range(400):
            assert processes[0].poll() is None, (output / "game.log").read_text()
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.025)
        else:
            raise AssertionError("game listener did not start")
        for seat in range(3):
            log = (output / f"player-{seat}.log").open("w")
            logs.append(log)
            player_env = {
                **env,
                "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
            }
            processes.append(
                subprocess.Popen(
                    [args.player], cwd=ROOT, env=player_env, stdout=log, stderr=log
                )
            )
        for process in processes:
            assert process.wait(timeout=1220) == 0, output
        result = json.loads((output / "results.json").read_text())
        assert (
            result["reason"] == "complete"
            and result["matchesPlayed"] == config["matches"]
        )
        trace = output / "private/host.jsonl"
        events = [json.loads(line) for line in trace.read_text().splitlines()]
        assert trace.stat().st_mode & 0o777 == 0o600
        assert (
            events[0]["source_revision"] == revision and not events[0]["source_dirty"]
        )
        assert events[-1]["results"] == result
        selected = "questions" if args.wording == "mixed" else args.wording
        configuration = {
            "bank": "negotiation-games-rules-v1",
            "variant": selected,
            "selection": args.wording,
            "seed": 3,
        }
        assert events[0]["prompt_configuration"] == configuration
        started = {
            e["event_id"]: e for e in events if e["event_type"] == "decision_started"
        }
        resolved = {
            e["event_id"]: e for e in events if e["event_type"] == "decision_resolved"
        }
        model_file = output / "private/model.jsonl"
        assert model_file.stat().st_mode & 0o777 == 0o600
        model = [json.loads(line) for line in model_file.read_text().splitlines()]
        requests = {
            (e["event_id"], e["attempt"]): e
            for e in model
            if e["event_type"] == "request_sent"
        }
        responses = {
            (e["event_id"], e["attempt"]): e
            for e in model
            if e["event_type"] == "response_received"
        }
        parsed = {
            (e["event_id"], e["attempt"]): e
            for e in model
            if e["event_type"] == "response_parsed"
        }
        assert requests.keys() == responses.keys()
        wire = [
            (json.loads(request), response) for request, response in fixture.requests
        ]
        for key, row in requests.items():
            response = responses[key]
            wire.remove((row["request"], response["body"]))
            assert response["status"] == 200 and response["latency_ms"] >= 0
            assert (
                response["attribution"]["x-softmax-llm-call-id"]
                == json.loads(response["body"])["id"]
            )
            metadata = row["prompt_template"]
            assert {field: metadata[field] for field in configuration} == configuration
            user = row["request"]["messages"][0]["content"]
            for role, text in (("system", row["request"]["system"]), ("user", user)):
                assert (
                    metadata[role + "_sha256"]
                    == hashlib.sha256(text.encode()).hexdigest()
                )
            if key[1] == 0:
                assert metadata == started[key[0]]["prompt_template"]
            else:
                first = requests[(key[0], 0)]["request"]
                assert row["request"]["system"] == first["system"]
                assert user.startswith(
                    first["messages"][0]["content"]
                    + "\nYour previous reply was invalid."
                )
            for other in range(3):
                if other != row["seat"]:
                    assert f"private-{other}" not in user
        assert not wire
        for event_id, row in resolved.items():
            attempts = [key for key in requests if key[0] == event_id]
            assert len(attempts) == (1 if args.mode == "accepted" else 2)
            assert row["fallback"] == row["scripted"] == (args.mode == "rejected")
            accepted = [key for key in parsed if key[0] == event_id]
            assert len(accepted) == (0 if args.mode == "rejected" else 1)
            if accepted:
                actual = parsed[accepted[0]]
                assert row["action"]["action"] == actual["action"]
                assert (
                    row["action"]["notes"]
                    == actual["notes"]
                    == f"private-{row['seat']}"
                )
                assert row["action"]["message"] == actual["message"]
        (output / "http-archives.json").write_text(json.dumps(fixture.requests))
        (output / "http-archives.json").chmod(0o600)
        subprocess.run(
            [args.verifier, trace, output / "replay.json"], cwd=ROOT, check=True
        )
        print(
            args.variant, args.wording, args.mode, "full native game PASS", flush=True
        )
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=10)
        for log in logs:
            log.close()
        fixture.shutdown()
        fixture.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
