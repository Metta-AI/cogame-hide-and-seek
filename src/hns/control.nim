## The control layer: the ONE deterministic function that turns an order into
## per-tick Sprite v1 actuator masks.
##
## Both LLM orders and scripted orders are compiled by this same code, so the
## two policy kinds are strictly comparable and a scripted baseline is legal
## by construction. It is a pure function of
## `(sim state, order, slot) -> uint8`.
##
## It sits OUTSIDE the determinism boundary: the server records the masks this
## produces into the replay, and the wasm viewer feeds those recorded masks to
## the identical sim. Nothing here is re-run at playback, which is why this
## module may use ordinary floating-point navigation maths where the hashed
## object layer may not.
##
## Kept VERBATIM from coworld-ctf's `src/ctf/control.nim`: the NavCell = 12 nav
## grid, `buildNavGrid`, `computeField`, `fieldFor` with FieldRefreshTicks and
## MaxCachedFields, `navSteer`, `ArriveRadius`, `AimDeadBrads`, `bradsErr`, the
## StuckTicks obstacle slide, and `observeEnemies` / `knownEnemy` with
## HuntMemoryTicks. TWO CHANGES: the nav grid is rebuilt when `geometryEpoch`
## changes (at most once per FieldRefreshTicks, and the cached fields go with
## it), and it is built over `wallMask or objectMask` so a cog paths AROUND
## furniture, including furniture it cannot move.

import
  std/[math, tables],
  bitworld/spriteprotocol,
  sim, directives

const
  NavCell* = 12               ## nav grid cell side, in px. At 12 px every
                              ## 56 px doorway contains a cell centre with the
                              ## full 13 px footprint's clearance.
  FieldRefreshTicks* = 12     ## a flow field is recomputed at most this often.
  MaxCachedFields* = 64       ## flow fields kept before the cache is dropped.
  ArriveRadius* = 20          ## px: a cog this close to its goal stops moving.
  AimMinRangeSq* = 16 * 16    ## an aim target nearer than this gives a vector
                              ## too short to mean a direction.
  AimDeadBrads* = 4           ## no turn button inside this error.
  StuckTicks* = 8             ## ticks of zero displacement after which a cog
                              ## steers along the obstacle instead of into it.
  WatchSweepBrads* = 32       ## `watch` oscillates this far either side of its
                              ## bearing, so a standing cog still searches.
  StandoffPx* = 18            ## how far off an object's face the driver parks
                              ## before it reaches for it.
  PushGiveUpTicks* = 120      ## ticks of zero object displacement before a
                              ## push gives up and releases.

type
  NavGrid* = object
    w*, h*: int
    open*: seq[bool]

  ControlState* = object
    ## Everything the control layer remembers between ticks. Lives on the
    ## SERVER, never on the sim, so it can never enter gameHash.
    grid*: NavGrid
    gridEpoch*: int                    ## geometryEpoch the grid was built at.
    gridTick*: int                     ## tick the grid was last rebuilt.
    fields*: Table[int, seq[int]]      ## goal cell -> BFS distance field
    fieldTick*: Table[int, int]        ## goal cell -> tick it was built
    lastSeenX*, lastSeenY*: seq[int]   ## per cog: last known enemy position
    lastSeenTick*: seq[int]
    lastSeenIndex*: seq[int]
    lastX*, lastY*: seq[int]           ## per cog: position at the last observe
    stuckTicks*: seq[int]              ## per cog: consecutive motionless ticks
    pushTicks*: seq[int]               ## per cog: ticks a push has made no
                                       ## object progress
    pushX*, pushY*: seq[int]           ## per cog: held object position at the
                                       ## last observe
    sweep*: seq[int]                   ## per cog: the `watch` sweep phase

proc navCellOf*(grid: NavGrid, x, y: int): int =
  ## The flat nav cell containing a map pixel, or -1 off the grid.
  let
    cx = x div NavCell
    cy = y div NavCell
  if x < 0 or y < 0 or cx >= grid.w or cy >= grid.h:
    return -1
  cy * grid.w + cx

proc navCentre*(grid: NavGrid, cell: int): tuple[x, y: int] =
  ((cell mod grid.w) * NavCell + NavCell div 2,
   (cell div grid.w) * NavCell + NavCell div 2)

