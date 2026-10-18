## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "negotiation-games-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, alias, opponent: string): string =
  result = case selection.selectedVariant
    of pvCanonical: "You are <ALIAS>, a cog at a three-seat negotiation table. Right now you are bargaining\none-on-one with <OPPONENT>."
    of pvPlain: "At this three-seat negotiation table, you play the cog <ALIAS>.\nYour current one-on-one bargaining partner is <OPPONENT>."
    of pvNumbered: "1. This negotiation table has three seats.\n2. You are the cog <ALIAS>.\n3. You are currently bargaining one-on-one with <OPPONENT>."
    of pvQuestions: "How many seats are at this negotiation table? Three.\nWho are you? The cog <ALIAS>. Who is your current one-on-one bargaining partner? <OPPONENT>."
    of pvReordered: "Your current one-on-one bargaining partner is <OPPONENT>.\nYou are <ALIAS>, a cog at a negotiation table with three seats."
    of pvHeldoutBriefing: "Negotiation briefing: three seats share this table. You are the cog <ALIAS>,\ncurrently bargaining one-on-one with <OPPONENT>."
    of pvHeldoutReference: "Table: three-seat negotiation. Your cog: <ALIAS>.\nCurrent bargaining format: one-on-one. Current opponent: <OPPONENT>."
    of pvMixed: raise newException(Defect, "unresolved mixed wording")
  result = result.replace("<ALIAS>", alias).replace("<OPPONENT>", opponent)
