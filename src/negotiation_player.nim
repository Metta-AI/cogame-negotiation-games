## Negotiation Games player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default bargaining strategy), then idles until the final frame. All of
## the actual decision making happens inside the game server, which sends
## this seat's prompt to Claude whenever the seat has to offer or accept.
##
## PLAYER_SCRIPTED=haggler|hardliner registers the seat as one of the
## built-in baselines instead: the server plays it deterministically, no
## LLM. `1|true|yes` also works and means `haggler`.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <image> --name my-negotiator \
##     --run /bin/negotiation-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Open by taking the whole pool and say which item you need most. Concede in
small steps, always giving away the item that is worth least to you per
unit and never the one you value most. Watch what your opponent keeps
asking for - that is what they value - and charge them for it while you
take the rest. Accept the standing offer when it is worth 6 or more to
you, or when three or fewer turns remain and it is worth 4 or more. On the
last turn available to you, accept anything worth 1 or more: a deal you
dislike still beats the zero that both of you get when the turns run out.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "negotiation player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "negotiation player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and the game's quit(0) can outrun the
  ## flushed final frame. An unhandled raise here exits 1 and fails
  ## certification with player_error on a coin flip (cogame-raid 0.1.4).
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "negotiation player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "negotiation player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "negotiation player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "negotiation player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "negotiation player: socket closed (", error.msg, "), exiting 0"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
