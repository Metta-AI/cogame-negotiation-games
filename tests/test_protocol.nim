## External policy observations expose one valuation and public offers.

import std/[json, strutils, unittest]
import negotiation/[server, sim]

suite "player decision observation":
  test "the actor gets its own values and a game-legal offer range":
    var config = defaultGameConfig()
    config.sampled = true
    for slot in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "P" & $slot))
      config.tokens.add("token-" & $slot)
    var game = initSim(config)
    game.beginMatch()
    let actor = game.currentCall().seat
    let side = game.sideOfSeat(actor)
    let opponent = game.plan.seats[1 - side]
    game.notes[opponent] = "opponent private note"
    let observation = game.decisionObservation(actor)
    check observation["yourValues"] == %game.plan.values[side]
    check observation{"opponentValues"}.isNil
    check "opponent private note" notin $observation
    check observation["canAccept"].getBool() == false
    check observation["pool"] == %game.plan.pool
    game.applyOffer(game.match, [0, 0, 0], "public offer", "", false)
    let nextActor = game.currentCall().seat
    let next = game.decisionObservation(nextActor)
    check next["canAccept"].getBool()
    check next["offers"].len == 1
    check next["offers"][0]["message"].getStr() == "public offer"
