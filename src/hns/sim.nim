## The gameplay core and the step loop. Re-exports every sim module, so
## `import hns/sim` still sees everything (the starter's arrangement).
##
## The whole physics of this game is the thirteen ordered steps of `step`
## below and NOTHING ELSE MUTATES THE WORLD. Forked from coworld-ctf's
## `src/ctf/sim.nim`: the gun, the grenades, the spray, the pickups, the
## hearts, the hill, the respawns and the map generator are deleted, and the
## grab / lock / push / vault / exposure / sealed-fort steps take their place.

import
  std/[json, math, os, random, strutils],
  bitworld/[pixelfonts, spriteprotocol],
  pixie,
  sim_types, sim_config, room, sim_state, objects, motion, vision, phase,
  fort, roster, map_art, rig_art, upstream, directives

export sim_types, sim_config, room, sim_state, objects, motion, vision,
  phase, fort, roster, map_art, rig_art, upstream

# ---------------------------------------------------------------------------
# Shouts (the starter's mechanic, verbatim: audible to ANYONE of ANY team
# within ShoutRange, drawn as a speech bubble, alive for ShoutTicks, and in
# gameHash. Shouting gives your position away; that is the point.)
# ---------------------------------------------------------------------------

proc sanitizeShout*(text: string): string =
  ## Reduces raw text to a legal shout: printable ASCII only, at most
  ## ShoutMaxChars characters, no leading or trailing spaces.
  for c in text:
    if c >= ' ' and c <= '~':
      result.add(c)
    if result.len == ShoutMaxChars:
      break
  result = result.strip()

proc applyShout*(sim: var SimServer, playerIndex: int,
                 text: string): bool {.discardable.} =
  if sim.phase != Playing:
    return false
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if not sim.players[playerIndex].alive:
    return false
  let shoutText = sanitizeShout(text)
  if shoutText.len == 0:
    return false
  let last = sim.players[playerIndex].lastShoutTick
  if last >= 0 and sim.tickCount - last < ShoutCooldownTicks:
    return false
  sim.players[playerIndex].lastShoutTick = sim.tickCount
  inc sim.players[playerIndex].shouts
  let address = sim.players[playerIndex].address
  var kept: seq[Shout] = @[]
  for shout in sim.recentShouts:
    if shout.address != address:
      kept.add shout
  let shout = Shout(
    address: address,
    team: sim.players[playerIndex].team,
    text: shoutText,
    tick: sim.tickCount,
    x: sim.players[playerIndex].x + CollisionW div 2,
    y: sim.players[playerIndex].y + CollisionH div 2
  )
  kept.add shout
  sim.recentShouts = kept
  sim.emitEvent(
    ShoutEvent,
    source = playerIndex,
    x = float(shout.x),
    y = float(shout.y),
    content = shoutText
  )
  true

proc shoutAudibleTo*(sim: SimServer, viewerIndex: int, shout: Shout): bool =
  ## Within ShoutRange of where it was made, for EITHER team. Shouts carry
  ## through walls and fog.
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return false
  if not sim.players[viewerIndex].alive:
    return false
  let
    vx = sim.players[viewerIndex].x + CollisionW div 2
    vy = sim.players[viewerIndex].y + CollisionH div 2
  distSq(vx, vy, shout.x, shout.y) <= ShoutRange * ShoutRange

# ---------------------------------------------------------------------------
# Grab / lock / vault — tick steps 4, 5 and 7
# ---------------------------------------------------------------------------

type ActionResult* = enum
  ## What the driver is told happened to its last order. These strings are
  ## the observation's `result` field.
  arNone
  arGrabbed
  arGrabFailed
  arDropped
  arLocked
  arUnlocked
  arLockRefused
  arVaulted
  arVaultFailed
  arPushStuck

proc actionResultText*(value: ActionResult): string =
  case value
  of arNone: ""
  of arGrabbed: "holding"
  of arGrabFailed: "grab_failed"
  of arDropped: "pushed"
  of arLocked: "locked"
  of arUnlocked: "unlocked"
  of arLockRefused: "lock_refused"
  of arVaulted: "vaulted"
  of arVaultFailed: "vault_failed"
  of arPushStuck: "push_stuck"

