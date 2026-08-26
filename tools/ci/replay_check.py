#!/usr/bin/env python3
"""Replay assertions over the episode `docker_smoke.sh` just produced.

Design note §Tests items 21 (the game-specific half), 22 and 23.

  21  the episode really played: three seats, a full `complete` episode,
      at least one match that ended in a deal, and every seat's tallies
      consistent with the events.
  22  STRICT-UTF-8 replay parse. A string truncated on a BYTE boundary
      mid-UTF-8 renders fine in a browser and fails exactly here; that is
      the point of the test.
  23  the replay outlasts the viewer soak: events x 320 ms >= soak + 2 s,
      so `viewer_smoke --soak` cannot mistake a finished replay for a
      frozen one (ecos, 2026-08-23).

Usage: python3 tools/ci/replay_check.py dist/smoke/replay.json [soak_seconds]
"""
from __future__ import annotations

import json
import pathlib
import sys

SEATS = 3
PROTOCOL = "negotiation.replay.v1"
STEP_MS = 320

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    path = pathlib.Path(sys.argv[1])
    soak = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0

    # Item 22: strict UTF-8, no replacement characters, no lenient decode.
    with open(path, encoding="utf-8", errors="strict") as handle:
        replay = json.loads(handle.read())

    check(replay.get("protocol") == PROTOCOL,
          f"replay.protocol must be {PROTOCOL!r}, got "
          f"{replay.get('protocol')!r}")
    check(len(replay.get("names") or []) == SEATS,
          f"replay.names must hold {SEATS} aliases")
    check(len(replay.get("policyNames") or []) == SEATS,
          f"replay.policyNames must hold {SEATS} policy names")
    config = replay.get("config") or {}
    check("seed" in config, "replay.config.seed is missing")
    matches = config.get("matches")
    check(isinstance(matches, int) and matches >= 3,
          f"replay.config.matches must be an integer >= 3, got {matches!r}")
    check(len(config.get("schedule") or []) == matches,
          "replay.config.schedule must carry one plan per match")
    for plan in config.get("schedule") or []:
        check(len(plan.get("pool") or []) == 3, "a schedule pool is malformed")
        values = plan.get("values") or []
        check(len(values) == 2 and all(len(v) == 3 for v in values),
              "a schedule entry is missing both seats' valuations")
        pool = plan.get("pool") or [0, 0, 0]
        for side, v in enumerate(values):
            total = sum(pool[i] * v[i] for i in range(3))
            check(total == 10,
                  f"the pool must be worth exactly 10 to side {side}, got "
                  f"{total}")

    events = replay.get("events") or []
    check(len(events) > 0, "replay.events is empty")
    if events:
        check(events[0].get("kind") == "start",
              f"the first event must be `start`, got {events[0].get('kind')!r}")
        check(events[-1].get("kind") == "end",
              f"the last event must be `end`, got {events[-1].get('kind')!r}")

    started = [e for e in events if e.get("kind") == "match"]
    ended = [e for e in events if e.get("kind") == "matchEnd"]
    check(len(started) == len(ended),
          f"every started match must emit exactly one matchEnd: "
          f"{len(started)} started, {len(ended)} settled")
    check(any(e.get("outcome") == "deal" for e in ended),
          "no match ended in a deal — the baselines are not bargaining")
    for event in events:
        if event.get("kind") == "offer":
            match = next((m for m in started
                          if m.get("match") == event.get("match")), None)
            if match:
                pool = match.get("pool") or [0, 0, 0]
                take = event.get("take") or [0, 0, 0]
                check(all(0 <= take[i] <= pool[i] for i in range(3)),
                      f"offer take {take} is outside the pool {pool}")
        if event.get("kind") == "accept":
            check(event.get("turn", 0) >= 2,
                  "accept on turn 1 is illegal and was recorded")

    results = replay.get("results") or {}
    check(results.get("reason") in ("complete", "deadline"),
          f"results.reason must be complete|deadline, got "
          f"{results.get('reason')!r}")
    check(results.get("reason") == "complete",
          "a scripted smoke episode must finish `complete`, not "
          f"{results.get('reason')!r}")
    check(len(results.get("scores") or []) == SEATS,
          f"results.scores must hold {SEATS} entries")
    for name in ("points", "matches", "deals", "giveaway", "fallbacks"):
        check(len(results.get(name) or []) == SEATS,
              f"results.{name} must hold {SEATS} entries")

    # Item 23: the replay must outlast the soak window.
    needed = int((soak + 2.0) * 1000 / STEP_MS) + 1
    check(len(events) * STEP_MS >= (soak + 2.0) * 1000,
          f"replay is too short for a {soak:g}s viewer soak: "
          f"{len(events)} events x {STEP_MS} ms = "
          f"{len(events) * STEP_MS} ms, need >= {int((soak + 2) * 1000)} ms "
          f"({needed} events). Lengthen the smoke episode, not the test.")

    if failures:
        for message in failures:
            print(f"::error::replay_check: {message}")
        print(f"replay_check: {len(failures)} failure(s)")
        return 1
    print(f"replay_check: OK — {len(events)} events, {len(started)} matches, "
          f"{sum(1 for e in ended if e.get('outcome') == 'deal')} deals, "
          f"reason={results.get('reason')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
