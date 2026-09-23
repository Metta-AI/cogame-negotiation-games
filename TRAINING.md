# Negotiation Games training

Both certified variants have a local simulator and hosted text players. Export
complete episodes for Metta post-training with the hosted prompt and reply
parser:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/negotiation-standard 10 1 standard
nim r --path:src tools/export_posttrain.nim /tmp/negotiation-sprint 10 1 sprint
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json`, applies the same episode budget sampling as
the server, and plays seeded matches with the published haggler and hardliner
policies. It writes `train.jsonl`, `validation.jsonl`, and `manifest.json`.
Seeds divisible by five go to validation, keeping each episode in one split.
Every offer or accept passes the hosted parser and native simulator. The
exporter refuses an existing output directory.

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/negotiation-standard \
  --output /tmp/negotiation-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset imitates scripted play; its loss does not measure policy quality.
Negotiation's offer or accept action includes three bounded item counts, so
numeric Metta RL and PufferLib training need a conditional action codec.