proc resolveGrabs(sim: var SimServer, inputs, prevInputs: openArray[InputState],
                  results: var seq[ActionResult]) =
  ## Tick step 4, ASCENDING SLOT. Ties (two cogs in the same tick) go to the
  ## lower slot; the loser gets nothing and a `grab_failed` result.
  for slot in 0 ..< sim.players.len:
    let
      input = if slot < inputs.len: inputs[slot] else: InputState()
      prev = if slot < prevInputs.len: prevInputs[slot] else: InputState()
    if not sim.players[slot].alive:
      continue
    let held = sim.players[slot].holding
    if held >= 0:
      let broke = sim.players[slot].pushBlockedTicks >= GrabBreakTicks
      if not input.c or broke or sim.players[slot].airborne:
        sim.emitEvent(Drop, source = slot, subject = sim.objects[held].id)
        sim.dropObject(slot)
        sim.players[slot].pushBlockedTicks = 0
        results[slot] = if broke: arPushStuck else: arDropped
      continue
    if not (input.c and not prev.c):
      continue
    if sim.players[slot].airborne:
      continue
    let target = sim.grabProbe(slot)
    if target < 0:
      results[slot] = arGrabFailed
      continue
    if not sim.mayTouch(slot, target):
      sim.emitEvent(LockRefused, source = slot,
        subject = sim.objects[target].id)
      results[slot] = arLockRefused
      continue
    if sim.objects[target].heldBy >= 0:
      results[slot] = arGrabFailed
      continue
    sim.objects[target].heldBy = slot
    sim.players[slot].holding = target
    sim.players[slot].pushBlockedTicks = 0
    inc sim.players[slot].grabs
    sim.emitEvent(Grab, source = slot, subject = sim.objects[target].id)
    results[slot] = arGrabbed

proc resolveLocks(sim: var SimServer, inputs, prevInputs: openArray[InputState],
                  results: var seq[ActionResult]) =
  ## Tick step 5, ASCENDING SLOT.
  for slot in 0 ..< sim.players.len:
    if sim.players[slot].lockCooldown > 0:
      dec sim.players[slot].lockCooldown
    if not sim.players[slot].alive or sim.players[slot].airborne:
      continue
    let
      input = if slot < inputs.len: inputs[slot] else: InputState()
      prev = if slot < prevInputs.len: prevInputs[slot] else: InputState()
    if not (input.attack and not prev.attack):
      continue
    if sim.players[slot].lockCooldown > 0:
      continue
    var target = sim.players[slot].holding
    if target < 0:
      target = sim.nearestObjectWithin(slot, sim.config.lockReach)
    if target < 0:
      continue
    let
      mine = lockOwnerFor(sim.players[slot].team)
      owner = sim.objects[target].lockedBy
    if owner == lockNone:
      sim.objects[target].lockedBy = mine
      inc sim.players[slot].locks
      sim.emitEvent(Lock, source = slot, subject = sim.objects[target].id,
        content = lockText(mine))
      results[slot] = arLocked
    elif owner == mine:
      sim.objects[target].lockedBy = lockNone
      sim.emitEvent(Unlock, source = slot, subject = sim.objects[target].id,
        content = lockText(mine))
      results[slot] = arUnlocked
    else:
      sim.emitEvent(LockRefused, source = slot,
        subject = sim.objects[target].id)
      results[slot] = arLockRefused
    sim.players[slot].lockCooldown = LockCooldownTicks

proc vaultMinSpeed(sim: SimServer): int {.inline.} =
  sim.config.maxSpeed div 2

