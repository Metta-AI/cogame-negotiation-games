#!/usr/bin/env python3
"""Regenerates coworld_manifest_template.json.

The manifest is the contract phase 40 uploads, and its long prose blocks
(description, protocols, docs) are far easier to keep correct here than in
hand-edited JSON. Run it and commit the result:

    python3 tools/build_manifest.py
"""
import json
import pathlib

IMAGE = "{{GAME_IMAGE}}"
SOURCE = "https://github.com/Metta-AI/cogame-negotiation-games/tree/main"
SEATS = 3

DESCRIPTION = (
    "Negotiation Games: a three-seat bargaining table for LLM-piloted cogs, "
    "a port of OpenSpiel's `bargaining` (Lewis et al. 2017 / DeepMind). An "
    "episode is six one-on-one matches; each match puts a pool of books, "
    "hats and balls between two of the three seats. The pool is worth "
    "exactly 10 points to each of them, but the per-item values are "
    "DIFFERENT and PRIVATE, so there is almost always a split that beats a "
    "50/50 hack. The two seats alternate for at most ten turns: OFFER "
    "exactly how many of each item you take (your opponent gets the rest), "
    "or ACCEPT the offer standing against you. Agree and you both bank the "
    "value TO YOU of what you took, out of 10; run out of turns and BOTH of "
    "you bank zero. Every match redraws the pairing, the pool and both "
    "seats' valuations, so nothing learned about one opponent transfers, "
    "and seats play under anonymous cog aliases so nobody can meta-game who "
    "is behind a seat. Offers may carry a short message, but talk is cheap: "
    "the structured offer is the only binding channel and the only thing "
    "that is graded. Spectators see BOTH seats' hidden valuations, so every "
    "offer reads instantly as generous or greedy. The game is LLM-driven: "
    "the server sends the acting seat's policy prompt plus the pool, its own "
    "private values, the standing offer, this match's history and its "
    "private notes to Claude, so A POLICY IS JUST A PROMPT - build one by "
    "reusing the published player runnable and setting the PLAYER_PROMPT "
    "environment variable to your strategy. Two scripted baselines "
    "(a conceding `haggler` and a stubborn `hardliner`) play any seat that "
    "registers as scripted - and every seat when no LLM credentials are "
    "available, so episodes always complete."
)

PLAYER_PROTOCOL = (
    "negotiation.player.v1 - JSON text frames over the websocket named by "
    "COWORLD_PLAYER_WS_URL (already carrying ?slot=N&token=T). A Negotiation "
    "Games policy is a prompt: the player container's only job is to deliver "
    "it, and the game server makes every decision by sending that prompt "
    "plus the acting seat's view (the pool, its OWN private per-item values, "
    "the offer standing against it with the worth to itself precomputed, an "
    "explicit ACCEPT IS LEGAL NOW line and the per-item bounds, this match's "
    "full offer history, its record this episode and its private notes) to "
    "Claude. game->player frames: "
    "{\"type\":\"welcome\",\"protocol\":\"negotiation.player.v1\",\"slot\":N,"
    "\"name\":str,\"matches\":int,\"maxTurns\":int} on connect; "
    "{\"type\":\"state\",\"slot\":N,\"name\":str,\"seat\":{\"score\":float,"
    "\"points\":int,\"matches\":int,\"deals\":int},\"match\":int,"
    "\"matches\":int,\"matchesPlayed\":int,\"started\":bool,\"done\":bool,"
    "\"reason\":str} after every event - REDACTED to the seat's own tallies "
    "and the match counter, because the game is hidden-information (the "
    "pool, both seats' valuations, the offers, the messages and the notes "
    "are not for the player containers) and every decision is server-side, "
    "so nothing is lost; player frames never carry policyNames. "
    "{\"type\":\"final\",\"done\":true,\"scores\":[...],\"points\":[...],"
    "\"deals\":[...],\"names\":[aliases],\"matchesPlayed\":int,"
    "\"reason\":str,\"slot\":N} at episode end, after which the player "
    "should exit 0. player->game frames: {\"type\":\"prompt\","
    "\"prompt\":str,\"scripted\":str|bool} (prompt max 4000 chars; send "
    "after connect and again after welcome; the latest frame applies to all "
    "later turns; scripted is \"haggler\", \"hardliner\", or a boolean where "
    "true means haggler). The published negotiation-player runnable reads "
    "its prompt from PLAYER_PROMPT and its baseline from PLAYER_SCRIPTED, so "
    "a new policy is `coworld upload-policy` of the same image with "
    "--secret-env PLAYER_PROMPT=\"<your strategy>\"."
)

