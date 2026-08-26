## Scripted-baseline and reply-parsing tests — design note §Tests items
## 14-19.
##
## The baselines are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path:
## every order they emit must be legal and bounded, and the two of them must
## not be interchangeable.

import std/[json, math, monotimes, os, strutils, times, unittest]
import negotiation/[llm, sim]

const Seeds = [1, 7, 42, 1234, 20260826]

proc fixture(seed: int, matches = 6, maxTurns = 10,
    names: seq[string] = @[]): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.matches = matches
  result.maxTurns = maxTurns
  result.sampled = true
  for index in 0 ..< Seats:
    let name = if index < names.len: names[index] else: "P" & $(index + 1)
    result.players.add(PlayerConfig(name: name))
    result.tokens.add("t" & $index)

proc playBaselines(config: GameConfig, baselines: array[Seats, string]): Sim =
  ## Plays a whole episode with one named baseline per seat. Every action
  ## goes through the same apply* procs the server calls, so an illegal
  ## order raises here.
  result = initSim(config)
  while not result.done:
    let call = result.currentCall()
    case call.kind
    of ckMatch:
      result.beginMatch()
    of ckAct:
      let decision = scriptedDecision(result, baselines[call.seat])
      check decision.scripted
      check decision.message.len == 0
      check decision.notes.len == 0
      if decision.action == "accept":
        result.applyAccept(call.match, decision.message, decision.notes, true)
      else:
        result.applyOffer(call.match, decision.take, decision.message,
          decision.notes, true)
    of ckNone:
      break

proc uniform(baseline: string): array[Seats, string] =
  for index in 0 ..< Seats:
    result[index] = baseline

suite "14. bounded orders":
  test "every baseline pairing plays whole episodes legally":
    for seed in Seeds:
      for baselines in [uniform("haggler"), uniform("hardliner"),
          ["haggler", "hardliner", "haggler"]]:
        let config = fixture(seed)
        let sim = playBaselines(config, baselines)
        check sim.done
        check sim.reason == "complete"
        check sim.matchesSettled == config.matches
        var started, settled = 0
        var turnsIn: array[64, int]
        for event in sim.events:
          case event.kind
          of evMatch:
            inc started
            turnsIn[event.match] = 0
          of evOffer:
            let pool = sim.schedule[event.match].pool
            for index in 0 ..< Items:
              check event.take[index] >= 0
              check event.take[index] <= pool[index]
            turnsIn[event.match] = max(turnsIn[event.match], event.turn)
          of evAccept:
            check event.turn >= 2          # accept on turn 1 is illegal
            turnsIn[event.match] = max(turnsIn[event.match], event.turn)
          of evMatchEnd:
            inc settled
            check event.turn <= config.maxTurns
            check turnsIn[event.match] <= config.maxTurns
          else:
            discard
        check started == config.matches
        check settled == config.matches
        for seat in 0 ..< Seats:
          check sim.matchesPlayed[seat] == 4
          check sim.fallbacks[seat] == 0

suite "15. the haggler concedes monotonically":
  test "the reservation is non-increasing in the turn":
    for maxTurns in [2, 4, 6, 10, 12]:
      var previous = 99
      for turn in 1 .. maxTurns:
        let reservation = reservationFor("haggler", turn, maxTurns)
        check reservation <= previous
        check reservation >= 1
        check reservation <= 10
        previous = reservation
      check reservationFor("haggler", 1, maxTurns) >=
        reservationFor("haggler", maxTurns, maxTurns)
    check reservationFor("haggler", 1, 10) == 10
    check reservationFor("haggler", 8, 10) == 5
    check reservationFor("haggler", 9, 10) == 1
    check reservationFor("haggler", 10, 10) == 1

  test "successive offers by the same side are worth no more to it":
    for seed in Seeds:
      let sim = playBaselines(fixture(seed), uniform("haggler"))
      var previous: array[2, int]
      var match = -1
      for event in sim.events:
        if event.kind == evMatch:
          match = event.match
          previous = [99, 99]
        elif event.kind == evOffer and match >= 0:
          let plan = sim.schedule[match]
          let side = if plan.seats[0] == event.seat: 0 else: 1
          check event.worth[0] <= previous[side]
          previous[side] = event.worth[0]