proc resolveVaults(sim: var SimServer, results: var seq[ActionResult]) =
  ## Tick step 7, ASCENDING SLOT. A cog that holds nothing, whose centre is
  ## inside a ramp's rectangle, running along the ramp axis toward its head
  ## at at least `vaultMinSpeed`, with a barrier at most `vaultSpanPx` thick
  ## beyond the head, goes airborne. While airborne it cannot grab or lock,
  ## and it IS VISIBLE OVER THE FURNITURE — being seen doing it is what the
  ## vault costs.
  for slot in 0 ..< sim.players.len:
    if not sim.players[slot].alive:
      continue
    if sim.players[slot].airborne:
      dec sim.players[slot].vaultLeft
      let unit = AimUnit[sim.players[slot].vaultDirBrads and
        (AimBradsTurn - 1)]
      sim.players[slot].x += unit.x * VaultSpeed div AimUnitScale
      sim.players[slot].y += unit.y * VaultSpeed div AimUnitScale
      sim.players[slot].x = clamp(sim.players[slot].x, 0, MapWidth - 1)
      sim.players[slot].y = clamp(sim.players[slot].y, 0, MapHeight - 1)
      if sim.players[slot].vaultLeft <= 0:
        sim.players[slot].airborne = false
        let landing = sim.vaultLanding(
          sim.players[slot].vaultFromX, sim.players[slot].vaultFromY,
          sim.players[slot].vaultDirBrads)
        if landing.ok:
          sim.placePlayer(slot, landing.x, landing.y)
          results[slot] = arVaulted
          sim.emitEvent(Vault, source = slot, amount = 1,
            x = float(landing.x), y = float(landing.y))
        else:
          sim.placePlayer(slot,
            sim.players[slot].vaultFromX, sim.players[slot].vaultFromY)
          results[slot] = arVaultFailed
          sim.emitEvent(Vault, source = slot, amount = 0)
      continue
    if sim.players[slot].holding >= 0:
      continue
    let ramp = sim.objectAt(sim.players[slot].x, sim.players[slot].y)
    if ramp < 0 or sim.objects[ramp].kind != okRamp:
      continue
    let
      brads = rampHeadBrads(sim.objects[ramp], sim.players[slot].x,
        sim.players[slot].y)
      unit = AimUnit[brads]
      along = (sim.players[slot].velX * unit.x +
        sim.players[slot].velY * unit.y) div AimUnitScale
    if along < sim.vaultMinSpeed():
      continue
    if not sim.vaultSpanClear(sim.players[slot].x, sim.players[slot].y,
        brads, sim.config.vaultSpanPx):
      continue
    sim.players[slot].airborne = true
    sim.players[slot].vaultLeft = sim.config.vaultTicks
    sim.players[slot].vaultDirBrads = brads
    sim.players[slot].vaultFromX = sim.players[slot].x
    sim.players[slot].vaultFromY = sim.players[slot].y
    inc sim.players[slot].vaults
    sim.emitEvent(Vault, source = slot, subject = sim.objects[ramp].id,
      headingBrads = brads, x = float(sim.players[slot].x),
      y = float(sim.players[slot].y))

# ---------------------------------------------------------------------------
# Game lifecycle
# ---------------------------------------------------------------------------

proc dealHiderPads(sim: var SimServer) =
  ## Step 3 of the seeded setup order: the room's three hider pads are
  ## shuffled and dealt to the hiding slots in ascending slot order.
  var order = @[0, 1, 2]
  sim.setupRng.shuffle(order)
  var
    hiderSeat = 0
    seekerSeat = 0
  let
    hiderPads = sim.gameMap.padsFor(anchorHiders)
    seekerPads = sim.gameMap.padsFor(anchorSeekers)
  for slot in 0 ..< sim.players.len:
    if sim.players[slot].team == Red:
      let pad =
        if hiderPads.len == 0: (x: MapWidth div 2, y: MapHeight div 2)
        else:
          let p = hiderPads[order[hiderSeat mod order.len] mod hiderPads.len]
          (x: p.x, y: p.y)
      inc hiderSeat
      let spot = sim.nearestWalkable(pad.x, pad.y)
      sim.players[slot].homeX = spot.x
      sim.players[slot].homeY = spot.y
    else:
      let pad =
        if seekerPads.len == 0: (x: MapWidth div 2, y: MapHeight div 2)
        else:
          let p = seekerPads[seekerSeat mod seekerPads.len]
          (x: p.x, y: p.y)
      inc seekerSeat
      let spot = sim.nearestWalkable(pad.x, pad.y)
      sim.players[slot].homeX = spot.x
      sim.players[slot].homeY = spot.y
    sim.resetPlayerToHome(slot)

