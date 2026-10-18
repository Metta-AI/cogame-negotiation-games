## Verify a complete private native host trace against production state and replay.
import std/[json, os, strutils]
import negotiation/[llm, prompts, sim]

let args = commandLineParams()
doAssert args.len == 2, "usage: check_native HOST_TRACE REPLAY"
var records: seq[JsonNode]
for line in readFile(args[0]).splitLines():
  if line.len > 0: records.add(parseJson(line))
let replay = parseFile(args[1])
let start = records[0]
doAssert start["event_type"].getStr() == "host_started"
doAssert not start["source_dirty"].getBool()
let metadata = start["prompt_configuration"]
let selection = promptSelection(%*{"promptVariant": metadata["selection"], "promptSeed": metadata["seed"]})
doAssert selection.selectionMetadata() == metadata
let raw = copy(start["config"])
raw["players"] = newJArray()
for name in replay["policyNames"]: raw["players"].add(%*{"name": name})
var config = defaultGameConfig()
config.update($raw)
var game = initSim(config)
var resolved: JsonNode
var phase = "started"
for index in 1 ..< records.len:
  let row = records[index]
  case row["event_type"].getStr()
  of "decision_started":
    doAssert phase in ["started", "applied"]
    if game.currentCall().kind == ckMatch: game.beginMatch()
    let seat = game.currentCall().seat
    doAssert row["event_id"].getInt() == game.events.len and row["seat"].getInt() == seat
    doAssert row["view"] == game.decisionObservation(seat)
    doAssert row["prompt_template"] == selection.promptMetadata(systemPrompt(selection, game, seat),
      userPrompt(game, seat, row["operator_prompt"].getStr()))
    phase = "observed"
  of "decision_resolved":
    doAssert phase == "observed"
    doAssert row["event_id"].getInt() == game.events.len
    resolved = row
    phase = "resolved"
  of "action_applied":
    doAssert phase == "resolved"
    let call = game.currentCall()
    doAssert row["event_id"].getInt() == game.events.len and row["seat"].getInt() == call.seat
    doAssert resolved["seat"] == row["seat"]
    let at = game.events.len
    let action = parseAction(game, resolved["action"])
    if action.action == "accept":
      game.applyAccept(call.match, action.message, action.notes, resolved["scripted"].getBool())
    else:
      game.applyOffer(call.match, action.take, action.message, action.notes, resolved["scripted"].getBool())
    if resolved["fallback"].getBool(): game.recordFallback(call.seat)
    var events = newJArray()
    for event in game.events[at .. ^1]: events.add(event.eventToJson())
    doAssert events == row["events"]
    phase = "applied"
  of "host_completed":
    doAssert index == records.high and phase == "applied" and game.done
    doAssert row["results"] == game.resultsJson()
    phase = "completed"
  else: raise newException(ValueError, "unknown native event")
doAssert phase == "completed"
doAssert game.replayJson(game.resultsJson()) == replay
echo "complete native private decisions and public replay qualified"