proc buildNavGrid*(sim: SimServer): NavGrid =
  ## A NavCell-px occupancy grid over the sim's REAL masks (not an observation
  ## stream): a cell is open when a cog footprint fits at its centre, clear of
  ## both the static walls and the FURNITURE. Rebuilt when `geometryEpoch`
  ## moves — this fork's one change to the starter's grid.
  result.w = (MapWidth + NavCell - 1) div NavCell
  result.h = (MapHeight + NavCell - 1) div NavCell
  result.open = newSeq[bool](result.w * result.h)
  for cell in 0 ..< result.open.len:
    let (cx, cy) = result.navCentre(cell)
    if cx < MapWidth and cy < MapHeight:
      result.open[cell] = sim.canOccupy(cx, cy)

proc nearestOpenCell*(grid: NavGrid, x, y: int): int =
  ## The open cell nearest a map point, by expanding ring search. -1 only
  ## when the grid has no open cell at all.
  let start = grid.navCellOf(clamp(x, 0, MapWidth - 1), clamp(y, 0, MapHeight - 1))
  if start >= 0 and grid.open[start]:
    return start
  let
    sx = clamp(x, 0, MapWidth - 1) div NavCell
    sy = clamp(y, 0, MapHeight - 1) div NavCell
  for r in 1 .. (grid.w + grid.h):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          cx = sx + dx
          cy = sy + dy
        if cx < 0 or cy < 0 or cx >= grid.w or cy >= grid.h:
          continue
        let cell = cy * grid.w + cx
        if grid.open[cell]:
          return cell
  -1

proc computeField*(grid: NavGrid, goal: int): seq[int] =
  ## Breadth-first flow field to `goal` over 4-connected open cells: the
  ## number of steps from every cell to the goal, -1 where unreachable.
  result = newSeq[int](grid.open.len)
  for i in 0 ..< result.len:
    result[i] = -1
  if goal < 0 or goal >= result.len or not grid.open[goal]:
    return
  var
    queue = @[goal]
    head = 0
  result[goal] = 0
  while head < queue.len:
    let
      cell = queue[head]
      cx = cell mod grid.w
      cy = cell div grid.w
      d = result[cell]
    inc head
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= grid.w or ny >= grid.h:
        continue
      let next = ny * grid.w + nx
      if not grid.open[next] or result[next] >= 0:
        continue
      result[next] = d + 1
      queue.add(next)

proc fieldFor*(ctl: var ControlState, tick, goal: int): seq[int] =
  ## The cached flow field for one goal cell, rebuilt at most once every
  ## FieldRefreshTicks. Cheap enough that eight cogs chasing eight distinct
  ## goals still costs a handful of BFS passes per second.
  if goal < 0:
    return @[]
  if ctl.fields.hasKey(goal) and
      tick - ctl.fieldTick.getOrDefault(goal, low(int) div 2) < FieldRefreshTicks:
    return ctl.fields[goal]
  if ctl.fields.len >= MaxCachedFields and not ctl.fields.hasKey(goal):
    ctl.fields.clear()
    ctl.fieldTick.clear()
  let field = computeField(ctl.grid, goal)
  ctl.fields[goal] = field
  ctl.fieldTick[goal] = tick
  field

proc navSteer*(
  ctl: var ControlState, tick, fromX, fromY, goalX, goalY: int
): tuple[dx, dy: int] =
  ## The steering vector for one cog: straight at the goal when the line of
  ## sight is clear (so a cog does not stair-step around an open floor), else
  ## down the flow field toward the neighbouring cell nearest the goal.
  let goalCell = ctl.grid.nearestOpenCell(goalX, goalY)
  if goalCell < 0:
    return (0, 0)
  let (gx, gy) = ctl.grid.navCentre(goalCell)
  let field = ctl.fieldFor(tick, goalCell)
  let here = ctl.grid.nearestOpenCell(fromX, fromY)
  if here < 0 or field.len == 0 or field[here] <= 1:
    return (gx - fromX, gy - fromY)
  let
    cx = here mod ctl.grid.w
    cy = here div ctl.grid.w
  var
    best = field[here]
    bestCell = -1
  for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]:
    let
      nx = cx + dx
      ny = cy + dy
    if nx < 0 or ny < 0 or nx >= ctl.grid.w or ny >= ctl.grid.h:
      continue
    let next = ny * ctl.grid.w + nx
    if not ctl.grid.open[next] or field[next] < 0:
      continue
    if dx != 0 and dy != 0:
      # No corner cutting: a diagonal is only taken when both of the cells it
      # squeezes between are open. A cell is barely wider than a cog, so
      # clipping the corner of an obstacle wedges the cog against it and it
      # presses the same direction forever.
      if not ctl.grid.open[cy * ctl.grid.w + nx] or
          not ctl.grid.open[ny * ctl.grid.w + cx]:
        continue
    if field[next] < best:
      best = field[next]
      bestCell = next
  if bestCell < 0:
    return (gx - fromX, gy - fromY)
  let (nxp, nyp) = ctl.grid.navCentre(bestCell)
  (nxp - fromX, nyp - fromY)