proc startGame*(sim: var SimServer) =
  sim.logGameEvent("game " & $(sim.gameIndex + 1) & " started: players=" &
    $sim.players.len)
  sim.recentShouts = @[]
  sim.applySideSwap()
  sim.resetObjectsToDeal()
  sim.resetGameCounters()
  for i in 0 ..< sim.players.len:
    sim.players[i].lastShoutTick = -1
    sim.players[i].alive = true
    sim.players[i].holding = -1
    sim.players[i].airborne = false
    sim.players[i].vaultLeft = 0
    sim.players[i].lockCooldown = 0
    sim.players[i].pushBlockedTicks = 0
    sim.players[i].sealed = false
    sim.players[i].aimBrads = spawnAimBrads(sim.players[i].team)
  sim.dealHiderPads()
  sim.feedDirectives = @[]
  sim.emitPhaseChange(Playing)
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.timeLimitReached = false
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1
  discard sim.scanSealed()

proc episodeComplete*(sim: SimServer): bool {.inline.} =
  sim.gameMargins.len >= sim.config.maxGames

proc finishGame*(sim: var SimServer, timeLimitReached = true) =
  ## Files the game and either swaps sides for game 2 or ends the episode.
  sim.archiveGame()
  sim.timeLimitReached = timeLimitReached
  sim.logGameEvent("game " & $sim.gameMargins.len & " over: margin " &
    $sim.gameMargins[^1] & " permille (hiders)")
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.gameOverTimer = sim.config.gameOverTicks

proc resetToLobby*(sim: var SimServer) =
  if sim.phase != Lobby:
    sim.emitPhaseChange(Lobby)
  sim.phase = Lobby
  sim.players = @[]
  sim.fovCaches = @[]
  sim.recentShouts = @[]
  sim.feedDirectives = @[]
  sim.nextJoinOrder = 0
  sim.gameStartTick = -1
  sim.startWaitTimer = 0
  sim.lobbyWaitTimer = 0
  sim.timeLimitReached = false
  sim.needsReregister = true
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1
  for account in sim.rewardAccounts.mitems:
    account.hasTeam = false
    account.won = false
    account.abandoned = false

proc stepLobby(sim: var SimServer) =
  if sim.players.len < sim.config.minPlayers:
    sim.startWaitTimer = 0
    if sim.config.lobbyJoinTimeoutTicks > 0:
      inc sim.lobbyWaitTimer
    sim.logLobbyWaiting()
    return
  if sim.config.startWaitTicks <= 0:
    sim.startGame()
    return
  if sim.startWaitTimer <= 0:
    sim.startWaitTimer = sim.config.startWaitTicks
  dec sim.startWaitTimer
  if sim.startWaitTimer <= 0:
    sim.startGame()
  else:
    sim.logLobbyCountdown()

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  sim.phase == Lobby and
    sim.config.lobbyJoinTimeoutTicks > 0 and
    sim.lobbyWaitTimer >= sim.config.lobbyJoinTimeoutTicks

