# Jev System One negotiation pilot

September 23, 2026. The original pilot used game-side System One calls.
Those results remain historical evidence. The corrected Jev player sets
`PLAYER_JEV=1`, receives its own private values and public offer history,
and sends an offer or acceptance through the normal external action path.
The game validates the action and owns results and replay. Existing prompt
and scripted policies remain available.

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

The original `tools/jev_eval.nim` drove the old game-side transport and was
removed. For the corrected local player path, build the image and run
`SMOKE_JEV_SLOT=0 TYPESAFE_API_KEY=... tools/ci/docker_smoke.sh <image>`.
Run the same image without `SMOKE_JEV_SLOT` for a non-Jev control. The old
production canary below does not validate the corrected protocol.

## Hosted production canary

Version `negotiation-games:0.1.2` passed local and hosted Coworld certification. A private production Experience Request (`xreq_427faf94-8a8c-4bc3-b4a0-abaa66c41759`) used relh-owned `relh-negotiation-jev-20260923:v1` in slot 0, a scripted hardliner in slot 1, and a prompt-driven policy in slot 2. It used a $0.05 combined player LLM cap and no ladder submission. The episode completed with scores 0.9, 0.75, and 0.9; Kubernetes execution cost was $0.017077, separate from player model spend.

The game log records 11 Jev judgments for slot 0 and five for slot 2, all through the hosted System One sidecar. Slot 0 provider cost was $0.00063735, with 301 ms mean and 425 ms maximum client-observed latency. No scripted fallback was logged. This one episode verifies hosted operation, not a performance gain.
