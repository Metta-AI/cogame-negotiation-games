## Claude-backed decision making for Negotiation Games. Each seat's policy
## is just a prompt: the game server composes the acting seat's view (the
## pool, its OWN private values, the standing offer rendered from its side,
## this match's offer history, its record so far and its private notes) plus
## that seat's prompt, and asks Claude whether it offers or accepts.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal
## scripted baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies: a player that registers as
## `haggler` or `hardliner` plays one deliberately, LLM or not.

import
  std/[json, math, os, random, strutils],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  ## The baseline a seat falls back to when it registered a prompt (or
  ## nothing at all) and the model path fails.
  DefaultBaseline* = "haggler"
  Baselines* = ["haggler", "hardliner"]
  RetryHint* = "\nYour previous reply was invalid. Respond with ONLY the " &
    "requested JSON object: either {\"action\":\"accept\",...} or " &
    "{\"action\":\"offer\",\"take\":{...}} with every count inside the " &
    "bounds shown."

type
  Decision* = object
    action*: string              ## "offer" | "accept"
    take*: array[Items, int]     ## offer: how many of each item the actor takes
    message*: string             ## cheap talk, <= MaxMessageLen runes
    notes*: string               ## private, <= MaxNotesLen runes
    scripted*: bool              ## produced by a scripted baseline
    fallback*: bool              ## the model path was skipped or gave up

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable
    rand: Rand

proc normalizeBaseline*(name: string): string =
  ## `1|true|yes` mean the default baseline, for compatibility with the
  ## lineage's boolean PLAYER_SCRIPTED.
  let text = name.strip().toLowerAscii()
  if text.len == 0:
    return ""
  if text in ["1", "true", "yes", "on"]:
    return DefaultBaseline
  for baseline in Baselines:
    if text == baseline:
      return baseline
  DefaultBaseline

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "negotiation llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL
  ## pins a single id; without it, fall through this list — model access is
  ## a per-account Marketplace subscription, so an id that works in one
  ## account 403s in another. Haiku leads: hosted Bedrock capacity is shared
  ## account-wide and the sonnet profiles run out of daily tokens first.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "negotiation llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    rand: initRand(config.seed xor 0x5EED)
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "negotiation llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "negotiation llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "negotiation llm: no LLM credentials; using scripted fallback"

# ---- Scripted baselines -----------------------------------------------------

proc reservationFor*(baseline: string, turn, maxTurns: int): int =
  ## What the bot insists on keeping for itself on this turn.
  ##
  ## haggler   monotone concession: 10 on turn 1, decaying linearly to 4 on
  ##           the last turn, then 1 on this seat's own final turn — a deal
  ##           it dislikes still beats the zero the cliff pays.
  ## hardliner stubborn: 8 all the way, 3 on its own final turn. It refuses
  ##           most splits and gets its way against a conceder.
  let lastOwnTurn = turn > maxTurns - 2
  if baseline == "hardliner":
    return (if lastOwnTurn: 3 else: 8)
  if lastOwnTurn:
    return 1
  let decayed = 10.0 - 6.0 * (turn - 1).float / max(maxTurns - 1, 1).float
  max(4, min(10, int(round(decayed))))

proc bestOffer*(pool, values: array[Items, int], reservation: int):
    array[Items, int] =
  ## The SMALLEST bundle worth at least `reservation` to this seat: ties go
  ## to the fewest total items taken, then to the lexicographically smallest
  ## vector. Taking the whole pool always qualifies, so the set is never
  ## empty. Enumerating in lexicographic order and only accepting a STRICT
  ## improvement makes the last tie-break fall out for free.
  var best = pool
  var bestWorth = worthOf(values, pool)
  var bestItems = pool[0] + pool[1] + pool[2]
  for x0 in 0 .. pool[0]:
    for x1 in 0 .. pool[1]:
      for x2 in 0 .. pool[2]:
        let take = [x0, x1, x2]
        let worth = worthOf(values, take)
        if worth < reservation:
          continue
        let items = x0 + x1 + x2
        if worth < bestWorth or (worth == bestWorth and items < bestItems):
          best = take
          bestWorth = worth
          bestItems = items
  best

proc scriptedDecision*(sim: Sim, baseline: string): Decision =
  ## Always legal, never chatty, no RNG: fully deterministic given the sim.
  let plan = sim.plan
  let side = sim.actorSide
  let values = plan.values[side]
  let reservation = reservationFor(baseline, sim.turn, sim.config.maxTurns)
  result.scripted = true
  if sim.acceptLegal and sim.standingWorthTo(side) >= reservation:
    result.action = "accept"
    return
  result.action = "offer"
  result.take = bestOffer(plan.pool, values, reservation)

# ---- Prompt building --------------------------------------------------------