proc decodeGridFont(image: Image, cellW, cellH, cols: int,
    spacing = 1): PixelFont =
  ## The starter's fixed-cell ASCII sheet decoder (data/ascii.png), kept
  ## verbatim: the shout bubble wants a chunkier face than the 6 px HUD font.
  result.height = cellH
  result.spacing = spacing
  proc ink(x, y: int): bool =
    if x < 0 or y < 0 or x >= image.width or y >= image.height:
      return false
    let p = image[x, y]
    p.a > 20'u8 and p.r >= 120'u8 and p.g >= 120'u8 and p.b >= 120'u8
  for code in FirstPrintableAscii .. LastPrintableAscii:
    let
      idx = code - FirstPrintableAscii
      cx = (idx mod cols) * cellW
      cy = (idx div cols) * cellH
    var minX = cellW
    var maxX = -1
    for gx in 0 ..< cellW:
      for gy in 0 ..< cellH:
        if ink(cx + gx, cy + gy):
          minX = min(minX, gx)
          maxX = max(maxX, gx)
          break
    let width = if maxX < 0: max(1, cellW div 2) else: maxX - minX + 1
    let start = if maxX < 0: 0 else: minX
    var glyph = PixelGlyph(ch: char(code), width: width, height: cellH)
    glyph.pixels = newSeq[bool](width * cellH)
    if maxX >= 0:
      for gy in 0 ..< cellH:
        for gx in 0 ..< width:
          glyph.pixels[gy * width + gx] = ink(cx + start + gx, cy + gy)
    result.glyphs.add(glyph)

proc loadShoutFont(): PixelFont =
  let path = gameDir() / "data" / "ascii.png"
  if fileExists(path):
    try:
      return decodeGridFont(readImage(path), 7, 9, 18)
    except CatchableError:
      discard
  readTiny5Font()

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.rng = initRand(config.seed)
  result.setupRng = newSetupRng(config.seed)
  for i in 0 ..< spriteprotocol.Palette.len:
    spriteprotocol.Palette[i] = rgba(
      sim_types.Palette[i].r, sim_types.Palette[i].g,
      sim_types.Palette[i].b, 255)
  result.asciiSprites = readTiny5Font()
  result.shoutFont = loadShoutFont()

  # Step 1 of the seeded setup order: the room. `resolveRoom` prefers the
  # PINNED document, so a replay renders the room it recorded even if
  # data/rooms/ has changed underneath it or is missing entirely.
  result.gameMap = loadHnsMap(config)
  result.roomName = result.gameMap.name

  let (rgbaBytes, wall) = bakeRoom(result.gameMap)
  result.mapRgba = rgbaBytes
  result.mapPixels = mapPixelsFromRgba(rgbaBytes)
  result.wallMask = wall
  result.walkMask = newSeq[bool](MapWidth * MapHeight)
  for i in 0 ..< result.walkMask.len:
    result.walkMask[i] = not wall[i]
  result.objectMask = newSeq[bool](MapWidth * MapHeight)
  result.fovBlocked = result.buildFovBlocked()

  # Step 2: the object deal, drawn BEFORE any seat connects.
  result.dealObjects()

  result.gameIndex = 0
  result.matchPhase = phasePrep
  result.endReason = ReasonComplete
  result.endRule = EndRuleFullTime
  result.fovCaches = @[]
  result.players = @[]
  result.nextJoinOrder = 0
  result.gameStartTick = -1
  result.startWaitTimer = 0
  result.lobbyWaitTimer = 0
  result.gameEventLoggingEnabled = true
  result.llmTurns = newSeq[int](config.numAgents)
  result.fallbackTurns = newSeq[int](config.numAgents)
  result.ordersRejected = newSeq[int](config.numAgents)
  result.deadSeats = newSeq[bool](config.numAgents)
  result.seatNames = newSeq[string](config.numAgents)
  result.seatPolicyKind = newSeq[string](config.numAgents)
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1

template pruneAgedFx(sim: var SimServer, fxField, tickField: untyped,
    life: untyped) =
  ## The starter's copy-filter, unchanged.
  var kept: typeof(sim.fxField) = @[]
  for fx {.inject.} in sim.fxField:
    if sim.tickCount - fx.tickField < life:
      kept.add fx
  sim.fxField = kept

var lastActionResults*: seq[ActionResult]
  ## The driver's honest report of how each cog's last action ended, read by
  ## the control layer to fill the observation's `result` field. Presentation
  ## state: never hashed, never recorded.

