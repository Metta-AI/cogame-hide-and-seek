## The object layer: the table of crates, panels and ramps, the seeded deal,
## the dirty-rect `objectMask` rasterisation, the grab probe, the lock rules,
## the keep-clear discs around the seeker pads and the vault geometry.
##
## This module is INTEGER ONLY. `tests/test_hns_determinism.nim` greps it (and
## phase.nim, fort.nim, motion.nim) for float literals, `/` and `sqrt` and
## requires none: everything here feeds `gameHash`, and a new float
## expression is exactly how a native/wasm hash chain diverges. Headings come
## from `AimUnit`, the compile-time integer table in sim_types.nim.

import
  std/random,
  sim_types, room, sim_state

proc objectSize*(kind: ObjectKind, axis: ObjectAxis): tuple[w, h: int] =
  case kind
  of okCrate: (CrateSize, CrateSize)
  of okPanel:
    if axis == axH: (PanelLong, PanelShort) else: (PanelShort, PanelLong)
  of okRamp:
    if axis == axH: (RampLong, RampShort) else: (RampShort, RampLong)

proc objectRect*(obj: GameObject): MapRect {.inline.} =
  MapRect(x: obj.x, y: obj.y, w: obj.w, h: obj.h)

proc objectCenter*(obj: GameObject): tuple[x, y: int] {.inline.} =
  (obj.x + obj.w div 2, obj.y + obj.h div 2)

proc objectIndexById*(sim: SimServer, id: string): int =
  for i, obj in sim.objects:
    if obj.id == id:
      return i
  -1

proc objectAt*(sim: SimServer, x, y: int): int =
  ## Index of the object covering this pixel, or -1.
  for i, obj in sim.objects:
    if inRect(x, y, objectRect(obj)):
      return i
  -1

proc rectsOverlap(a, b: MapRect): bool {.inline.} =
  a.x < b.x + b.w and b.x < a.x + a.w and
    a.y < b.y + b.h and b.y < a.y + a.h

proc rectDistSq(rect: MapRect, px, py: int): int =
  ## Squared distance from a point to the nearest pixel of a rectangle.
  ## Integer only, so the keep-clear test is bit-exact on both targets.
  var
    dx = 0
    dy = 0
  if px < rect.x:
    dx = rect.x - px
  elif px >= rect.x + rect.w:
    dx = px - (rect.x + rect.w - 1)
  if py < rect.y:
    dy = rect.y - py
  elif py >= rect.y + rect.h:
    dy = py - (rect.y + rect.h - 1)
  dx * dx + dy * dy

proc rectInsideBoard(rect: MapRect): bool {.inline.} =
  rect.x >= 0 and rect.y >= 0 and
    rect.x + rect.w <= MapWidth and rect.y + rect.h <= MapHeight

proc rectHitsWall(sim: SimServer, rect: MapRect): bool =
  if not rectInsideBoard(rect):
    return true
  for y in rect.y ..< rect.y + rect.h:
    for x in rect.x ..< rect.x + rect.w:
      if sim.wallMask[mapIndex(x, y)]:
        return true
  false

proc coversAnyPad*(sim: SimServer, rect: MapRect): bool =
  ## No object may be DEALT onto a spawn pad. The keep-clear discs below are
  ## a hunting rule that applies to the seeker pads only; this is a much
  ## weaker sanity rule that applies to both teams' pads, because a cog dealt
  ## inside a crate cannot move at all.
  for anchor in sim.gameMap.anchors:
    if anchor.kind != anchorPad:
      continue
    let body = MapRect(
      x: anchor.x - PlayerHalf - 2,
      y: anchor.y - PlayerHalf - 2,
      w: PlayerSolidSpan + 5,
      h: PlayerSolidSpan + 5
    )
    if rectsOverlap(rect, body):
      return true
  false