GLOBAL_PROTOCOL = (
    "Global spectators connect a websocket to /global and receive the full "
    "snapshot as JSON after every event: {\"type\":\"state\","
    "\"game\":\"negotiation-games\",\"seats\":[{name,score,points,matches,"
    "deals,giveaway,fallbacks,role,notes} x3],\"match\":int,\"matches\":int,"
    "\"matchesPlayed\":int,\"kind\":\"bargaining\",\"itemNames\":[\"books\","
    "\"hats\",\"balls\"],\"table\":null|{\"a\":seat,\"b\":seat,"
    "\"opener\":seat,\"pool\":[3],\"values\":[[3],[3]],\"turn\":int,"
    "\"maxTurns\":int,\"actor\":seat,\"standing\":null|{\"side\":0|1,"
    "\"take\":[3],\"worth\":[2]},\"offers\":[{turn,side,take[3],worth[2],"
    "text,scripted}],\"messages\":[2],\"outcome\":\"open|deal|no_deal\","
    "\"payoff\":[2]},\"phase\":\"offer|between|done\",\"gameDone\":bool,"
    "\"reason\":str,\"policyNames\":[...],\"events\":[...],"
    "\"started\":bool,\"done\":bool,\"connected\":[bool]}. seats[].role is "
    "actor for the seat to move, waiting for its opponent and idle for the "
    "seat sitting the match out. The events array is append-only and carries "
    "the complete transcript. Event vocabulary: start (no fields); match "
    "(match, matchKind, seats[2], opener, pool[3], values[2][3], maxTurns); "
    "offer (match, turn, seat, other, take[3] = the actor's take, worth = "
    "[uActor, uOther], scripted, optional text = the public message, "
    "optional notes); accept (match, turn, seat, other, take[3] = what the "
    "accepter receives, payoff = [uA, uB] in the match's seat order, "
    "scripted, optional text, optional notes); matchEnd (match, outcome = "
    "deal|no_deal, payoff[2], turn = turns used); end (match = matches "
    "played, text = complete|deadline). The browser page at /client/global "
    "renders the stage and /client/replay plays a recorded episode, while "
    "the static wasm replay-viewer bundle renders the replays the platform "
    "hosts (index.html?replay=<url>)."
)

README = (
    "Negotiation Games is a three-seat bargaining table. Each match pairs "
    "two of the three cogs over a pool of books, hats and balls that is "
    "worth exactly 10 to each of them under private, different per-item "
    "values. They alternate offers for at most ten turns; either side may "
    "accept the offer standing against it. A deal pays each side the value "
    "TO IT of what it ended up holding, out of 10; the turn cliff pays both "
    "sides zero. Six matches per episode, so every pairing plays twice and "
    "every seat opens twice. A policy is just a prompt: field one by "
    "reusing the published negotiation-player runnable with PLAYER_PROMPT "
    "set to your strategy. With no LLM credentials (or for seats that "
    "register PLAYER_SCRIPTED=haggler|hardliner) the server plays a scripted "
    "baseline, so episodes always complete. The league ranks seats by mean "
    "episode score - the share of the pie they took - descending."
)

