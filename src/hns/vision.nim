## The line-of-sight engine: the recursive shadowcast, the cone/bubble filter
## and the per-cog visibility cache. THIS IS THE REASON coworld-ctf WAS THE
## STARTER - `castFovOctant`, `computeFovShadowcast`, `applyFovCone`,
## `refreshPlayerFov`, `fovVisibleAt`, `playerVisibleTo` and
## `lineOfSightClear` are forked from `src/ctf/sim.nim:2489-2718` with one
## named edit: `visionRange` is now `config.sightRange` (a real config field)
## instead of `gunRange * 3 div 2`, because the gun is deleted.
##
## `applyFovCone`'s floating-point cone filter is kept EXACTLY AS WRITTEN:
## it is already the mechanism the starter's own native<->wasm hash chain
## survives - the same expression, the same order, the same libm on both
## targets. What must never happen is a NEW float expression feeding a hashed
## value, which is why objects.nim / phase.nim / fort.nim / motion.nim are
## integer-only and this file's float block is whitelisted by name in
## `tests/test_hns_determinism.nim`.

import
  std/math,
  sim_types, sim_state

proc castFovOctant(
  blocked: openArray[bool],
  visible: var seq[bool],
  originCx, originCy, row: int,
  startSlope, endSlope: float,
  xx, xy, yx, yy: int
) =
  ## Recursive shadowcasting over one octant of the fog-of-war grid
  ## (Bergstrom-style). Row distance is unbounded; scanning stops at the grid
  ## edge, so THIS pass is limited only by walls — the caller's cone/range
  ## filter applies the visionRange cutoff (GV34) afterwards.
  if startSlope < endSlope:
    return
  var
    start = startSlope
    rowBlocked = false
    newStart = 0.0
  let maxDist = FovGridW + FovGridH
  for dist in row .. maxDist:
    if rowBlocked:
      break
    var anyInside = false
    for dx in -dist .. 0:
      let
        dy = -dist
        lSlope = (float(dx) - 0.5) / (float(dy) + 0.5)
        rSlope = (float(dx) + 0.5) / (float(dy) - 0.5)
      if start < rSlope:
        continue
      if endSlope > lSlope:
        break
      let
        cx = originCx + dx * xx + dy * xy
        cy = originCy + dx * yx + dy * yy
      if cx < 0 or cy < 0 or cx >= FovGridW or cy >= FovGridH:
        continue
      anyInside = true
      let index = fovCellIndex(cx, cy)
      visible[index] = true
      if rowBlocked:
        if blocked[index]:
          newStart = rSlope
        else:
          rowBlocked = false
          start = newStart
      elif blocked[index]:
        rowBlocked = true
        castFovOctant(
          blocked,
          visible,
          originCx,
          originCy,
          dist + 1,
          start,
          lSlope,
          xx, xy, yx, yy
        )
        newStart = rSlope
    if not anyInside and dist > row:
      break


proc visionRange*(sim: SimServer): int =
  ## How far the vision CONE reaches, in px. The starter derived this from
  ## the gun; here it is a config field of its own (see the design note's
  ## Vision section), because the gun is deleted. The close-quarters bubble
  ## (visionBubble) is never shrunk by this cap.
  sim.config.sightRange

proc computeFovShadowcast*(
  sim: SimServer,
  originCx, originCy: int,
  visible: var seq[bool]
) =
  ## The aim-independent half of fog-of-war: recursive shadowcasting from
  ## the viewer's cell (walls block, unbounded by range). Cacheable per
  ## cell — this is the expensive pass.
  if visible.len != FovCellCount:
    visible.setLen(FovCellCount)
  zeroMem(addr visible[0], visible.len * sizeof(bool))
  visible[fovCellIndex(originCx, originCy)] = true
  const Octants = [
    (1, 0, 0, 1), (0, 1, 1, 0), (0, -1, 1, 0), (-1, 0, 0, 1),
    (-1, 0, 0, -1), (0, -1, -1, 0), (0, 1, -1, 0), (1, 0, 0, -1)
  ]
  for (xx, xy, yx, yy) in Octants:
    castFovOctant(
      sim.fovBlocked,
      visible,
      originCx,
      originCy,
      1,
      1.0,
      0.0,
      xx, xy, yx, yy
    )

proc applyFovCone*(
  sim: SimServer,
  originCx, originCy, aimBrads: int,
  shadowcast: seq[bool],
  visible: var seq[bool]
) =
  ## The aim-dependent half of fog-of-war: intersects a cached shadowcast
  ## with the forward vision cone (half-angle visionConeDeg around the aim
  ## angle, reaching visionRange px — 1.5x the gun range, GV34) plus the
  ## omnidirectional vision bubble (visionBubble px, exempt from the range
  ## cap).
  if visible.len != FovCellCount:
    visible.setLen(FovCellCount)
  copyMem(addr visible[0], unsafeAddr shadowcast[0],
    FovCellCount * sizeof(bool))
  let
    (ox, oy) = fovCellCenter(originCx, originCy)
    (ax, ay) = aimVector(aimBrads)
    coneCos = cos(float(sim.config.visionConeDeg) * PI / 180.0)
    bubbleSq = float(sim.config.visionBubble * sim.config.visionBubble)
    rangeSq = float(sim.visionRange() * sim.visionRange())
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      let index = fovCellIndex(cx, cy)
      if not visible[index]:
        continue
      let
        (px, py) = fovCellCenter(cx, cy)
        vx = float(px - ox)
        vy = float(py - oy)
        d2 = vx * vx + vy * vy
      if d2 <= bubbleSq:
        continue
      if d2 > rangeSq:
        visible[index] = false
        continue
      let dot = vx * ax + vy * ay
      if dot < coneCos * sqrt(d2):
        visible[index] = false

