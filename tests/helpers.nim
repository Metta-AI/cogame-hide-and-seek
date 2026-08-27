## Shared test scaffolding: build a real six-seat sim, drive it with the real
## control layer, and assert on the real numbers. No mocks — every test below
## plays the game.

import
  std/[json, strutils],
  bitworld/spriteprotocol,
  hns/[sim, control, directives, baselines, decide]

export sim, control, directives, baselines, decide, spriteprotocol, json

template check*(cond: bool, message: string) =
  if not cond:
    raise newException(AssertionDefect,
      instantiationInfo().filename & ":" & $instantiationInfo().line &
      ": " & message)

proc testConfigJson*(extra: JsonNode = nil): string =
  var node = %*{
    "seed": 42,
    "roomPool": "warren",
    "num_agents": 6,
    "minPlayers": 6,
    "prepTurns": 2,
    "huntTurns": 3,
    "maxGames": 2,
    "turnSpacingMs": 0,
    "startWaitTicks": 0,
    "gameOverTicks": 0,
    "fastMode": true,
    "players": [{"name": "Cog1"}, {"name": "Cog2"}, {"name": "Cog3"},
                {"name": "Cog4"}, {"name": "Cog5"}, {"name": "Cog6"}],
    "slots": [{"team": "red"}, {"team": "blue"}, {"team": "red"},
              {"team": "blue"}, {"team": "red"}, {"team": "blue"}]
  }
  if extra != nil:
    for key, value in extra:
      node[key] = value
  $node

proc newTestSim*(extra: JsonNode = nil): SimServer =
  var config = defaultGameConfig()
  config.update(testConfigJson(extra))
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false

proc seatAll*(game: var SimServer) =
  for slot in 0 ..< game.config.numAgents:
    let name =
      if slot < game.config.slots.len and game.config.slots[slot].name.len > 0:
        game.config.slots[slot].name
      else:
        "cog" & $slot
    discard game.addPlayer(name, slot, "", trusted = true)

type Harness* = object
  game*: SimServer
  ctl*: ControlState
  orders*: seq[Order]
  prev*: seq[InputState]
  kinds*: seq[Baseline]

proc newHarness*(extra: JsonNode = nil,
                 kinds: seq[Baseline] = @[],
                 startImmediately = true): Harness =
  result.game = newTestSim(extra)
  result.game.seatAll()
  result.ctl = initControlState(result.game)
  result.orders = newSeq[Order](result.game.players.len)
  result.prev = newSeq[InputState](result.game.players.len)
  result.kinds = newSeq[Baseline](result.game.players.len)
  for i in 0 ..< result.kinds.len:
    result.kinds[i] =
      if i < kinds.len: kinds[i]
      elif i mod 2 == 0: blBurrow
      else: blScatter
    result.orders[i] = Order(slot: i, intent: intWatch)
  if startImmediately:
    result.game.startGame()

proc stepOnce*(h: var Harness) =
  ## One tick, exactly as the server drives it: observe, re-order on a turn
  ## boundary, compile a mask per cog, step.
  if h.game.phase == Playing:
    h.ctl.observeEnemies(h.game)
    let turnIndex = h.game.gameTick() div h.game.config.turnTicks
    if h.game.gameTick() mod h.game.config.turnTicks == 0:
      for cog in 0 ..< h.game.players.len:
        h.orders[cog] = baselineOrder(
          h.kinds[cog], h.game, h.ctl, cog, h.game.cogAlias(cog), turnIndex)
  var inputs = newSeq[InputState](h.game.players.len)
  if h.game.phase == Playing:
    for cog in 0 ..< h.game.players.len:
      var mask = h.ctl.compileMask(h.game, h.orders[cog], cog)
      if h.game.frozenSeeker(cog):
        mask = 0
      inputs[cog] = decodeInputMask(mask)
  h.game.step(inputs, h.prev)
  h.prev = inputs

proc runEpisode*(h: var Harness, tickCap = 6000) =
  var ticks = 0
  while h.game.gameMargins.len < h.game.config.maxGames and ticks < tickCap:
    h.stepOnce()
    inc ticks
  h.game.settleEpisode()

proc readFileText*(path: string): string =
  ## Tests run from the repo ROOT (assets resolve via `data/`).
  readFile(path)

proc countOccurrences*(haystack, needle: string): int =
  var index = 0
  while true:
    let hit = haystack.find(needle, index)
    if hit < 0:
      break
    inc result
    index = hit + 1
