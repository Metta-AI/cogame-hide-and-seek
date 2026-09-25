## JSONL training bridge over the game's seeded simulator and order driver.

import std/[hashes, json]
import bitworld/spriteprotocol
import sim, control, decide, directives, policy_actions

var
  game: SimServer
  engine: DecisionEngine
  previousInputs: seq[InputState]
  pendingSeats: seq[int]
  pendingPosition: int
  pendingOrders: seq[string]
  lastTurnKey: int
  lastObservedTick: int
  decisionId: int
  finished: bool

proc dispatchBridge(turn, deadlineMs: int,
                    requests: seq[ExternalRequest]) =
  discard turn
  discard deadlineMs
  discard requests

proc collectBridge(turn, deadlineMs: int,
                   requests: seq[ExternalRequest]): seq[string] =
  discard turn
  discard deadlineMs
  for request in requests: result.add(pendingOrders[request.seat])

proc currentSeat(): int = pendingSeats[pendingPosition]

proc currentView(): JsonNode =
  let seat = currentSeat()
  result = engine.seatViewJson(game, seat,
    game.gameTick() div game.config.turnTicks)
  result["your_notes"] = %engine.notes[seat]

proc currentDecision(): JsonNode =
  let view = currentView()
  %*{"kind": "decision", "game": "hide-and-seek",
    "decision_id": decisionId, "seat": currentSeat(),
    "engine_seat": currentSeat(), "turn": game.turnIndex,
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "user", "content": $view}],
    "speech_messages": [],
    "action_schema": {"type": "object", "additionalProperties": false,
      "properties": {"intent": {"type": "string"}},
      "required": ["intent"]},
    "typed_question": newJNull()}

proc driveUntilDecision() =
  while game.gameMargins.len < game.config.maxGames:
    if game.phase == Playing:
      if game.tickCount != lastObservedTick:
        engine.ctl.observeEnemies(game)
        lastObservedTick = game.tickCount
      let turn = game.gameTick() div game.config.turnTicks
      let key = game.gameIndex * 1_000_000 + turn
      if game.gameTick() mod game.config.turnTicks == 0 and
          key != lastTurnKey:
        pendingSeats.setLen(0)
        for seat in 0 ..< game.config.numAgents:
          let index = game.playerIndexForSlot(seat)
          if index >= 0 and not game.frozenSeeker(index):
            pendingSeats.add(seat)
        if pendingSeats.len > 0:
          pendingPosition = 0
          game.turnIndex = turn
          return
      var inputs = newSeq[InputState](game.players.len)
      for index in 0 ..< game.players.len:
        let seat = game.players[index].joinOrder
        let order = if engine.haveOrder[seat]: engine.orders[seat]
          else: engine.burrowFor(game, seat, turn)
        var mask = engine.ctl.compileMask(game, order, index)
        if game.frozenSeeker(index): mask = 0
        inputs[index] = decodeInputMask(mask)
      game.step(inputs, previousInputs)
      previousInputs = inputs
    else:
      let inputs = newSeq[InputState](game.players.len)
      game.step(inputs, previousInputs)
      previousInputs = inputs
  game.settleEpisode()
  finished = true

proc reset(request: JsonNode): JsonNode =
  doAssert request["players"].getInt() == 6
  var config = defaultGameConfig()
  config.update($( %*{"seed": int(hash(request["seed"].getStr()) and
    hash(high(int))), "num_agents": 6, "minPlayers": 6,
    "prepTurns": 2, "huntTurns": 3, "maxGames": 2,
    "turnSpacingMs": 0, "startWaitTicks": 0,
    "gameOverTicks": 0, "fastMode": true}))
  game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  for seat in 0 ..< config.numAgents:
    discard game.addPlayer(game.aliasForSlot(seat), seat, "", trusted = true)
  engine = initDecisionEngine(game, enableLlm = false)
  engine.externalDispatch = dispatchBridge
  engine.externalCollect = collectBridge
  for seat in 0 ..< config.numAgents:
    engine.seats[seat].isExternal = true
    game.seatPolicyKind[seat] = engine.policyKind(seat)
  game.startGame()
  previousInputs = newSeq[InputState](game.players.len)
  pendingOrders = newSeq[string](config.numAgents)
  pendingSeats = @[]
  lastTurnKey = -1
  lastObservedTick = -1
  decisionId = 0
  finished = false
  driveUntilDecision()
  currentDecision()

proc step(request: JsonNode): JsonNode =
  if request["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(request["response"].getStr())
  if action notin actionChoices(currentView()):
    return %*{"kind": "rejected",
      "reason": "action outside visible order catalog"}
  pendingOrders[currentSeat()] = $action
  inc decisionId
  if pendingPosition + 1 < pendingSeats.len:
    inc pendingPosition
    return %*{"kind": "accepted", "action": action,
      "observation": currentDecision()}
  let turn = game.gameTick() div game.config.turnTicks
  var views = newSeq[JsonNode](game.config.numAgents)
  var sources = newSeq[DirectiveSource](game.config.numAgents)
  var latencies = newSeq[int](game.config.numAgents)
  discard engine.turn(game, turn, 0, views, sources, latencies)
  lastTurnKey = game.gameIndex * 1_000_000 + turn
  for seat in pendingSeats:
    if sources[seat] == dsExternal: inc game.llmTurns[seat]
    elif sources[seat] == dsFallback: inc game.fallbackTurns[seat]
    if engine.lastResult[seat] == "unknown_object":
      inc game.ordersRejected[seat]
  driveUntilDecision()
  if finished:
    let results = parseJson(game.roomResultsJson())
    var scores = newJObject()
    var utilities = newJObject()
    for seat in 0 ..< game.config.numAgents:
      scores[$seat] = results["scores"][seat]
      utilities[$seat] = results["scores"][seat]
    return %*{"kind": "accepted", "action": action,
      "observation": {"kind": "terminal", "scores": scores,
        "utilities": utilities}}
  %*{"kind": "accepted", "action": action,
    "observation": currentDecision()}

proc teacher(): JsonNode =
  let seat = currentSeat()
  let turn = game.gameTick() div game.config.turnTicks
  let order = engine.scriptedFor(game, seat, turn, engine.seats[seat].baseline)
  let choices = actionChoices(currentView())
  var selected = choices[0]
  var best = -1_000_000
  for choice in choices:
    if choice.kind == JNull or choice["intent"].getStr() != $order.intent:
      continue
    var score = 10
    if choice.hasKey("object"):
      if choice["object"].getStr() != order.obj: continue
      score += 10
    if choice.hasKey("at"):
      if choice["at"].getStr() == order.at: score += 10
    if choice.hasKey("to") and order.hasTo:
      let at = choice["to"]
      let dx = at[0].getInt() - order.toX
      let dy = at[1].getInt() - order.toY
      score -= (dx * dx + dy * dy) div 10_000
    if score > best:
      best = score
      selected = choice
  %*{"response": $selected}

when isMainModule:
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request)
      of "encode": %*{"decision_id": decisionId,
        "values": values(currentView()),
        "actions": actionChoices(currentView())}
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
