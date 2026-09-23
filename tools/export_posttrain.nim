## Export complete certified Negotiation Games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import negotiation/[llm, sim]

const OperatorPrompt = "Make deals that maximize your own score before the turn limit."
const Variants = ["standard", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %*["t0", "t1", "t2"]
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckMatch:
        sim.beginMatch()
      of ckAct:
        let teacher = scriptedDecision(sim,
          if call.seat == 2: "hardliner" else: "haggler")
        let completion = if teacher.action == "accept":
          %*{"action": "accept", "message": teacher.message,
            "notes": teacher.notes}
        else:
          %*{"action": "offer", "take": {
            "books": teacher.take[0], "hats": teacher.take[1],
            "balls": teacher.take[2]}, "message": teacher.message,
            "notes": teacher.notes}
        let parsed = parseAction(sim, completion)
        doAssert parsed.action == teacher.action and
          parsed.take == teacher.take and parsed.message == teacher.message and
          parsed.notes == teacher.notes
        rows.add($(%*{
          "episode_id": "negotiation-" & variant & "-" & $seed,
          "seed": "negotiation-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(sim, call.seat)},
            {"role": "user", "content": userPrompt(sim, call.seat,
              OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "negotiation-games",
          "action_schema_revision": "negotiation-offer-v1"
        }))
        if parsed.action == "accept":
          sim.applyAccept(call.match, parsed.message, parsed.notes, true)
        else:
          sim.applyOffer(call.match, parsed.take, parsed.message,
            parsed.notes, true)
      of ckNone:
        doAssert sim.done
    doAssert sim.reason == "complete" and
      sim.matchesSettled == config.matches
    let outcome = sim.resultsJson()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"],
      "matches_played": sim.matchesSettled})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "negotiation-games",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-haggler-and-hardliner",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
