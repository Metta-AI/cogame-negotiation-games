## Pure game rules for Negotiation Games. No IO, no networking, no LLM —
## the server, the tests and the wasm replay viewer all drive this module.
##
## An episode is three cogs and a sequence of one-on-one BARGAINING matches
## (OpenSpiel `bargaining`, Lewis et al. 2017). Each match puts a pool of
## books, hats and balls between two of the seats. The pool is worth exactly
## 10 to each of them under private, different per-item values. They
## alternate: offer (how many of each item I take) or accept the offer
## standing against them. Agree and both bank their share; run out of turns
## and both bank nothing.
##
## Everything random is drawn from the seed at `initSim`, so a replay
## re-derives the whole schedule — pairings, openers, pools and both seats'
## valuations — from the recorded offer/accept events alone.

import std/[json, random, strutils, unicode], types

export types

const
  Seats* = 3
  Items* = 3
  ItemNames* = ["books", "hats", "balls"]
  ItemSingular* = ["book", "hat", "ball"]
  ## The whole pool is worth exactly this to each seat, by construction.
  PoolValue* = 10
  MinMatches* = 3
  MaxMatchesCap* = 6
  ## An episode's whole model-call allowance (one call per turn; only the
  ## seat whose turn it is is ever queried).
  EpisodeCallBudget* = 72
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 20_000
  ## Wall-clock floor between two model calls. The hosted Bedrock sidecar
  ## caps 30 requests/minute per episode (cogame-raid, 2026-08-23).
  MinCallSpacingMs* = 2200
  ## The certifier pings /global AFTER the player pods start, so the server
  ## keeps answering for this long once the artifacts are written
  ## (cogame-lantern 0.1.3).
  ShutdownGraceSeconds* = 20
  MaxMessageLen* = 200
  MaxNotesLen* = 400
  ## The cap on a player container's operator prompt. Measured in runes like
  ## every other cap here: a byte slice at 4000 lands inside a multi-byte
  ## rune and rides into the model request body as invalid UTF-8.
  MaxPromptLen* = 4000
  ## Match m is played by Pairings[m mod 3].
  Pairings* = [[0, 1], [0, 2], [1, 2]]
  ## Used when 32 count draws all miss the 5..7 window; keeps generation
  ## bounded, so the sim can never spin.
  FallbackPool* = [3, 2, 2]
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ## Bumped by any change to the rules.
  ReplayProtocol* = "negotiation.replay.v1"

type
  CallKind* = enum
    ckMatch = "match"  ## the next match needs starting (beginMatch)
    ckAct = "act"      ## a seat must offer or accept
    ckNone = "none"    ## the episode is over

  Call* = tuple[kind: CallKind, match, seat: int]

  Phase* = enum
    phOffer = "offer"
    phBetween = "between"
    phDone = "done"

  MatchPlan* = object
    kind*: string                 ## "bargaining" in v1
    seats*: array[2, int]         ## [a, b]; the index is the "side"
    opener*: int                  ## 0 or 1, an index into `seats`
    pool*: array[Items, int]
    values*: array[2, array[Items, int]]

  OfferRecord* = object
    turn*: int
    side*: int
    take*: array[Items, int]
    ## [worth to the offering side, worth to the other side].
    worth*: array[2, int]
    text*: string
    scripted*: bool

  Sim* = object
    config*: GameConfig
    names*: seq[string]                ## anonymous aliases, seeded
    schedule*: seq[MatchPlan]          ## drawn at initSim from the seed
    match*: int                        ## match in progress / last shown; -1 before the first
    turn*: int                         ## 1-based turn in the live match; 0 between matches
    phase*: Phase
    standing*: array[Items, int]       ## the standing take, from standingSide's side
    standingSide*: int                 ## -1 when no offer stands
    offers*: seq[OfferRecord]          ## the live match's offers
    lastMessage*: array[2, string]
    outcome*: string                   ## "" | "deal" | "no_deal" for the shown match
    payoff*: array[2, int]
    points*, matchesPlayed*, deals*: array[Seats, int]
    given*, taken*: array[Seats, int]  ## for giveaway: opponent's u and own u, summed
    fallbacks*: array[Seats, int]
    notes*: seq[string]                ## latest private notes per seat
    done*: bool
    reason*: string                    ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Strings ----------------------------------------------------------------