proc computeFovVisible*(
  sim: SimServer,
  originCx, originCy, aimBrads: int,
  visible: var seq[bool]
) =
  ## Computes one viewer's full fog-of-war cell visibility in one shot:
  ## shadowcast, then cone/range filter. Uncached path, kept for tools and
  ## probes; the server loop goes through refreshPlayerFov's two-level
  ## cache instead.
  var shadowcast = newSeq[bool](FovCellCount)
  sim.computeFovShadowcast(originCx, originCy, shadowcast)
  sim.applyFovCone(originCx, originCy, aimBrads, shadowcast, visible)

proc ensureFovCacheSlots(sim: var SimServer) =
  ## Keeps player-indexed fog-of-war cache storage aligned with players.
  while sim.fovCaches.len < sim.players.len:
    sim.fovCaches.add PlayerFov(
      valid: false,
      visible: newSeq[bool](FovCellCount)
    )
  if sim.fovCaches.len > sim.players.len:
    sim.fovCaches.setLen(sim.players.len)

proc refreshPlayerFov*(sim: var SimServer, playerIndex: int): bool =
  ## Refreshes one cog's cached fog-of-war grid and returns true when it was
  ## recomputed (the viewer moved to a new cell, turned, or the FURNITURE
  ## moved — the `geometryEpoch` term is this fork's one addition).
  sim.ensureFovCacheSlots()
  let
    player = sim.players[playerIndex]
    (cx, cy) = fovCellAt(
      player.x + CollisionW div 2,
      player.y + CollisionH div 2
    )
  template cache: untyped = sim.fovCaches[playerIndex]
  if cache.valid and
      cache.epoch == sim.geometryEpoch and
      cache.originCx == cx and
      cache.originCy == cy and
      cache.aimBrads == player.aimBrads:
    return false
  # Two-level refresh: the shadowcast only depends on the viewer's cell and
  # the geometry epoch, so a viewer who merely turned (cogs rotate aim nearly
  # every tick) reuses it and pays only the cone filter.
  if not (cache.cellValid and cache.cellCx == cx and cache.cellCy == cy and
      cache.epoch == sim.geometryEpoch):
    sim.computeFovShadowcast(cx, cy, cache.cellVisible)
    cache.cellValid = true
    cache.cellCx = cx
    cache.cellCy = cy
  sim.applyFovCone(cx, cy, player.aimBrads, cache.cellVisible, cache.visible)
  cache.valid = true
  cache.epoch = sim.geometryEpoch
  cache.originCx = cx
  cache.originCy = cy
  cache.aimBrads = player.aimBrads
  true

proc playerFov*(sim: SimServer, playerIndex: int): lent PlayerFov =
  ## Returns one player's cached fog-of-war grid (refreshPlayerFov first).
  sim.fovCaches[playerIndex]

proc fovVisibleAt*(sim: SimServer, playerIndex, x, y: int): bool =
  ## Returns whether one map point is inside a viewer's vision. Dead viewers
  ## have no eyes: everything is fogged until they respawn. Call
  ## refreshPlayerFov first.
  if not sim.players[playerIndex].alive:
    return false
  if playerIndex >= sim.fovCaches.len or not sim.fovCaches[playerIndex].valid:
    return true
  let (cx, cy) = fovCellAt(x, y)
  sim.fovCaches[playerIndex].visible[fovCellIndex(cx, cy)]


proc invalidateStaleFov*(sim: var SimServer) =
  ## Any cog whose cached cast predates the current `geometryEpoch` has a
  ## stale shadowcast: the furniture moved under it.
  for i in 0 ..< sim.fovCaches.len:
    if sim.fovCaches[i].epoch != sim.geometryEpoch:
      sim.fovCaches[i].valid = false
      sim.fovCaches[i].cellValid = false

proc lineOfSightClear*(sim: SimServer, ax, ay, bx, by: int): bool =
  ## True when a straight segment between two map points crosses no STATIC
  ## WALL. Furniture is deliberately ignored: this is the test an AIRBORNE
  ## target is judged by (its head is above the crates), which is what makes
  ## the vault the one dramatic act a spectator always gets to see.
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return not sim.isWall(ax, ay)
  for step in 0 .. steps:
    let
      px = ax + dx * step div steps
      py = ay + dy * step div steps
    if sim.isWall(px, py):
      return false
  true

proc playerVisibleTo*(sim: SimServer, viewerIndex, targetIndex: int): bool =
  ## Whether one cog is observable by a viewer. Enemies are fogged exactly as
  ## the starter fogs them; an AIRBORNE target is judged against the STATIC
  ## wall mask instead, because it is over the furniture (the documented
  ## divergence 4).
  if viewerIndex == targetIndex:
    return true
  let target = sim.players[targetIndex]
  if target.airborne:
    if not sim.players[viewerIndex].alive:
      return false
    let
      viewer = sim.players[viewerIndex]
      dist2 = distSq(viewer.x, viewer.y, target.x, target.y)
    if dist2 > sim.visionRange() * sim.visionRange():
      return false
    if dist2 > sim.config.visionBubble * sim.config.visionBubble:
      let
        (ax, ay) = aimVector(viewer.aimBrads)
        vx = float(target.x - viewer.x)
        vy = float(target.y - viewer.y)
        coneCos = cos(float(sim.config.visionConeDeg) * PI / 180.0)
      if vx * ax + vy * ay < coneCos * sqrt(vx * vx + vy * vy):
        return false
    return sim.lineOfSightClear(viewer.x, viewer.y, target.x, target.y)
  sim.fovVisibleAt(
    viewerIndex,
    target.x + CollisionW div 2,
    target.y + CollisionH div 2
  )
