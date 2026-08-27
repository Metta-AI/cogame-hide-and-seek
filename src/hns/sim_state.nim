## Sim-state services shared by the roster machinery and the gameplay core:
## lobby status, spawn placement, game-event logging, the replay hash
## (`gameHash` / `mixHash`), walkability, the tier-2 event sink (`emitEvent`)
## and the broadcast feed ring.
##
## Forked from coworld-ctf's `src/ctf/sim_state.nim`; the flag reset, the
## endzone spawn draw and the weapon/paint hash fields are deleted and the
## object layer, the two-phase clock and the exposure counters are appended
## to the hash AFTER the inherited fields, so the inherited ordering never
## moves (§Determinism, native <-> wasm, step 4).

import
  std/[json, random, strutils],
  sim_types, room

proc lobbyIsStarting*(sim: SimServer): bool =
  sim.phase == Lobby and sim.players.len >= sim.config.minPlayers

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  if not sim.lobbyIsStarting():
    return 0
  max(0, sim.config.startWaitTicks - sim.startWaitTimer)

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  let ticks = sim.lobbyStartTicksRemaining()
  if ticks <= 0:
    return 0
  (ticks + TargetFps - 1) div TargetFps

proc spawnAimBrads*(team: Team): int =
  ## Hiders start facing east (into the room), seekers west (into the room
  ## from their pads). Cosmetic at spawn, but it decides what a frozen seeker
  ## sees on the first hunt tick, so it is deterministic and hashed through
  ## `aimBrads`.
  case team
  of Red: 0
  of Blue: 128

proc playerText*(sim: SimServer, playerIndex: int): string =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return "unknown"
  let color = sim.players[playerIndex].color
  for i, candidate in PlayerColors:
    if candidate == color:
      return PlayerColorNames[i]
  "unknown"

proc logGameEvent*(sim: SimServer, text: string) =
  if sim.gameEventLoggingEnabled:
    echo text

proc logLobbyWaiting*(sim: var SimServer) =
  let
    needed = max(0, sim.config.minPlayers - sim.players.len)
    players = sim.players.len
  if players == sim.lastLobbyPlayersLogged and
      needed == sim.lastLobbyNeededLogged:
    return
  sim.lastLobbyPlayersLogged = players
  sim.lastLobbyNeededLogged = needed
  sim.lastLobbySecondsLogged = -1
  sim.logGameEvent(
    "waiting for players: " & $players & "/" &
      $sim.config.minPlayers & ", need " & $needed & " more"
  )

proc logLobbyCountdown*(sim: var SimServer) =
  let seconds = sim.lobbyStartSecondsRemaining()
  if seconds <= 0 or seconds == sim.lastLobbySecondsLogged:
    return
  sim.lastLobbySecondsLogged = seconds
  sim.logGameEvent("game starting in " & $seconds)

proc mapIndex*(x, y: int): int {.inline.} =
  y * MapWidth + x

proc mixHash(hash: var uint64, value: uint64) =
  ## Mixes one integer into a deterministic FNV-1a hash.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashInt(hash: var uint64, value: int) =
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashBool(hash: var uint64, value: bool) =
  hash.mixHashInt(ord(value))

proc gameHash*(sim: SimServer): uint64 =
  ## A deterministic hash of gameplay state, checked EVERY tick by the wasm
  ## viewer against the recorded chain. Field order is wire format.
  result = 14695981039346656037'u64
  # --- the inherited block: never reorder, never insert ---
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(ord(sim.phase))
  result.mixHashInt(sim.gameOverTimer)
  result.mixHashInt(sim.gameStartTick)
  result.mixHashInt(sim.startWaitTimer)
  result.mixHashBool(sim.timeLimitReached)
  result.mixHashInt(sim.nextJoinOrder)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashInt(player.x)
    result.mixHashInt(player.y)
    result.mixHashInt(player.homeX)
    result.mixHashInt(player.homeY)
    result.mixHashInt(player.velX)
    result.mixHashInt(player.velY)
    result.mixHashInt(player.carryX)
    result.mixHashInt(player.carryY)
    result.mixHashBool(player.flipH)
    result.mixHashInt(player.aimBrads)
    result.mixHashInt(ord(player.team))
    result.mixHashBool(player.alive)
    result.mixHashInt(player.lastShoutTick)
    result.mixHashInt(player.joinOrder)
    # Colour is an unsigned packed value: widening directly keeps the hash
    # identical on 32- and 64-bit targets (the starter's wasm32 fix).
    result.mixHash(uint64(player.color))
  # --- appended after them, so the inherited ordering never moves ---
  for player in sim.players:
    result.mixHashInt(player.holding)
    result.mixHashBool(player.airborne)
    result.mixHashInt(player.vaultLeft)
    result.mixHashInt(player.vaultDirBrads)
    result.mixHashInt(player.lockCooldown)
    result.mixHashInt(player.pushBlockedTicks)
  result.mixHashInt(sim.objects.len)
  for obj in sim.objects:
    result.mixHashInt(ord(obj.kind))
    result.mixHashInt(ord(obj.axis))
    result.mixHashInt(obj.x)
    result.mixHashInt(obj.y)
    result.mixHashInt(ord(obj.lockedBy))
    result.mixHashInt(obj.heldBy)
  result.mixHashInt(ord(sim.matchPhase))
  result.mixHashInt(sim.config.prepTurns * sim.config.turnTicks)
  result.mixHashInt(sim.gameIndex)
  result.mixHashInt(sim.hiddenTicks)
  result.mixHashInt(sim.seenTicks)
  for player in sim.players:
    result.mixHashInt(player.seatSeenTicks)
  result.mixHash(sim.sealedMask)
  result.mixHashInt(sim.geometryEpoch)
  # --- the starter's shout block, unchanged ---
  result.mixHashInt(sim.recentShouts.len)
  for shout in sim.recentShouts:
    for ch in shout.address:
      result.mixHashInt(ord(ch))
    result.mixHashInt(ord(shout.team))
    for ch in shout.text:
      result.mixHashInt(ord(ch))
    result.mixHashInt(shout.tick)
    result.mixHashInt(shout.x)
    result.mixHashInt(shout.y)