proc capRunes*(text: string, limit: int): string =
  ## Cuts on a RUNE boundary with the cut marked. A byte-boundary cut makes
  ## replay bytes fail a strict JSON parser while still rendering in a
  ## browser, which is exactly the bug nothing else catches.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc cleanNotes*(text: string): string =
  capRunes(text, MaxNotesLen)

proc cleanPrompt*(text: string): string =
  capRunes(text, MaxPromptLen)

proc cleanMessage*(text: string): string =
  ## ASCII control characters are stripped before the cap (tabs, newlines
  ## and carriage returns become spaces so words do not fuse); the cap is
  ## then measured in runes.
  var stripped = newStringOfCap(text.len)
  for ch in text:
    let code = ord(ch)
    if code == 0x09 or code == 0x0A or code == 0x0D:
      stripped.add(' ')
    elif code < 0x20 or code == 0x7F:
      discard
    else:
      stripped.add(ch)
  capRunes(stripped, MaxMessageLen)

proc itemPhrase*(count, item: int): string =
  $count & " " & (if count == 1: ItemSingular[item] else: ItemNames[item])

proc poolText*(pool: array[Items, int]): string =
  ## "3 books, 2 hats, 1 ball"
  var parts: seq[string]
  for index in 0 ..< Items:
    parts.add(itemPhrase(pool[index], index))
  parts.join(", ")

proc takeText*(take, pool: array[Items, int]): string =
  ## "2 books, 0 hats, 1 ball". Item types absent from the pool are skipped,
  ## so a bundle never mentions an item nobody can hold.
  var parts: seq[string]
  for index in 0 ..< Items:
    if pool[index] > 0:
      parts.add(itemPhrase(take[index], index))
  parts.join(", ")

proc valuesText*(values, pool: array[Items, int]): string =
  ## "books 2 each, hats 1 each, balls 2 each"
  var parts: seq[string]
  for index in 0 ..< Items:
    if pool[index] > 0:
      parts.add(ItemNames[index] & " " & $values[index] & " each")
  parts.join(", ")

# ---- Vector helpers ---------------------------------------------------------

proc worthOf*(values, take: array[Items, int]): int =
  for index in 0 ..< Items:
    result += values[index] * take[index]

proc complementOf*(pool, take: array[Items, int]): array[Items, int] =
  for index in 0 ..< Items:
    result[index] = pool[index] - take[index]

proc toSeq3(vector: array[Items, int]): seq[int] =
  for index in 0 ..< Items:
    result.add(vector[index])

proc fromSeq3(values: seq[int]): array[Items, int] =
  for index in 0 ..< Items:
    result[index] = (if index < values.len: values[index] else: 0)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(rng: var Rand, players: seq[PlayerConfig]): seq[string] =
  ## Policy display names never reach the table: every seat plays under an
  ## anonymous cog name, drawn from the episode's one seeded stream so
  ## replays and the live table agree.
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc drawPool*(rng: var Rand, maxAttempts = 32): array[Items, int] =
  ## Counts of 1..4 per item type, redrawn as a whole triple until the pool
  ## holds 5..7 items. Bounded: after `maxAttempts` misses it settles on
  ## FallbackPool, so generation can never spin.
  for attempt in 0 ..< maxAttempts:
    var counts: array[Items, int]
    var total = 0
    for index in 0 ..< Items:
      counts[index] = 1 + rng.rand(3)
      total += counts[index]
    if total >= 5 and total <= 7:
      return counts
  FallbackPool