proc bradsErr*(desired, current: int): int =
  ## Signed shortest turn from `current` to `desired`, in brads: positive is
  ## counter-clockwise (button B), negative clockwise (button Select).
  var d = (desired - current) mod AimBradsTurn
  if d < -(AimBradsTurn div 2): d += AimBradsTurn
  if d > AimBradsTurn div 2: d -= AimBradsTurn
  d

proc initControlState*(sim: SimServer): ControlState =
  result.grid = buildNavGrid(sim)
  result.gridEpoch = sim.geometryEpoch
  result.gridTick = sim.tickCount
  result.fields = initTable[int, seq[int]]()
  result.fieldTick = initTable[int, int]()
  result.lastSeenX = newSeq[int](MaxPlayers)
  result.lastSeenY = newSeq[int](MaxPlayers)
  result.lastSeenTick = newSeq[int](MaxPlayers)
  result.lastSeenIndex = newSeq[int](MaxPlayers)
  result.lastX = newSeq[int](MaxPlayers)
  result.lastY = newSeq[int](MaxPlayers)
  result.stuckTicks = newSeq[int](MaxPlayers)
  result.pushTicks = newSeq[int](MaxPlayers)
  result.pushX = newSeq[int](MaxPlayers)
  result.pushY = newSeq[int](MaxPlayers)
  result.sweep = newSeq[int](MaxPlayers)
  for i in 0 ..< MaxPlayers:
    result.lastSeenTick[i] = low(int) div 2
    result.lastSeenIndex[i] = -1
    result.lastX[i] = low(int) div 2
    result.lastY[i] = low(int) div 2
    result.pushX[i] = low(int) div 2
    result.pushY[i] = low(int) div 2

proc refreshNavGrid*(ctl: var ControlState, sim: SimServer) =
  ## The furniture moved: rebuild the grid and drop every cached field with
  ## it. Rate-limited to FieldRefreshTicks so a cog dragging a crate across
  ## the room does not rebuild five thousand cells every tick.
  if ctl.gridEpoch == sim.geometryEpoch:
    return
  if sim.tickCount - ctl.gridTick < FieldRefreshTicks:
    return
  ctl.grid = buildNavGrid(sim)
  ctl.gridEpoch = sim.geometryEpoch
  ctl.gridTick = sim.tickCount
  ctl.fields.clear()
  ctl.fieldTick.clear()

proc observeEnemies*(ctl: var ControlState, sim: SimServer) =
  ## The control layer's ONCE-PER-TICK observation: each cog's memory of the
  ## nearest enemy it can currently see, and whether it is making progress.
  ## Vision is the sim's own fog rule, so the control layer never knows more
  ## than the cog does.
  ##
  ## Both are updated here rather than in `compileMask` so that compiling a
  ## mask stays a pure read of this state: the same (state, directive) pair
  ## yields the same byte however many times it is asked.
  while ctl.lastSeenX.len < sim.players.len:
    ctl.lastSeenX.add(0)
    ctl.lastSeenY.add(0)
    ctl.lastSeenTick.add(low(int) div 2)
    ctl.lastSeenIndex.add(-1)
  while ctl.lastX.len < sim.players.len:
    ctl.lastX.add(low(int) div 2)
    ctl.lastY.add(low(int) div 2)
    ctl.stuckTicks.add(0)
  ctl.refreshNavGrid(sim)
  while ctl.pushTicks.len < sim.players.len:
    ctl.pushTicks.add(0)
    ctl.pushX.add(low(int) div 2)
    ctl.pushY.add(low(int) div 2)
    ctl.sweep.add(0)
  for i in 0 ..< sim.players.len:
    let held = sim.players[i].holding
    if held >= 0 and held < sim.objects.len:
      if sim.objects[held].x == ctl.pushX[i] and
          sim.objects[held].y == ctl.pushY[i]:
        inc ctl.pushTicks[i]
      else:
        ctl.pushTicks[i] = 0
      ctl.pushX[i] = sim.objects[held].x
      ctl.pushY[i] = sim.objects[held].y
    else:
      ctl.pushTicks[i] = 0
    inc ctl.sweep[i]
    if sim.players[i].x == ctl.lastX[i] and sim.players[i].y == ctl.lastY[i]:
      inc ctl.stuckTicks[i]
    else:
      ctl.stuckTicks[i] = 0
    ctl.lastX[i] = sim.players[i].x
    ctl.lastY[i] = sim.players[i].y
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    var
      bestDist = high(int)
      bestIndex = -1
    for j in 0 ..< sim.players.len:
      if j == i or not sim.players[j].alive:
        continue
      if sim.players[j].team == sim.players[i].team:
        continue
      if not sim.playerVisibleTo(i, j):
        continue
      let d = distSq(sim.players[i].x, sim.players[i].y,
                     sim.players[j].x, sim.players[j].y)
      if d < bestDist:
        bestDist = d
        bestIndex = j
    if bestIndex >= 0:
      ctl.lastSeenX[i] = sim.players[bestIndex].x
      ctl.lastSeenY[i] = sim.players[bestIndex].y
      ctl.lastSeenTick[i] = sim.tickCount
      ctl.lastSeenIndex[i] = bestIndex