proc keepClearViolated*(sim: SimServer, rect: MapRect): bool =
  ## No object may be moved to within `keepClearPx` of a SEEKER PAD. Without
  ## this a hider trio can wall the seekers in during prep and win 1000
  ## permille with no game played; with it, sealing a fort is legal and
  ## sealing the door the seekers come out of is not.
  let limit = sim.config.keepClearPx * sim.config.keepClearPx
  for anchor in sim.gameMap.anchors:
    if anchor.kind != anchorPad or anchor.team != anchorSeekers:
      continue
    if rectDistSq(rect, anchor.x, anchor.y) < limit:
      return true
  false

proc stampObjectRect(sim: var SimServer, rect: MapRect, value: bool) =
  let
    x0 = max(rect.x, 0)
    y0 = max(rect.y, 0)
    x1 = min(rect.x + rect.w - 1, MapWidth - 1)
    y1 = min(rect.y + rect.h - 1, MapHeight - 1)
  for y in y0 .. y1:
    for x in x0 .. x1:
      sim.objectMask[mapIndex(x, y)] = value

proc rasterizeObjects*(sim: var SimServer) =
  ## Full rebuild of `objectMask` and the whole occlusion grid. Used at game
  ## start and by `tests/test_hns_vision.nim` as the reference the
  ## incremental path is compared against, cell for cell.
  sim.objectMask = newSeq[bool](MapWidth * MapHeight)
  for obj in sim.objects:
    sim.stampObjectRect(objectRect(obj), true)
  sim.fovBlocked = sim.buildFovBlocked()

proc invalidateFovCaches*(sim: var SimServer) =
  ## `geometryEpoch` moved, so every cached shadowcast is stale.
  for i in 0 ..< sim.fovCaches.len:
    sim.fovCaches[i].valid = false
    sim.fovCaches[i].cellValid = false

proc refreshObjectGeometry*(sim: var SimServer, oldRect, newRect: MapRect) =
  ## The dirty-rect rebuild of tick step 8: re-rasterise the UNION of an
  ## object's old and new rectangles, recompute the affected occlusion cells
  ## from wall OR object, and bump `geometryEpoch`, which invalidates every
  ## cog's cached shadowcast. Nothing outside the dirty rect is touched.
  let
    x0 = max(0, min(oldRect.x, newRect.x))
    y0 = max(0, min(oldRect.y, newRect.y))
    x1 = min(MapWidth, max(oldRect.x + oldRect.w, newRect.x + newRect.w))
    y1 = min(MapHeight, max(oldRect.y + oldRect.h, newRect.y + newRect.h))
  for y in y0 ..< y1:
    for x in x0 ..< x1:
      sim.objectMask[mapIndex(x, y)] = false
  for obj in sim.objects:
    let rect = objectRect(obj)
    if rect.x < x1 and x0 < rect.x + rect.w and
        rect.y < y1 and y0 < rect.y + rect.h:
      let
        cx0 = max(rect.x, x0)
        cy0 = max(rect.y, y0)
        cx1 = min(rect.x + rect.w - 1, x1 - 1)
        cy1 = min(rect.y + rect.h - 1, y1 - 1)
      for y in cy0 .. cy1:
        for x in cx0 .. cx1:
          sim.objectMask[mapIndex(x, y)] = true
  sim.refreshFovCells(x0, y0, x1, y1)
  inc sim.geometryEpoch
  sim.invalidateFovCaches()

# ---------------------------------------------------------------------------
# The seeded deal
# ---------------------------------------------------------------------------

proc objectIdFor(kind: ObjectKind, ordinal: int): string =
  case kind
  of okCrate: "box" & $ordinal
  of okPanel: "pan" & $ordinal
  of okRamp: "ramp" & $ordinal