const SystemPromptTemplate = """You are $1, a cog at a three-seat negotiation table. Right now you are bargaining
one-on-one with $2.

Rules:
- A pool of items sits between you: $3 books, $4 hats, $5 balls. The whole pool is
  worth exactly 10 points to you, and exactly 10 points to your opponent - but the
  per-item values are DIFFERENT and PRIVATE. You know yours. You will never be told
  theirs, and they are never told yours.
- You take turns. On your turn you either make an OFFER - exactly how many of each
  item YOU take, your opponent getting the rest - or ACCEPT the offer standing
  against you.
- The match is at most $6 turns long, yours and theirs together. If nobody has
  accepted when the turns run out, the deal fails and BOTH of you score zero for
  this match.
- Your score for this match is the value TO YOU of the items you end up with, out
  of 10. No deal is 0. Waiting costs nothing except turns, and turns are the only
  thing you cannot get back.
- You may attach a short message of at most $7 characters. Your opponent reads it.
  It is cheap talk: nothing you say is enforced. The OFFER is the only binding
  channel, and it is the only thing you are graded on.
- Your notes are private, are handed back to you on your next turn, and are never
  shown to your opponent.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis, no
explanation, no markdown fences, no text before or after the object. Your reply
must begin with the character { and end with }."""

proc systemPrompt*(sim: Sim, seat: int): string =
  let plan = sim.plan
  let side = sim.sideOfSeat(seat)
  SystemPromptTemplate % [
    sim.names[seat], sim.names[plan.seats[1 - side]],
    $plan.pool[0], $plan.pool[1], $plan.pool[2],
    $sim.config.maxTurns, $MaxMessageLen
  ]

proc historyText(sim: Sim, side: int): string =
  ## Every offer of THIS match, both sides, each with its worth to this seat.
  if sim.offers.len == 0:
    return "  (nothing yet)"
  let plan = sim.plan
  let them = sim.names[plan.seats[1 - side]]
  var lines: seq[string]
  for record in sim.offers:
    let mine =
      if record.side == side: record.take
      else: complementOf(plan.pool, record.take)
    let worth = worthOf(plan.values[side], mine)
    let who = if record.side == side: "you offered" else: them & " offered"
    let what =
      if record.side == side: "you take " & takeText(record.take, plan.pool)
      else: "you get " & takeText(mine, plan.pool)
    var line = "  Turn " & $record.turn & " - " & who & ": " & what &
      " (worth " & $worth & " to you)."
    if record.text.len > 0:
      line.add(" \"" & record.text & "\"")
    lines.add(line)
  lines.join("\n")

proc recordText(sim: Sim, seat: int): string =
  ## The seat's own settled matches this episode, and nothing else.
  var lines: seq[string]
  var index = 0
  for event in sim.events:
    if event.kind != evMatchEnd:
      continue
    let plan = sim.schedule[event.match]
    var side = -1
    if plan.seats[0] == seat: side = 0
    elif plan.seats[1] == seat: side = 1
    if side < 0:
      continue
    inc index
    let opponent = sim.names[plan.seats[1 - side]]
    let mine = (if event.payoff.len > side: event.payoff[side] else: 0)
    if event.outcome == "deal":
      lines.add("  Match " & $(event.match + 1) & " vs " & opponent &
        " - DEAL, you scored " & $mine & "/10.")
    else:
      lines.add("  Match " & $(event.match + 1) & " vs " & opponent &
        " - NO DEAL, 0/10.")
  if lines.len == 0:
    return "  (no matches settled yet)"
  lines.join("\n")

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply\nin the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let plan = sim.plan
  let side = sim.sideOfSeat(seat)
  let them = sim.names[plan.seats[1 - side]]
  result.add("MATCH " & $(sim.match + 1) & " of " & $sim.config.matches &
    ". TURN " & $sim.turn & " of " & $sim.config.maxTurns & ". You are " &
    sim.names[seat] & "; your opponent is " & them & ".\n\n")
  result.add("THE POOL: " & poolText(plan.pool) & "\n")
  result.add("YOUR PRIVATE VALUES: " &
    valuesText(plan.values[side], plan.pool) &
    " (the whole pool = 10 to you)\n\n")
  if sim.standingSide >= 0 and sim.standingSide != side:
    let theirs = sim.standing
    let mine = complementOf(plan.pool, theirs)
    result.add("THE OFFER STANDING AGAINST YOU: " & them & " takes " &
      takeText(theirs, plan.pool) & "; you get\n" & takeText(mine, plan.pool) &
      " - worth " & $worthOf(plan.values[side], mine) & " to you.\n")
  else:
    result.add("NO OFFER YET - you open.\n")
  result.add("ACCEPT IS LEGAL NOW: " &
    (if sim.acceptLegal: "yes" else: "no") & "\n")
  let talk = sim.lastMessage[1 - side]
  if talk.len > 0:
    result.add("TABLE TALK FROM " & them & ": \"" & talk & "\"\n")
  result.add("\nTHIS MATCH SO FAR:\n" & historyText(sim, side) & "\n\n")
  result.add("YOUR RECORD THIS EPISODE:\n" & recordText(sim, seat) & "\n\n")
  result.add("YOUR NOTES FROM EARLIER TURNS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"action\":\"offer\",\"take\":" &
    "{\"books\":0,\"hats\":0,\"balls\":0},\"message\":\"...\"," &
    "\"notes\":\"...\"} or {\"action\":\"accept\",\"message\":\"...\"," &
    "\"notes\":\"...\"} - books 0.." & $plan.pool[0] & ", hats 0.." &
    $plan.pool[1] & ", balls 0.." & $plan.pool[2] &
    ", whole numbers only; message at most " & $MaxMessageLen &
    " characters; notes at most " & $MaxNotesLen & " characters.")