proc knownEnemy*(
  ctl: ControlState, sim: SimServer, cogIndex: int
): tuple[known: bool, x, y, index, ticksAgo: int] =
  ## The nearest enemy this cog knows about — seen now, or seen within
  ## HuntMemoryTicks. That memory is intel a commander legitimately has.
  if cogIndex >= ctl.lastSeenTick.len:
    return (false, 0, 0, -1, 0)
  let age = sim.tickCount - ctl.lastSeenTick[cogIndex]
  if age > HuntMemoryTicks or ctl.lastSeenIndex[cogIndex] < 0:
    return (false, 0, 0, -1, 0)

# ---------------------------------------------------------------------------
# The driver: what each intent does, and how it finishes.
# ---------------------------------------------------------------------------

proc objectIndexOf*(sim: SimServer, order: Order): int =
  if order.obj.len == 0:
    return -1
  sim.objectIndexById(order.obj)

proc orderPoint*(sim: SimServer, order: Order, fallbackX, fallbackY: int):
    tuple[x, y: int] =
  ## `at` WINS over `to` (the reply schema's rule). An unresolvable `at`
  ## falls through to `to`, and a missing `to` to the caller's fallback.
  if order.at.len > 0:
    let hit = sim.gameMap.resolvePoint(order.at)
    if hit.ok:
      return (hit.x, hit.y)
  if order.hasTo:
    return (order.toX, order.toY)
  (fallbackX, fallbackY)

proc standoffFor(sim: SimServer, index, fromX, fromY: int):
    tuple[x, y: int] =
  ## The point 18 px off the centre of the object's face nearest the cog.
  let
    obj = sim.objects[index]
    cx = obj.x + obj.w div 2
    cy = obj.y + obj.h div 2
  var
    dx = fromX - cx
    dy = fromY - cy
  if abs(dx) * obj.h >= abs(dy) * obj.w:
    let side = if dx >= 0: 1 else: -1
    (cx + side * (obj.w div 2 + StandoffPx + PlayerHalf), cy)
  else:
    let side = if dy >= 0: 1 else: -1
    (cx, cy + side * (obj.h div 2 + StandoffPx + PlayerHalf))

proc nearestDoorOf(sim: SimServer, x, y: int): tuple[x, y: int, ok: bool] =
  var
    best = -1
    bestDist = high(int)
  for i, door in sim.gameMap.doors:
    let d = distSq(x, y, door.x, door.y)
    if d < bestDist:
      bestDist = d
      best = i
  if best < 0:
    return (0, 0, false)
  (sim.gameMap.doors[best].x, sim.gameMap.doors[best].y, true)