proc dealObjects*(sim: var SimServer) =
  ## The deal is SEEDED, not authored: the room's `objectSpawns` are shuffled
  ## by the episode's `setupRng` and the first `crates` crate-capable,
  ## `panels` panel-capable and `ramps` ramp-capable candidates are taken in
  ## that fixed order, each object taking its candidate's axis. The SAME deal
  ## is used for both games of the episode — the two trios play the same room
  ## and the same furniture, which is what makes the swap a fair comparison.
  ##
  ## Drawn from `setupRng` BEFORE any seat connects, so nothing a seat does
  ## can shift it (the idea's integrity note).
  var order = newSeq[int](sim.gameMap.objectSpawns.len)
  for i in 0 ..< order.len:
    order[i] = i
  sim.setupRng.shuffle(order)
  sim.objects = @[]
  var taken = newSeq[bool](order.len)
  template take(takeKind: ObjectKind, count: int) =
    var placed = 0
    for slot in order:
      if placed >= count:
        break
      if taken[slot]:
        continue
      let spawn = sim.gameMap.objectSpawns[slot]
      let capable =
        case takeKind
        of okCrate: spawn.crate
        of okPanel: spawn.panel
        of okRamp: spawn.ramp
      if not capable:
        continue
      let size = objectSize(takeKind, spawn.axis)
      var obj = GameObject(
        id: objectIdFor(takeKind, placed + 1),
        kind: takeKind,
        axis: spawn.axis,
        x: spawn.x - size.w div 2,
        y: spawn.y - size.h div 2,
        w: size.w,
        h: size.h,
        lockedBy: lockNone,
        heldBy: -1
      )
      let rect = objectRect(obj)
      if sim.rectHitsWall(rect) or sim.keepClearViolated(rect) or
          sim.coversAnyPad(rect):
        continue
      var clashes = false
      for other in sim.objects:
        if rectsOverlap(rect, objectRect(other)):
          clashes = true
          break
      if clashes:
        continue
      obj.spawnX = obj.x
      obj.spawnY = obj.y
      taken[slot] = true
      sim.objects.add(obj)
      inc placed
  take(okCrate, sim.config.crates)
  take(okPanel, sim.config.panels)
  take(okRamp, sim.config.ramps)
  sim.rasterizeObjects()

proc resetObjectsToDeal*(sim: var SimServer) =
  ## Game 2 replays the SAME furniture from the SAME dealt positions.
  for i in 0 ..< sim.objects.len:
    sim.objects[i].x = sim.objects[i].spawnX
    sim.objects[i].y = sim.objects[i].spawnY
    sim.objects[i].lockedBy = lockNone
    sim.objects[i].heldBy = -1
  sim.rasterizeObjects()
  inc sim.geometryEpoch
  sim.invalidateFovCaches()

# ---------------------------------------------------------------------------
# Grab, lock, push
# ---------------------------------------------------------------------------

proc mayTouch*(sim: SimServer, slot, index: int): bool =
  ## An object locked by the OTHER team refuses every grab and every push.
  if index < 0 or index >= sim.objects.len:
    return false
  let obj = sim.objects[index]
  case obj.lockedBy
  of lockNone: true
  of lockHiders: sim.players[slot].team == Red
  of lockSeekers: sim.players[slot].team == Blue

proc grabProbe*(sim: SimServer, slot: int): int =
  ## The grab probe of tick step 4: a segment from the cog's centre along its
  ## AIM, from the body edge out to `grabReach`. Returns the FIRST object the
  ## segment meets — nothing beyond it — or -1.
  let
    player = sim.players[slot]
    unit = AimUnit[player.aimBrads and (AimBradsTurn - 1)]
  for step in PlayerHalf .. PlayerHalf + sim.config.grabReach:
    let
      px = player.x + unit.x * step div AimUnitScale
      py = player.y + unit.y * step div AimUnitScale
    let hit = sim.objectAt(px, py)
    if hit >= 0:
      return hit
  -1

proc nearestObjectWithin*(sim: SimServer, slot, reach: int): int =
  ## The object whose RECTANGLE is nearest the cog's centre and inside
  ## `reach`, or -1. Ties go to the lower index, so two cogs equidistant from
  ## two objects still resolve deterministically.
  let
    player = sim.players[slot]
    limit = reach * reach
  var
    best = -1
    bestDist = 0
  for i, obj in sim.objects:
    let dist = rectDistSq(objectRect(obj), player.x, player.y)
    if dist > limit:
      continue
    if best < 0 or dist < bestDist:
      best = i
      bestDist = dist
  best