# ---- Reply parsing ----------------------------------------------------------

proc countFrom(node: JsonNode): int =
  ## A count is a JSON integer or an integer-valued string. Anything else —
  ## a float, a fraction, a word — is an invalid reply.
  if node.isNil or node.kind == JNull:
    return 0
  case node.kind
  of JInt:
    node.getInt()
  of JString:
    try:
      parseInt(node.getStr().strip())
    except ValueError:
      raise newException(NegotiationError,
        "counts must be whole numbers: " & node.getStr())
  else:
    raise newException(NegotiationError, "counts must be whole numbers: " & $node)

proc parseAction*(sim: Sim, payload: JsonNode): Decision =
  ## Tolerant in exactly these ways and no others:
  ##  - `action` case-insensitive after trimming; accept|agree|deal and
  ##    offer|propose|counter are synonyms;
  ##  - `action` absent but `take` present means an offer;
  ##  - `take` may be {books,hats,balls} (missing keys are 0) or the
  ##    3-element array [books, hats, balls], with JSON integers or
  ##    integer-valued strings.
  ## Everything else is an invalid reply. Legality (bounds, accept on turn
  ## one) is enforced by applying the decision to a probe copy in `decide`.
  result.message = cleanMessage(payload{"message"}.getStr())
  result.notes = cleanNotes(payload{"notes"}.getStr())
  let takeNode = payload{"take"}
  let hasTake = not takeNode.isNil and takeNode.kind != JNull
  let action = payload{"action"}.getStr().strip().toLowerAscii()
  if action in ["accept", "agree", "deal"]:
    result.action = "accept"
    return
  if action notin ["offer", "propose", "counter"]:
    if action.len > 0 or not hasTake:
      raise newException(NegotiationError,
        "unknown action: " & payload{"action"}.getStr())
  result.action = "offer"
  if not hasTake:
    raise newException(NegotiationError, "an offer needs a take")
  case takeNode.kind
  of JObject:
    for index in 0 ..< Items:
      result.take[index] = countFrom(takeNode{ItemNames[index]})
  of JArray:
    if takeNode.len != Items:
      raise newException(NegotiationError,
        "take as an array must hold exactly " & $Items & " counts")
    for index in 0 ..< Items:
      result.take[index] = countFrom(takeNode[index])
  else:
    raise newException(NegotiationError,
      "take must be an object or a 3-element array")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...). Cut on a
    ## rune boundary: this string can reach a log line and a replay.
    let head = capRunes(text.strip().replace("\n", " "), 160)
    raise newException(NegotiationError, "no JSON object in response: " & head)
  parseJson(text[start .. stop])

proc completeText(client: LlmClient, system, user: string): string =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  var url: string
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    url = AnthropicUrl
  let response = client.curl.post(url, headers, $body, client.timeoutSeconds)
  if response.code == 401 or response.code == 403:
    let detail = capRunes(response.body, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(NegotiationError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(NegotiationError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = capRunes(response.body, 300)
    discard client.tryNextBedrockModel("throttled")
    raise newException(NegotiationError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(NegotiationError, "anthropic error " & $response.code &
      ": " & capRunes(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(NegotiationError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(NegotiationError, "reply cut off at max_tokens before " &
      "any JSON: " & capRunes(result.replace("\n", " "), 160))

proc decide*(
  client: LlmClient,
  sim: Sim,
  call: Call,
  prompt: string,
  scripted: string,
  forceScripted = false
): Decision =
  ## One decision for one seat. Never raises: any failure falls back to the
  ## seat's scripted baseline so the turn always advances.
  let baseline =
    if scripted.len > 0: normalizeBaseline(scripted) else: DefaultBaseline
  if scripted.len > 0:
    ## A registered scripted seat is playing its policy, not degrading.
    return scriptedDecision(sim, baseline)
  if forceScripted or client.disabled:
    result = scriptedDecision(sim, baseline)
    result.fallback = true
    return
  let system = systemPrompt(sim, call.seat)
  for attempt in 0 .. 1:
    var user = userPrompt(sim, call.seat, prompt)
    if attempt > 0:
      user.add(RetryHint)
    try:
      let payload = extractJsonObject(client.completeText(system, user))
      var decision = parseAction(sim, payload)
      ## Reject illegal replies here so the retry carries the hint.
      var probe = sim
      if decision.action == "accept":
        probe.applyAccept(call.match, decision.message, decision.notes, false)
      else:
        probe.applyOffer(call.match, decision.take, decision.message,
          decision.notes, false)
      return decision
    except CatchableError as error:
      echo "negotiation llm: seat ", call.seat, " attempt ", attempt,
        " failed: ", error.msg
      if client.disabled:
        break
  echo "negotiation llm: seat ", call.seat,
    " falling back to the ", baseline, " baseline"
  result = scriptedDecision(sim, baseline)
  result.fallback = true
