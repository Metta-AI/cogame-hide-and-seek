## GameConfig lifecycle: defaults, JSON readers, validation, `update`, and
## the config echo (`configJson`). Forked from coworld-ctf's
## `src/ctf/sim_config.nim`, with every weapon / paint / perk / mapgen knob
## deleted and the object, clock and vision knobs of this game in their
## place.
##
## The resolved room document is pinned into the echo as `mapSpec`, exactly
## as the starter pins a generated map, so a replay carries the exact
## geometry and playback never reads `data/rooms/` at all.

import
  std/[json, strutils],
  jsony,
  sim_types, room

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    motionScale: MotionScale,
    accel: Accel,
    frictionNum: FrictionNum,
    frictionDen: FrictionDen,
    maxSpeed: MaxSpeed,
    stopThreshold: StopThreshold,
    playerBouncePct: PlayerBouncePct,
    seed: 0xA6019,
    speed: 1,
    aimTurnRate: AimTurnRate,
    sightRange: SightRange,
    visionConeDeg: VisionConeDeg,
    visionBubble: VisionBubble,
    carrySpeedPct: CarrySpeedPct,
    grabReach: GrabReach,
    lockReach: LockReach,
    vaultSpanPx: VaultSpanPx,
    vaultTicks: VaultTicks,
    keepClearPx: KeepClearPx,
    crates: 4,
    panels: 2,
    ramps: 2,
    roomPool: "all",
    turnTicks: DefaultTurnTicks,
    prepTurns: DefaultPrepTurns,
    huntTurns: DefaultHuntTurns,
    maxGames: DefaultMaxGames,
    minPlayers: MinPlayers,
    numAgents: 6,
    startWaitTicks: StartWaitTicks,
    lobbyJoinTimeoutTicks: DefaultLobbyJoinTimeoutTicks,
    gameOverTicks: GameOverTicks,
    showPlayerLabels: false,
    fastMode: true,
    closedRoster: false,
    slots: @[],
    mapSpec: "",
    turnBudgetMs: DefaultTurnBudgetMs,
    attempt1Ms: DefaultAttempt1Ms,
    retryMs: DefaultRetryMs,
    turnSpacingMs: DefaultTurnSpacingMs,
    wallClockBudgetSeconds: DefaultWallClockBudgetSeconds,
    model: "",
    maxOutputTokens: DefaultMaxOutputTokens
  )

proc prepTicks*(config: GameConfig): int {.inline.} =
  config.prepTurns * config.turnTicks

proc huntTicks*(config: GameConfig): int {.inline.} =
  config.huntTurns * config.turnTicks

proc maxTicks*(config: GameConfig): int {.inline.} =
  ## DERIVED, never a config field, so the phase clock and the tick cap can
  ## never disagree (§Packaging).
  (config.prepTurns + config.huntTurns) * config.turnTicks

proc turnsPerGame*(config: GameConfig): int {.inline.} =
  config.prepTurns + config.huntTurns

proc readConfigInt(node: JsonNode, name: string, value: var int) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JInt:
    raise newException(HnsError,
      "Config field " & name & " must be an integer.")
  value = item.getInt()

proc readConfigBool(node: JsonNode, name: string, value: var bool) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JBool:
    raise newException(HnsError,
      "Config field " & name & " must be a boolean.")
  value = item.getBool()

proc readConfigString(node: JsonNode, name: string, value: var string) =
  if not node.hasKey(name):
    return
  let item = node[name]
  if item.kind != JString:
    raise newException(HnsError,
      "Config field " & name & " must be a string.")
  value = item.getStr()

proc readSlotTeam(text: string, slotIndex: int): Team =
  case text.strip().toLowerAscii()
  of "red", "hiders", "hider":
    Red
  of "blue", "seekers", "seeker":
    Blue
  else:
    raise newException(HnsError,
      "Config field slots[" & $slotIndex & "].team must be red or blue.")

proc playerColorText*(color: uint8): string =
  for i in 0 ..< PlayerColors.len:
    if PlayerColors[i] == color:
      return PlayerColorNames[i]
  "unknown"

proc readSlotColor(text: string, slotIndex: int): uint8 =
  let name = text.strip().toLowerAscii().replace("_", "").replace("-", "")
    .replace(" ", "")
  for i, candidate in PlayerColorNames:
    if candidate == name:
      return PlayerColors[i]
  raise newException(HnsError,
    "Config field slots[" & $slotIndex & "].color is unknown.")

