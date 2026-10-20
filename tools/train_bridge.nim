## Complete private bargaining decisions through the shared language protocol.
import std/[json, os]
import negotiation/[llm, prompts, sim]

var selection: PromptSelection

proc seedOf(value: JsonNode): int =
  if value.kind == JInt:
    return value.getInt()
  var hash = 2166136261'u32
  for ch in value.getStr():
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc observation(game: Sim, id: int): JsonNode =
  if game.done:
    let outcome = game.resultsJson()
    var scores = newJObject()
    for seat in 0 ..< Seats:
      scores[$seat] = outcome["scores"][seat]
    return %*{"kind": "terminal", "scores": scores}
  let seat = game.currentCall().seat
  let system = systemPrompt(selection, game, seat)
  let user = userPrompt(game, seat, "")
  let view = game.decisionObservation(seat)
  view["prompt_template"] = selection.promptMetadata(system, user)
  let pool = game.plan.pool
  %*{"kind": "decision", "game": "negotiation-games", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.events.len,
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": system},
      {"role": "user", "content": user}], "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "action": {"type": "string", "enum": (if game.acceptLegal: %*["offer", "accept"] else: %*["offer"])},
      "take": {"type": "object", "properties": {
        "books": {"type": "integer", "minimum": 0, "maximum": pool[0]},
        "hats": {"type": "integer", "minimum": 0, "maximum": pool[1]},
        "balls": {"type": "integer", "minimum": 0, "maximum": pool[2]}},
        "required": ["books", "hats", "balls"]},
      "message": {"type": "string", "maxLength": MaxMessageLen},
      "notes": {"type": "string", "maxLength": MaxNotesLen}},
      "required": ["action"], "oneOf": [
        {"properties": {"action": {"const": "offer"}}, "required": ["take"]},
        {"properties": {"action": {"const": "accept"}}}]}, "inference_mode": "text_action",
    "typed_question": nil}

when isMainModule:
  let args = commandLineParams()
  doAssert args.len == 2, "usage: negotiation-train-bridge MANIFEST standard|sprint"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for variant in manifest["variants"]:
    if variant["id"].getStr() == args[1]:
      variantConfig = variant["game_config"]
  doAssert not variantConfig.isNil, "unknown variant"
  var game: Sim
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Seats
      selection = promptSelection(request)
      if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
        doAssert request.hasKey("split") and
          request["split"].getStr() in ["evaluation", "validation", "test"],
          "held-out wording requires an explicit evaluation split"
      let runtime = copy(variantConfig)
      runtime["seed"] = %seedOf(request["seed"])
      runtime["tokens"] = %*["t0", "t1", "t2"]
      var config = defaultGameConfig()
      config.update($runtime)
      game = initSim(sampleEpisode(config))
      game.beginMatch()
      id = 0
      response = game.observation(id)
    of "teacher":
      doAssert not game.done
      let teacher = scriptedDecision(game,
        if game.currentCall().seat == 2: "hardliner" else: "haggler")
      response = %*{"response": $teacher.decisionJson()}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let call = game.currentCall()
      let parsed = parseAction(game, extractJsonObject(request["response"].getStr()))
      if parsed.action == "accept":
        game.applyAccept(call.match, parsed.message, parsed.notes, false)
      else:
        game.applyOffer(call.match, parsed.take, parsed.message, parsed.notes, false)
      if game.currentCall().kind == ckMatch:
        game.beginMatch()
      inc id
      response = %*{"kind": "accepted", "action": parsed.decisionJson(),
        "observation": game.observation(id)}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
