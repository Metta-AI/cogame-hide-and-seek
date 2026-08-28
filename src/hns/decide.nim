## The decision layer: the per-turn loop that asks every LIVE seat what its
## cog does next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (90 ticks = 3.75 s of sim time), 12
## turns per game, 24 per episode. At each turn the server builds every live
## seat's request body and issues them as ONE PARALLEL BATCH — hide and seek
## is a simultaneous-decision game, so querying seats one after another would
## multiply the wall clock by six for nothing. During PREP only the three
## hiders are live: a frozen, unobserving seeker has nothing to decide and its
## call would be a wasted request against the rate cap.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, the whole turn is wrapped in
## a monotonic `turnBudgetMs` deadline, and a rolling 60 s request counter
## keeps the episode under the sidecar's per-episode cap. A provider throttle
## with no other candidate model skips the retry outright (it cannot land) and
## fails fast to the scripted layer for that turn. On a second failure the
## seat plays the `burrow` scripted order for that turn and a `fallback`
## record names the cause. No failure mode leaves a cog unactuated: the
## control layer always has an order — this turn's, else last turn's, else
## `burrow`'s.

import
  std/[json, monotimes, os, strutils, times],
  curly,
  sim, control, directives, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## — or never registers at all — is `burrow`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    orders*: seq[Order]
    haveOrder*: seq[bool]
    lastResult*: seq[string]   ## the driver's honest report, per seat.
    radio*: seq[string]        ## the last radio line each seat sent.
    notes*: seq[string]        ## each seat's private note, echoed back.
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here.
    requestStamps*: seq[MonoTime]  ## the rolling 60 s request counter.
    records*: seq[string]      ## chat records queued for the replay writer.

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.ctl = initControlState(sim)
  let seats = sim.seatCount()
  result.seats = newSeq[SeatPolicy](seats)
  result.orders = newSeq[Order](seats)
  result.haveOrder = newSeq[bool](seats)
  result.lastResult = newSeq[string](seats)
  result.radio = newSeq[string](seats)
  result.notes = newSeq[string](seats)
  for i in 0 ..< seats:
    result.seats[i].baseline = blBurrow
    result.seats[i].label = "burrow"
    result.orders[i] = Order(slot: i, intent: intWatch)

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  The per-seat observation
# ---------------------------------------------------------------------------

proc roomBlock(sim: SimServer, seeker: bool, myPad: RoomAnchor): JsonNode =
  ## The room, once, at a seat's first turn: static wall rectangles, doors,
  ## named regions, pocket anchors, and the seeker pads with their keep-clear
  ## radius. A SEEKER is told only `your_pad`.
  var walls = newJArray()
  for wall in sim.gameMap.walls:
    walls.add(%*[wall.x, wall.y, wall.w, wall.h])
  var doors = newJArray()
  for door in sim.gameMap.doors:
    doors.add(%*{
      "id": door.id, "at": [door.x, door.y], "w": door.w,
      "axis": (if door.vertical: "v" else: "h")
    })
  var regions = newJArray()
  for region in sim.gameMap.regions:
    var ids = newJArray()
    for id in region.doors:
      ids.add(%id)
    regions.add(%*{
      "id": region.id, "name": region.name,
      "box": [region.box.x, region.box.y, region.box.w, region.box.h],
      "doors": ids
    })
  var pockets = newJArray()
  for anchor in sim.gameMap.anchorsOf(anchorPocket):
    pockets.add(%*{"id": anchor.id, "at": [anchor.x, anchor.y]})
  result = %*{
    "name": sim.gameMap.name,
    "w": sim.gameMap.width,
    "h": sim.gameMap.height,
    "walls": walls,
    "doors": doors,
    "regions": regions,
    "pockets": pockets,
    "keep_clear_px": sim.config.keepClearPx
  }
  if seeker:
    result["your_pad"] = %[myPad.x, myPad.y]
  else:
    var pads = newJArray()
    for anchor in sim.gameMap.anchorsOf(anchorPad, anchorSeekers):
      pads.add(%*[anchor.x, anchor.y])
    result["seeker_pads"] = pads

proc regionIdAt(sim: SimServer, x, y: int): string =
  let index = sim.gameMap.regionAt(x, y)
  if index >= 0: sim.gameMap.regions[index].id else: ""

