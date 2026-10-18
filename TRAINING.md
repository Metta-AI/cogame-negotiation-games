# Negotiation Games training

Both published variants use the production bargaining simulator and hosted text parser.
Episode prompt selection changes only the introduction. Shared rules, private observations,
canonical prompt bytes, action semantics, and sampled game budgets remain fixed.

## Episode wording

Game configuration and bridge resets accept `promptVariant`: `canonical` (default), `plain`,
`numbered`, `questions`, `reordered`, `heldout-briefing`, `heldout-reference`, or `mixed`.
Mixed selection requires a nonnegative `promptSeed`; its remainder modulo five selects a
training introduction. Selection stays fixed for the episode and does not advance simulation
randomness. The two held-out introductions are evaluation-only.

External observations carry `prompt_configuration` and the actual rendered `input.system`
and `input.user`. Native prompt policies receive the same selected renderer. Private source
and bridge metadata records the selected bank and exact system/user SHA-256 hashes.

## Complete language games

```bash
nim c --parallelBuild:1 --path:src -o:negotiation-train-bridge tools/train_bridge.nim
python tools/test_prompt_games.py ./negotiation-train-bridge
./negotiation-train-bridge coworld_manifest_template.json standard
```

The bridge reads one JSON object per line. Reset with
`{"kind":"reset","players":3,"seed":1,"promptVariant":"mixed","promptSeed":2}`.
Each decision exposes only the acting seat's valuation, public bargaining history, and its
own notes. Reply through `step` with the decision ID and a JSON response string. `teacher`
returns a published scripted policy's response. Offer counts, acceptance, public messages,
and private notes pass through the hosted parser and simulator. This bridge is text-only;
it does not supply a numeric codec for conditional offers.

Reset requests with `split: train` reject held-out wording. Teacher calls support deterministic
pipeline checks; they do not establish language-model quality.

## Review-required source candidates

```bash
nim c --parallelBuild:1 --path:src -o:negotiation-export tools/export_posttrain.nim
nim c --parallelBuild:1 --path:src -o:negotiation-check tools/check_episode.nim
./negotiation-export /tmp/negotiation-standard 10 1 standard mixed 2
```

Commit the source before exporting. The exporter requires at least ten complete games and
rejects held-out wording or an existing destination. It preserves the published variant's
sampled configuration and plays the haggler and hardliner policies through the real parser.

Outputs are owner-only private canonical trajectories, per-game replays, and a manifest
marked `review_required`. Every candidate is reconstructed through the production simulator:
private observations, rendered prompts, parsed responses, applied actions, all replay events,
and final outcomes must agree. Recheck retained evidence with
`./negotiation-check <episode.jsonl> <episode.replay.json>`.

There are no automatic training or validation projections. The shared Metta importer owns
scenario-family splitting and requires independent review before training admission. Families
use the scenario seed across wording and game variants, preventing replicas from crossing
splits. Historical exports remain unchanged; their existence is not training approval.

These checks measure pipeline correctness. Matched model evaluations and learning experiments
are still required to measure whether wording diversity improves robustness.