proc readConfigSlots(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  if not node.hasKey("slots"):
    return
  let items = node["slots"]
  if items.kind != JArray:
    raise newException(HnsError, "Config field slots must be an array.")
  slots.setLen(0)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(HnsError,
        "Config field slots[" & $i & "] must be an object.")
    if item.hasKey("name"):
      raise newException(HnsError,
        "Config field slots[" & $i & "].name is not supported; use players[" &
          $i & "].name instead.")
    var slot: PlayerSlotConfig
    item.readConfigString("token", slot.token)
    if item.hasKey("team"):
      let team = item["team"]
      if team.kind != JString:
        raise newException(HnsError,
          "Config field slots[" & $i & "].team must be a string.")
      slot.team = readSlotTeam(team.getStr(), i)
      slot.hasTeam = true
    if item.hasKey("color"):
      let color = item["color"]
      if color.kind != JString:
        raise newException(HnsError,
          "Config field slots[" & $i & "].color must be a string.")
      slot.color = readSlotColor(color.getStr(), i)
      slot.hasColor = true
    slots.add(slot)

proc readConfigPlayers(node: JsonNode, slots: var seq[PlayerSlotConfig]) =
  if node.hasKey("player_names"):
    raise newException(HnsError,
      "Config field player_names is not supported; use players[].name.")
  if not node.hasKey("players"):
    return
  let items = node["players"]
  if items.kind != JArray:
    raise newException(HnsError, "Config field players must be an array.")
  if items.len > MaxPlayers:
    raise newException(HnsError,
      "Config field players cannot have more than " & $MaxPlayers & " entries.")
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JObject:
      raise newException(HnsError,
        "Config field players[" & $i & "] must be an object.")
    if not item.hasKey("name"):
      raise newException(HnsError,
        "Config field players[" & $i & "].name is required.")
    let nameNode = item["name"]
    if nameNode.kind != JString:
      raise newException(HnsError,
        "Config field players[" & $i & "].name must be a string.")
    let name = nameNode.getStr()
    if name.len == 0:
      raise newException(HnsError,
        "Config field players[" & $i & "].name must not be empty.")
    slots[i].name = name

proc defaultSlotName(slotIndex: int): string =
  "Cog" & $(slotIndex + 1)

proc readConfigTokens(
  node: JsonNode,
  slots: var seq[PlayerSlotConfig],
  closedRoster: bool
) =
  ## `tokens` is RUNNER-INJECTED: it never appears in a shipped game_config,
  ## but config_schema keeps requiring it because the runner supplies it.
  if not node.hasKey("tokens"):
    return
  let items = node["tokens"]
  if items.kind != JArray:
    raise newException(HnsError, "Config field tokens must be an array.")
  if items.len > MaxPlayers:
    raise newException(HnsError,
      "Config field tokens cannot have more than " & $MaxPlayers & " entries.")
  if slots.len < items.len:
    slots.setLen(items.len)
  for i, item in items.elems:
    if item.kind != JString:
      raise newException(HnsError,
        "Config field tokens[" & $i & "] must be a string.")
    let token = item.getStr()
    if slots[i].token.len > 0 and slots[i].token != token:
      raise newException(HnsError,
        "Config field tokens[" & $i & "] conflicts with slots[" & $i &
          "].token.")
    slots[i].token = token
    if closedRoster and slots[i].name.len == 0:
      slots[i].name = defaultSlotName(i)

proc validate*(config: GameConfig) =
  template require(cond: bool, message: string) =
    if not cond:
      raise newException(HnsError, message)
  require(config.motionScale > 0, "motionScale must be positive.")
  require(config.maxSpeed > 0, "maxSpeed must be positive.")
  require(config.turnTicks > 0, "turnTicks must be positive.")
  require(config.prepTurns >= 0, "prepTurns must not be negative.")
  require(config.huntTurns > 0, "huntTurns must be positive.")
  require(config.maxGames >= 1, "maxGames must be at least 1.")
  require(config.numAgents == 6,
    "num_agents must be exactly 6: this game seats three hiders and three " &
    "seekers and nothing else (§Out of scope).")
  require(config.minPlayers >= 1 and config.minPlayers <= config.numAgents,
    "minPlayers must be between 1 and num_agents.")
  require(config.visionConeDeg > 0 and config.visionConeDeg <= 180,
    "visionConeDeg must be in 1..180.")
  require(config.sightRange > 0, "sightRange must be positive.")
  require(config.visionBubble >= 0, "visionBubble must not be negative.")
  require(config.carrySpeedPct > 0 and config.carrySpeedPct <= 100,
    "carrySpeedPct must be in 1..100.")
  require(config.grabReach > 0, "grabReach must be positive.")
  require(config.lockReach > 0, "lockReach must be positive.")
  require(config.vaultSpanPx > 0, "vaultSpanPx must be positive.")
  require(config.vaultTicks > 0, "vaultTicks must be positive.")
  require(config.keepClearPx >= 0, "keepClearPx must not be negative.")
  require(config.crates >= 0 and config.crates <= 6, "crates must be 0..6.")
  require(config.panels >= 0 and config.panels <= 4, "panels must be 0..4.")
  require(config.ramps >= 0 and config.ramps <= 3, "ramps must be 0..3.")
  require(config.crates + config.panels + config.ramps <= MaxObjects,
    "crates + panels + ramps must not exceed " & $MaxObjects & ".")
  require(config.wallClockBudgetSeconds > 0,
    "wallClockBudgetSeconds must be positive.")
  require(config.wallClockBudgetSeconds <= 660,
    "wallClockBudgetSeconds must be <= 660: the engine stop has to fall " &
    "inside 60% of the platform's episode timeout.")
  require(config.attempt1Ms > 0, "attempt1Ms must be positive.")
  require(config.retryMs >= 0, "retryMs must not be negative.")
  require(config.turnBudgetMs >= config.attempt1Ms + config.retryMs,
    "turnBudgetMs must cover attempt1Ms + retryMs.")
  require(config.turnSpacingMs >= 0, "turnSpacingMs must not be negative.")
  require(config.slots.len <= MaxPlayers, "too many slots.")
  discard roomPool(config.roomPool)  ## raises on an unknown pool name.

proc update*(config: var GameConfig, jsonText: string) =
  ## Updates a gameplay config from a JSON object, then resolves and PINS the
  ## room document. The seed must already be final when this runs — the
  ## entrypoint randomises it before calling here (the starter's rule), so
  ## every seed-derived draw follows the final seed.
  if jsonText.len == 0:
    return
  var node: JsonNode
  try:
    node = fromJson(jsonText)
  except jsony.JsonError as e:
    raise newException(HnsError, "Could not parse config JSON: " & e.msg)
  if node.kind != JObject:
    raise newException(HnsError, "Config must be a JSON object.")
  node.readConfigInt("motionScale", config.motionScale)
  node.readConfigInt("accel", config.accel)
  node.readConfigInt("frictionNum", config.frictionNum)
  node.readConfigInt("frictionDen", config.frictionDen)
  node.readConfigInt("maxSpeed", config.maxSpeed)
  node.readConfigInt("stopThreshold", config.stopThreshold)
  node.readConfigInt("playerBouncePct", config.playerBouncePct)
  node.readConfigInt("seed", config.seed)
  node.readConfigInt("speed", config.speed)
  node.readConfigInt("aimTurnRate", config.aimTurnRate)
  node.readConfigInt("sightRange", config.sightRange)
  node.readConfigInt("visionConeDeg", config.visionConeDeg)
  node.readConfigInt("visionBubble", config.visionBubble)
  node.readConfigInt("carrySpeedPct", config.carrySpeedPct)
  node.readConfigInt("grabReach", config.grabReach)
  node.readConfigInt("lockReach", config.lockReach)
  node.readConfigInt("vaultSpanPx", config.vaultSpanPx)
  node.readConfigInt("vaultTicks", config.vaultTicks)
  node.readConfigInt("keepClearPx", config.keepClearPx)
  node.readConfigInt("crates", config.crates)
  node.readConfigInt("panels", config.panels)
  node.readConfigInt("ramps", config.ramps)
  node.readConfigString("roomPool", config.roomPool)
  node.readConfigInt("turnTicks", config.turnTicks)
  node.readConfigInt("prepTurns", config.prepTurns)
  node.readConfigInt("huntTurns", config.huntTurns)
  node.readConfigInt("maxGames", config.maxGames)
  node.readConfigInt("minPlayers", config.minPlayers)
  node.readConfigInt("num_agents", config.numAgents)
  node.readConfigInt("numAgents", config.numAgents)
  node.readConfigInt("startWaitTicks", config.startWaitTicks)
  node.readConfigInt("gameStartWaitTicks", config.startWaitTicks)
  node.readConfigInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readConfigInt("gameOverTicks", config.gameOverTicks)
  node.readConfigBool("showPlayerLabels", config.showPlayerLabels)
  node.readConfigBool("fastMode", config.fastMode)
  node.readConfigInt("turnBudgetMs", config.turnBudgetMs)
  node.readConfigInt("attempt1Ms", config.attempt1Ms)
  node.readConfigInt("retryMs", config.retryMs)
  node.readConfigInt("turnSpacingMs", config.turnSpacingMs)
  node.readConfigInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readConfigString("model", config.model)
  node.readConfigInt("maxOutputTokens", config.maxOutputTokens)
  if node.hasKey("mapSpec"):
    if node["mapSpec"].kind != JObject:
      raise newException(HnsError, "Config field mapSpec must be an object.")
    config.mapSpec = $node["mapSpec"]
  node.readConfigBool("closedRoster", config.closedRoster)
  node.readConfigSlots(config.slots)
  node.readConfigTokens(config.slots, config.closedRoster)
  node.readConfigPlayers(config.slots)
  config.validate()
  ## Resolve the room ONCE and PIN it: playback re-reads the document out of
  ## the replay bytes and never touches data/rooms/.
  if config.mapSpec.len == 0:
    config.mapSpec = mapSpecJson(pickRoom(config.roomPool, config.seed))

proc slotTeamText(slot: PlayerSlotConfig): string =
  if not slot.hasTeam:
    return ""
  teamText(slot.team)

proc slotColorText(slot: PlayerSlotConfig): string =
  if not slot.hasColor:
    return ""
  playerColorText(slot.color)

proc configJson*(config: GameConfig): string =
  ## The complete replay config echo. Everything the wasm viewer needs to
  ## re-derive the episode is here — including the full room document and
  ## the object deal's inputs — so the bytes are self-sufficient.
  var
    players = newJArray()
    slots = newJArray()
    tokens = newJArray()
    includePlayers = false
  for slot in config.slots:
    var item = newJObject()
    if slot.name.len > 0:
      includePlayers = true
    tokens.add(%slot.token)
    players.add(%*{"name": slot.name})
    if slot.hasTeam:
      item["team"] = %slot.slotTeamText()
    if slot.hasColor:
      item["color"] = %slot.slotColorText()
    slots.add(item)
  var node = %*{
    "motionScale": config.motionScale,
    "accel": config.accel,
    "frictionNum": config.frictionNum,
    "frictionDen": config.frictionDen,
    "maxSpeed": config.maxSpeed,
    "stopThreshold": config.stopThreshold,
    "playerBouncePct": config.playerBouncePct,
    "seed": config.seed,
    "speed": config.speed,
    "aimTurnRate": config.aimTurnRate,
    "sightRange": config.sightRange,
    "visionConeDeg": config.visionConeDeg,
    "visionBubble": config.visionBubble,
    "carrySpeedPct": config.carrySpeedPct,
    "grabReach": config.grabReach,
    "lockReach": config.lockReach,
    "vaultSpanPx": config.vaultSpanPx,
    "vaultTicks": config.vaultTicks,
    "keepClearPx": config.keepClearPx,
    "crates": config.crates,
    "panels": config.panels,
    "ramps": config.ramps,
    "roomPool": config.roomPool,
    "turnTicks": config.turnTicks,
    "prepTurns": config.prepTurns,
    "huntTurns": config.huntTurns,
    "maxTicks": config.maxTicks,
    "maxGames": config.maxGames,
    "minPlayers": config.minPlayers,
    "num_agents": config.numAgents,
    "startWaitTicks": config.startWaitTicks,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "closedRoster": config.closedRoster,
    "showPlayerLabels": config.showPlayerLabels,
    "fastMode": config.fastMode,
    "turnBudgetMs": config.turnBudgetMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "maxOutputTokens": config.maxOutputTokens,
    "tokens": tokens,
    "slots": slots
  }
  if includePlayers:
    node["players"] = players
  if config.model.len > 0:
    node["model"] = %config.model
  if config.mapSpec.len > 0:
    node["mapSpec"] = fromJson(config.mapSpec)
  $node