proc goalFor*(
  ctl: ControlState, sim: SimServer, order: Order, slot: int
): tuple[x, y: int] =
  ## The goal point one intent resolves to. EVERY branch has a defined
  ## answer, so a cog is never left without somewhere to be — an unreachable
  ## target degrades to standing still and watching, which is a legal mask.
  let
    player = sim.players[slot]
    px = player.x + CollisionW div 2
    py = player.y + CollisionH div 2
    index = sim.objectIndexOf(order)
  case order.intent
  of intMoveTo, intHide:
    sim.orderPoint(order, px, py)
  of intWatch:
    (px, py)
  of intChase:
    let enemy = ctl.knownEnemy(sim, slot)
    if enemy.known: (enemy.x, enemy.y) else: (px, py)
  of intPush:
    if index < 0:
      (px, py)
    elif player.holding == index:
      # Stage (c): nav so the OBJECT's centre reaches the target, so the goal
      # is offset by the cog's grip on it.
      let
        obj = sim.objects[index]
        ocx = obj.x + obj.w div 2
        ocy = obj.y + obj.h div 2
        want = sim.orderPoint(order, ocx, ocy)
      (px + want.x - ocx, py + want.y - ocy)
    else:
      standoffFor(sim, index, px, py)
  of intLock, intUnlock:
    if index < 0: (px, py) else: standoffFor(sim, index, px, py)
  of intVault:
    if index < 0:
      (px, py)
    else:
      # The ramp's FOOT: the far side from where the vault will launch.
      let
        obj = sim.objects[index]
        cx = obj.x + obj.w div 2
        cy = obj.y + obj.h div 2
      if obj.axis == axH:
        (cx - obj.w div 2 - StandoffPx, cy)
      else:
        (cx, cy + obj.h div 2 + StandoffPx)

