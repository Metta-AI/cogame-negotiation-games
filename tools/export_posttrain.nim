## Export complete certified Negotiation Games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import negotiation/[llm, sim, prompts]

const OperatorPrompt = "Make deals that maximize your own score before the turn limit."
const Variants = ["standard", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let configured = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  doAssert configured.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference}, "held-out wording is evaluation only"
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
    wordingCounts: array[2, int]
  for seed in firstSeed ..< firstSeed + games:
    var selection = configured
    let split = ord(seed mod 5 == 0)
    if selection.variant == pvMixed:
      selection.seed += wordingCounts[split]
      inc wordingCounts[split]
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
        let completion = teacher.decisionJson()
        let parsed = parseAction(sim, completion)
        doAssert parsed.action == teacher.action and
          parsed.take == teacher.take and parsed.message == teacher.message and
          parsed.notes == teacher.notes
        rows.add($(%*{
          "episode_id": "negotiation-" & variant & "-" & $seed & "-" &
            $selection.selectedVariant & "-" & $selection.seed,
          "seed": "negotiation-" & $seed,
          "prompt_template": selection.promptMetadata(systemPrompt(selection, sim, call.seat), userPrompt(sim, call.seat, OperatorPrompt)),
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(selection, sim, call.seat)},
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