RULES = """# Negotiation Games rules

## The table

Three seats. An episode is `matches` one-on-one BARGAINING matches (default
6, legal 3 or 6), played one at a time so there is always exactly one table
to watch. Match `m` (0-based) is played by the pairing `P[m mod 3]` where
`P = [(0,1), (0,2), (1,2)]`. The opener - the seat that moves on turn 1 - is
the pairing's first seat when `(m div 3) mod 2 == 0`, otherwise the second.
Over six matches every seat plays exactly four matches and opens exactly two.
The third seat sits the match out: it is never queried, never sees the pool,
the values, the offers or the messages, and its tallies do not move.

## The pool and the valuations

Item types are fixed and ordered: books, hats, balls. For each match the seed
draws, in this order:

1. counts `c[i]`, each 1..4, redrawn as a whole triple until the pool holds
   5 to 7 items (bounded: after 32 misses it settles on `[3, 2, 2]`);
2. the value table `V(c)` - every `v` in `{0..10}^3` with
   `c[0]*v[0] + c[1]*v[1] + c[2]*v[2] == 10`, enumerated lexicographically;
3. seat A's values from `V`, then seat B's, redrawn at most 16 times until no
   item type is worthless to both.

So the whole pool is worth exactly 10 to each seat, the two seats generally
value different things (integrative trades exist), and no item is worthless
to both. Values are redrawn every match, so nothing learned about one
opponent transfers to the next match.

## The two actions

On its turn a seat takes exactly one of:

- **offer** - a `take` vector: how many of each item THIS seat takes. Legal
  iff `0 <= take[i] <= c[i]` for every item. The opponent gets the
  complement.
- **accept** - accept the standing offer (the offer made on the previous
  turn). Legal iff a standing offer exists, i.e. from turn 2 on. `accept` on
  turn 1 is illegal.

Both may carry an optional free-text `message` (at most 200 characters, seen
by the opponent) and optional private `notes` (at most 400 characters, fed
back verbatim on this seat's next turn, never shown to the opponent). Only
the structured take/accept is graded; the message is cheap talk and is never
enforced by the rules.

## The turn cliff

A match lasts at most `maxTurns` turns (default 10, legal even 2..12), turn
`t` taken by the opener when `t` is odd. If the last turn passes with no
accept, the match ends `no_deal` and both seats bank 0. There is no discount
for stalling: the cliff is the only pressure.

## Scoring - formula, sign, what the league ranks

For a settled match, seat `s` receives `recv[i]` of each item and banks
`u(s) = sum over i of recv[i] * v_s[i]`, an integer 0..10 (0 for a no-deal).
Over the episode:

    points[s]        = sum of u(s) over the matches s played
    matchesPlayed[s] = matches s played that reached a matchEnd
    deals[s]         = those that ended "deal"
    score[s]         = points[s] / (10 * matchesPlayed[s])   in [0, 1]
                     = 0.0 when matchesPlayed[s] == 0
    giveaway[s]      = mean over settled matches of (opponent's u - s's u)

**Higher is better.** `score` is a share of the pie: 1.0 means it took the
whole pool in every match, 0.0 means no deal in every match. The league ranks
seats by mean episode `score`, descending. `giveaway` is NOT ranked - it is
the mechanical softplay audit: a seat that systematically hands the pool to a
partner shows a large positive `giveaway` with a low `score`.

## How an episode ends

`results.reason` takes exactly two values and nothing else:

- **complete** - all scheduled matches reached a `matchEnd`.
- **deadline** - the play clock (60% of `episodeTimeoutSeconds`, or of
  `COWORLD_TIMEOUT_SECONDS` when the platform provides it) stopped play
  BETWEEN matches. Scores use the matches actually settled.

A match-level outcome - `deal` or `no_deal` - is a separate enum carried by
the `matchEnd` event. It never appears in `results.reason`.
"""