suite "16. the two baselines are not interchangeable":
  test "haggler pairs deal, and the hardliner beats a conceder":
    var matches, deals, joint = 0
    ## 17 seeds x 6 matches = 102 haggler-vs-haggler matches.
    for seed in 0 ..< 17:
      let sim = playBaselines(fixture(seed + 1), uniform("haggler"))
      for event in sim.events:
        if event.kind == evMatchEnd:
          inc matches
          if event.outcome == "deal":
            inc deals
          joint += event.payoff[0] + event.payoff[1]
    check matches >= 100
    echo "haggler-vs-haggler: ", deals, "/", matches, " deals, mean joint ",
      joint.float / matches.float
    check deals.float / matches.float >= 0.90
    check joint.float / matches.float >= 12.0

    ## The design note's third clause here reads "hardliner-vs-hardliner
    ## produces at least 10 no-deals". That is NOT reachable with the
    ## reservations the note itself pins: both baselines drop to 1 (haggler)
    ## or 3 (hardliner) on their own final turn, and an offer is always the
    ## SMALLEST bundle that clears the reservation, so the final-turn
    ## acceptance test passes essentially always. Measured over 300 matches
    ## at maxTurns 6, 10 and 12: zero no-deals, for every pairing. What that
    ## clause is really asserting - that the two baselines are genuinely
    ## different - is asserted directly instead, over the SAME seeded
    ## matches.
    var compared, differing = 0
    for seed in 0 ..< 17:
      let soft = playBaselines(fixture(seed + 1), uniform("haggler"))
      let hard = playBaselines(fixture(seed + 1), uniform("hardliner"))
      check soft.schedule == hard.schedule
      var softEnds, hardEnds: seq[GameEvent]
      for event in soft.events:
        if event.kind == evMatchEnd: softEnds.add(event)
      for event in hard.events:
        if event.kind == evMatchEnd: hardEnds.add(event)
      check softEnds.len == hardEnds.len
      for index in 0 ..< softEnds.len:
        inc compared
        if softEnds[index].payoff != hardEnds[index].payoff or
            softEnds[index].turn != hardEnds[index].turn or
            softEnds[index].outcome != hardEnds[index].outcome:
          inc differing
    echo "haggler vs hardliner behaviour differs in ", differing, "/",
      compared, " matches"
    check compared >= 100
    check differing >= 40

    ## Mixed: seat 1 is the hardliner, so matches (0,1) and (1,2) are the
    ## mixed ones. Openers alternate over the six matches, so neither
    ## baseline gets a first-mover advantage.
    var hardTotal, softTotal, mixed = 0
    for seed in 0 ..< 25:
      let sim = playBaselines(fixture(seed + 1),
        ["haggler", "hardliner", "haggler"])
      for event in sim.events:
        if event.kind != evMatchEnd:
          continue
        let plan = sim.schedule[event.match]
        if plan.seats[0] != 1 and plan.seats[1] != 1:
          continue
        let hardSide = if plan.seats[0] == 1: 0 else: 1
        inc mixed
        hardTotal += event.payoff[hardSide]
        softTotal += event.payoff[1 - hardSide]
    echo "mixed matches: ", mixed, ", hardliner mean ",
      hardTotal.float / mixed.float, " vs haggler mean ",
      softTotal.float / mixed.float
    check mixed >= 100
    check hardTotal.float / mixed.float > softTotal.float / mixed.float

suite "17. no credentials, no network":
  test "decide returns the scripted action immediately":
    delEnv("ANTHROPIC_API_KEY")
    delEnv("ANTHROPIC_API_KEY_URI")
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    let config = fixture(3, matches = 3, maxTurns = 6)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    sim.beginMatch()
    let call = sim.currentCall()
    let started = getMonoTime()
    let decision = client.decide(sim, call, "bargain hard", scripted = "")
    let elapsed = (getMonoTime() - started).inMilliseconds
    check elapsed < 1000
    check decision.scripted
    ## A prompt seat that could not reach the model fell back: it counts.
    check decision.fallback
    let baseline = scriptedDecision(sim, "haggler")
    check decision.action == baseline.action
    check decision.take == baseline.take
    ## A seat that REGISTERED a baseline is playing its policy, not degrading.
    let registered = client.decide(sim, call, "", scripted = "hardliner")
    check registered.scripted
    check not registered.fallback
    check registered.action == scriptedDecision(sim, "hardliner").action
    ## Past the deadline every remaining turn is scripted, instantly.
    let forced = client.decide(sim, call, "bargain hard", scripted = "",
      forceScripted = true)
    check forced.scripted
    check forced.fallback

  test "PLAYER_SCRIPTED values normalise":
    check normalizeBaseline("haggler") == "haggler"
    check normalizeBaseline("HARDLINER") == "hardliner"
    check normalizeBaseline(" Hardliner ") == "hardliner"
    check normalizeBaseline("1") == "haggler"
    check normalizeBaseline("true") == "haggler"
    check normalizeBaseline("yes") == "haggler"
    check normalizeBaseline("") == ""
    check normalizeBaseline("nonsense") == "haggler"