proc step*(
  sim: var SimServer,
  inputs: openArray[InputState],
  prevInputs: openArray[InputState]
) =
  ## THE WHOLE PHYSICS OF THE GAME, in the design note's order. Nothing else
  ## mutates the world.
  inc sim.tickCount

  if sim.players.len == 0 and sim.phase == Playing:
    sim.finishGame(timeLimitReached = true)
  elif sim.players.len == 0 and sim.phase != Lobby and sim.episodeComplete():
    discard

  if sim.phase == Lobby:
    sim.stepLobby()
    return

  if sim.phase == GameOver:
    dec sim.gameOverTimer
    if sim.gameOverTimer <= 0 and not sim.episodeComplete():
      inc sim.gameIndex
      sim.startGame()
    return

  if lastActionResults.len != sim.players.len:
    lastActionResults = newSeq[ActionResult](sim.players.len)

  # 1. The phase transition.
  let tick = sim.gameTick()
  if sim.matchPhase == phasePrep and tick >= sim.config.prepTicks:
    sim.matchPhase = phaseHunt
    sim.releaseEmitted = true
    sim.emitEvent(Release, amount = sim.tickCount)
    sim.invalidateFovCaches()
    discard sim.scanSealed()

  # 2. Compile actuator masks -> already done by the control layer; a
  #    seeker's mask during prep is forced to zero HERE, so the recorded
  #    masks and the sim always agree.
  var effective = newSeq[InputState](sim.players.len)
  var effectivePrev = newSeq[InputState](sim.players.len)
  for slot in 0 ..< sim.players.len:
    if sim.frozenSeeker(slot):
      continue
    effective[slot] = (if slot < inputs.len: inputs[slot] else: InputState())
    effectivePrev[slot] =
      (if slot < prevInputs.len: prevInputs[slot] else: InputState())

  # 3. Aim.
  for slot in 0 ..< sim.players.len:
    sim.applyAim(slot, effective[slot])

  # 4. Grab / release, ascending slot.
  sim.resolveGrabs(effective, effectivePrev, lastActionResults)

  # 5. Lock toggle, ascending slot.
  sim.resolveLocks(effective, effectivePrev, lastActionResults)

  # 6. Movement, ascending slot.
  for slot in 0 ..< sim.players.len:
    sim.applyInput(slot, effective[slot])

  # 7. Vault, ascending slot.
  sim.resolveVaults(lastActionResults)

  # 8. Geometry refresh happens inside moveObject's dirty rect; 9. fov
  #    refresh, ascending slot, skipping frozen seekers.
  for slot in 0 ..< sim.players.len:
    if sim.frozenSeeker(slot):
      continue
    discard sim.refreshPlayerFov(slot)

  # 10. Exposure scoring — hunt phase only.
  if sim.matchPhase == phaseHunt:
    let transitions = sim.scoreExposure()
    for (seeker, hider) in transitions.spotted:
      sim.emitEvent(Spotted, source = seeker, target = hider,
        x = float(sim.players[hider].x), y = float(sim.players[hider].y))
    for (seeker, hider) in transitions.lost:
      sim.emitEvent(Lost, source = seeker, target = hider)
    sim.accrueSealedTicks()

  # 11. Sealed-fort scan — only at a turn boundary (and at the release tick,
  #     above).
  if sim.config.turnTicks > 0 and tick mod sim.config.turnTicks == 0:
    let changes = sim.scanSealed()
    for slot in changes.sealed:
      sim.emitEvent(Sealed, source = slot, amount = sim.tickCount)
    for slot in changes.unsealed:
      sim.emitEvent(Unsealed, source = slot, amount = sim.tickCount)

  # 12. Shout expiry — observable gameplay state, so it is part of the
  #     deterministic sim and the hash.
  sim.pruneAgedFx(recentShouts, tick, ShoutTicks)

  # 13. End evaluation.
  if sim.gameTick() >= sim.config.maxTicks:
    sim.finishGame(timeLimitReached = true)

