## Sim unit tests — design note §Tests items 1-13.
##
## The rules module is shared by the server, these tests and the wasm replay
## viewer, so everything asserted here is asserted about all three.

import std/[json, random, strutils, unicode, unittest]
import negotiation/[llm, sim]

proc fixtureConfig(matches = 6, maxTurns = 10, seed = 0,
    names: seq[string] = @[]): GameConfig =
  result = defaultGameConfig()
  result.matches = matches
  result.maxTurns = maxTurns
  result.seed = seed
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    let name = if index < names.len: names[index] else: "P" & $(index + 1)
    result.players.add(PlayerConfig(name: name))
    result.tokens.add("token-" & $index)

proc drive(sim: var Sim, baseline = "haggler", stopAfter = -1) =
  ## Plays the episode out with the scripted baseline. `stopAfter` fires the
  ## play deadline once that many matches have settled — always BETWEEN
  ## matches, exactly as the server does.
  while not sim.done:
    let call = sim.currentCall()
    case call.kind
    of ckMatch:
      if stopAfter >= 0 and sim.matchesSettled >= stopAfter:
        sim.endEarly()
        break
      sim.beginMatch()
    of ckAct:
      let decision = scriptedDecision(sim, baseline)
      if decision.action == "accept":
        sim.applyAccept(call.match, decision.message, decision.notes, true)
      else:
        sim.applyOffer(call.match, decision.take, decision.message,
          decision.notes, true)
    of ckNone:
      break

proc lexLess(a, b: array[Items, int]): bool =
  for index in 0 ..< Items:
    if a[index] != b[index]:
      return a[index] < b[index]
  false

proc roundTrip(sim: Sim): seq[GameEvent] =
  for event in sim.events:
    result.add(eventFromJson(event.eventToJson()))

suite "1. determinism":
  test "the seed fixes the aliases, pairings, openers, pools and values":
    let a = initSim(fixtureConfig(seed = 7))
    let b = initSim(fixtureConfig(seed = 7))
    check a.names == b.names
    check a.schedule == b.schedule
    let c = initSim(fixtureConfig(seed = 8))
    check c.schedule.len == a.schedule.len
    var differs = false
    for m in 0 ..< a.schedule.len:
      if a.schedule[m].pool != c.schedule[m].pool or
          a.schedule[m].values != c.schedule[m].values:
        differs = true
      ## The pairing and the opener are structural, not random.
      check a.schedule[m].seats == c.schedule[m].seats
      check a.schedule[m].opener == c.schedule[m].opener
    check differs

suite "2. schedule balance":
  test "six matches: every seat plays four and opens two, every pairing twice":
    let sim = initSim(fixtureConfig(matches = 6, seed = 3))
    var plays, opens: array[Seats, int]
    var pairSeen: array[3, int]
    for m in 0 ..< 6:
      let plan = sim.schedule[m]
      check plan.kind == "bargaining"
      check plan.seats == [Pairings[m mod 3][0], Pairings[m mod 3][1]]
      check plan.opener in 0 .. 1
      inc plays[plan.seats[0]]
      inc plays[plan.seats[1]]
      inc opens[plan.seats[plan.opener]]
      inc pairSeen[m mod 3]
    for seat in 0 ..< Seats:
      check plays[seat] == 4
      check opens[seat] == 2
    for pairing in 0 ..< 3:
      check pairSeen[pairing] == 2

suite "3. pool draw":
  test "every pool holds 1..4 of each type and 5..7 in total":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(matches = 6, seed = seed))
      for plan in sim.schedule:
        var total = 0
        for index in 0 ..< Items:
          check plan.pool[index] >= 1
          check plan.pool[index] <= 4
          total += plan.pool[index]
        check total >= 5
        check total <= 7

  test "the bounded redraw path yields the fallback pool":
    var rng = initRand(99)
    ## Zero attempts stands in for 32 misses: the draw can never spin.
    check drawPool(rng, 0) == FallbackPool
    check FallbackPool == [3, 2, 2]
    var total = 0
    for index in 0 ..< Items:
      total += FallbackPool[index]
    check total == 7

