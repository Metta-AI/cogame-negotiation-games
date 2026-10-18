## Export complete certified Negotiation Games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, posix, strutils]
import negotiation/[llm, prompts, sim, qualification]

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
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  doAssert selection.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference},
    "held-out wording is evaluation only"
  doAssert execProcess("git status --porcelain").strip().len == 0,
    "commit qualified source before exporting pinned candidates"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  discard umask(Mode(0o077))
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    records: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %*["t0", "t1", "t2"]
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    config = sampleEpisode(config)
    var sim = initSim(config)
    let family = "negotiation-games-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    var rows: seq[JsonNode]
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
        let system = systemPrompt(selection, sim, call.seat)
        let user = userPrompt(sim, call.seat, OperatorPrompt)
        let messages = %*[{"role": "system", "content": system},
          {"role": "user", "content": user}]
        let attemptId = $rows.len & "-teacher"
        rows.add(%*{"schema_version": "1", "event_type": "decision",
          "episode_id": episode, "decision_id": $rows.len, "decision_index": rows.len,
          "game": "negotiation-games", "game_version": "source-" & sourceRevision,
          "source_revision": sourceRevision, "seat": $call.seat, "visibility": "private",
          "observation": {"view": sim.decisionObservation(call.seat),
            "operator_prompt": OperatorPrompt,
            "prompt_template": selection.promptMetadata(system, user)},
          "prompt": messages, "attempts": [{"attempt_id": attemptId,
            "policy": "scripted-haggler-and-hardliner", "origin": "teacher",
            "inference_mode": "text_action", "prompt": messages,
            "response": $completion, "parsed_action": completion,
            "accepted": true, "rejection_reason": newJNull(), "request": newJNull(),
            "platform_call_id": newJNull(), "behavior_logprobs": newJNull()}],
          "selected_attempt_id": attemptId, "executed_action": completion,
          "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
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
    var participants = newJObject()
    for seat in 0 ..< Seats:
      participants[$seat] = %*{"score": outcome["scores"][seat]}
    var gameRecords: seq[string]
    for index, row in rows:
      row["terminal"] = %(index == rows.high)
      gameRecords.add($row)
    gameRecords.add($(%*{"schema_version": "1", "event_type": "episode",
      "episode_id": episode, "seed_family": family, "game": "negotiation-games",
      "game_version": "source-" & sourceRevision, "source_revision": sourceRevision,
      "status": "completed", "outcome": outcome, "participant_outcomes": participants}))
    let jsonl = gameRecords.join("\n") & "\n"
    let replay = sim.replayJson(outcome)
    verifyEpisode(jsonl, replay)
    writeFile(output / (episode & ".jsonl"), jsonl)
    writeFile(output / (episode & ".replay.json"), $replay & "\n")
    records.add(jsonl)
    runs.add(%*{"seed": seed, "episode_id": episode, "decisions": rows.len,
      "trajectory": episode & ".jsonl", "replay": episode & ".replay.json",
      "scores": outcome["scores"], "matches_played": sim.matchesSettled})
  writeFile(output / "trajectories.jsonl", records.join(""))
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": "1", "format": "coworld-private-candidates-v1", "review_required": true,
    "game": "negotiation-games", "variant": variant, "source_revision": sourceRevision,
    "teacher": "scripted-haggler-and-hardliner", "operator_prompt": OperatorPrompt,
    "prompt_configuration": selection.selectionMetadata(), "runs": runs}) & "\n")
  echo "complete review-required games=", games