proc seatViewJson*(
  engine: DecisionEngine,
  sim: SimServer,
  seat, turnIndex: int
): JsonNode =
  ## Everything this seat may legitimately know (§Per-seat observation). The
  ## guiding line: THE ROOM AND ITS FURNITURE ARE PUBLIC; BODIES AND
  ## INTENTIONS ARE NOT. The other trio's orders, notes, radio and prompt are
  ## never in here, and no real policy name ever is — cogs are HIDER-alpha…
  ## and SEEKER-alpha… and nothing else.
  let
    index = sim.playerIndexForSlot(seat)
  if index < 0:
    return newJObject()
  let
    player = sim.players[index]
    hiding = player.team == Red
    myPads = sim.gameMap.padsFor(
      if hiding: anchorHiders else: anchorSeekers)
    myPad =
      if myPads.len == 0: RoomAnchor()
      else: myPads[(seat div 2) mod myPads.len]

  var objects = newJArray()
  for obj in sim.objects:
    var holder = newJNull()
    if obj.heldBy >= 0 and obj.heldBy < sim.players.len:
      holder = %sim.cogAlias(obj.heldBy)
    objects.add(%*{
      "id": obj.id,
      "kind": objectKindText(obj.kind),
      "box": [obj.x, obj.y, obj.w, obj.h],
      "locked": lockText(obj.lockedBy),
      "held_by": holder
    })

  var teammates = newJArray()
  for other in 0 ..< sim.players.len:
    if other == index or sim.players[other].team != player.team:
      continue
    var holding = newJNull()
    if sim.players[other].holding >= 0:
      holding = %sim.objects[sim.players[other].holding].id
    let otherSlot = sim.players[other].joinOrder
    teammates.add(%*{
      "id": sim.cogAlias(other),
      "pos": [sim.players[other].x, sim.players[other].y],
      "holding": holding,
      "last_radio":
        (if otherSlot < engine.radio.len: engine.radio[otherSlot] else: "")
    })

  var seen = newJArray()
  let enemy = engine.ctl.knownEnemy(sim, index)
  if enemy.known and enemy.index >= 0 and enemy.index < sim.players.len:
    seen.add(%*{
      "id": sim.cogAlias(enemy.index),
      "pos": [enemy.x, enemy.y],
      "ticks_ago": enemy.ticksAgo
    })

  var heard = newJArray()
  for shout in sim.recentShouts:
    if not sim.shoutAudibleTo(index, shout):
      continue
    # The JITTERED position (§Per-seat observation): a heard shout gives the
    # neighbourhood, never the shouter's exact pixel.
    let at = shoutHeardAt(shout)
    heard.add(%*{
      "team": roleText(shout.team),
      "text": shout.text,
      "at": [at.x, at.y],
      "ticks_ago": sim.tickCount - shout.tick
    })

  var holdingId = newJNull()
  if player.holding >= 0:
    holdingId = %sim.objects[player.holding].id

  # `margin` is from the HIDING trio's view, so it is NEGATED for a seeker:
  # "higher is better for me" always holds.
  let
    rawMargin = sim.currentMargin()
    margin = if hiding: rawMargin else: -rawMargin
    huntLeft = max(0, sim.config.huntTicks -
      max(0, sim.gameTick() - sim.config.prepTicks))

  var fort = %*{
    "locked_by_us": sim.lockedCount(lockOwnerFor(player.team)),
    "locked_by_them": sim.lockedCount(
      lockOwnerFor(if player.team == Red: Blue else: Red))
  }
  if hiding:
    var sealedList = newJArray()
    for other in 0 ..< sim.players.len:
      if sim.players[other].team == Red and sim.players[other].sealed:
        sealedList.add(%sim.cogAlias(other))
    fort["sealed"] = sealedList
  else:
    # A seeker may NOT be told where the fort is — only how many are in it.
    fort["sealed_count"] = %sim.sealedCount()

  var lastOrder = newJNull()
  if seat < engine.haveOrder.len and engine.haveOrder[seat]:
    let previous = engine.orders[seat]
    var node = %*{
      "intent": $previous.intent,
      "object": previous.obj,
      "result":
        (if seat < engine.lastResult.len: engine.lastResult[seat] else: "")
    }
    if previous.hasTo:
      node["to"] = %[previous.toX, previous.toY]
    lastOrder = node

  result = %*{
    "you": sim.cogAlias(index),
    "role": (if hiding: "hider" else: "seeker"),
    "game": sim.gameIndex + 1,
    "of": sim.config.maxGames,
    "phase": phaseText(sim.matchPhase),
    "turn": turnIndex,
    "turns": sim.config.turnsPerGame,
    "clock": {
      "phase": phaseText(sim.matchPhase),
      "phase_left_s": sim.phaseTicksLeft() div TargetFps,
      "hunt_len_s": sim.config.huntTicks div TargetFps
    },
    "room": roomBlock(sim, not hiding, myPad),
    "you_at": {
      "pos": [player.x, player.y],
      "aim": player.aimBrads,
      "region": sim.regionIdAt(player.x, player.y),
      "holding": holdingId,
      "airborne": player.airborne
    },
    "objects": objects,
    "teammates": teammates,
    "seen_enemies": seen,
    "heard": heard,
    "exposure": {
      "team_seen_ticks": sim.seenTicks,
      "team_hidden_ticks": sim.hiddenTicks,
      "margin": margin.float / 1000.0,
      "you_seen_ticks": player.seatSeenTicks,
      "seen_now": sim.exposedNow,
      "hunt_ticks_left": huntLeft
    },
    "fort": fort,
    "your_last_order": lastOrder
  }

