## Reconstruct full private candidate games and the production public replay.
import std/[json, strutils]
import llm, prompts, sim

proc verifyEpisode*(jsonl: string, replay: JsonNode) =
  var records: seq[JsonNode]
  for line in jsonl.splitLines():
    if line.len > 0: records.add(parseJson(line))
  let episode = records[^1]
  doAssert episode["event_type"].getStr() == "episode"
  doAssert episode["status"].getStr() == "completed"
  doAssert episode["outcome"] == replay["results"]
  let raw = copy(replay["config"])
  raw["tokens"] = %*["t0", "t1", "t2"]
  raw["players"] = newJArray()
  for name in replay["policyNames"]:
    raw["players"].add(%*{"name": name})
  var config = defaultGameConfig()
  config.update($raw)
  var game = initSim(config)
  doAssert episode["seed_family"].getStr() == "negotiation-games-" & $config.seed
  var index = 0
  while not game.done:
    let call = game.currentCall()
    case call.kind
    of ckMatch: game.beginMatch()
    of ckAct:
      let row = records[index]
      doAssert row["event_type"].getStr() == "decision"
      doAssert row["visibility"].getStr() == "private"
      doAssert row["action_status"].getStr() == "accepted"
      doAssert row["fallback_origin"].kind == JNull
      doAssert row["decision_index"].getInt() == index
      doAssert row["episode_id"] == episode["episode_id"]
      doAssert row["source_revision"] == episode["source_revision"]
      doAssert row["seat"].getStr() == $call.seat
      let observation = row["observation"]
      doAssert observation["view"] == game.decisionObservation(call.seat)
      let metadata = observation["prompt_template"]
      let selection = promptSelection(%*{"promptVariant": metadata["selection"], "promptSeed": metadata["seed"]})
      let system = systemPrompt(selection, game, call.seat)
      let user = userPrompt(game, call.seat, observation["operator_prompt"].getStr())
      doAssert metadata == selection.promptMetadata(system, user)
      let attempt = row["attempts"][0]
      doAssert row["attempts"].len == 1 and attempt["accepted"].getBool()
      doAssert row["selected_attempt_id"] == attempt["attempt_id"]
      doAssert row["prompt"] == attempt["prompt"]
      doAssert row["prompt"] == %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
      let parsed = parseAction(game, extractJsonObject(attempt["response"].getStr()))
      doAssert parsed.decisionJson() == attempt["parsed_action"]
      doAssert parsed.decisionJson() == row["executed_action"]
      if parsed.action == "accept":
        game.applyAccept(call.match, parsed.message, parsed.notes, true)
      else:
        game.applyOffer(call.match, parsed.take, parsed.message, parsed.notes, true)
      doAssert row["terminal"].getBool() == game.done
      inc index
    of ckNone: doAssert game.done
  doAssert index == records.len - 1
  doAssert game.replayJson(game.resultsJson()) == replay,
    "candidate actions do not reconstruct every replay event and outcome"
