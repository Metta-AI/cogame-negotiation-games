## Verify native captures against the source-owned seeded replay engine.
import std/[json, os, strutils]
import negotiation/[sim, llm, server, prompts]

let args = commandLineParams()
if args.len != 3: quit("usage: verify_native REPLAY TRAJECTORY EPISODE_ID", 1)
let replay = parseFile(args[0])
var captures: seq[JsonNode]
for line in readFile(args[1]).strip().splitLines(): captures.add(parseJson(line))
let summary = captures[^1]
let traceGame = summary["game"].getStr()
doAssert traceGame in ["negotiation", "negotiation-games"]
doAssert summary["event_type"].getStr() == "episode"
doAssert summary["episode_id"].getStr() == args[2]
doAssert summary["outcome"] == replay["results"]
let config = configFromReplay(replay)
doAssert summary["seed_family"].getStr() == $config.seed
var events: seq[GameEvent]
for event in replay["events"]: events.add(eventFromJson(event))
let frames = replayMatch(config, events)
let fullSchedule = frames[^1].done and frames[^1].reason == "complete"
doAssert frames[^1].resultsJson()["scores"] == replay["results"]["scores"]
doAssert (summary["status"].getStr() == "completed") == fullSchedule
var index = 0
var episodeSelection: JsonNode
for eventIndex, event in events:
  if event.kind in {evOffer, evAccept}:
    let seat = event.seat
    let capture = captures[index]
    doAssert capture["event_type"].getStr() == "decision"
    doAssert capture["game"].getStr() == traceGame
    doAssert capture["decision_index"].getInt() == index
    doAssert capture["decision_id"].getStr() == $eventIndex
    doAssert capture["seat"].getStr() == $seat
    let action = block:
      var action = %*{"action": (if event.kind == evOffer: "offer" else: "accept"), "message": event.text, "notes": event.notes}
      if event.kind == evOffer:
        var take = newJObject()
        for item in 0 ..< Items: take[ItemNames[item]] = %event.take[item]
        action["take"] = take
      action
    doAssert capture["executed_action"] == action
    doAssert capture["observation"]["view"] == decisionObservation(frames[eventIndex], seat)
    let operatorPrompt = capture["observation"]["operator_prompt"].getStr()
    let configuration = capture["observation"]["prompt_configuration"]
    if index == 0: episodeSelection = configuration
    doAssert configuration == episodeSelection
    let selection = if configuration.hasKey("bank"):
      promptSelection(%*{"promptVariant": configuration["selection"], "promptSeed": configuration["seed"]})
      else: promptSelection(configuration)
    if traceGame == "negotiation-games":
      doAssert configuration == selection.selectionMetadata()
    let system = systemPrompt(selection, frames[eventIndex], seat)
    let user = userPrompt(frames[eventIndex], seat, operatorPrompt)
    var modelAttempt = 0
    for attempt in capture["attempts"]:
      if attempt["origin"].getStr() == "model":
        doAssert attempt["prompt"][0]["content"].getStr() == system
        doAssert modelAttempt < 2
        let expectedUser = user & (if modelAttempt == 1: RetryHint else: "")
        doAssert attempt["prompt"][1]["content"].getStr() == expectedUser
        inc modelAttempt
        doAssert attempt["request"]["system"].getStr() == system
        doAssert attempt["request"]["messages"][0]["content"] == attempt["prompt"][1]["content"]
      if attempt["attempt_id"] == capture["selected_attempt_id"] and attempt["origin"].getStr() in ["model", "teacher"]:
        let parsed = parseAction(frames[eventIndex], extractJsonObject(attempt["response"].getStr()))
        var normalized = %*{"action": parsed.action, "message": parsed.message, "notes": parsed.notes}
        if parsed.action == "offer":
          var take = newJObject()
          for item in 0 ..< Items: take[ItemNames[item]] = %parsed.take[item]
          normalized["take"] = take
        doAssert normalized == action
    inc index
doAssert index == captures.len - 1
echo $(%*{"seed": config.seed, "scores": replay["results"]["scores"],
  "full_schedule": fullSchedule, "decisions": index, "policy_names": replay["policyNames"]})