proc canPlaceObject*(sim: SimServer, index: int, rect: MapRect,
                     holder: int): bool =
  ## True when this object may occupy this rectangle: inside the board, clear
  ## of every static wall, clear of every OTHER object, clear of every cog
  ## other than its holder, and outside every keep-clear disc.
  if sim.rectHitsWall(rect):
    return false
  for i, other in sim.objects:
    if i == index:
      continue
    if rectsOverlap(rect, objectRect(other)):
      return false
  for i, player in sim.players:
    if i == holder or not player.alive or player.airborne:
      continue
    let body = MapRect(
      x: player.x - PlayerHalf,
      y: player.y - PlayerHalf,
      w: PlayerSolidSpan + 1,
      h: PlayerSolidSpan + 1
    )
    if rectsOverlap(rect, body):
      return false
  if sim.keepClearViolated(rect):
    return false
  true

proc moveObject*(sim: var SimServer, index, dx, dy: int) =
  ## Translates one object and repairs the geometry through the dirty rect.
  let old = objectRect(sim.objects[index])
  sim.objects[index].x += dx
  sim.objects[index].y += dy
  sim.refreshObjectGeometry(old, objectRect(sim.objects[index]))

proc dropObject*(sim: var SimServer, slot: int) =
  ## Releases whatever this cog holds. Idempotent.
  let held = sim.players[slot].holding
  if held < 0:
    return
  if held < sim.objects.len and sim.objects[held].heldBy == slot:
    sim.objects[held].heldBy = -1
  sim.players[slot].holding = -1

proc lockedRamps*(sim: SimServer): int =
  for obj in sim.objects:
    if obj.kind == okRamp and obj.lockedBy != lockNone:
      inc result

proc lockedCount*(sim: SimServer, owner: LockOwner): int =
  for obj in sim.objects:
    if obj.lockedBy == owner:
      inc result

# ---------------------------------------------------------------------------
# The vault
# ---------------------------------------------------------------------------

proc rampHeadBrads*(obj: GameObject, fromX, fromY: int): int =
  ## Which way this ramp launches from where the cog stands: along the ramp's
  ## LONG axis, away from the cog. A ramp is the only object with a head.
  let centre = objectCenter(obj)
  if obj.axis == axH:
    if fromX <= centre.x: 0 else: 128
  else:
    if fromY <= centre.y: 192 else: 64

proc vaultSpanClear*(sim: SimServer, fromX, fromY, brads, span: int): bool =
  ## True when the FIRST blocking span (wall or object) beyond the ramp head
  ## is at most `span` px thick — i.e. there is somewhere to land within the
  ## vault's reach.
  let unit = AimUnit[brads and (AimBradsTurn - 1)]
  var
    entered = false
    thickness = 0
  for step in 1 .. span + VaultTicks * VaultSpeed:
    let
      px = fromX + unit.x * step div AimUnitScale
      py = fromY + unit.y * step div AimUnitScale
    if px < 0 or py < 0 or px >= MapWidth or py >= MapHeight:
      return false
    let blocked = sim.isWall(px, py) or sim.isObject(px, py)
    if blocked:
      entered = true
      inc thickness
      if thickness > span:
        return false
    elif entered:
      return true
  entered

proc vaultLanding*(sim: SimServer, fromX, fromY, brads: int):
    tuple[x, y: int, ok: bool] =
  ## The first position along the vault axis whose 12 px footprint is clear,
  ## inside the airborne distance. `ok = false` refunds the cog to the ramp's
  ## foot (`vault_failed`).
  let unit = AimUnit[brads and (AimBradsTurn - 1)]
  for step in countdown(VaultTicks * VaultSpeed, 1):
    let
      px = fromX + unit.x * step div AimUnitScale
      py = fromY + unit.y * step div AimUnitScale
    if sim.canOccupy(px, py):
      return (px, py, true)
  (fromX, fromY, false)