proc valueTable*(pool: array[Items, int]): seq[array[Items, int]] =
  ## Every v in {0..10}^3 with pool·v == PoolValue, in lexicographic order.
  ## Exhaustive and deterministic, so there is no rejection loop.
  for v0 in 0 .. PoolValue:
    for v1 in 0 .. PoolValue:
      for v2 in 0 .. PoolValue:
        if pool[0] * v0 + pool[1] * v1 + pool[2] * v2 == PoolValue:
          result.add([v0, v1, v2])

proc bothValued(a, b: array[Items, int]): bool =
  for index in 0 ..< Items:
    if a[index] + b[index] <= 0:
      return false
  true

proc drawValues*(rng: var Rand, table: seq[array[Items, int]]):
    array[2, array[Items, int]] =
  ## Seat A's values, then seat B's — redrawn at most 16 times until no item
  ## type is worthless to both. Bounded, and always yields a legal table.
  if table.len == 0:
    raise newException(NegotiationError, "no valuation solves this pool")
  let a = table[rng.rand(table.high)]
  var b = table[rng.rand(table.high)]
  var attempt = 0
  while attempt < 16 and not bothValued(a, b):
    b = table[rng.rand(table.high)]
    inc attempt
  if not bothValued(a, b):
    for candidate in table:
      if bothValued(a, candidate):
        b = candidate
        break
  [a, b]

proc drawSchedule*(rng: var Rand, matches: int): seq[MatchPlan] =
  ## Match m is played by Pairings[m mod 3]; the opener is the pairing's
  ## first seat when (m div 3) mod 2 == 0, otherwise the second. Over six
  ## matches every seat plays four and opens two.
  for m in 0 ..< matches:
    var plan = MatchPlan(kind: "bargaining")
    let pairing = Pairings[m mod 3]
    plan.seats = [pairing[0], pairing[1]]
    plan.opener = (if (m div 3) mod 2 == 0: 0 else: 1)
    plan.pool = drawPool(rng)
    plan.values = drawValues(rng, valueTable(plan.pool))
    result.add(plan)

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the match count into one episode's model-call budget and floors it
  ## to a multiple of 3 so every seat plays the same number of matches.
  ## Idempotent: a config that already carries the cap (a replay being
  ## re-read) is untouched.
  result = config
  if result.sampled:
    return
  let cap = (EpisodeCallBudget div max(result.maxTurns, 1) div 3) * 3
  result.matches = max(min(config.matches, cap), MinMatches)
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.matches, 1))
  result.sampled = true

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, match: -1, turn: -1, seat: -1, other: -1, opener: -1)

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(NegotiationError,
      "negotiation-games needs exactly " & $Seats & " players")
  if config.matches < MinMatches:
    raise newException(NegotiationError,
      "matches must be at least " & $MinMatches)
  if config.maxTurns < 2 or config.maxTurns mod 2 != 0:
    raise newException(NegotiationError, "maxTurns must be an even number >= 2")
  ## One stream for everything the seed decides: the aliases first, then the
  ## whole schedule, drawn before a single decision is made.
  var rng = initRand(int64(config.seed) * 7919 + 17)
  result = Sim(config: config, names: tableNames(rng, config.players))
  result.schedule = drawSchedule(rng, config.matches)
  result.match = -1
  result.turn = 0
  result.phase = phBetween
  result.standingSide = -1
  result.notes = newSeq[string](Seats)
  result.addEvent(blankEvent(evStart))

# ---- Queries ----------------------------------------------------------------

proc plan*(sim: Sim): MatchPlan =
  if sim.match < 0:
    raise newException(NegotiationError, "no match has started")
  sim.schedule[sim.match]

proc matchesSettled*(sim: Sim): int =
  ## Every settled match credits exactly two seats, so the episode-level
  ## count needs no extra bookkeeping.
  var total = 0
  for seat in 0 ..< Seats:
    total += sim.matchesPlayed[seat]
  total div 2

proc actorSide*(sim: Sim): int =
  ## The side (0 or 1 within the match) whose turn it is.
  let p = sim.plan
  if sim.turn mod 2 == 1: p.opener else: 1 - p.opener

proc actorSeat*(sim: Sim): int =
  sim.plan.seats[sim.actorSide]