const MaxFeedDirectives* = 8
  ## How many commander lines the match feed keeps. The feed shows four rows
  ## at a time and a seek re-hydrates from the keyframe, so a short ring is
  ## all the client can ever draw.

proc pushFeedDirective*(sim: var SimServer, record: string) =
  ## Records one `directive` chat record for the broadcast feed. Called from
  ## the live server as it writes the record AND from the replay's chat
  ## re-application, so the feed tells the same story either way. Never
  ## hashed: this is presentation state.
  if record.len == 0 or record[0] != '{':
    return
  try:
    let node = parseJson(record)
    if node.kind != JObject:
      return
    let kind = node{"k"}.getStr()
    if kind != "directive" and kind != "fallback" and kind != "register":
      return
  except CatchableError:
    return
  sim.feedDirectives.add(record)
  if sim.feedDirectives.len > MaxFeedDirectives:
    sim.feedDirectives.delete(0)

proc isWalkable*(sim: SimServer, x, y: int): bool {.inline.} =
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return false
  sim.walkMask[mapIndex(x, y)]

proc isWall*(sim: SimServer, x, y: int): bool {.inline.} =
  ## STATIC wall only — the furniture is `objectMask`.
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return true
  sim.wallMask[mapIndex(x, y)]

proc isObject*(sim: SimServer, x, y: int): bool {.inline.} =
  if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
    return false
  sim.objectMask[mapIndex(x, y)]

proc isBlocked*(sim: SimServer, x, y: int): bool {.inline.} =
  ## Wall OR furniture: what a body and a sightline both stop against.
  sim.isWall(x, y) or sim.isObject(x, y)

proc canOccupy*(sim: SimServer, x, y: int): bool =
  ## True when a solid footprint of half-extent PlayerHalf centred on (x, y)
  ## fits entirely on floor that is neither wall nor furniture.
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      if not sim.isWalkable(x + dx, y + dy):
        return false
      if sim.isObject(x + dx, y + dy):
        return false
  true

proc canOccupyIgnoringObject*(sim: SimServer, x, y, ignore: int): bool =
  ## `canOccupy`, but the rectangle of one object is treated as floor — what
  ## a holder needs, because it moves rigidly with the thing it holds.
  var box: MapRect
  if ignore >= 0 and ignore < sim.objects.len:
    let obj = sim.objects[ignore]
    box = MapRect(x: obj.x, y: obj.y, w: obj.w, h: obj.h)
  for dy in -PlayerHalf .. PlayerHalf:
    for dx in -PlayerHalf .. PlayerHalf:
      let
        px = x + dx
        py = y + dy
      if not sim.isWalkable(px, py):
        return false
      if sim.isObject(px, py) and not inRect(px, py, box):
        return false
  true

proc nearestWalkable*(sim: SimServer, x, y: int): tuple[x, y: int] =
  ## Nearest occupiable point, by expanding ring search.
  if sim.canOccupy(x, y):
    return (x, y)
  for r in 1 .. max(MapWidth, MapHeight):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = x + dx
          ny = y + dy
        if sim.canOccupy(nx, ny):
          return (nx, ny)
  (x, y)

proc placePlayer*(sim: var SimServer, playerIndex, x, y: int) =
  ## Moves one cog to (x, y) with all motion state cleared.
  sim.players[playerIndex].x = x
  sim.players[playerIndex].y = y
  sim.players[playerIndex].velX = 0
  sim.players[playerIndex].velY = 0
  sim.players[playerIndex].carryX = 0
  sim.players[playerIndex].carryY = 0

