## The reply schema: what a seat (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and how an illegal reply is REPAIRED instead of
## rejected.
##
## Forked from coworld-ctf's `src/ctf/directives.nim`. The tolerant JSON
## extraction (`extractJsonObject`), the tolerant coordinate reader
## (`readPoint`), the rune truncation and the repair-don't-reject discipline
## are the starter's, unchanged in shape. What changed is the vocabulary: a
## seat here commands ONE cog, so the reply is a flat object with an
## `intent`, an `object`, a `to`/`at`, and the three text channels.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES and every
## truncation lands on a rune boundary (`runeLen` / `runeSubStr`). Slicing a
## string by BYTE index anywhere on the path to the replay is forbidden: a
## byte-truncated multi-byte character renders fine in a browser and then
## fails a strict UTF-8 parser, which is exactly the class of bug that makes
## a replay unreadable to everything except the one viewer that happened to
## be lenient.

import
  std/[json, strutils, unicode],
  sim_types

type
  Intent* = enum
    ## What a cog is being told to do for the next turn. A closed enum: an
    ## unrecognised intent is repaired to `watch`, never dropped, because
    ## `watch` is always actuatable and needs no target.
    intMoveTo = "move_to"
    intHide = "hide"
    intWatch = "watch"
    intChase = "chase"
    intPush = "push"
    intLock = "lock"
    intUnlock = "unlock"
    intVault = "vault"

  Order* = object
    ## One seat's order for the next turn.
    slot*: int
    id*: string                ## the cog's anonymous alias, e.g. HIDER-beta.
    intent*: Intent
    obj*: string               ## <= MaxObjectIdRunes; "" = none.
    hasTo*: bool
    toX*, toY*: int            ## clamped into the board.
    at*: string                ## <= MaxAnchorIdRunes; wins over `to`.
    hasFace*: bool
    faceX*, faceY*: int
    say*: string               ## <= MaxSayRunes; becomes an in-world SHOUT.
    radio*: string             ## <= MaxRadioRunes; the TEAM channel.
    notes*: string             ## <= MaxNoteRunes; private to the seat.
    fromReply*: bool           ## a reply really carried an intent. False
                               ## means the caller repairs it from last turn's
                               ## order (else burrow's) — never from a
                               ## default.

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  Directive* = object
    slot*: int
    order*: Order
    source*: DirectiveSource
    latencyMs*: int

  DirectiveError* = object of ValueError

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## An in-world shout: capped at MaxSayRunes on a rune boundary FIRST, then
  ## run through the starter's printable-ASCII shout filter. That order means
  ## the rune cut never leaves half a codepoint for the ASCII filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    # Braces are excluded deliberately: the replay chat stream carries the
    # control records as JSON objects and tells them apart from a cog's shout
    # by a leading '{'.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeLine*(text: string, limit: int): string =
  ## A recorded free-text line. Newlines collapse to spaces so one record
  ## stays one line; the cut lands on a rune boundary.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(limit)

proc sanitizeRadio*(text: string): string =
  sanitizeLine(text, MaxRadioRunes)

proc sanitizeNote*(text: string): string =
  sanitizeLine(text, MaxNoteRunes)

proc parseIntent*(text: string): tuple[intent: Intent, known: bool] =
  ## Tolerant: case-insensitive, hyphens and spaces normalised to
  ## underscores. Anything still unknown becomes `watch`.
  let key = text.strip().truncateRunes(MaxIntentRunes)
    .toLowerAscii().replace("-", "_").replace(" ", "_")
  for intent in Intent:
    if $intent == key:
      return (intent, true)
  (intWatch, false)

proc needsObject*(intent: Intent): bool {.inline.} =
  intent in {intPush, intLock, intUnlock, intVault}

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair, which is
  ## what recovers a reply whose braces sit inside a quoted string.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readCoord(node: JsonNode): tuple[ok: bool, value: int] =
  ## One coordinate: an int, a float, or a numeric string. Anything
  ## non-finite or unparseable reports `ok = false` so the caller can apply
  ## its own default rather than inventing a position.
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt:
    (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0)
    else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else:
    (false, 0)

proc readPoint*(
  node: JsonNode, defaultX, defaultY, maxX, maxY: int
): tuple[given: bool, x, y: int] =
  ## An `[x, y]` pair (an object with x/y keys is accepted too), CLAMPED into
  ## the board. A missing or non-finite pair reports `given = false`.
  result = (false, defaultX, defaultY)
  if node.isNil or node.kind == JNull:
    return
  var
    rx = (ok: false, value: 0)
    ry = (ok: false, value: 0)
  if node.kind == JArray and node.len >= 2:
    rx = readCoord(node[0])
    ry = readCoord(node[1])
  elif node.kind == JObject:
    rx = readCoord(node{"x"})
    ry = readCoord(node{"y"})
  if not rx.ok or not ry.ok:
    return
  result = (
    true,
    clamp(rx.value, 0, max(0, maxX)),
    clamp(ry.value, 0, max(0, maxY))
  )