proc forceWallClockStop*(sim: var SimServer) =
  ## The starter's wall-clock stop, kept. A wall-clock fact cannot be
  ## re-derived from sim state, so the SERVER writes it as one load-bearing
  ## record and BOTH the recording and the playback apply it through THIS
  ## proc — which is what makes the record -> re-derive check pass for
  ## `wall_clock` as well as `full_time`.
  if sim.phase == Playing:
    sim.archiveGame()
  while sim.gameMargins.len < sim.config.maxGames:
    sim.gameMargins.add(0)
    sim.gameHidden.add(0)
    sim.gameSeen.add(0)
    sim.gameHuntPlayed.add(0)
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.gameOverTimer = 0
  sim.endReason = ReasonDeadline
  sim.endRule = EndRuleWallClock

proc forceFaultStop*(sim: var SimServer, detail: string) =
  ## The fault stop, applied by the same proc on record and on playback.
  if sim.phase == Playing:
    sim.archiveGame()
  while sim.gameMargins.len < sim.config.maxGames:
    sim.gameMargins.add(0)
    sim.gameHidden.add(0)
    sim.gameSeen.add(0)
    sim.gameHuntPlayed.add(0)
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.gameOverTimer = 0
  sim.endReason = ReasonFault
  sim.endRule = EndRuleSimFault
  # Rune-truncated HERE, not at the caller: `stopDetail` reaches the results
  # document (roster.nim) and from there the replay's `result` record, and it
  # carries a caught exception's `msg`. The stop RECORD already goes through
  # `sanitizeLine` (server.nim); this is the same cut for the same string on
  # the other path, and it is applied on record and on playback alike because
  # both go through this proc.
  sim.stopDetail = sanitizeLine(detail, MaxFallbackDetailRunes)

proc applyControlRecord*(sim: var SimServer, record: string) =
  ## Re-applies one replay CONTROL record at playback. Everything but `stop`
  ## lands in NON-HASHED presentation state (the broadcast feed); `stop` is the
  ## LOAD-BEARING wall-clock/fault record and is applied through the same
  ## procs the recording used, which is what makes the record -> re-derive
  ## check pass for every end reason and not only the healthy one.
  if record.len == 0 or record[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(record)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  case node{"k"}.getStr()
  of "stop":
    case node{"endRule"}.getStr()
    of EndRuleWallClock: sim.forceWallClockStop()
    of EndRuleSimFault, EndRuleHostError:
      sim.forceFaultStop(node{"detail"}.getStr())
    else: discard
  of "result":
    let results = node{"results"}
    if results != nil and results.kind == JObject:
      sim.endReason = results{"reason"}.getStr(sim.endReason)
      sim.endRule = results{"endRule"}.getStr(sim.endRule)
      let names = results{"names"}
      if names != nil and names.kind == JArray:
        sim.seatNames = @[]
        for name in names:
          sim.seatNames.add(name.getStr())
      let kinds = results{"policyKinds"}
      if kinds != nil and kinds.kind == JArray:
        sim.seatPolicyKind = @[]
        for kind in kinds:
          sim.seatPolicyKind.add(kind.getStr())
  of "register":
    let slot = node{"slot"}.getInt(-1)
    if slot >= 0:
      while sim.seatPolicyKind.len <= slot:
        sim.seatPolicyKind.add("scripted")
      while sim.seatNames.len <= slot:
        sim.seatNames.add("")
      sim.seatPolicyKind[slot] = node{"kind"}.getStr("scripted")
      if sim.seatNames[slot].len == 0:
        sim.seatNames[slot] = node{"policy"}.getStr()
    sim.pushFeedDirective(record)
  of "fallback":
    let slot = node{"slot"}.getInt(-1)
    if slot >= 0:
      while sim.fallbackTurns.len <= slot:
        sim.fallbackTurns.add(0)
      inc sim.fallbackTurns[slot]
    sim.pushFeedDirective(record)
  else:
    sim.pushFeedDirective(record)

proc settleEpisode*(sim: var SimServer) =
  ## Called once the last game is filed: pads the per-game arrays so a
  ## deadline episode is still rankable and still exactly zero-sum.
  while sim.gameMargins.len < sim.config.maxGames:
    sim.gameMargins.add(0)
    sim.gameHidden.add(0)
    sim.gameSeen.add(0)
    sim.gameHuntPlayed.add(0)
