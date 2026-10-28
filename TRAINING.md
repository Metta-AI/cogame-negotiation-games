# Negotiation Games training

The `negotiation-games-rules-v3` bank provides five training presentations and two
evaluation-only presentations. Complete explanations of private values, offers,
acceptance, turn limits, payoffs, cheap talk, and private notes vary in wording and
order. Canonical messages, sampled game budgets, and action syntax stay fixed.

Set `promptVariant` and `promptSeed` in game configuration or bridge resets.
`mixed` requires a nonnegative explicit seed and selects one presentation for the
episode without consuming game randomness. Native prompt calls and external player
observations use the same renderer. Metadata records selection and exact message hashes.

## Complete language games

```sh
negotiation-train-bridge coworld_manifest_template.json standard
python3 tools/test_prompt_games.py BRIDGE
```

The bridge uses the production parser and simulator. Acting seats receive only their
own private valuation, public bargaining history, and private notes. `reset` accepts
three players, a scenario seed, and prompt selection. `teacher` returns the scripted
action; `step` accepts the decision ID and JSON reply. Notes persist privately, and
messages reach the opponent. Held-out wording is rejected for training resets.

## Teacher exports

```sh
export_posttrain PRIVATE_OUTPUT 10 1 standard mixed 0
export_posttrain PRIVATE_OUTPUT 10 1 sprint mixed 0
```

The original train/validation JSONL and manifest are retained. Every fifth scenario
is validation; scenario families use `negotiation-SEED` across both variants. Mixed
exports cycle separately within each split so all five presentations reach training.
Each reply passes through the hosted parser and native simulator using the ordinary
sampled manifest budget. Existing output directories are refused. Run from clean
committed source so revision pins identify the exported code.

Corpora require content review before training. Scripted parity checks do not measure
model quality or establish resistance to training collapse. Numeric training still
requires a separate conditional action codec for offer/accept and item quantities.

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test`
split. Omitted, training, and unrecognized splits reject them.

Version three independently phrases the numbered, question-led, reordered, and
held-out rules. Canonical/plain text and response syntax remain unchanged. Export
episode IDs include requested selection, resolved wording, and prompt seed; gameplay seed families stay fixed.

## Hosted private trace identity

New private traces use catalog identity `negotiation-games`, matching the registered
engine and authenticated serving receipts. Their `observation.prompt_configuration`
uses the same complete bank/variant/selection/seed metadata as native external
observation frames. This fixes the old incomplete configuration object without
changing rule wording, model requests, offers, acceptance, private values, notes,
match budgets or outcomes.

The source-owned replay verifier explicitly retains the archived `negotiation`
name and raw prompt-selection format. It checks current canonical bank metadata
and decision identity consistently. Stored traces and old failed admissions are
not rewritten or granted new authority by this source correction. Recollect on a
source-pinned certified release, independently join provider receipts and review
physical/dependency families before preparing a learner.

The complete system check runs both ordinary manifest variants at two seeds through
the actual game server and bundled reference players. It verifies typed prompt-bank
metadata, executed actions and terminal replay scores, owner-readable private
artifacts and legacy reader support. Its scripted fixture responses are software
qualification, not real-model training data. Only spectator pacing is removed;
match counts, turn limits and gameplay remain the ordinary native ones.

```sh
nim c -d:release --path:src -o:/path/negotiation src/negotiation.nim
nim c -d:release --path:src -o:/path/player src/negotiation_player.nim
nim c -d:release --path:src -o:/path/verifier tools/verify_native_posttrain.nim
python3 tools/test_native_trace_identity.py /path/negotiation /path/player /path/verifier /new/private/output
```