proc parseOrder*(
  payload: JsonNode,
  slot: int,
  alias: string,
  objectIds: seq[string],
  anchorIds: seq[string],
  rampIds: seq[string],
  maxX, maxY: int
): tuple[order: Order, rejected: bool] =
  ## Turns one parsed reply into a legal order, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * `intent`  unknown -> `watch`;
  ## * `object`  unknown, or illegal for the intent -> `rejected = true`, so
  ##             the caller drops back to the seat's PREVIOUS order and counts
  ##             it in `ordersRejected`;
  ## * `to`      missing / non-finite -> not given; otherwise clamped;
  ## * `at`      a published anchor / door / region id; it WINS over `to`;
  ## * `say`     <= MaxSayRunes then the printable-ASCII shout filter;
  ## * `radio`   <= MaxRadioRunes; `notes` <= MaxNoteRunes.
  ##
  ## A reply with a valid `say`/`radio` but NO intent is USABLE: the cog keeps
  ## its standing order and the line is delivered.
  var order = Order(slot: slot, id: alias, intent: intWatch)
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  order.say = sanitizeSay(payload{"say"}.getStr())
  order.radio = sanitizeRadio(payload{"radio"}.getStr())
  order.notes = sanitizeNote(payload{"notes"}.getStr())
  let hasIntent = payload.hasKey("intent") and
    payload["intent"].kind == JString and
    payload["intent"].getStr().strip().len > 0
  if not hasIntent:
    return (order, false)
  let parsed = parseIntent(payload["intent"].getStr())
  order.intent = parsed.intent
  order.fromReply = true
  let target = readPoint(payload{"to"}, 0, 0, maxX, maxY)
  order.hasTo = target.given
  order.toX = target.x
  order.toY = target.y
  let face = readPoint(payload{"face"}, 0, 0, maxX, maxY)
  order.hasFace = face.given
  order.faceX = face.x
  order.faceY = face.y
  let atRaw = payload{"at"}.getStr().strip().truncateRunes(MaxAnchorIdRunes)
  if atRaw.len > 0:
    for id in anchorIds:
      if id == atRaw:
        order.at = atRaw
        break
  let objRaw = payload{"object"}.getStr().strip()
    .truncateRunes(MaxObjectIdRunes)
  if objRaw.len > 0:
    for id in objectIds:
      if id == objRaw:
        order.obj = objRaw
        break
  if order.intent.needsObject():
    if order.obj.len == 0:
      return (order, true)
    if order.intent == intVault:
      var isRamp = false
      for id in rampIds:
        if id == order.obj:
          isRamp = true
      if not isRamp:
        return (order, true)
  (order, false)

proc orderRecord*(
  directive: Directive,
  game, turn: int,
  alias, outcome: string,
  view: JsonNode
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## `tools/replay_summary.py` and can never affect the simulation.
  ## `view` is the observation MINUS `your_notes`, so the replay explains
  ## every decision without leaking a seat's private channel.
  let order = directive.order
  var node = %*{
    "k": "directive",
    "game": game,
    "turn": turn,
    "slot": directive.slot,
    "alias": alias,
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "intent": $order.intent,
    "object": order.obj,
    "at": order.at,
    "say": order.say,
    "radio": order.radio,
    "result": outcome
  }
  if order.hasTo:
    node["to"] = %[order.toX, order.toY]
  else:
    node["to"] = newJNull()
  if view != nil:
    node["view"] = view
  node

proc boundedOrderRecord*(
  directive: Directive,
  game, turn: int,
  alias, outcome: string,
  view: JsonNode
): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes. The
  ## observation and the radio line are what shrink; the cut still lands on a
  ## rune boundary. NEVER cut the SERIALIZED string — that would emit broken
  ## JSON, which is the exact failure the rune rule exists to prevent.
  result = $directive.orderRecord(game, turn, alias, outcome, view)
  if result.runeLen <= MaxDirectiveRunes:
    return
  var trimmed = directive
  result = $trimmed.orderRecord(game, turn, alias, outcome, nil)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    trimmed.order.radio = trimmed.order.radio.truncateRunes(
      max(0, trimmed.order.radio.runeLen - max(8,
        trimmed.order.radio.runeLen div 2)))
    trimmed.order.say = trimmed.order.say.truncateRunes(
      max(0, trimmed.order.say.runeLen - 2))
    result = $trimmed.orderRecord(game, turn, alias, outcome, nil)

proc fallbackRecord*(
  game, turn, slot, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "game": game,
    "turn": turn,
    "slot": slot,
    "attempt": attempt,
    "cause": cause,
    "detail": sanitizeLine(detail, MaxFallbackDetailRunes)
  })

proc registerRecord*(
  slot: int, alias, policy, kind, baseline: string
): string =
  ## The REDACTED registration record: the policy label and kind, never the
  ## prompt.
  $(%*{
    "k": "register",
    "slot": slot,
    "alias": alias,
    "policy": sanitizeLine(policy, MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

proc stopRecord*(tick: int, endRule: string): string =
  ## THE LOAD-BEARING STOP. A wall-clock fact cannot be re-derived from sim
  ## state, so it is written as one record and applied by the SAME proc on
  ## record and on playback.
  $(%*{"k": "stop", "tick": tick, "endRule": endRule})
