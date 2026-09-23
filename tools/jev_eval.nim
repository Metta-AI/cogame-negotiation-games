## Paired local Negotiation Games episodes: Jev seat 0 versus scripted haggler.
import std/[json, os, strutils]
import negotiation/[llm, sim]

proc run(seed: int, jev: bool): JsonNode =
  var config = defaultGameConfig()
  config.seed = seed
  config.matches = 3
  config.maxTurns = 10
  config.sampled = true
  for seat in 0 ..< Seats:
    config.players.add(PlayerConfig(name: "P" & $seat))
    config.tokens.add("token-" & $seat)
  var sim = initSim(config)
  let client = newLlmClient(config)
  var calls = 0
  while not sim.done:
    let call = sim.currentCall()
    case call.kind
    of ckMatch:
      sim.beginMatch()
    of ckAct:
      let decision =
        if jev and call.seat == 0:
          if calls >= 30:
            raise newException(ValueError, "Jev evaluation exceeded 30 model calls")
          inc calls
          client.decide(sim, call, "Maximize your own payoff while reaching a deal.", "")
        else:
          scriptedDecision(sim, "haggler")
      if decision.action == "accept":
        sim.applyAccept(call.match, decision.message, decision.notes,
          decision.scripted)
      else:
        sim.applyOffer(call.match, decision.take, decision.message,
          decision.notes, decision.scripted)
    of ckNone:
      break
  result = %*{"scores": sim.resultsJson()["scores"], "jev_calls": calls}

let seed = parseInt(paramStr(1))
echo "jev_result " & $run(seed, true)
echo "baseline_result " & $run(seed, false)