POLICY_DOC = """# Writing a policy

A policy is just a prompt. Upload the published player image with your
strategy in `PLAYER_PROMPT`:

    coworld upload-policy <image> --name my-negotiator \\
      --run /bin/negotiation-player \\
      --secret-env PLAYER_PROMPT="<your strategy>"

## What your prompt sees

Every turn the game server composes, for the acting seat only:

- its own alias and the opponent's alias, `match m of M`, `turn t of maxTurns`;
- the pool counts per item type, and ITS OWN private values per item type,
  with the reminder that the whole pool is worth 10 to it;
- the offer standing against it rendered from its own side ("they take ...,
  you get ...") with the worth to itself already computed, plus an explicit
  `ACCEPT IS LEGAL NOW: yes|no` line and the explicit per-type bounds;
- the full offer history of THIS match, both sides, each with its worth to
  this seat, and each side's messages;
- its own record so far this episode (per settled match: opponent alias,
  deal/no-deal, `u/10`);
- its own private notes, fed back verbatim;
- your prompt, under "GUIDANCE FROM YOUR OPERATOR".

It never sees the opponent's private values (or any function of them), the
opponent's notes, anything about matches it is not in, the seed, the future
schedule, or the policy name of any seat including its own.

## The reply schema

    {"action": "offer",  "take": {"books": 2, "hats": 0, "balls": 1},
     "message": "<= 200 characters", "notes": "<= 400 characters"}
    {"action": "accept", "message": "<= 200 characters", "notes": "<= 400 characters"}

Parsing is tolerant in exactly these ways: `action` is matched
case-insensitively after trimming (`accept|agree|deal` and
`offer|propose|counter` are synonyms); `action` absent with `take` present
means an offer; `take` may be the object above (missing keys are 0) or the
3-element array `[books, hats, balls]`, with JSON integers or
integer-valued strings. Anything else - a fractional count, an out-of-range
count, `accept` on turn 1, an unknown action, no JSON object in the reply -
is an invalid reply.

Both caps are measured and cut in RUNES, not bytes, with a trailing ellipsis
marking the cut.

## When a reply does not parse

An invalid or illegal reply is retried ONCE with an appended hint line. A
second failure, a transport error, a timeout, a refusal or missing
credentials falls back to the seat's scripted baseline, applied with
`scripted: true`, and increments `results.fallbacks[seat]`. A seat that
registered a prompt (or nothing) falls back to `haggler`. The scripted move
is always legal, so the turn always advances.

## The two baselines

Both are fieldable policies in their own right
(`PLAYER_SCRIPTED=haggler|hardliner`). Let `t` be the turn, `T = maxTurns`,
and `worth(x)` the bundle's value under this seat's own values.

**haggler** - a monotone conceder, and the universal fallback.

1. Reservation `R(t) = clamp(round(10 - 6 * (t - 1) / max(T - 1, 1)), 4, 10)`:
   10 on turn 1, decaying linearly to 4 on turn `T`.
2. Endgame override: on this seat's last turn of the match (`t > T - 2`),
   `R(t) = 1`.
3. If a standing offer exists and the complement is worth at least `R(t)`,
   accept.
4. Otherwise enumerate every legal `take` and choose the one with the
   SMALLEST `worth(take)` that is still at least `R(t)`; ties break by the
   fewest total items taken, then by the lexicographically smallest vector.
   (Taking the whole pool always qualifies, so the set is never empty.)
5. Never emits a message or notes; uses no RNG.

**hardliner** - identical except for the reservation: `R(t) = 8` while
`t <= T - 2`, and `R(t) = 3` on this seat's last turn. It refuses most splits
and gets its way against a conceder.
"""

ANCHOR_PROMPT = (
    "Open by taking everything and say why: name the one item you claim to "
    "need most. Concede in small steps, one item at a time, and always "
    "concede the item that is worth least to you per unit - never the item "
    "you value most. Track what your opponent keeps asking for; that is what "
    "they value, so charge them for it and take the rest. Accept when the "
    "standing offer is worth 6 or more to you, or when three or fewer turns "
    "remain and it is worth 4 or more. On the last turn available to you, "
    "accept anything worth 1 or more: a deal you dislike still beats the "
    "zero that both of you get when the turns run out."
)

RESOURCES = {
    # A 500m limit is rejected at upload (cogame-pistonball 0.1.1).
    "requests": {"cpu": "100m", "memory": "64Mi"},
    "limits": {"cpu": "1"},
}


def player(pid, name, description, env=None):
    entry = {
        "id": pid,
        "name": name,
        "type": "player",
        "description": description,
        "image": IMAGE,
        "run": ["/bin/negotiation-player"],
    }
    if env:
        entry["env"] = env
    entry["resources"] = RESOURCES
    entry["source_url"] = SOURCE
    return entry


def variant(vid, name, description, matches, max_turns, turn_delay):
    return {
        "id": vid,
        "name": name,
        "description": description,
        # No literal `tokens` in any game_config: the runner injects them and
        # a literal fails matriculation (cogame-knights-archers 0.1.0).
        "game_config": {
            "players": [{"name": f"Player{i + 1}"} for i in range(SEATS)],
            "num_agents": SEATS,
            "matches": matches,
            "maxTurns": max_turns,
            "turnDelayMs": turn_delay,
            "player_connect_timeout_seconds": 180,
        },
    }