suite "18. reply parsing":
  test "tolerant in exactly the documented ways":
    var sim = initSim(fixture(0, matches = 3, maxTurns = 6))
    sim.beginMatch()
    check parseAction(sim, parseJson("""{"action":"accept"}""")).action ==
      "accept"
    check parseAction(sim, parseJson("""{"action":"AGREE"}""")).action ==
      "accept"
    check parseAction(sim, parseJson("""{"action":" Deal "}""")).action ==
      "accept"
    check parseAction(sim, parseJson("""{"action":"Offer","take":[0,0,0]}""")
      ).action == "offer"
    check parseAction(sim, parseJson("""{"action":"propose","take":[0,0,0]}""")
      ).action == "offer"
    let object3 = parseAction(sim,
      parseJson("""{"action":"counter","take":{"books":2,"balls":1}}"""))
    check object3.action == "offer"
    check object3.take == [2, 0, 1]        # a missing key defaults to 0
    let array3 = parseAction(sim,
      parseJson("""{"action":"offer","take":[1,2,3]}"""))
    check array3.take == [1, 2, 3]
    let strings = parseAction(sim,
      parseJson("""{"take":{"books":"2","hats":"0","balls":"1"}}"""))
    check strings.action == "offer"        # no action, but a take: an offer
    check strings.take == [2, 0, 1]
    let withText = parseAction(sim, parseJson(
      """{"action":"accept","message":"done","notes":"took it"}"""))
    check withText.message == "done"
    check withText.notes == "took it"

    expect NegotiationError:                        # a fractional count
      discard parseAction(sim,
        parseJson("""{"action":"offer","take":{"books":1.5}}"""))
    expect NegotiationError:                        # a non-numeric count
      discard parseAction(sim,
        parseJson("""{"action":"offer","take":{"books":"two"}}"""))
    expect NegotiationError:                        # an unknown action
      discard parseAction(sim, parseJson("""{"action":"burn"}"""))
    expect NegotiationError:                        # no action and no take
      discard parseAction(sim, parseJson("""{"message":"hello"}"""))
    expect NegotiationError:                        # a malformed take
      discard parseAction(sim,
        parseJson("""{"action":"offer","take":[1,2]}"""))

  test "JSON is extracted from fences and trailing prose":
    let fenced = extractJsonObject(
      "```json\n{\"action\":\"accept\",\"message\":\"ok\"}\n```\n" &
      "That is my move.")
    check fenced["action"].getStr() == "accept"
    let leading = extractJsonObject(
      "Here is my offer: {\"action\":\"offer\",\"take\":[1,0,0]}")
    check leading["take"].len == 3
    expect NegotiationError:
      discard extractJsonObject("I accept your generous offer.")
    expect NegotiationError:
      discard extractJsonObject("")

  test "out-of-range takes and accept on turn 1 are rejected on the probe":
    ## `decide` applies every parsed decision to a probe copy of the sim
    ## before returning it, so the retry carries the hint. These are the
    ## rejections that probe makes.
    var sim = initSim(fixture(4, matches = 3, maxTurns = 6))
    sim.beginMatch()
    let pool = sim.plan.pool
    var probe = sim
    expect NegotiationError:
      probe.applyOffer(0, [pool[0] + 1, 0, 0], "", "", false)
    var probe2 = sim
    expect NegotiationError:
      probe2.applyAccept(0, "", "", false)

suite "19. the certification fixture fits certify's default timeout":
  test "grace plus play plus linger is under 50 s":
    ## The fixture is players Sprocket/Gizmo/Ratchet, seed 7, matches 3,
    ## maxTurns 6, turnDelayMs 0 — with no API key, so all 18 turns are
    ## scripted.
    let config = fixture(7, matches = 3, maxTurns = 6)
    let started = getMonoTime()
    let sim = playBaselines(config,
      ["haggler", "haggler", "hardliner"])
    let playMs = (getMonoTime() - started).inMilliseconds.int
    check sim.done
    check sim.reason == "complete"
    const connectMs = 2000            # observed container connect grace
    let totalMs = playMs + connectMs + ShutdownGraceSeconds * 1000
    echo "cert fixture budget: play ", playMs, " ms + connect ", connectMs,
      " ms + shutdown grace ", ShutdownGraceSeconds * 1000, " ms = ",
      totalMs, " ms"
    check playMs < 5000
    check totalMs < 50_000
