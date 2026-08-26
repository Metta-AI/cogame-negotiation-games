#!/usr/bin/env python3
"""Manifest gate for negotiation-games (design note §Tests item 20).

Two halves:

1. Repo-local invariants this game pins — num_agents everywhere, the
   certification roster, no runner-managed `tokens` in any game_config,
   bounded arrays in config_schema, the protocols/docs shapes, the static
   replay-viewer bundle, and the secret namespace matching `game.name`.
2. The installed `coworld` CLI's OWN loaders, run offline:
   `coworld.bundle._load_template_manifest` (the pydantic upload contract,
   which is what phase 40's `coworld build` runs) and
   `coworld.manifest_validation.validate_coworld_manifest_game_configs`
   (every variant and the cert fixture against config_schema, with tokens
   injected). A manifest that repo CI likes but phase 40 rejects fails here
   instead (cogame-collab-cooking, 2026-08-25).

Usage: python3 tools/ci/manifest_check.py [manifest.json]
"""
from __future__ import annotations

import copy
import json
import pathlib
import sys

SEATS = 3
GAME_NAME = "negotiation-games"
IMAGE_PLACEHOLDER = "{{GAME_IMAGE}}"

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[2]
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else \
        root / "coworld_manifest_template.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    game = document.get("game") or {}

    # ---- seat count, everywhere -------------------------------------------
    variants = document.get("variants") or []
    check(len(variants) >= 1, "no variants declared")
    for variant in variants:
        config = variant.get("game_config") or {}
        check(config.get("num_agents") == SEATS,
              f"variant {variant.get('id')!r}: num_agents must be {SEATS}, "
              f"got {config.get('num_agents')!r}")
        check("tokens" not in config,
              f"variant {variant.get('id')!r}: game_config must not carry a "
              "literal `tokens` (the runner injects them)")
        check(len(config.get("players") or []) == SEATS,
              f"variant {variant.get('id')!r}: game_config.players must name "
              f"{SEATS} seats")

    certification = document.get("certification") or {}
    cert_config = certification.get("game_config") or {}
    check(cert_config.get("num_agents") == SEATS,
          f"certification.game_config.num_agents must be {SEATS}")
    check("tokens" not in cert_config,
          "certification.game_config must not carry a literal `tokens`")
    cert_players = certification.get("players") or []
    check(len(cert_players) == SEATS,
          f"certification.players must seat {SEATS} slots, got "
          f"{len(cert_players)}")
    check(len(cert_config.get("players") or []) == SEATS,
          f"certification.game_config.players must name {SEATS} seats")

    # ---- every declared runnable is seated --------------------------------
    declared = [entry.get("id") for entry in (document.get("player") or [])]
    check(len(declared) >= 1, "no player runnables declared")
    seated = {entry.get("player_id") for entry in cert_players}
    for player_id in declared:
        check(player_id in seated,
              f"player {player_id!r} has no certification slot "
              "(certification would fail players_missing)")
    for entry in document.get("player") or []:
        check(entry.get("image") == IMAGE_PLACEHOLDER,
              f"player {entry.get('id')!r} image must be "
              f"{IMAGE_PLACEHOLDER}")
        limits = ((entry.get("resources") or {}).get("limits") or {})
        check(limits.get("cpu") == "1",
              f"player {entry.get('id')!r} resources.limits.cpu must be "
              "\"1\" (a 500m limit is rejected at upload)")

    # ---- game block --------------------------------------------------------
    check(game.get("name") == GAME_NAME,
          f"game.name must be {GAME_NAME!r}")
    check(bool(game.get("description")),
          "game.description is required by the platform validator")
    check("tags" not in game,
          "game.tags is forbidden; tags live at the top level only")
    check(len(document.get("tags") or []) >= 3,
          "at least three top-level tags are required")
    check("version" not in document, "no top-level version key")
    check("version" not in game, "game.version is set by `coworld build`")
    check("display_name" not in game, "game.display_name is not permitted")
    check(bool(game.get("owner")), "game.owner is required")
    check((game.get("replay_viewer") or {}).get("bundle") ==
          "static-replay-viewer",
          "game.replay_viewer.bundle must be \"static-replay-viewer\", "
          "nested under game")
    check("replay_viewer" not in document,
          "replay_viewer must be nested under game, not top-level")
    check((game.get("runnable") or {}).get("type") == "game",
          "game.runnable.type must be \"game\"")
    check("episode_timeout_minutes" in document,
          "episode_timeout_minutes must be declared at the top level")

    # ---- the secret namespace equals game.name ----------------------------
    env = (game.get("runnable") or {}).get("env") or {}
    uri = env.get("ANTHROPIC_API_KEY_URI")
    check(uri == f"secret://coworld/{GAME_NAME}/anthropic_api_key",
          "game.runnable.env.ANTHROPIC_API_KEY_URI must be "
          f"secret://coworld/{GAME_NAME}/anthropic_api_key — without it the "
          "hosted container never sees the key and every league episode "
          f"silently plays scripted (got {uri!r})")

    # ---- config_schema: every array property is bounded -------------------
    schema = game.get("config_schema") or {}
    check(schema.get("additionalProperties") is False,
          "config_schema.additionalProperties must be false")
    for key in ("tokens", "players"):
        check(key in (schema.get("required") or []),
              f"config_schema must require {key!r}")
    for name, prop in (schema.get("properties") or {}).items():
        if isinstance(prop, dict) and prop.get("type") == "array":
            check("minItems" in prop and "maxItems" in prop,
                  f"config_schema.properties.{name} is an array and must "
                  "declare both minItems and maxItems")
    num_agents = (schema.get("properties") or {}).get("num_agents") or {}
    check(num_agents.get("minimum") == SEATS and
          num_agents.get("maximum") == SEATS,
          f"config_schema num_agents must be pinned to {SEATS}")

    # ---- results_schema ----------------------------------------------------
    results = game.get("results_schema") or {}
    for name in ("names", "scores", "points", "matches", "deals",
                 "giveaway", "fallbacks"):
        prop = (results.get("properties") or {}).get(name) or {}
        check(prop.get("minItems") == SEATS and prop.get("maxItems") == SEATS,
              f"results_schema.properties.{name} must be bounded to {SEATS}")
    reason = (results.get("properties") or {}).get("reason") or {}
    check("complete" in (reason.get("description") or "") and
          "deadline" in (reason.get("description") or ""),
          "results_schema.reason must document complete | deadline")

    # ---- protocols and docs ------------------------------------------------
    protocols = game.get("protocols") or {}
    for name in ("player", "global"):
        block = protocols.get(name)
        check(isinstance(block, dict) and block.get("type") == "text" and
              isinstance(block.get("value"), str) and block["value"],
              f"game.protocols.{name} must be a "
              "{\"type\":\"text\",\"value\":…} object — a bare string fails "
              "the platform validator, not repo CI")
    docs = game.get("docs") or {}
    readme = docs.get("readme")
    check(isinstance(readme, dict) and readme.get("type") == "text" and
          isinstance(readme.get("value"), str) and readme["value"],
          "game.docs.readme must be a {\"type\":\"text\",\"value\":…} object")
    pages = docs.get("pages") or []
    check(len(pages) == 2, "game.docs.pages must carry two pages")
    page_ids = {page.get("id") for page in pages}
    check(page_ids == {"rules.md", "writing-a-policy.md"},
          f"game.docs.pages ids must be rules.md and writing-a-policy.md, "
          f"got {sorted(page_ids)}")
    for page in pages:
        content = page.get("content")
        check(isinstance(content, dict) and content.get("type") == "text" and
              isinstance(content.get("value"), str) and content["value"],
              f"page {page.get('id')!r} content must be a "
              "{\"type\":\"text\",\"value\":…} object")
        check(bool(page.get("title")), f"page {page.get('id')!r} needs a title")

    # ---- the CLI's own loaders, offline -----------------------------------
    try:
        from coworld.bundle import _load_template_manifest
        from coworld.manifest_validation import (
            validate_coworld_manifest_game_configs,
        )
    except Exception as error:  # pragma: no cover - install failure
        failures.append(
            "could not import the coworld CLI's manifest loaders "
            f"({error!r}). This check is the gate that stops a manifest repo "
            "CI likes from failing phase 40; install coworld and re-run."
        )
    else:
        try:
            manifest = _load_template_manifest(
                copy.deepcopy(document),
                "0.0.1",
                {IMAGE_PLACEHOLDER: "coworld-negotiation-games:latest"},
            )
            validate_coworld_manifest_game_configs(manifest)
            print("coworld CLI validators: OK")
        except Exception as error:
            failures.append(
                "the coworld CLI rejected this manifest (phase 40 would fail "
                f"at `coworld build`): {type(error).__name__}: {error}"
            )

    if failures:
        for message in failures:
            print(f"::error::manifest_check: {message}")
        print(f"manifest_check: {len(failures)} failure(s)")
        return 1
    print(f"manifest_check: OK ({path})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
