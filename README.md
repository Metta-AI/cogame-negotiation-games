# Negotiation Games

A **three-seat bargaining table** for the Softmax Coworld platform, on the
[cogame-parley](https://github.com/Metta-AI/cogame-parley) technology stack
(forked from [cogame-babel](https://github.com/Metta-AI/cogame-babel)). A
port of OpenSpiel's `bargaining` (Lewis et al. 2017 / DeepMind).

Three cogs, six one-on-one matches. Each match puts a pool of **books, hats
and balls** between two of them. The pool is worth **exactly 10 points to
each side** — but the per-item values are *different* and *private*, so there
is almost always a split that beats a 50/50 hack. The two seats alternate for
at most ten turns: **OFFER** exactly how many of each item you take (your
opponent gets the rest), or **ACCEPT** the offer standing against you. Agree
and you both bank the value *to you* of what you took, out of 10. Run out of
turns and **both of you bank zero**. The third seat sits the match out.

Every match redraws the pairing, the pool and both seats' valuations, so
nothing learned about one opponent transfers to the next match. Offers may
carry a short message, but talk is cheap: the structured offer is the only
binding channel and the only thing that is graded.

**Spectators see both seats' hidden valuations**, so every offer reads
instantly as generous or greedy — and a `DEAL 7–3` / `NO DEAL` stamp closes
each match.

**The game is LLM-driven and a policy is just a prompt.** Whenever a seat has
to move, the server sends that seat's policy prompt plus the pool, its own
private values, the offer standing against it (with the worth to itself
already computed), this match's full history and its private notes to Claude,
which answers with an offer or an accept, a message and new notes. Player
containers exist only to deliver their prompt over the websocket. Two
built-in **scripted baselines** — a conceding `haggler` and a stubborn
`hardliner` — play any seat that registers as scripted, and every seat when
no LLM credentials are available, so episodes (and offline certification)
always complete.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy display
names never reach the agents' prompts, so nobody can meta-game "that seat is
the champion". The spectator and replay viewers map the aliases back to
policy names; results are reported under policy names.

**Scoring.** A settled match pays each side the value *to it* of what it
holds, 0..10 (a no-deal pays 0). Over the episode
`score = points / (10 × matches played)`, in `[0, 1]`, **higher is better**;
the league ranks seats by mean episode score. Results also carry `points`,
`matches`, `deals`, `giveaway` (the mechanical softplay audit: the mean of
*opponent's payoff − mine*) and `fallbacks`. The episode ends `complete` or,
if the play clock stops it between matches, `deadline`.

## Layout

- `src/negotiation.nim` — entrypoint (Coworld runtime contract, live vs replay)
- `src/negotiation/sim.nim` — pure rules: the seeded schedule (pairings,
  openers, pools, both seats' valuations), offer/accept, the turn cliff,
  tallies, endings, replay derivation; shared by server, tests and the wasm
  viewer
- `src/negotiation/llm.nim` — Claude client, the prompts, and the two
  scripted baselines
- `src/negotiation/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/negotiation_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED=haggler|hardliner`)
- `client/chrome_common.js` — the cogame-babel broadcast chrome, frozen
- `client/renderer.js` — the game block only (stage, feed, scorebug, endcard)
- `client/{global,player,replay_broadcast}.html`, `client/chrome.css`
- `replay-viewer/` — the static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — the `coworld build` replay-viewer hook
- `tools/build_manifest.py` — regenerates `coworld_manifest_template.json`
- `tools/ci/` — the CI harness (docker smoke, viewer smoke, manifest, chrome
  and replay gates)
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT)
- `docs/plans/` — the design note this game was built from

## Fielding a policy

```bash
coworld upload-policy coworld-negotiation-games:latest \
  --name my-negotiator --run /bin/negotiation-player \
  --secret-env PLAYER_PROMPT="Open by taking everything, concede the item you
value least, and never let a match end at zero."
```

`PLAYER_SCRIPTED=haggler` or `PLAYER_SCRIPTED=hardliner` fields a baseline
instead. Both entry points live in the same image.

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the paths
# are machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim
nim r --path:src tests/test_bot.nim
docker build -t coworld-negotiation-games:ci .
SMOKE_GAME_BIN=/bin/negotiation SMOKE_PLAYER_BIN=/bin/negotiation-player \
  ./tools/ci/docker_smoke.sh coworld-negotiation-games:ci
```

CI (`.github/workflows/ci.yml`) is the only harness that matters: it runs
every test twice (debug and release), builds the image, plays a real episode
in raw Docker, and opens the built wasm replay bundle in headless chromium
against the bytes that episode produced.
