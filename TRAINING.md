# Negotiation Games training

The `negotiation-games-rules-v2` bank provides five training presentations and two
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