proc currentCall*(sim: Sim): Call =
  if sim.done:
    return (ckNone, -1, -1)
  case sim.phase
  of phBetween:
    if sim.matchesSettled >= sim.config.matches: (ckNone, -1, -1)
    else: (ckMatch, sim.matchesSettled, -1)
  of phOffer: (ckAct, sim.match, sim.actorSeat)
  of phDone: (ckNone, -1, -1)

proc sideOfSeat*(sim: Sim, seat: int): int =
  ## 0 or 1 when `seat` is in the shown match, -1 when it is sitting out.
  if sim.match < 0:
    return -1
  let p = sim.plan
  if p.seats[0] == seat: 0
  elif p.seats[1] == seat: 1
  else: -1

proc roleOf*(sim: Sim, seat: int): string =
  ## "actor" for the seat to move, "waiting" for its opponent, "idle" for
  ## the seat sitting this match out.
  let side = sim.sideOfSeat(seat)
  if side < 0:
    return "idle"
  if sim.phase == phOffer and side == sim.actorSide: "actor" else: "waiting"

proc worthTo*(sim: Sim, side: int, take: array[Items, int]): int =
  worthOf(sim.plan.values[side], take)

proc acceptLegal*(sim: Sim): bool =
  sim.phase == phOffer and sim.standingSide >= 0

proc standingWorthTo*(sim: Sim, side: int): int =
  ## What `side` would bank if the standing offer were accepted.
  if sim.standingSide < 0:
    return 0
  if side == sim.standingSide:
    sim.worthTo(side, sim.standing)
  else:
    sim.worthTo(side, complementOf(sim.plan.pool, sim.standing))

proc score*(sim: Sim, seat: int): float =
  if sim.matchesPlayed[seat] == 0: 0.0
  else: sim.points[seat].float /
    (PoolValue.float * sim.matchesPlayed[seat].float)

proc giveaway*(sim: Sim, seat: int): float =
  ## Mean over settled matches of (opponent's u − own u). Not ranked: it is
  ## the mechanical softplay audit.
  if sim.matchesPlayed[seat] == 0: 0.0
  else: (sim.given[seat] - sim.taken[seat]).float /
    sim.matchesPlayed[seat].float

# ---- Play -------------------------------------------------------------------

proc settle*(sim: var Sim, reason: string) =
  ## The single load-bearing record of a stop. `replayMatch` applies the end
  ## event through this same proc, so a `deadline` replay re-derives
  ## frame-for-frame identically to a `complete` one.
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.match = sim.matchesSettled
  event.text = reason
  sim.addEvent(event)

proc beginMatch*(sim: var Sim) =
  if sim.done:
    raise newException(NegotiationError, "the episode is over")
  if sim.phase != phBetween:
    raise newException(NegotiationError, "a match is already in progress")
  if sim.matchesSettled >= sim.config.matches:
    raise newException(NegotiationError, "no matches remain")
  sim.match = sim.matchesSettled
  sim.phase = phOffer
  sim.turn = 1
  sim.standingSide = -1
  sim.standing = [0, 0, 0]
  sim.offers = @[]
  sim.lastMessage = ["", ""]
  sim.outcome = ""
  sim.payoff = [0, 0]
  let p = sim.plan
  var event = blankEvent(evMatch)
  event.match = sim.match
  event.matchKind = p.kind
  event.seats = @[p.seats[0], p.seats[1]]
  event.opener = p.seats[p.opener]
  event.pool = toSeq3(p.pool)
  event.values = @[toSeq3(p.values[0]), toSeq3(p.values[1])]
  event.maxTurns = sim.config.maxTurns
  sim.addEvent(event)

