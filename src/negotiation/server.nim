## Negotiation Games server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - the game block of the renderer
##   GET /client/chrome_common.js    - the inherited broadcast chrome
##   GET /client/chrome.css          - stylesheet
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Player protocol (negotiation.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","slot":N,"name":...,"matches":M,"maxTurns":T}
##                   {"type":"state",...} after every event, REDACTED to the
##                   seat's own tallies (the game is hidden-information and
##                   every decision is server-side)
##                   {"type":"final","scores":[...],...}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"haggler"}
##                   (prompt max 4000 chars; scripted names a baseline)

import
  std/[json, locks, os, sets, strutils, tables, times],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  PlayerProtocol = "negotiation.player.v1"

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[string]      ## "" = LLM seat; else the baseline's name
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous table names; the policy names ride alongside
  ## for the SPECTATOR views only, which render them in place of the aliases.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.tableStateJson()
  result["type"] = %"state"
  result["game"] = %"negotiation-games"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc playerStateJson(gs: GameState, slot: int): JsonNode =
  ## Hidden information: the pool, both seats' valuations, the offers and
  ## the notes are not for the player containers. A seat sees only its own
  ## tallies and the match counter. Decisions are server-side, so this
  ## loses nothing. NEVER carries policyNames.
  %*{
    "type": "state",
    "slot": slot,
    "name": gs.sim.names[slot],
    "seat": {
      "score": gs.sim.score(slot),
      "points": gs.sim.points[slot],
      "matches": gs.sim.matchesPlayed[slot],
      "deals": gs.sim.deals[slot]
    },
    "match": gs.sim.match,
    "matches": gs.config.matches,
    "matchesPlayed": gs.sim.matchesSettled,
    "started": gs.started,
    "done": gs.sim.done,
    "reason": gs.sim.reason
  }

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole table; players get the
  ## redacted per-seat state.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honoring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var names = newJArray()
  for name in gs.sim.names:
    names.add(%name)
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var itemNames = newJArray()
  for name in ItemNames:
    itemNames.add(%name)
  $ %*{
    "protocol": ReplayProtocol,
    "names": names,
    "policyNames": gs.policyNamesJson(),
    "config": {
      "seed": gs.config.seed,
      "matches": gs.config.matches,
      "maxTurns": gs.config.maxTurns,
      "sampled": true,
      "itemNames": itemNames,
      "schedule": gs.sim.scheduleJson()
    },
    "events": events,
    "results": results
  }

proc statesFromEvents(config: GameConfig, events: seq[GameEvent]): JsonNode =
  ## One table-state object per event prefix, for scrubbing replays.
  result = newJArray()
  for frame in replayMatch(config, events):
    result.add(frame.tableStateJson())

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists, and
    ## writing first would race player log collection.
    ## Results carry POLICY names for the platform; the final frame goes to
    ## the player sockets, so hand them the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "points": results["points"],
      "deals": results["deals"],
      "names": aliasNames,
      "matchesPlayed": results["matchesPlayed"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "negotiation: writing results and replay"
  writeArtifact(
    runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD"
  )
  writeArtifact(
    runtimeConfig.replayUri, replayData, "application/octet-stream",
    "COGAME_SAVE_REPLAY_METHOD"
  )
  ## The episode runner pings /global (2 s deadline) AFTER the player pods
  ## start, and a short episode can otherwise already be gone. Keep
  ## /healthz, /global and the /client/* routes answering for a bounded
  ## grace, then exit; the runner waits on process exit anyway
  ## (cogame-lantern 0.1.3).
  echo "negotiation: artifacts written; serving a ",
    ShutdownGraceSeconds, "s shutdown grace"
  sleep(ShutdownGraceSeconds * 1000)
  echo "negotiation: episode complete, shutting down"
  quit(0)

const PlayBudgetFraction* = 0.6
  ## Share of the platform's episode timeout spent playing. The rest covers
  ## container start, player connects, and writing the artifacts — the part
  ## that must never be the thing that runs out of time.

proc decisionText(sim: Sim, decision: Decision): string =
  let plan = sim.plan
  let side = sim.actorSide
  let me = sim.names[plan.seats[side]]
  if decision.action == "accept":
    me & " accepts"
  else:
    me & " takes " & takeText(decision.take, plan.pool)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "negotiation: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    ## The platform kills the episode at its timeout and keeps nothing. Play
    ## inside a fraction of it so results and the replay are written with
    ## room to spare. The hosted dispatcher hands the timeout only to its own
    ## worker sidecar, NOT to the game container, so when the env is silent
    ## assume the configured platform default rather than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "negotiation: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    var lastCallStart = 0.0
    var pacingSpent = 0

    while true:
      var simCopy: Sim
      var call: Call
      var seatPrompt: string
      var seatScripted: string
      var pastDeadline = false
      withLock stateLock:
        if state.sim.done:
          break
        call = state.sim.currentCall()
        pastDeadline = playDeadline > 0.0 and epochTime() > playDeadline
        if call.kind == ckNone:
          break
        if call.kind == ckMatch:
          if pastDeadline:
            ## The deadline is honoured BETWEEN matches only: a match that
            ## has started is always finished (by the baseline, in
            ## microseconds) so every `match` event has its `matchEnd`.
            echo "negotiation: episode deadline reached after ",
              state.sim.matchesSettled, "/", config.matches,
              " matches; ending early"
            state.sim.endEarly()
            state.broadcastLocked()
            break
          state.sim.beginMatch()
          let plan = state.sim.plan
          echo "negotiation: match ", state.sim.match + 1, " of ",
            config.matches, ": ", state.sim.names[plan.seats[0]], " vs ",
            state.sim.names[plan.seats[1]], ", pool ", poolText(plan.pool),
            " at ", (epochTime() - gameStart).int, "s"
          state.broadcastLocked()
          continue
        simCopy = state.sim
        seatPrompt = state.prompts[call.seat]
        seatScripted = state.scripted[call.seat]

      let useScripted = seatScripted.len > 0 or pastDeadline or client.disabled
      if not useScripted:
        ## Wall-clock floor between model calls: the hosted Bedrock sidecar
        ## caps 30 requests/minute per episode.
        let waitMs = MinCallSpacingMs -
          int((epochTime() - lastCallStart) * 1000.0)
        if lastCallStart > 0.0 and waitMs > 0:
          sleep(waitMs)
        lastCallStart = epochTime()

      ## The slow part (Claude) runs outside the lock on a snapshot; only
      ## this thread mutates the sim, so the snapshot cannot go stale.
      let decision = client.decide(simCopy, call, seatPrompt,
        scripted = seatScripted, forceScripted = pastDeadline)

      var settledBefore = 0
      var settledAfter = 0
      withLock stateLock:
        settledBefore = state.sim.matchesSettled
        echo "negotiation: match ", state.sim.match + 1, " turn ",
          state.sim.turn, " ", decisionText(state.sim, decision),
          (if decision.scripted: " [scripted]" else: ""), " at ",
          (epochTime() - gameStart).int, "s"
        try:
          if decision.action == "accept":
            state.sim.applyAccept(call.match, decision.message,
              decision.notes, decision.scripted)
          else:
            state.sim.applyOffer(call.match, decision.take, decision.message,
              decision.notes, decision.scripted)
        except NegotiationError as error:
          echo "negotiation: reply rejected (", error.msg,
            "); using the scripted fallback"
          let fallback = scriptedDecision(state.sim, DefaultBaseline)
          state.sim.recordFallback(call.seat)
          if fallback.action == "accept":
            state.sim.applyAccept(call.match, "", "", true)
          else:
            state.sim.applyOffer(call.match, fallback.take, "", "", true)
        if decision.fallback:
          state.sim.recordFallback(call.seat)
        settledAfter = state.sim.matchesSettled
        state.broadcastLocked()

      ## Pace between matches for the spectator, inside a whole-episode
      ## budget so pacing can never be the thing that runs out of time.
      if settledAfter > settledBefore and config.turnDelayMs > 0 and
          pacingSpent + config.turnDelayMs <= PacingBudgetMs:
        pacingSpent += config.turnDelayMs
        sleep(config.turnDelayMs)

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc scriptHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name,
        "application/javascript; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "negotiation: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": PlayerProtocol,
        "slot": slot,
        "name": state.sim.names[slot],
        "matches": state.config.matches,
        "maxTurns": state.config.maxTurns
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.len > MaxPromptLen:
            prompt = prompt[0 ..< MaxPromptLen]
          let scriptedNode = payload{"scripted"}
          var baseline = ""
          if not scriptedNode.isNil:
            case scriptedNode.kind
            of JString: baseline = normalizeBaseline(scriptedNode.getStr())
            of JBool:
              baseline = (if scriptedNode.getBool(): DefaultBaseline else: "")
            else: discard
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = baseline
          echo "negotiation: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if baseline.len > 0: ", scripted " & baseline else: ""), ")"
      except CatchableError as error:
        echo "negotiation: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay_broadcast.html"))
  result.get("/client/renderer.js", scriptHandler("renderer.js"))
  result.get("/client/chrome_common.js", scriptHandler("chrome_common.js"))
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.matches = payload["config"]{"matches"}.getInt(6)
  result.maxTurns = payload["config"]{"maxTurns"}.getInt(10)
  result.seed = payload["config"]{"seed"}.getInt(0)
  ## The replay carries the episode's fitted cap; never re-fit it. The
  ## schedule it carries is re-derived from the seed.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: parse the recorded replay, precompute the scrub states,
  ## and serve the viewer until the platform tears the container down.
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var enriched = %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr(ReplayProtocol),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "states": statesFromEvents(config, events)
  }
  replayPayloadGlobal = $enriched

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "negotiation: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(NegotiationError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[string](config.players.len)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "negotiation: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
