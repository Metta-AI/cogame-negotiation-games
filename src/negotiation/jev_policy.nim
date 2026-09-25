## Jev ranks offers from one private bargaining observation in the player.

import std/[json, os, strutils]
import curly

proc chooseAction*(observation: JsonNode, guidance: string): JsonNode =
  let pool = observation["pool"]
  let values = observation["yourValues"]
  var criteria = newJObject()
  for reservation in [10, 8, 6, 4, 2]:
    var selected = [0, 0, 0]
    var fewest = high(int)
    var selectedWorth = high(int)
    for books in 0 .. pool[0].getInt():
      for hats in 0 .. pool[1].getInt():
        for balls in 0 .. pool[2].getInt():
          let worth = books * values[0].getInt() +
            hats * values[1].getInt() + balls * values[2].getInt()
          let units = books + hats + balls
          if worth >= reservation and
              (units < fewest or (units == fewest and worth < selectedWorth)):
            selected = [books, hats, balls]
            fewest = units
            selectedWorth = worth
    let name = "offer_" & $selected[0] & "_" & $selected[1] & "_" &
      $selected[2]
    criteria[name] = %("Offer to take " & $selected[0] & " books, " &
      $selected[1] & " hats, and " & $selected[2] &
      " balls. Worth " & $selectedWorth & "/10 to you; the opponent " &
      "receives the remaining items.")
  if observation["canAccept"].getBool():
    criteria["accept"] = %("Accept the standing offer, worth " &
      $observation["standing"]["worthToYou"].getInt() &
      "/10 to you. The match ends now.")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let routerKey = getEnv("OPENROUTER_API_KEY").strip()
  let directKey = getEnv("TYPESAFE_API_KEY").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = "typesafe/jev-1.13"
    key = getEnv("METTA_CAPTURE_KEY").strip()
  elif routerKey.len > 0:
    endpoint = "https://openrouter.ai/api"
    model = "typesafe/jev-1.13"
    key = routerKey
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = directKey
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Jev player has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  let body = %*{
    "model": model,
    "state": "You are bargaining over books, hats, and balls. Maximize " &
      "your match payoff while preserving a chance of agreement. " &
      "Your own private values and public bargaining history are in this " &
      "seat observation:\n" & $observation &
      "\nStrategy guidance: " & guidance,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose a legal offer or accept the standing offer.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  if selected == "accept":
    result = %*{"action": "accept", "message": "", "notes": ""}
  else:
    let parts = selected.split('_')
    result = %*{"action": "offer", "take": [
      parseInt(parts[1]), parseInt(parts[2]), parseInt(parts[3])],
      "message": "", "notes": ""}
  echo "Negotiation Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