proc viewForRecord*(view: JsonNode): JsonNode =
  ## The observation as the replay records it: everything MINUS
  ## `your_notes`, so the replay explains every decision without publishing a
  ## seat's private channel.
  if view.isNil or view.kind != JObject:
    return newJObject()
  result = copy(view)
  if result.hasKey("your_notes"):
    result.delete("your_notes")

proc viewForPrompt(engine: DecisionEngine, view: JsonNode,
                   seat: int): string =
  var node = copy(view)
  node["your_notes"] =
    %(if seat < engine.notes.len: engine.notes[seat] else: "")
  $node

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc scriptedFor*(
  engine: DecisionEngine, sim: SimServer, seat, turnIndex: int,
  kind: Baseline
): Order =
  let index = sim.playerIndexForSlot(seat)
  if index < 0:
    return Order(slot: seat, intent: intWatch, fromReply: true)
  baselineOrder(kind, sim, engine.ctl, index, sim.cogAlias(index), turnIndex)

proc burrowFor*(
  engine: DecisionEngine, sim: SimServer, seat, turnIndex: int
): Order =
  ## The published `burrow` order — the SAME proc the baseline uses, so the
  ## fallback and the baseline cannot drift.
  let index = sim.playerIndexForSlot(seat)
  if index < 0:
    return Order(slot: seat, intent: intWatch, fromReply: true)
  fallbackOrder(sim, engine.ctl, index, sim.cogAlias(index), turnIndex)

proc rateGuardBlocks(engine: var DecisionEngine, count: int): bool =
  ## The rolling 60 s request counter. `turnSpacingMs` pins the steady state
  ## at 27.7 req/min, but a turn in which every seat retries issues twelve
  ## requests; if issuing the next batch would push the trailing-60 s count
  ## above the cap, the seats that would exceed it skip the call and take the
  ## `burrow` order with cause `rate_guard`. Bounded, logged, NEVER a sleep on
  ## the episode's critical path.
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in engine.requestStamps:
    if (now - stamp).inMilliseconds.int < RateGuardWindowMs:
      kept.add(stamp)
  engine.requestStamps = kept
  engine.requestStamps.len + count > RateGuardMaxRequests

proc noteRequests(engine: var DecisionEngine, count: int) =
  let now = getMonoTime()
  for _ in 0 ..< count:
    engine.requestStamps.add(now)