proc endMatch(sim: var Sim, outcome: string, payoff: array[2, int],
    turns: int) =
  let p = sim.plan
  sim.outcome = outcome
  sim.payoff = payoff
  for side in 0 .. 1:
    let seat = p.seats[side]
    sim.points[seat] += payoff[side]
    inc sim.matchesPlayed[seat]
    if outcome == "deal":
      inc sim.deals[seat]
    sim.taken[seat] += payoff[side]
    sim.given[seat] += payoff[1 - side]
  var event = blankEvent(evMatchEnd)
  event.match = sim.match
  event.outcome = outcome
  event.payoff = @[payoff[0], payoff[1]]
  event.turn = turns
  sim.addEvent(event)
  if sim.matchesSettled >= sim.config.matches:
    sim.settle("complete")
  else:
    sim.phase = phBetween
    sim.turn = 0

proc requireLiveTurn(sim: Sim, match: int) =
  if sim.done:
    raise newException(NegotiationError, "the episode is over")
  if sim.phase != phOffer:
    raise newException(NegotiationError, "no action is due")
  if match != sim.match:
    raise newException(NegotiationError,
      "match " & $sim.match & " is in progress, not " & $match)

proc applyOffer*(sim: var Sim, match: int, take: array[Items, int],
    message, notes: string, scripted: bool) =
  ## The acting seat proposes how many of each item IT takes; the opponent
  ## gets the complement. Raises NegotiationError on anything illegal.
  sim.requireLiveTurn(match)
  let p = sim.plan
  for index in 0 ..< Items:
    if take[index] < 0 or take[index] > p.pool[index]:
      raise newException(NegotiationError,
        "take[" & $index & "] must be 0.." & $p.pool[index] &
        ", got " & $take[index])
  let side = sim.actorSide
  let seat = p.seats[side]
  let other = p.seats[1 - side]
  let mine = sim.worthTo(side, take)
  let theirs = sim.worthTo(1 - side, complementOf(p.pool, take))
  let text = cleanMessage(message)
  let kept = cleanNotes(notes)
  if kept.len > 0:
    sim.notes[seat] = kept
  sim.standing = take
  sim.standingSide = side
  sim.lastMessage[side] = text
  sim.offers.add(OfferRecord(turn: sim.turn, side: side, take: take,
    worth: [mine, theirs], text: text, scripted: scripted))
  var event = blankEvent(evOffer)
  event.match = sim.match
  event.turn = sim.turn
  event.seat = seat
  event.other = other
  event.take = toSeq3(take)
  event.worth = @[mine, theirs]
  event.scripted = scripted
  event.text = text
  event.notes = sim.notes[seat]
  sim.addEvent(event)
  if sim.turn >= sim.config.maxTurns:
    ## The turn cliff: nobody accepted, so both bank nothing.
    sim.endMatch("no_deal", [0, 0], sim.config.maxTurns)
  else:
    inc sim.turn

proc applyAccept*(sim: var Sim, match: int, message, notes: string,
    scripted: bool) =
  ## The acting seat takes the offer standing against it.
  sim.requireLiveTurn(match)
  if sim.standingSide < 0:
    raise newException(NegotiationError, "no offer stands; accept is illegal")
  let p = sim.plan
  let side = sim.actorSide
  let seat = p.seats[side]
  let other = p.seats[1 - side]
  let received = complementOf(p.pool, sim.standing)
  var payoff: array[2, int]
  payoff[side] = sim.worthTo(side, received)
  payoff[1 - side] = sim.worthTo(1 - side, sim.standing)
  let text = cleanMessage(message)
  let kept = cleanNotes(notes)
  if kept.len > 0:
    sim.notes[seat] = kept
  sim.lastMessage[side] = text
  var event = blankEvent(evAccept)
  event.match = sim.match
  event.turn = sim.turn
  event.seat = seat
  event.other = other
  event.take = toSeq3(received)
  event.payoff = @[payoff[0], payoff[1]]
  event.scripted = scripted
  event.text = text
  event.notes = sim.notes[seat]
  sim.addEvent(event)
  sim.endMatch("deal", payoff, sim.turn)

proc endEarly*(sim: var Sim) =
  ## Stop now. The hosted platform kills an episode that outlives its
  ## timeout and keeps NOTHING, so a short honest episode always beats a
  ## long one that never lands. Scores use the matches actually settled.
  sim.settle("deadline")

