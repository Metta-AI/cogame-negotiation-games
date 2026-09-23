# Jev System One negotiation pilot

September 23, 2026. This pilot selects a structured offer or accept action
from a bounded legal set. The game server makes the System One call because
player policies in Negotiation Games only deliver a prompt. Jev sees the
acting seat's own values, public offer history, and operator guidance through
the existing prompt builder. It never receives the opponent's private values.
The candidate set contains offers at several own-payoff thresholds, the
scripted haggler's exact move, and accept when legal. Jev emits no table talk.

Set `NEGOTIATION_JEV=1` on the game process. Hosted calls use its Coworld
sidecar and a player-slot header. Local calls use `OPENROUTER_API_KEY` and
`typesafe/jev-1.13`. A local System One capture proxy can instead be selected
with `METTA_CAPTURE_URL` and `METTA_CAPTURE_KEY`; it receives one trajectory ID
per seed. No game version or hosted policy was uploaded for this pilot.

## Paired local episodes

Each arm uses the same seed, three matches, and scripted haggler opponents.
Seat 0 is the only Jev seat. Calls are capped at 30 per episode.

| Seed | Jev seat score | Haggler seat score | Jev calls | Jev cost |
| --- | ---: | ---: | ---: | ---: |
| 0 | 0.65 | 0.60 | 8 | $0.00044117 |
| 1 | 0.80 | 0.90 | 4 | $0.00020706 |
| 2 | 0.85 | 0.85 | 5 | $0.00025423 |

The 17 calls cost $0.00090245 in total. Response time averaged 275 ms; the
maximum was 445 ms. The mean seat-0 score difference was -0.017 across three
seeds. This sample does not establish a win-rate or social-intelligence effect.
The candidate set and haggler opponent constrain the result; neither arm
generates chat.

The local `linux/amd64` container smoke ran the certification roster: one Jev
prompt policy, one haggler, and one hardliner. It completed three matches with
scores 0.80, 0.50, 0.80, zero fallbacks, five logged Jev judgments, and a
replay. Those judgments cost $0.000282786 and averaged 286 ms. A separate
capture-proxy run recorded six System One requests and six matching HTTP 200
responses under one trajectory ID. Raw bodies are retained in the owner's
ignored `train_dir/jev-multigame/` directory, not committed as training labels.
An HTTP sidecar stub completed nine Jev decisions with both sidecar and
OpenRouter variables present; every request carried slot 0 and no bearer key.

## Reproduce

Generate the ignored `nim.cfg` with the package paths shown in `README.md`,
then run:

```bash
nim c -r --path:src tests/test_sim.nim
nim c -d:release --path:src -o:tmp/jev_eval tools/jev_eval.nim
NEGOTIATION_JEV=1 OPENROUTER_API_KEY="$APPROVED_KEY" tmp/jev_eval 0
docker build --platform linux/amd64 -t coworld-negotiation-games:jev-local .
NEGOTIATION_JEV=1 OPENROUTER_API_KEY="$APPROVED_KEY" \
  SMOKE_GAME_BIN=/bin/negotiation SMOKE_PLAYER_BIN=/bin/negotiation-player \
  SMOKE_GAME_LOG_OUT=/tmp/negotiation-jev-game.log \
  bash tools/ci/docker_smoke.sh coworld-negotiation-games:jev-local
```

To capture calls, run Metta's `metta_posttrain.capture` proxy with an approved
OpenRouter inference key, then set `METTA_CAPTURE_URL` and `METTA_CAPTURE_KEY`
on the game process. The proxy stores request and response JSONL lines. The
game still requires an action-to-outcome join before those lines can become
post-training examples.

The Jev transport is behind a game-process flag. Deploying it to a hosted
league requires a new Coworld game version; uploading a prompt-only player to
the current game would continue to use its existing Claude path. No hosted
performance claim follows from these local runs.