proc installOrder(engine: var DecisionEngine, seat: int, order: Order) =
  ## The standing order for this seat, and the two lines that outlive the turn
  ## (`radio` is what teammates read next turn; `notes` is the seat's own
  ## private channel). The DIRECTIVE's source and latency are the caller's:
  ## they ride `sources[]`/`latencies[]` into the record, and this proc used to
  ## take and `discard` them, which read as if it recorded them.
  engine.orders[seat] = order
  engine.haveOrder[seat] = true
  if order.radio.len > 0:
    engine.radio[seat] = order.radio
  if order.notes.len > 0:
    engine.notes[seat] = order.notes

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex: int,
  elapsedSeconds: int,
  views: var seq[JsonNode],
  sources: var seq[DirectiveSource],
  latencies: var seq[int]
): seq[string] =
  ## Runs ONE decision turn and installs each live seat's order. Returns the
  ## replay chat records this turn produced. NEVER RAISES: every failure path
  ## ends in a legal order.
  let
    game = sim.gameIndex + 1
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a 429 on turn k says nothing about turn k+1.
  engine.client.throttled = false
  if views.len != engine.seats.len:
    views = newSeq[JsonNode](engine.seats.len)
    sources = newSeq[DirectiveSource](engine.seats.len)
    latencies = newSeq[int](engine.seats.len)

  # --- budget guard: settle EARLY rather than overrun ----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "hide-and-seek: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats are LIVE, and which of those need a call? ---------------
  var
    live: seq[int]
    open: seq[int]
  for seat in 0 ..< engine.seats.len:
    let index = sim.playerIndexForSlot(seat)
    if index < 0 or sim.frozenSeeker(index):
      continue
    live.add(seat)
  for seat in live:
    let index = sim.playerIndexForSlot(seat)
    views[seat] = engine.seatViewJson(sim, seat, turnIndex)
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a FALLBACK, not a
      # scripted policy: recording it is what makes the two countable.
      engine.installOrder(seat, engine.burrowFor(sim, seat, turnIndex))
      sources[seat] = dsFallback
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(game, turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing burrow"))
      echo "hide-and-seek llm: seat ", seat,
        " falling back to burrow (", cause, ") on turn ", turnIndex
    else:
      engine.installOrder(seat,
        engine.scriptedFor(sim, seat, turnIndex, engine.seats[seat].baseline))
      sources[seat] = dsScripted

  # --- the rate floor ------------------------------------------------------
  # Hold the START of consecutive batches `turnSpacingMs` apart, which pins
  # six seats at 27.7 req/min under the sidecar's 30/min per-episode cap. The
  # cert fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- the rolling rate guard ----------------------------------------------
  if open.len > 0 and engine.rateGuardBlocks(open.len):
    for seat in open:
      engine.installOrder(seat, engine.burrowFor(sim, seat, turnIndex))
      sources[seat] = dsFallback
      result.add(fallbackRecord(game, turnIndex, seat, 1, "rate_guard",
        "the trailing 60 s request count would exceed the provider cap"))
    echo "hide-and-seek llm: rate guard held ", open.len,
      " seat(s) at turn ", turnIndex
    open = @[]

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          game, turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = engine.viewForPrompt(views[seat], seat)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    engine.noteRequests(open.len)
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS — which is why every shipped
    # deadline is a whole number of seconds (7000 -> 7 s, 3000 -> 3 s, worst
    # case 10 s inside the 16 s turnBudgetMs cap).
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        var text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        if text.len > MaxReplyBytes:
          text = text[0 ..< MaxReplyBytes]
        let index = sim.playerIndexForSlot(seat)
        var objectIds: seq[string]
        var rampIds: seq[string]
        for obj in sim.objects:
          objectIds.add(obj.id)
          if obj.kind == okRamp:
            rampIds.add(obj.id)
        var anchorIds: seq[string]
        for anchor in sim.gameMap.anchors:
          anchorIds.add(anchor.id)
        for door in sim.gameMap.doors:
          anchorIds.add(door.id)
        for region in sim.gameMap.regions:
          anchorIds.add(region.id)
        let parsed = parseOrder(
          extractJsonObject(text), seat, sim.cogAlias(index),
          objectIds, anchorIds, rampIds, MapWidth - 1, MapHeight - 1)
        var order = parsed.order
        if parsed.rejected or not order.fromReply:
          # REPAIR, never drop: an unresolvable object drops back to the
          # seat's PREVIOUS order (else burrow's) and counts in
          # `ordersRejected`.
          let keepText = order.say
          let keepRadio = order.radio
          let keepNotes = order.notes
          order =
            if engine.haveOrder[seat]: engine.orders[seat]
            else: engine.burrowFor(sim, seat, turnIndex)
          order.say = keepText
          order.radio = keepRadio
          order.notes = keepNotes
          if parsed.rejected:
            engine.lastResult[seat] = "unknown_object"
        engine.installOrder(seat, order)
        sources[seat] = dsLlm
        latencies[seat] = latency
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "throttled"
        result.add(fallbackRecord(
          game, turnIndex, seat, attempt + 1, cause, error.msg))
        echo "hide-and-seek llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way.
      echo "hide-and-seek llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays burrow for this turn ----------------------
  for seat in open:
    engine.installOrder(seat, engine.burrowFor(sim, seat, turnIndex))
    sources[seat] = dsFallback
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(game, turnIndex, seat, 2, cause,
      "seat fell back to the burrow order"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "hide-and-seek llm: seat ", seat, " falling back to burrow (",
      cause, ") on turn ", turnIndex

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end. It is what
  ## makes the replay SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI. The document is already valid JSON, so it is embedded
  ## verbatim rather than re-parsed: nothing on the path to the artifact
  ## writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.roomResultsJson() & "}"