proc recordFallback*(sim: var Sim, seat: int) =
  inc sim.fallbacks[seat]

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var points = newJArray()
  var matches = newJArray()
  var deals = newJArray()
  var giveaways = newJArray()
  var fallbacks = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    points.add(%sim.points[seat])
    matches.add(%sim.matchesPlayed[seat])
    deals.add(%sim.deals[seat])
    giveaways.add(%sim.giveaway(seat))
    fallbacks.add(%sim.fallbacks[seat])
  %*{
    "names": names,
    "scores": scores,
    "points": points,
    "matches": matches,
    "deals": deals,
    "giveaway": giveaways,
    "fallbacks": fallbacks,
    "matchesPlayed": sim.matchesSettled,
    "maxMatches": sim.config.matches,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc tableJson(sim: Sim): JsonNode =
  ## The match in progress, or the last completed one once done; null
  ## before the first match.
  if sim.match < 0:
    return newJNull()
  let p = sim.plan
  var values = newJArray()
  for side in 0 .. 1:
    var row = newJArray()
    for index in 0 ..< Items:
      row.add(%p.values[side][index])
    values.add(row)
  var offers = newJArray()
  for record in sim.offers:
    offers.add(%*{
      "turn": record.turn,
      "side": record.side,
      "take": toSeq3(record.take),
      "worth": @[record.worth[0], record.worth[1]],
      "text": record.text,
      "scripted": record.scripted
    })
  var standing = newJNull()
  if sim.standingSide >= 0:
    standing = %*{
      "side": sim.standingSide,
      "take": toSeq3(sim.standing),
      "worth": @[
        sim.worthTo(sim.standingSide, sim.standing),
        sim.worthTo(1 - sim.standingSide,
          complementOf(p.pool, sim.standing))
      ]
    }
  %*{
    "a": p.seats[0],
    "b": p.seats[1],
    "opener": p.seats[p.opener],
    "pool": toSeq3(p.pool),
    "values": values,
    "turn": sim.turn,
    "maxTurns": sim.config.maxTurns,
    "actor": (if sim.phase == phOffer: sim.actorSeat else: -1),
    "standing": standing,
    "offers": offers,
    "messages": @[sim.lastMessage[0], sim.lastMessage[1]],
    "outcome": (if sim.outcome.len == 0: "open" else: sim.outcome),
    "payoff": @[sim.payoff[0], sim.payoff[1]]
  }

proc tableStateJson*(sim: Sim): JsonNode =
  var seats = newJArray()
  for seat in 0 ..< Seats:
    seats.add(%*{
      "name": sim.names[seat],
      "score": sim.score(seat),
      "points": sim.points[seat],
      "matches": sim.matchesPlayed[seat],
      "deals": sim.deals[seat],
      "giveaway": sim.giveaway(seat),
      "fallbacks": sim.fallbacks[seat],
      "role": sim.roleOf(seat),
      "notes": sim.notes[seat]
    })
  var itemNames = newJArray()
  for name in ItemNames:
    itemNames.add(%name)
  %*{
    "seats": seats,
    "match": sim.match,
    "matches": sim.config.matches,
    "matchesPlayed": sim.matchesSettled,
    "kind": (if sim.match >= 0: sim.plan.kind else: ""),
    "itemNames": itemNames,
    "table": sim.tableJson(),
    "phase": $sim.phase,
    "gameDone": sim.done,
    "reason": sim.reason
  }

proc scheduleJson*(sim: Sim): JsonNode =
  ## Both seats' private valuations ride in the replay: spectators see them,
  ## the seats never do. Re-derivable from the seed, and `replayMatch`
  ## checks them against it.
  result = newJArray()
  for plan in sim.schedule:
    var values = newJArray()
    for side in 0 .. 1:
      values.add(%toSeq3(plan.values[side]))
    result.add(%*{
      "kind": plan.kind,
      "seats": @[plan.seats[0], plan.seats[1]],
      "opener": plan.seats[plan.opener],
      "pool": toSeq3(plan.pool),
      "values": values
    })

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.match >= 0:
    result["match"] = %event.match
  case event.kind
  of evStart:
    discard
  of evMatch:
    result["matchKind"] = %event.matchKind
    result["seats"] = %event.seats
    result["opener"] = %event.opener
    result["pool"] = %event.pool
    var values = newJArray()
    for row in event.values:
      values.add(%row)
    result["values"] = values
    result["maxTurns"] = %event.maxTurns
  of evOffer:
    result["turn"] = %event.turn
    result["seat"] = %event.seat
    result["other"] = %event.other
    result["take"] = %event.take
    result["worth"] = %event.worth
    result["scripted"] = %event.scripted
  of evAccept:
    result["turn"] = %event.turn
    result["seat"] = %event.seat
    result["other"] = %event.other
    result["take"] = %event.take
    result["payoff"] = %event.payoff
    result["scripted"] = %event.scripted
  of evMatchEnd:
    result["outcome"] = %event.outcome
    result["payoff"] = %event.payoff
    result["turn"] = %event.turn
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text
  if event.notes.len > 0:
    result["notes"] = %event.notes

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    match: node{"match"}.getInt(-1),
    turn: node{"turn"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    other: node{"other"}.getInt(-1),
    matchKind: node{"matchKind"}.getStr(""),
    opener: node{"opener"}.getInt(-1),
    maxTurns: node{"maxTurns"}.getInt(0),
    outcome: node{"outcome"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr(""),
    notes: node{"notes"}.getStr("")
  )
  for key in ["seats", "pool", "take", "worth", "payoff"]:
    if node.hasKey(key):
      var values: seq[int]
      for entry in node[key]:
        values.add(entry.getInt())
      case key
      of "seats": result.seats = values
      of "pool": result.pool = values
      of "take": result.take = values
      of "worth": result.worth = values
      else: result.payoff = values
  if node.hasKey("values"):
    for row in node["values"]:
      var line: seq[int]
      for entry in row:
        line.add(entry.getInt())
      result.values.add(line)

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying
  ## the offer / accept events through the rules (the schedule comes from
  ## the seed). frames[i] = state after events[0 ..< i].
  var sim = initSim(config)
  ## initSim already logged the start event; the recorded log's first event
  ## is that same start.
  sim.events = @[]
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evMatch:
      sim.beginMatch()
      let logged = sim.events[^1]
      if event.match != logged.match or event.seats != logged.seats or
          event.opener != logged.opener or event.pool != logged.pool or
          event.values != logged.values or
          event.matchKind != logged.matchKind or
          event.maxTurns != logged.maxTurns:
        raise newException(NegotiationError,
          "match " & $event.match & " does not match the seeded schedule")
    of evOffer:
      ## An apply can append more than one event (the turn cliff settles the
      ## match, and the last match's settlement ends the episode), so the
      ## re-derived action is found by INDEX, never by counting back from
      ## the tail.
      let at = sim.events.len
      sim.applyOffer(event.match, fromSeq3(event.take), event.text,
        event.notes, event.scripted)
      let logged = sim.events[at]
      if event.worth.len > 0 and event.worth != logged.worth:
        raise newException(NegotiationError,
          "match " & $event.match & " turn " & $event.turn &
          " offer worth does not match the seeded valuations")
    of evAccept:
      let at = sim.events.len
      sim.applyAccept(event.match, event.text, event.notes, event.scripted)
      let logged = sim.events[at]
      if (event.take.len > 0 and event.take != logged.take) or
          (event.payoff.len > 0 and event.payoff != logged.payoff):
        raise newException(NegotiationError,
          "match " & $event.match & " turn " & $event.turn &
          " accept payoff does not match the seeded valuations")
    of evMatchEnd:
      ## Emitted by applyOffer / applyAccept; the recorded copy is a
      ## checkpoint, not an instruction.
      discard
    of evEnd:
      ## A wall-clock stop is not derivable from the offers alone, so it is
      ## applied through the same proc the live server calls.
      sim.settle(event.text)
    result.add(sim)