proc compileMask*(
  ctl: var ControlState,
  sim: SimServer,
  order: Order,
  slot: int
): uint8 =
  ## One cog's Sprite v1 actuator mask for this tick.
  ##
  ## Legality is STRUCTURAL, not checked afterwards: Up and Down are chosen
  ## from one sign so they can never both be set (same for Left/Right), B and
  ## Select come from one signed error, A is never pressed while
  ## `lockCooldown > 0`, and bit 7 (C) is held only while a push wants it.
  result = 0
  if slot < 0 or slot >= sim.players.len:
    return
  let player = sim.players[slot]
  if not player.alive or player.airborne:
    return
  let
    px = player.x + CollisionW div 2
    py = player.y + CollisionH div 2
    index = sim.objectIndexOf(order)
    goal = ctl.goalFor(sim, order, slot)
    holding = player.holding

  # --- d-pad ---
  var wantsMove = distSq(px, py, goal.x, goal.y) > ArriveRadius * ArriveRadius
  if order.intent == intWatch:
    wantsMove = false
  if order.intent == intVault and index >= 0 and
      sim.objectAt(px, py) == index:
    # Stage (b) of the vault: on the ramp, drive along its axis at full speed
    # until the launch triggers.
    let
      obj = sim.objects[index]
      brads = rampHeadBrads(obj, px, py)
      unit = AimUnit[brads]
    if unit.x > AimUnitScale div 4: result = result or ButtonRight
    elif unit.x < -AimUnitScale div 4: result = result or ButtonLeft
    if unit.y > AimUnitScale div 4: result = result or ButtonDown
    elif unit.y < -AimUnitScale div 4: result = result or ButtonUp
    wantsMove = false
  if wantsMove:
    var steer = ctl.navSteer(sim.tickCount, px, py, goal.x, goal.y)
    if slot < ctl.stuckTicks.len and ctl.stuckTicks[slot] >= StuckTicks:
      # Wedged: steer a quarter turn clockwise instead, which slides the cog
      # ALONG whatever it is pressed against. One consistent rotation makes
      # this a wall follower, so a convex obstacle is always escaped rather
      # than oscillated against.
      steer = (dx: -steer.dy, dy: steer.dx)
    let
      ax = abs(steer.dx)
      ay = abs(steer.dy)
      major = max(ax, ay)
    if major > 0:
      if ax * 5 >= major * 2:
        result = result or (if steer.dx > 0: ButtonRight else: ButtonLeft)
      if ay * 5 >= major * 2:
        result = result or (if steer.dy > 0: ButtonDown else: ButtonUp)

  # --- aim ---
  var
    aimX = goal.x
    aimY = goal.y
  if order.hasFace:
    aimX = order.faceX
    aimY = order.faceY
  elif index >= 0 and holding != index and
      order.intent in {intPush, intLock, intUnlock, intVault}:
    # Stage (b) of a push and the approach of a lock: point AT the object, so
    # the grab probe and the lock reach both find it.
    aimX = sim.objects[index].x + sim.objects[index].w div 2
    aimY = sim.objects[index].y + sim.objects[index].h div 2
  elif order.intent == intWatch:
    let point = sim.orderPoint(order, px + 64, py)
    let sweep =
      if slot < ctl.sweep.len:
        # Oscillate +/- WatchSweepBrads around the bearing, so a standing cog
        # still searches instead of staring at one pixel.
        let phase = (ctl.sweep[slot] div 24) mod 4
        case phase
        of 0: 0
        of 1: WatchSweepBrads
        of 2: 0
        else: -WatchSweepBrads
      else: 0
    let base = bradsOfVector(point.x - px, point.y - py)
    let dir = aimVector(((base + sweep) mod AimBradsTurn + AimBradsTurn) mod
      AimBradsTurn)
    aimX = px + int(dir.x * 128.0)
    aimY = py + int(dir.y * 128.0)
  elif order.intent == intHide and
      distSq(px, py, goal.x, goal.y) <= ArriveRadius * ArriveRadius:
    # Arrived and hiding: face the nearest door of the region it stands in.
    let door = sim.nearestDoorOf(px, py)
    if door.ok:
      aimX = door.x
      aimY = door.y
  elif order.intent == intChase:
    let enemy = ctl.knownEnemy(sim, slot)
    if enemy.known:
      aimX = enemy.x
      aimY = enemy.y
  if distSq(px, py, aimX, aimY) <= AimMinRangeSq:
    aimX = px + MapWidth div 2
    aimY = py
  let
    desired = bradsOfVector(aimX - px, aimY - py)
    err = bradsErr(desired, player.aimBrads)
  if err > AimDeadBrads:
    result = result or ButtonB          ## counter-clockwise
  elif err < -AimDeadBrads:
    result = result or ButtonSelect     ## clockwise

  # --- C: hold to grab, release to drop ---
  if order.intent == intPush and index >= 0:
    let giveUp = slot < ctl.pushTicks.len and
      ctl.pushTicks[slot] >= PushGiveUpTicks
    if holding == index:
      let
        obj = sim.objects[index]
        ocx = obj.x + obj.w div 2
        ocy = obj.y + obj.h div 2
        want = sim.orderPoint(order, ocx, ocy)
      if not giveUp and
          distSq(ocx, ocy, want.x, want.y) > ArriveRadius * ArriveRadius:
        result = result or ButtonC
    elif holding < 0 and sim.mayTouch(slot, index) and
        sim.objects[index].heldBy < 0 and not giveUp:
      let
        obj = sim.objects[index]
        ocx = obj.x + obj.w div 2
        ocy = obj.y + obj.h div 2
        want = sim.orderPoint(order, ocx, ocy)
      # Two guards, both learned the hard way:
      #
      # DONE IS DONE — reaching for an object that is already where the order
      # wanted it makes the driver grab it and drop it on alternate ticks
      # forever.
      #
      # ONLY REACH FOR THE THING YOU WERE TOLD TO — the sim's probe binds the
      # FIRST object along the aim, so pressing C merely because the ordered
      # object is nearby grabs whatever is actually in front of the cog, the
      # `holding != index` branch drops it on the next tick, and the pair
      # oscillates at 12 Hz. Asking the probe first makes the press mean
      # exactly what the order said.
      if distSq(ocx, ocy, want.x, want.y) > ArriveRadius * ArriveRadius and
          sim.grabProbe(slot) == index:
        result = result or ButtonC
  elif holding >= 0:
    # Any other intent lets go of whatever it is dragging.
    discard

  # --- A: the lock toggle ---
  if order.intent in {intLock, intUnlock} and index >= 0 and
      player.lockCooldown == 0:
    let obj = sim.objects[index]
    var dx = 0
    var dy = 0
    if px < obj.x: dx = obj.x - px
    elif px >= obj.x + obj.w: dx = px - (obj.x + obj.w - 1)
    if py < obj.y: dy = obj.y - py
    elif py >= obj.y + obj.h: dy = py - (obj.y + obj.h - 1)
    if dx * dx + dy * dy <= sim.config.lockReach * sim.config.lockReach:
      let mine = lockOwnerFor(player.team)
      let wantsToggle =
        (order.intent == intLock and obj.lockedBy == lockNone) or
        (order.intent == intUnlock and obj.lockedBy == mine)
      if wantsToggle:
        result = result or ButtonA
