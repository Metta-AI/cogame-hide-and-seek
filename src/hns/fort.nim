## The sealed-fort scan: a breadth-first fill over the 8 px fov grid from
## every seeker's current cell, blocked by static walls and by objects the
## HIDERS have locked. Unlocked objects are passable — a seeker can shove
## them, so a fort built out of unlocked crates is a ten-second delay, not a
## wall. Every hider whose cell the fill does not reach is `sealed`.
##
## Runs only at a turn boundary and at the release tick (not every tick):
## it is O(cells) and nothing about it changes inside a turn that a spectator
## or a policy can act on.
##
## INTEGER ONLY (`tests/test_hns_determinism.nim`).

import
  sim_types, sim_state

proc hiderLockedMask(sim: SimServer): seq[bool] =
  ## The fov-grid cells a hider-locked object makes impassable, on the same
  ## half-a-cell rule `buildFovBlocked` uses, so the scan and the renderer
  ## agree about what counts as a wall.
  result = newSeq[bool](FovCellCount)
  for obj in sim.objects:
    if obj.lockedBy != lockHiders:
      continue
    let
      gx0 = clamp(obj.x div FovCellSize, 0, FovGridW - 1)
      gy0 = clamp(obj.y div FovCellSize, 0, FovGridH - 1)
      gx1 = clamp((obj.x + obj.w - 1) div FovCellSize, 0, FovGridW - 1)
      gy1 = clamp((obj.y + obj.h - 1) div FovCellSize, 0, FovGridH - 1)
    for gy in gy0 .. gy1:
      for gx in gx0 .. gx1:
        result[fovCellIndex(gx, gy)] = true

proc wallCellMask(sim: SimServer): seq[bool] =
  ## Static walls only, downsampled the same way.
  result = newSeq[bool](FovCellCount)
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      var
        walls = 0
        pixels = 0
      for py in cy * FovCellSize ..< min((cy + 1) * FovCellSize, MapHeight):
        for px in cx * FovCellSize ..< min((cx + 1) * FovCellSize, MapWidth):
          inc pixels
          if sim.wallMask[mapIndex(px, py)]:
            inc walls
      result[fovCellIndex(cx, cy)] = walls * 2 >= pixels

proc scanSealed*(sim: var SimServer):
    tuple[sealed, unsealed: seq[int]] =
  ## Tick step 11. Returns the hiders whose sealed state CHANGED, and
  ## updates `Player.sealed`, `Player.sealedTicks` and `sim.sealedMask`.
  let
    blocked = sim.wallCellMask()
    locked = sim.hiderLockedMask()
  var
    reached = newSeq[bool](FovCellCount)
    queue: seq[int] = @[]
  for slot in 0 ..< sim.players.len:
    if sim.players[slot].team != Blue or not sim.players[slot].alive:
      continue
    let (cx, cy) = fovCellAt(sim.players[slot].x, sim.players[slot].y)
    let index = fovCellIndex(cx, cy)
    if not reached[index]:
      reached[index] = true
      queue.add(index)
  var head = 0
  while head < queue.len:
    let
      index = queue[head]
      cx = index mod FovGridW
      cy = index div FovGridW
    inc head
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= FovGridW or ny >= FovGridH:
        continue
      let next = fovCellIndex(nx, ny)
      if reached[next] or blocked[next] or locked[next]:
        continue
      reached[next] = true
      queue.add(next)
  var mask = 0'u64
  for slot in 0 ..< sim.players.len:
    if sim.players[slot].team != Red:
      continue
    let
      (cx, cy) = fovCellAt(sim.players[slot].x, sim.players[slot].y)
      isSealed = not reached[fovCellIndex(cx, cy)]
    if isSealed and not sim.players[slot].sealed:
      result.sealed.add(slot)
    elif not isSealed and sim.players[slot].sealed:
      result.unsealed.add(slot)
    sim.players[slot].sealed = isSealed
    if isSealed and slot < 64:
      mask = mask or (1'u64 shl slot)
  sim.sealedMask = mask

proc accrueSealedTicks*(sim: var SimServer) =
  ## Per hider, `sealedTicks` accumulates the hunt ticks it spent sealed.
  for slot in 0 ..< sim.players.len:
    if sim.players[slot].team == Red and sim.players[slot].sealed:
      inc sim.players[slot].sealedTicks

proc sealedCount*(sim: SimServer): int =
  for player in sim.players:
    if player.team == Red and player.sealed:
      inc result
