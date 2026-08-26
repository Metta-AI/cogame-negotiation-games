## Config and event types for Negotiation Games. No IO — the sim, the
## server, the tests and the wasm replay viewer all share these.

import std/[json, strutils]

type
  NegotiationError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    matches*: int                 ## matches in the episode (default 6, legal 3 or 6)
    maxTurns*: int                ## turns per match (default 10, legal even 2..12)
    episodeTimeoutSeconds*: int   ## assumed platform kill time when the env is silent
    sampled*: bool                ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  EventKind* = enum
    evStart = "start"
    evMatch = "match"
    evOffer = "offer"
    evAccept = "accept"
    evMatchEnd = "matchEnd"
    evEnd = "end"

  GameEvent* = object
    ## Flat, babel's shape. Unset fields are omitted by `eventToJson`.
    kind*: EventKind
    match*: int            ## match index; end: matches played; start: -1
    turn*: int             ## offer/accept: 1-based turn; matchEnd: turns used
    seat*: int             ## offer/accept: the actor
    other*: int            ## offer/accept: the opponent
    ## `MatchPlan.kind` cannot ride under the JSON key "kind" — that key
    ## already carries the EVENT kind — so the match event spells it
    ## `matchKind`. Value in v1: "bargaining".
    matchKind*: string
    seats*: seq[int]       ## match: [a, b]
    opener*: int           ## match: the seat id that moves on turn 1
    pool*: seq[int]        ## match: item counts
    values*: seq[seq[int]] ## match: both seats' private per-item values
    maxTurns*: int         ## match: the turn cliff
    take*: seq[int]        ## offer: the actor's take; accept: what it receives
    worth*: seq[int]       ## offer: [uActor, uOther] under this offer
    payoff*: seq[int]      ## accept/matchEnd: [uA, uB] in the match's seat order
    outcome*: string       ## matchEnd: "deal" | "no_deal"
    scripted*: bool        ## offer/accept: decided by a scripted baseline
    text*: string          ## offer/accept: the public message; end: reason
    notes*: string         ## offer/accept: the actor's private notes

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    matches: 6,
    maxTurns: 10,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 900,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 30
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(NegotiationError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("matches"):
    config.matches = node["matches"].getInt()
  if node.hasKey("maxTurns"):
    config.maxTurns = node["maxTurns"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.matches < 3:
    raise newException(NegotiationError, "matches must be at least 3")
  if config.matches mod 3 != 0:
    ## An episode whose match count is not a multiple of 3 gives the three
    ## seats unequal match counts, which the score normalisation assumes away.
    raise newException(NegotiationError, "matches must be a multiple of 3")
  if config.maxTurns < 2 or config.maxTurns > 12:
    raise newException(NegotiationError, "maxTurns must be between 2 and 12")
  if config.maxTurns mod 2 != 0:
    ## Odd turn counts hand the opener one more turn than its opponent.
    raise newException(NegotiationError, "maxTurns must be even")
