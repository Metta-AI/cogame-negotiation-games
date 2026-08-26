#!/usr/bin/env python3
"""Builds the worst-case renderer fixture replay (design note §Tests item 25).

`docker_smoke.sh` runs with no ANTHROPIC_API_KEY, so every seat plays a
scripted baseline and a scripted baseline emits no message and no notes:
EVERY replay CI produces carries zero LLM text, and nothing that plays one
can draw the message/notes chrome. This script takes that real replay — the
bytes the shipped wasm module is known to accept — and rewrites it into the
worst case:

  * a full-cap 200-rune multibyte message and a full-cap 400-rune multibyte
    note on every offer and every accept, on every seat;
  * the last match rewritten into a NO DEAL that runs the full turn cliff,
    so both stamps are exercised (the smoke's own matches all deal);
  * every derived field (`worth`, `payoff`) recomputed from the schedule's
    valuations, because the wasm re-derives them and raises on a mismatch.

Nothing is invented: the seed, the schedule and the pairing structure are
the smoke episode's own, so the module accepts the result.

Usage: python3 tools/ci/make_fixture_replay.py <in.json> <out.json>
"""
from __future__ import annotations

import json
import sys

# Multibyte on purpose: a byte-boundary cut would show up as mojibake here.
MESSAGE_UNIT = "négocions—jé "
NOTES_UNIT = "réserve ≥ 6 · céder les ballons—garder les livrés "


def runes(unit: str, count: int) -> str:
    text = (unit * (count // len(unit) + 2))[:count]
    assert len(text) == count, (len(text), count)
    return text


def worth(values: list[int], take: list[int]) -> int:
    return sum(values[i] * take[i] for i in range(3))


def main() -> int:
    source, target = sys.argv[1], sys.argv[2]
    replay = json.loads(open(source, encoding="utf-8").read())
    schedule = (replay.get("config") or {}).get("schedule") or []
    plans = {}
    for event in replay["events"]:
        if event.get("kind") == "match":
            plans[event["match"]] = event
    if not plans:
        raise SystemExit("the source replay has no match events")
    last = max(plans)

    message = runes(MESSAGE_UNIT, 200)
    notes = runes(NOTES_UNIT, 400)

    out = []
    for event in replay["events"]:
        kind = event.get("kind")
        if event.get("match") == last and kind in ("offer", "accept",
                                                   "matchEnd"):
            continue          # the last match is rebuilt below
        if kind in ("offer", "accept"):
            event = dict(event)
            event["text"] = message
            event["notes"] = notes
        out.append(event)
        if kind == "match" and event["match"] == last:
            plan = event
            pool = plan["pool"]
            values = plan["values"]
            seats = plan["seats"]
            opener_side = 0 if plan["opener"] == seats[0] else 1
            turns = plan.get("maxTurns") or 10
            for turn in range(1, turns + 1):
                side = opener_side if turn % 2 == 1 else 1 - opener_side
                # Taking the whole pool is always legal and always refused,
                # so the match runs the full cliff.
                out.append({
                    "kind": "offer",
                    "match": last,
                    "turn": turn,
                    "seat": seats[side],
                    "other": seats[1 - side],
                    "take": list(pool),
                    "worth": [worth(values[side], pool),
                              worth(values[1 - side], [0, 0, 0])],
                    "scripted": False,
                    "text": message,
                    "notes": notes,
                })
            out.append({
                "kind": "matchEnd",
                "match": last,
                "outcome": "no_deal",
                "payoff": [0, 0],
                "turn": turns,
            })

    replay["events"] = out
    # The endcard reads results; keep them consistent enough to render.
    results = replay.get("results") or {}
    if results:
        replay["results"] = results
    with open(target, "w", encoding="utf-8") as handle:
        json.dump(replay, handle, ensure_ascii=False)
    deals = sum(1 for e in out
                if e.get("kind") == "matchEnd" and e.get("outcome") == "deal")
    nodeals = sum(1 for e in out if e.get("kind") == "matchEnd" and
                  e.get("outcome") == "no_deal")
    print(f"fixture replay: {len(out)} events, {len(schedule)} scheduled "
          f"matches, {deals} deals, {nodeals} no-deals, "
          f"message={len(message)} runes, notes={len(notes)} runes -> {target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