MANIFEST = {
    "$schema": "https://raw.githubusercontent.com/Metta-AI/coworld/main/src/coworld/coworld_manifest_schema.json",
    "tags": [
        "negotiation",
        "bargaining",
        "mixed-motive",
        "hidden-information",
        "llm-driven",
        "turn-based",
        "three-player",
        "openspiel-port",
    ],
    "episode_timeout_minutes": 20,
    "game": {
        "name": "negotiation-games",
        "replay_viewer": {"bundle": "static-replay-viewer"},
        "description": DESCRIPTION,
        "owner": "daveey@gmail.com",
        "runnable": {
            "type": "game",
            "image": IMAGE,
            "run": ["/bin/negotiation"],
            "env": {
                # Without this the hosted container never sees the key and
                # every league episode silently plays scripted (hive).
                "ANTHROPIC_API_KEY_URI":
                    "secret://coworld/negotiation-games/anthropic_api_key"
            },
            "source_url": SOURCE,
        },
        "config_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "required": ["tokens", "players"],
            "properties": {
                "tokens": {
                    "description": "One connection token per player slot, indexed by slot.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "string", "minLength": 1},
                },
                "players": {
                    "description": "One player display-name object per seat, indexed by slot.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["name"],
                        "properties": {"name": {"type": "string", "minLength": 1}},
                    },
                },
                "num_agents": {
                    "description": "Seat count; injected by the commissioner. Negotiation Games is a three-player game.",
                    "type": "integer",
                    "minimum": SEATS,
                    "maximum": SEATS,
                },
                "seed": {
                    "description": "Pins the seat aliases and, per match, the pairing, the opener, the pool and both seats' private valuations. Omit for a fresh random seed per episode.",
                    "type": "integer",
                },
                "matches": {
                    "description": "One-on-one matches in the episode. A multiple of 3 so every seat plays the same number of matches.",
                    "type": "integer",
                    "minimum": 3,
                    "maximum": 6,
                    "multipleOf": 3,
                    "default": 6,
                },
                "maxTurns": {
                    "description": "Turns per match, both seats together. Even, so both seats get the same number of turns. Nobody accepting by the last turn is a no-deal worth 0 to both.",
                    "type": "integer",
                    "minimum": 2,
                    "maximum": 12,
                    "multipleOf": 2,
                    "default": 10,
                },
                "episodeTimeoutSeconds": {
                    "description": "Wall-clock the game assumes the platform allows an episode when COWORLD_TIMEOUT_SECONDS is not in its environment; play stops between matches at 60% of it so results and the replay always land.",
                    "type": "integer",
                    "minimum": 60,
                    "maximum": 6000,
                    "default": 1200,
                },
                "turnDelayMs": {
                    "description": "Spectator pacing delay between matches.",
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 10000,
                    "default": 900,
                },
                "model": {
                    "description": "Claude model that drives every prompt seat.",
                    "type": "string",
                    "default": "claude-sonnet-5",
                },
                "maxOutputTokens": {
                    "type": "integer",
                    "minimum": 64,
                    "maximum": 2000,
                    "default": 900,
                },
                "llmTimeoutSeconds": {
                    "type": "integer",
                    "minimum": 5,
                    "maximum": 300,
                    "default": 30,
                },
                "player_connect_timeout_seconds": {
                    "type": "number",
                    "minimum": 0,
                    "default": 180,
                },
            },
        },
        "results_schema": {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": False,
            "required": [
                "names",
                "scores",
                "points",
                "matches",
                "deals",
                "giveaway",
                "fallbacks",
                "matchesPlayed",
                "maxMatches",
                "reason",
            ],
            "properties": {
                "names": {
                    "description": "Policy display names, indexed by slot. Seats play under anonymous cog aliases in-game; results attribute by policy name.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "string"},
                },
                "scores": {
                    "description": "Share of the pie: points / (10 * matches played), 0..1. Higher is better; the league ranks on the mean of this.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "number", "minimum": 0, "maximum": 1},
                },
                "points": {
                    "description": "Total value banked, in this seat's own valuations, over the matches it played.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "integer", "minimum": 0},
                },
                "matches": {
                    "description": "Matches this seat played that reached a settlement.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "integer", "minimum": 0},
                },
                "deals": {
                    "description": "Of those, the ones that ended in a deal rather than the turn cliff.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "integer", "minimum": 0},
                },
                "giveaway": {
                    "description": "Mean over settled matches of (opponent's payoff - this seat's payoff). Not ranked: it is the mechanical softplay audit.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "number", "minimum": -10, "maximum": 10},
                },
                "fallbacks": {
                    "description": "Turns on which this seat's model call was skipped or gave up and the scripted baseline moved instead.",
                    "type": "array",
                    "minItems": SEATS,
                    "maxItems": SEATS,
                    "items": {"type": "integer", "minimum": 0},
                },
                "matchesPlayed": {
                    "description": "Matches the table actually settled.",
                    "type": "integer",
                    "minimum": 0,
                },
                "maxMatches": {
                    "description": "The episode's match count after budget fitting.",
                    "type": "integer",
                    "minimum": 3,
                },
                "reason": {
                    "description": "How the episode ended: complete (every scheduled match settled) or deadline (the play clock stopped play between matches; scores use the matches settled).",
                    "type": "string",
                },
            },
        },
        "protocols": {
            # Bare strings fail the platform validator, not repo CI
            # (cogame-garble v0.1.0).
            "player": {"type": "text", "value": PLAYER_PROTOCOL},
            "global": {"type": "text", "value": GLOBAL_PROTOCOL},
        },
        "docs": {
            "readme": {"type": "text", "value": README},
            "pages": [
                {
                    "id": "rules.md",
                    "title": "rules.md",
                    "content": {"type": "text", "value": RULES},
                },
                {
                    "id": "writing-a-policy.md",
                    "title": "writing-a-policy.md",
                    "content": {"type": "text", "value": POLICY_DOC},
                },
            ],
        },
    },
    "player": [
        player(
            "negotiation-player",
            "Negotiation Prompt Player",
            "The reference Negotiation Games policy: delivers its PLAYER_PROMPT "
            "(or a default bargaining strategy) to the game and spectates until "
            "the final frame. Field your own policy by uploading this same image "
            "with a different PLAYER_PROMPT.",
        ),
        player(
            "negotiation-haggler",
            "Negotiation Haggler Baseline",
            "The scripted monotone-concession baseline as a fieldable policy: it "
            "opens demanding the whole pool and concedes linearly to a floor of "
            "4/10, taking the smallest bundle that still clears its reservation, "
            "and accepts anything on its last turn rather than bank zero.",
            {"PLAYER_SCRIPTED": "haggler"},
        ),
        player(
            "negotiation-hardliner",
            "Negotiation Hardliner Baseline",
            "The scripted stubborn baseline as a fieldable policy: it holds a "
            "reservation of 8/10 all the way to its last turn, refusing most "
            "splits and getting its way against a conceder.",
            {"PLAYER_SCRIPTED": "hardliner"},
        ),
    ],
    "variants": [
        variant(
            "standard",
            "Standard game",
            "Three cogs, six matches, ten turns each: every pairing twice, every seat opening twice.",
            6,
            10,
            900,
        ),
        variant(
            "sprint",
            "Sprint",
            "Six short matches - six turns each, so a concession that comes late comes too late.",
            6,
            6,
            400,
        ),
    ],
    "certification": {
        "game_config": {
            "players": [{"name": n} for n in ("Sprocket", "Gizmo", "Ratchet")],
            "num_agents": SEATS,
            "seed": 7,
            "matches": 3,
            "maxTurns": 6,
            "turnDelayMs": 0,
            "player_connect_timeout_seconds": 180,
        },
        # Every declared player[] entry must occupy a slot or certification
        # fails players_missing (cogame-raid 0.1.3).
        "players": [
            {"player_id": "negotiation-player"},
            {"player_id": "negotiation-haggler"},
            {"player_id": "negotiation-hardliner"},
        ],
    },
}

if __name__ == "__main__":
    out = pathlib.Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
    out.write_text(json.dumps(MANIFEST, indent=2) + "\n")
    print(f"wrote {out}")
