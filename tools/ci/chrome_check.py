#!/usr/bin/env python3
"""Static chrome gates (design note §Tests item 26).

  * every frozen id inherited from the cogame-babel broadcast page is still
    present in BOTH client/replay_broadcast.html and
    replay-viewer/index.html (a rewrite that reuses the starter's ids is not
    an inheritance — cogame-gridlock, 2026-08-23);
  * the game block (client/renderer.js) declares NO identifier from
    NegChrome's export list (a hoisted `function markBeat` in the game block
    shadowed the chrome alias on cogame-tandem, 2026-08-23);
  * client/chrome.css carries a rule for every beat class the scrubber
    emits;
  * replay-viewer/static_replay.js sets data-replay-loaded and posts the
    bridge `ready` AFTER it, never before (chorus, 2026-08-24).

Usage: python3 tools/ci/chrome_check.py
"""
from __future__ import annotations

import pathlib
import re
import sys

FROZEN_IDS = [
    "layout", "stage", "topband", "wordmark", "clock", "topright",
    "statuschip", "feedtoggle", "scorebug", "board-wrap", "table",
    "lightpool", "grain", "endscreen", "transport", "scrub", "play", "pos",
    "feed", "loading",
]
BEAT_KINDS = ["offer", "accept", "deal", "nodeal", "end"]

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[2]
    chrome_common = (root / "client/chrome_common.js").read_text(encoding="utf-8")
    game_block = (root / "client/renderer.js").read_text(encoding="utf-8")
    css = (root / "client/chrome.css").read_text(encoding="utf-8")
    shell = (root / "replay-viewer/static_replay.js").read_text(encoding="utf-8")

    # ---- the frozen id set -------------------------------------------------
    for name in ("client/replay_broadcast.html", "replay-viewer/index.html"):
        page = (root / name).read_text(encoding="utf-8")
        for frozen in FROZEN_IDS:
            check(f'id="{frozen}"' in page,
                  f"{name} is missing the inherited id #{frozen}")
        check('class="tbar"' in page, f"{name} is missing .tbar")
        check("viewpanel" not in page,
              f"{name} still carries #viewpanel; this fork ships no zoom bar")
        for extra in ("gameblock", "matchbar", "valuestrip"):
            check(f'id="{extra}"' in page,
                  f"{name} is missing the appended game block id #{extra}")

    # ---- no shadowing of the chrome's exports ------------------------------
    exported = re.search(r"window\.NegChrome\s*=\s*\{(.*?)\n  \};",
                         chrome_common, re.S)
    check(exported is not None, "could not read NegChrome's export list")
    names = sorted(set(re.findall(r"^\s{4}(\w+)\s*:",
                                  exported.group(1), re.M))) if exported else []
    check(len(names) > 10,
          f"NegChrome's export list looks wrong: {names}")
    for name in names:
        pattern = re.compile(
            r"(?:^|[^.\w$])(?:function|var|let|const|class)\s+" +
            re.escape(name) + r"\b")
        hit = pattern.search(game_block)
        check(hit is None,
              "client/renderer.js declares " + name + ", which shadows "
              "NegChrome." + name + " (cogame-tandem)")
    print(f"chrome_check: {len(names)} chrome exports, none shadowed")

    # ---- one CSS rule per beat kind the scrubber emits ---------------------
    emitted = sorted(set(re.findall(r"kind:\s*\"(\w+)\"", game_block)))
    for kind in BEAT_KINDS:
        check(kind in emitted,
              f"the game block never emits a `{kind}` scrubber beat")
        check(re.search(r"\.beat-marker\.%s\b" % re.escape(kind), css)
              is not None,
              f"client/chrome.css has no rule for .beat-marker.{kind}")
    check("<button" in chrome_common and "beat-marker" in chrome_common,
          "the scrubber must emit labelled <button> beats, not divs")
    check("aria-label" in chrome_common,
          "scrubber beats must carry an aria-label")

    # ---- the load signal ---------------------------------------------------
    loaded = shell.find('"data-replay-loaded"')
    ready = shell.find('tell("ready")')
    check(loaded >= 0,
          "static_replay.js never sets data-replay-loaded")
    check(ready >= 0, "static_replay.js never posts the bridge `ready`")
    check(loaded >= 0 and ready >= 0 and loaded < ready,
          "static_replay.js must post `ready` AFTER setting "
          "data-replay-loaded, from the same first-drawn-frame callback "
          "(chorus, 2026-08-24)")
    check("onFirstFrame" in shell and "onFirstFrame" in chrome_common,
          "the load signal must come from attachReplay's onFirstFrame "
          "callback, not a bare requestAnimationFrame at the call site")
    check("data-replay-error" in shell,
          "static_replay.js never sets data-replay-error")

    # ---- the scorebug stays legible at 360 px ------------------------------
    check(re.search(r"\.plate-name\s*\{[^}]*flex:\s*1 1 auto", css)
          is not None,
          ".plate-name must be flex: 1 1 auto")
    check(re.search(r"\.plate-name\s*\{[^}]*min-width:\s*3\.2em", css)
          is not None,
          ".plate-name must have min-width: 3.2em")
    check(re.search(r"max-width:\s*640px[^{]*\)\s*\{[^}]*\.plate-label\s*\{"
                    r"[^}]*display:\s*none", css, re.S) is not None,
          "plate labels must be hidden under 640 px")
    check("--band" in css and "--hudscale" in css,
          "chrome.css must use --band and --hudscale")

    if failures:
        for message in failures:
            print(f"::error::chrome_check: {message}")
        print(f"chrome_check: {len(failures)} failure(s)")
        return 1
    print("chrome_check: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