proc resetPlayerToHome*(sim: var SimServer, playerIndex: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  sim.placePlayer(playerIndex,
    sim.players[playerIndex].homeX, sim.players[playerIndex].homeY)

proc eventSlot*(sim: SimServer, playerIndex: int): int {.inline.} =
  if playerIndex >= 0 and playerIndex < sim.players.len:
    return sim.players[playerIndex].joinOrder
  -1

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  source = -1,
  target = -1,
  subject = "",
  amount = 0,
  x = 0.0,
  y = 0.0,
  headingBrads = -1,
  content = "",
  sourceSlot = -1,
  targetSlot = -1
) {.inline.} =
  ## Appends one tier-2 analysis event; a no-op unless collectEvents is on,
  ## so live servers pay nothing. `source`/`target` are PLAYER INDICES here
  ## and are recorded as stable join slots.
  if not sim.collectEvents:
    return
  sim.events.add SimEvent(
    tick: sim.tickCount,
    kind: kind,
    source: (if sourceSlot >= 0: sourceSlot else: sim.eventSlot(source)),
    target: (if targetSlot >= 0: targetSlot else: sim.eventSlot(target)),
    subject: subject,
    amount: amount,
    x: x,
    y: y,
    headingBrads: headingBrads,
    content: content
  )

proc emitPhaseChange*(sim: var SimServer, newPhase: GamePhase) {.inline.} =
  ## Call BEFORE assigning sim.phase, with the phase being switched to.
  if not sim.collectEvents:
    return
  sim.emitEvent(
    PhaseChange,
    subject = ($newPhase).toLowerAscii,
    amount = ord(newPhase)
  )


proc fovCellIndex*(cx, cy: int): int {.inline.} =
  cy * FovGridW + cx

proc fovCellAt*(x, y: int): tuple[cx, cy: int] {.inline.} =
  (clamp(x div FovCellSize, 0, FovGridW - 1),
   clamp(y div FovCellSize, 0, FovGridH - 1))

proc fovCellCenter*(cx, cy: int): tuple[x, y: int] {.inline.} =
  (cx * FovCellSize + FovCellSize div 2, cy * FovCellSize + FovCellSize div 2)

proc buildFovBlocked*(sim: SimServer): seq[bool] =
  ## Downsamples the pixel blocking mask (wall OR furniture) into the
  ## fog-of-war occlusion grid: a cell is opaque when at least half of its
  ## pixels block. The starter's rule, with the furniture added — which is
  ## the whole reason this grid now has to be rebuilt on a dirty rect.
  result = newSeq[bool](FovCellCount)
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      var
        walls = 0
        pixels = 0
      for py in cy * FovCellSize ..< min((cy + 1) * FovCellSize, MapHeight):
        for px in cx * FovCellSize ..< min((cx + 1) * FovCellSize, MapWidth):
          inc pixels
          if sim.wallMask[mapIndex(px, py)] or sim.objectMask[mapIndex(px, py)]:
            inc walls
      result[fovCellIndex(cx, cy)] = walls * 2 >= pixels

proc refreshFovCells*(sim: var SimServer, x0, y0, x1, y1: int) =
  ## Rebuilds the fog occlusion cells covering one map box from the live
  ## masks, on exactly the rule buildFovBlocked uses, so an incremental
  ## rebuild and a full one can never disagree.
  let
    gx0 = clamp(x0 div FovCellSize, 0, FovGridW - 1)
    gx1 = clamp((x1 - 1) div FovCellSize, 0, FovGridW - 1)
    gy0 = clamp(y0 div FovCellSize, 0, FovGridH - 1)
    gy1 = clamp((y1 - 1) div FovCellSize, 0, FovGridH - 1)
  for gy in gy0 .. gy1:
    for gx in gx0 .. gx1:
      var
        walls = 0
        pixels = 0
      for py in gy * FovCellSize ..< min((gy + 1) * FovCellSize, MapHeight):
        for px in gx * FovCellSize ..< min((gx + 1) * FovCellSize, MapWidth):
          let index = mapIndex(px, py)
          inc pixels
          if sim.wallMask[index] or sim.objectMask[index]:
            inc walls
      sim.fovBlocked[fovCellIndex(gx, gy)] = walls * 2 >= pixels

proc splitmix64*(state: var uint64): uint64 =
  ## The seeded setup stream (§Integer arithmetic and determinism). One
  ## source, consumed in one fixed order before any seat connects.
  state += 0x9E3779B97F4A7C15'u64
  var z = state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc newSetupRng*(seed: int): Rand =
  ## Nim's `Rand` seeded through splitmix64, so the whole setup draw is a
  ## pure function of the episode seed on both targets.
  var state = cast[uint64](int64(seed))
  # `initRand` rejects 0 and takes a signed seed, so the 64-bit splitmix draw
  # is folded into the positive range rather than cast through it.
  let draw = splitmix64(state) and 0x7FFF_FFFF_FFFF_FFFF'u64
  initRand(int64(max(1'u64, draw)))