suite "4. valuations":
  test "the pool is worth 10 to both seats and nothing is worthless to both":
    for seed in 0 ..< 200:
      let sim = initSim(fixtureConfig(matches = 3, seed = seed))
      for plan in sim.schedule:
        for side in 0 .. 1:
          check worthOf(plan.values[side], plan.pool) == PoolValue
          for index in 0 ..< Items:
            check plan.values[side][index] >= 0
            check plan.values[side][index] <= 10
        for index in 0 ..< Items:
          check plan.values[0][index] + plan.values[1][index] > 0

  test "the value table is exhaustive and lexicographic":
    let table = valueTable([3, 2, 2])
    check table.len > 0
    for entry in table:
      check 3 * entry[0] + 2 * entry[1] + 2 * entry[2] == PoolValue
    for index in 1 ..< table.len:
      check lexLess(table[index - 1], table[index])

suite "5. legality":
  test "illegal actions raise NegotiationError and change nothing":
    var sim = initSim(fixtureConfig(matches = 3, maxTurns = 6, seed = 5))
    expect NegotiationError:
      sim.applyOffer(0, [0, 0, 0], "", "", false)   # no match has started
    expect NegotiationError:
      sim.applyAccept(0, "", "", false)
    sim.beginMatch()
    expect NegotiationError:
      sim.beginMatch()                               # already in progress
    expect NegotiationError:
      sim.applyAccept(0, "", "", false)              # accept on turn 1
    check not sim.acceptLegal
    let pool = sim.plan.pool
    expect NegotiationError:
      sim.applyOffer(0, [pool[0] + 1, 0, 0], "", "", false)
    expect NegotiationError:
      sim.applyOffer(0, [-1, 0, 0], "", "", false)
    expect NegotiationError:
      sim.applyOffer(1, [0, 0, 0], "", "", false)    # the wrong match
    check sim.events.len == 2                        # start, match
    ## Run the cliff, then act on the settled match.
    for turn in 1 .. sim.config.maxTurns:
      sim.applyOffer(0, pool, "", "", true)
    check sim.outcome == "no_deal"
    expect NegotiationError:
      sim.applyOffer(0, pool, "", "", true)
    expect NegotiationError:
      sim.applyAccept(0, "", "", true)
    ## And after the episode has ended.
    sim.endEarly()
    check sim.done
    expect NegotiationError:
      sim.beginMatch()
    expect NegotiationError:
      sim.applyOffer(1, [0, 0, 0], "", "", true)

  test "the actor alternates and accept becomes legal on turn 2":
    var sim = initSim(fixtureConfig(matches = 3, maxTurns = 6, seed = 6))
    sim.beginMatch()
    let plan = sim.plan
    check sim.actorSide == plan.opener
    check sim.currentCall() == (ckAct, 0, plan.seats[plan.opener])
    sim.applyOffer(0, plan.pool, "", "", true)
    check sim.turn == 2
    check sim.actorSide == 1 - plan.opener
    check sim.acceptLegal
    check sim.roleOf(plan.seats[1 - plan.opener]) == "actor"
    check sim.roleOf(plan.seats[plan.opener]) == "waiting"
    for seat in 0 ..< Seats:
      if seat != plan.seats[0] and seat != plan.seats[1]:
        check sim.roleOf(seat) == "idle"

suite "6. payoffs and scoring":
  test "an accept pays each side its own value of its own share":
    var sim = initSim(fixtureConfig(matches = 3, maxTurns = 6, seed = 11))
    sim.beginMatch()
    let plan = sim.plan
    let mine = plan.opener
    let theirs = 1 - plan.opener
    let take = [plan.pool[0], 0, 0]
    sim.applyOffer(0, take, "the books are mine", "keep the books", false)
    check sim.standingSide == mine
    check sim.standingWorthTo(theirs) ==
      worthOf(plan.values[theirs], complementOf(plan.pool, take))
    sim.applyAccept(0, "fine", "", false)
    check sim.outcome == "deal"
    check sim.payoff[mine] == worthOf(plan.values[mine], take)
    check sim.payoff[theirs] ==
      worthOf(plan.values[theirs], complementOf(plan.pool, take))
    let seatA = plan.seats[mine]
    let seatB = plan.seats[theirs]
    check sim.points[seatA] == sim.payoff[mine]
    check sim.points[seatB] == sim.payoff[theirs]
    check sim.matchesPlayed[seatA] == 1
    check sim.deals[seatA] == 1
    check abs(sim.score(seatA) -
      sim.points[seatA].float / (10.0 * 1.0)) < 1e-9
    check abs(sim.giveaway(seatA) -
      (sim.payoff[theirs] - sim.payoff[mine]).float) < 1e-9
    ## The seat sitting out banks nothing and plays nothing.
    for seat in 0 ..< Seats:
      if seat != seatA and seat != seatB:
        check sim.matchesPlayed[seat] == 0
        check sim.score(seat) == 0.0
        check sim.giveaway(seat) == 0.0

  test "score is points over ten times the matches played":
    var sim = initSim(fixtureConfig(matches = 6, maxTurns = 10, seed = 12))
    sim.drive()
    check sim.done
    check sim.reason == "complete"
    let results = sim.resultsJson()
    for seat in 0 ..< Seats:
      let points = results["points"][seat].getInt()
      let matches = results["matches"][seat].getInt()
      check matches == 4
      let expected = points.float / (10.0 * matches.float)
      check abs(results["scores"][seat].getFloat() - expected) < 1e-9
      check results["scores"][seat].getFloat() >= 0.0
      check results["scores"][seat].getFloat() <= 1.0
    check results["matchesPlayed"].getInt() == 6
    check results["maxMatches"].getInt() == 6
    check results["reason"].getStr() == "complete"

  test "a fresh episode scores zero, not NaN":
    let sim = initSim(fixtureConfig(seed = 0))
    let results = sim.resultsJson()
    for seat in 0 ..< Seats:
      check results["scores"][seat].getFloat() == 0.0
      check results["giveaway"][seat].getFloat() == 0.0
    check results["reason"].getStr() == ""
    check sim.tableStateJson()["table"].kind == JNull

suite "7. the turn cliff":
  test "maxTurns offers with no accept pay both seats nothing":
    var sim = initSim(fixtureConfig(matches = 3, maxTurns = 4, seed = 13))
    sim.beginMatch()
    let pool = sim.plan.pool
    for turn in 1 .. 4:
      sim.applyOffer(0, pool, "", "", true)
    var settlements = 0
    for event in sim.events:
      if event.kind == evMatchEnd:
        inc settlements
        check event.outcome == "no_deal"
        check event.payoff == @[0, 0]
        check event.turn == 4
    check settlements == 1
    check sim.payoff == [0, 0]
    for seat in sim.plan.seats:
      check sim.points[seat] == 0
      check sim.matchesPlayed[seat] == 1
      check sim.deals[seat] == 0

suite "8. one matchEnd per started match":
  test "including when the deadline fires after the baseline finishes it":
    for stopAfter in [-1, 0, 2, 4]:
      var sim = initSim(fixtureConfig(matches = 6, maxTurns = 6, seed = 17))
      sim.drive(stopAfter = stopAfter)
      check sim.done
      var started, settled = 0
      for event in sim.events:
        if event.kind == evMatch: inc started
        if event.kind == evMatchEnd: inc settled
      check started == settled
      check settled == sim.matchesSettled
      check sim.reason == (if stopAfter < 0: "complete" else: "deadline")
      check sim.events[^1].kind == evEnd
      check sim.events[^1].match == sim.matchesSettled

suite "9. record then re-derive, for every end reason":
  test "complete and deadline replays reproduce the live sim exactly":
    for stopAfter in [-1, 3]:
      var sim = initSim(fixtureConfig(matches = 6, maxTurns = 6, seed = 23))
      sim.drive(stopAfter = stopAfter)
      let events = sim.roundTrip()
      let frames = replayMatch(sim.config, events)
      check frames.len == events.len + 1
      check frames[^1].done
      check frames[^1].reason == sim.reason
      check frames[^1].points == sim.points
      check frames[^1].notes == sim.notes
      check $frames[^1].tableStateJson() == $sim.tableStateJson()
      check frames[0].match == -1
      check frames[0].events.len == 0
      check frames[^1].events.len == events.len

  test "a tampered match event is rejected":
    var sim = initSim(fixtureConfig(matches = 3, maxTurns = 6, seed = 24))
    sim.drive()
    var events = sim.roundTrip()
    for index in 0 ..< events.len:
      if events[index].kind == evMatch:
        events[index].pool[0] = events[index].pool[0] + 1
        break
    var raised = false
    try:
      discard replayMatch(sim.config, events)
    except NegotiationError as error:
      raised = true
      check "does not match the seeded schedule" in error.msg
    check raised

  test "a tampered offer worth is rejected":
    var sim = initSim(fixtureConfig(matches = 3, maxTurns = 6, seed = 25))
    sim.drive()
    var events = sim.roundTrip()
    for index in 0 ..< events.len:
      if events[index].kind == evOffer:
        events[index].worth[0] = events[index].worth[0] + 1
        break
    expect NegotiationError:
      discard replayMatch(sim.config, events)

suite "10. event JSON":
  test "every event kind round-trips, empty text and notes omitted":
    var sim = initSim(fixtureConfig(matches = 3, maxTurns = 4, seed = 31))
    let start = sim.events[0].eventToJson()
    check start["kind"].getStr() == "start"
    check not start.hasKey("match")
    check not start.hasKey("text")
    check eventFromJson(start).kind == evStart
    check eventFromJson(start).text == ""

    sim.beginMatch()
    let plan = sim.plan
    let matchJson = sim.events[^1].eventToJson()
    check matchJson["kind"].getStr() == "match"
    check matchJson["matchKind"].getStr() == "bargaining"
    check matchJson["match"].getInt() == 0
    check matchJson["seats"].len == 2
    check matchJson["opener"].getInt() == plan.seats[plan.opener]
    check matchJson["pool"].len == Items
    check matchJson["values"].len == 2
    check matchJson["maxTurns"].getInt() == 4
    let matchBack = eventFromJson(matchJson)
    check matchBack.kind == evMatch
    check matchBack.seats == @[plan.seats[0], plan.seats[1]]
    check matchBack.pool == @[plan.pool[0], plan.pool[1], plan.pool[2]]
    check matchBack.values.len == 2
    check matchBack.maxTurns == 4

    sim.applyOffer(0, plan.pool, "everything, for now", "opened high", false)
    let offer = sim.events[^1].eventToJson()
    check offer["kind"].getStr() == "offer"
    check offer["turn"].getInt() == 1
    check offer["take"].len == Items
    check offer["worth"].len == 2
    check offer["scripted"].getBool() == false
    check offer["text"].getStr() == "everything, for now"
    check offer["notes"].getStr() == "opened high"
    check not offer.hasKey("payoff")
    let offerBack = eventFromJson(offer)
    check offerBack.kind == evOffer
    check offerBack.take == @[plan.pool[0], plan.pool[1], plan.pool[2]]
    check offerBack.worth.len == 2
    check offerBack.text == "everything, for now"
    check offerBack.notes == "opened high"

    sim.applyAccept(0, "", "", true)
    let accept = sim.events[^2].eventToJson()
    check accept["kind"].getStr() == "accept"
    check accept["turn"].getInt() == 2
    check accept["payoff"].len == 2
    check accept["scripted"].getBool()
    check not accept.hasKey("text")
    check not accept.hasKey("notes")
    let acceptBack = eventFromJson(accept)
    check acceptBack.kind == evAccept
    check acceptBack.text == ""
    check acceptBack.notes == ""
    check acceptBack.payoff.len == 2

    let settled = sim.events[^1].eventToJson()
    check settled["kind"].getStr() == "matchEnd"
    check settled["outcome"].getStr() == "deal"
    check settled["payoff"].len == 2
    check settled["turn"].getInt() == 2
    check eventFromJson(settled).outcome == "deal"

    sim.endEarly()
    let finish = sim.events[^1].eventToJson()
    check finish["kind"].getStr() == "end"
    check finish["match"].getInt() == 1
    check finish["text"].getStr() == "deadline"
    check eventFromJson(finish).kind == evEnd
    check eventFromJson(finish).text == "deadline"

suite "11. episode budget":
  test "sampleEpisode caps matches, floors to a multiple of 3, clamps pacing":
    var config = fixtureConfig(matches = 60, maxTurns = 12, seed = 0)
    config.sampled = false
    config.turnDelayMs = 10_000
    let fitted = sampleEpisode(config)
    check fitted.matches == 6
    check fitted.matches mod 3 == 0
    check fitted.matches * fitted.maxTurns <= EpisodeCallBudget
    check fitted.turnDelayMs == PacingBudgetMs div fitted.matches
    check fitted.sampled
    ## Idempotent: a replay being re-read is never re-fitted.
    check sampleEpisode(fitted) == fitted
    var small = fixtureConfig(matches = 3, maxTurns = 10, seed = 0)
    small.sampled = false
    check sampleEpisode(small).matches == MinMatches

suite "12. rune-safe caps":
  test "a multibyte message and note cap in runes, not bytes":
    var longMessage = ""
    for index in 0 ..< 500:
      longMessage.add("é")
    var longNotes = ""
    for index in 0 ..< 900:
      longNotes.add("ñ")
    let message = cleanMessage(longMessage)
    let notes = cleanNotes(longNotes)
    check message.runeLen == MaxMessageLen
    check notes.runeLen == MaxNotesLen
    check validateUtf8(message) == -1
    check validateUtf8(notes) == -1
    check message.endsWith("…")
    check notes.endsWith("…")
    check message.len > MaxMessageLen      # multibyte: bytes exceed runes
    check cleanMessage("a\nb\tc\x01d") == "a b cd"

  test "every string the sim records is capped on a rune boundary":
    var longMessage = ""
    for index in 0 ..< 500:
      longMessage.add("é")
    var longNotes = ""
    for index in 0 ..< 900:
      longNotes.add("ñ")
    var sim = initSim(fixtureConfig(matches = 3, maxTurns = 6, seed = 3))
    sim.beginMatch()
    let plan = sim.plan
    let pool = plan.pool
    sim.applyOffer(0, pool, longMessage, longNotes, false)
    check sim.offers[^1].text.runeLen == MaxMessageLen
    check sim.notes[plan.seats[plan.opener]].runeLen == MaxNotesLen
    check sim.events[^1].text.runeLen == MaxMessageLen
    check sim.events[^1].notes.runeLen == MaxNotesLen
    check validateUtf8($sim.tableStateJson()) == -1

suite "13. two name spaces":
  test "policy display names never reach a composed prompt":
    let names = @["ZQXanchorpolicy", "ZQXintegrativepolicy", "ZQXbaseline"]
    var sim = initSim(fixtureConfig(matches = 6, maxTurns = 6, seed = 29,
      names = names))
    var inspected = 0
    while not sim.done:
      let call = sim.currentCall()
      case call.kind
      of ckMatch:
        sim.beginMatch()
      of ckAct:
        let system = systemPrompt(sim, call.seat)
        let user = userPrompt(sim, call.seat, "concede the cheap item first")
        for name in names:
          check name notin system
          check name notin user
        ## The alias IS in the prompt: that is the whole point of the alias.
        check sim.names[call.seat] in user
        inc inspected
        let decision = scriptedDecision(sim, "haggler")
        if decision.action == "accept":
          sim.applyAccept(call.match, "deal", "took it", true)
        else:
          sim.applyOffer(call.match, decision.take, "my offer", "held", true)
      of ckNone:
        break
    check inspected > 10
    let results = sim.resultsJson()
    for index in 0 ..< Seats:
      check results["names"][index].getStr() == names[index]
      check sim.names[index] notin names
