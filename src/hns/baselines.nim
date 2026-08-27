## The two published scripted baselines.
##
## Both emit the SAME order object an LLM does, on the same 3.75 s cadence,
## through the same validator, which is what makes the bounded-orders test in
## `tests/test_hns_control.nim` meaningful. Both are pure functions of the
## world state, and both implement BOTH ROLES, because sides swap mid-episode.
## Neither ever emits `radio` or `notes`; `burrow` emits one shout per game,
## `scatter` none.
##
## `burrow` is load-bearing in three places: it is a certification player, the
## per-turn fallback when a seat's LLM call fails twice (the SAME proc —
## imported, never duplicated), and the default for a seat that registers with
## neither PLAYER_PROMPT nor PLAYER_SCRIPTED.

import
  std/strutils,
  sim, control, directives

type
  Baseline* = enum
    blBurrow = "burrow"
    blScatter = "scatter"

  BaselineParams* = object
    ## The six tunables of the two baselines. They are a parameter object
    ## rather than literals because they were CHOSEN by a grid sweep, not
    ## guessed: `tools/tune_baselines.nim` plays the head-to-head episode over
    ## a bounded matrix and prints the table, `tools/ci/baseline_tuning.json`
    ## records the sweep's pick, and `tests/test_hns_tuning.nim` asserts the
    ## shipped defaults still equal it.
    panelReach*: int      ## px: a panel this close is preferred to a crate.
    rampSweep*: int       ## px: a ramp this close to home gets dragged away.
    flinchRadius*: int    ## px: a known seeker this close moves a hider.
    chaseRadius*: int     ## px: a known hider this close is chased.
    pushGiveUpTicks*: int ## ticks of no object progress before a push stops.
    doorRotation*: int    ## how the three hiders split the doors of a region.

const DoorPlaceRadius* = 48
  ## px: how close an object's RECTANGLE must come to the door's centre to
  ## count as "placed in the gap". Measured on the RECTANGLE, not the centre,
  ## because a 128 px panel whose centre is 90 px from the door has its edge
  ## in the doorway — a centre test says it is nowhere near and the hider
  ## never locks the wall it just built.

const DefaultBaselineParams* = BaselineParams(
  panelReach: 200,
  rampSweep: 300,
  flinchRadius: 140,
  chaseRadius: 340,
  pushGiveUpTicks: 120,
  doorRotation: 1
)

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `burrow`: a seat that
  ## says nothing useful still plays the published default rather than
  ## sitting out.
  case text.strip().toLowerAscii()
  of "scatter": blScatter
  else: blBurrow

proc regionOfSlot(sim: SimServer, slot: int): int =
  let index = sim.gameMap.regionAt(sim.players[slot].x, sim.players[slot].y)
  if index >= 0: index else: 0

proc homeRegion(sim: SimServer, slot: int): int =
  ## `home` = the region containing this cog's spawn pad, or, if that region
  ## holds a seeker pad, the nearest region that does not.
  var index = sim.gameMap.regionAt(
    sim.players[slot].homeX, sim.players[slot].homeY)
  if index < 0:
    index = sim.regionOfSlot(slot)
  if index < 0 or index >= sim.gameMap.regions.len:
    return 0
  var holdsPad = false
  for anchor in sim.gameMap.anchors:
    if anchor.kind == anchorPad and anchor.team == anchorSeekers and
        inRect(anchor.x, anchor.y, sim.gameMap.regions[index].box):
      holdsPad = true
  if not holdsPad:
    return index
  var
    best = index
    bestDist = high(int)
  for i, region in sim.gameMap.regions:
    var bad = false
    for anchor in sim.gameMap.anchors:
      if anchor.kind == anchorPad and anchor.team == anchorSeekers and
          inRect(anchor.x, anchor.y, region.box):
        bad = true
    if bad:
      continue
    let d = distSq(sim.players[slot].x, sim.players[slot].y,
      region.box.x + region.box.w div 2, region.box.y + region.box.h div 2)
    if d < bestDist:
      bestDist = d
      best = i
  best

proc myDoor(sim: SimServer, slot, region: int, params: BaselineParams):
    tuple[x, y: int, id: string, ok: bool] =
  ## The `homeDoorIndex`-th door of `home`, so the three hiders take
  ## different doors.
  if region < 0 or region >= sim.gameMap.regions.len:
    return (0, 0, "", false)
  let doors = sim.gameMap.regions[region].doors
  if doors.len == 0:
    return (0, 0, "", false)
  let pick = ((sim.players[slot].joinOrder div 2) * params.doorRotation) mod
    doors.len
  let index = sim.gameMap.doorById(doors[pick])
  if index < 0:
    return (0, 0, "", false)
  (sim.gameMap.doors[index].x, sim.gameMap.doors[index].y,
   sim.gameMap.doors[index].id, true)

proc rectDistToPoint(obj: GameObject, px, py: int): int =
  ## Squared distance from a point to the nearest pixel of an object.
  var
    dx = 0
    dy = 0
  if px < obj.x: dx = obj.x - px
  elif px >= obj.x + obj.w: dx = px - (obj.x + obj.w - 1)
  if py < obj.y: dy = obj.y - py
  elif py >= obj.y + obj.h: dy = py - (obj.y + obj.h - 1)
  dx * dx + dy * dy

proc nearestCoverObject(sim: SimServer, slot, x, y: int,
                        params: BaselineParams): int =
  ## The nearest unheld, unlocked object that could cover a door: a panel if
  ## one is inside `panelReach` OF THE COG, else the nearest crate. Measured
  ## from the COG, not from the door: the cog has to walk to the thing before
  ## it can drag it, and a panel on the far side of the room is a whole prep
  ## phase of walking that ends with nothing placed.
  var
    bestPanel = -1
    bestPanelDist = high(int)
    bestCrate = -1
    bestCrateDist = high(int)
  for i, obj in sim.objects:
    # Held BY ME still counts: re-picking a different object every turn
    # because the one in my hands is "held" is how a hider spends a whole
    # prep phase walking between two panels and placing neither.
    if (obj.heldBy >= 0 and obj.heldBy != slot) or obj.lockedBy != lockNone:
      continue
    if not sim.mayTouch(slot, i):
      continue
    let d = distSq(x, y, obj.x + obj.w div 2, obj.y + obj.h div 2)
    case obj.kind
    of okPanel:
      if d < bestPanelDist:
        bestPanelDist = d
        bestPanel = i
    of okCrate:
      if d < bestCrateDist:
        bestCrateDist = d
        bestCrate = i
    of okRamp: discard
  # A panel covers a 56 px door on its own, so it is worth walking `panelReach`
  # for; past that the nearest crate is the better bet. Measured: making the
  # crate branch obey the same budget (so a far crate means "just hide") is
  # WORSE, because a hider dragging furniture across a sightline breaks it
  # whether or not the drag ever reaches the door.
  if bestPanel >= 0 and bestPanelDist <= params.panelReach * params.panelReach:
    return bestPanel
  if bestCrate >= 0:
    return bestCrate
  bestPanel

proc nearestRamp(sim: SimServer, slot, x, y: int): tuple[index, dist: int] =
  result = (-1, high(int))
  for i, obj in sim.objects:
    if obj.kind != okRamp or obj.heldBy >= 0:
      continue
    if not sim.mayTouch(slot, i):
      continue
    let d = distSq(x, y, obj.x + obj.w div 2, obj.y + obj.h div 2)
    if d < result.dist:
      result = (i, d)

proc farCorner(sim: SimServer, x, y: int): tuple[x, y: int] =
  let
    cx = if x < MapWidth div 2: MapWidth - 80 else: 80
    cy = if y < MapHeight div 2: MapHeight - 80 else: 80
  (cx, cy)

proc pocketsIn(sim: SimServer, region: int): seq[RoomAnchor] =
  for anchor in sim.gameMap.anchors:
    if anchor.kind != anchorPocket:
      continue
    if region >= 0 and region < sim.gameMap.regions.len and
        not inRect(anchor.x, anchor.y, sim.gameMap.regions[region].box):
      continue
    result.add(anchor)

proc allPockets(sim: SimServer): seq[RoomAnchor] =
  sim.gameMap.anchorsOf(anchorPocket)

proc patrolAnchors(sim: SimServer): seq[RoomAnchor] =
  result = sim.gameMap.anchorsOf(anchorPatrol)
  if result.len == 0:
    result = sim.gameMap.anchorsOf(anchorPocket)

proc order(slot: int, alias: string, intent: Intent, obj = "", at = "",
           toX = -1, toY = -1, say = ""): Order =
  result = Order(slot: slot, id: alias, intent: intent, obj: obj, at: at,
    say: say, fromReply: true)
  if toX >= 0 and toY >= 0:
    result.hasTo = true
    result.toX = clamp(toX, 0, MapWidth - 1)
    result.toY = clamp(toY, 0, MapHeight - 1)

proc burrowHider(sim: SimServer, ctl: ControlState, slot: int,
                 alias: string, params: BaselineParams, turn: int): Order =
  ## First matching rule wins (§Scripted baselines).
  let
    px = sim.players[slot].x
    py = sim.players[slot].y
    home = homeRegion(sim, slot)
    door = sim.myDoor(slot, home, params)
  # 5. During hunt, flinch: re-hide at the pocket furthest from a known
  #    seeker inside home.
  if sim.matchPhase == phaseHunt:
    let enemy = ctl.knownEnemy(sim, slot)
    if enemy.known and
        distSq(px, py, enemy.x, enemy.y) <=
          params.flinchRadius * params.flinchRadius:
      var pockets = sim.pocketsIn(home)
      if pockets.len == 0:
        pockets = sim.allPockets()
      var
        best = -1
        bestDist = -1
      for i, pocket in pockets:
        let d = distSq(pocket.x, pocket.y, enemy.x, enemy.y)
        if d > bestDist:
          bestDist = d
          best = i
      if best >= 0:
        return order(slot, alias, intHide, at = pockets[best].id,
          toX = pockets[best].x, toY = pockets[best].y)
  if door.ok:
    let cover = sim.nearestCoverObject(slot, px, py, params)
    if cover >= 0:
      let
        obj = sim.objects[cover]
        ocx = obj.x + obj.w div 2
        ocy = obj.y + obj.h div 2
        atDoor = rectDistToPoint(obj, door.x, door.y) <=
          DoorPlaceRadius * DoorPlaceRadius
      # 2. The cover is on the door and unlocked -> lock it.
      if atDoor and obj.lockedBy == lockNone:
        return order(slot, alias, intLock, obj = obj.id)
      # 1. Otherwise drag it there.
      if not atDoor:
        return order(slot, alias, intPush, obj = obj.id,
          toX = door.x, toY = door.y,
          say = (if turn == 1: "on it" else: ""))
    # 3. The door is sealed and locked: take a nearby ramp to the far corner
    #    and lock it there — a ramp left near your fort is the seekers' key.
    let ramp = sim.nearestRamp(slot, door.x, door.y)
    if ramp.index >= 0 and ramp.dist <= params.rampSweep * params.rampSweep:
      let obj = sim.objects[ramp.index]
      if obj.lockedBy == lockNone:
        let corner = sim.farCorner(obj.x, obj.y)
        if distSq(obj.x + obj.w div 2, obj.y + obj.h div 2,
                  corner.x, corner.y) <= 48 * 48:
          return order(slot, alias, intLock, obj = obj.id)
        return order(slot, alias, intPush, obj = obj.id,
          toX = corner.x, toY = corner.y)
  # 4. Hide at the pocket inside home nearest this cog, facing myDoor.
  var pockets = sim.pocketsIn(home)
  if pockets.len == 0:
    pockets = sim.allPockets()
  if pockets.len == 0:
    return order(slot, alias, intWatch)
  # The pocket inside `home` NEAREST this cog. Deliberately not "furthest from
  # the seekers": measured, that funnels all three hiders into one corner, and
  # ONE hider caught in the open loses the tick for all three — so spreading
  # them across their own regions beats crowding them into the safest one.
  var
    best = 0
    bestDist = high(int)
  for i, pocket in pockets:
    let d = distSq(px, py, pocket.x, pocket.y)
    if d < bestDist:
      bestDist = d
      best = i
  result = order(slot, alias, intHide, at = pockets[best].id,
    toX = pockets[best].x, toY = pockets[best].y)
  if door.ok:
    result.hasFace = true
    result.faceX = door.x
    result.faceY = door.y

proc burrowSeeker(sim: SimServer, ctl: ControlState, slot: int,
                  alias: string, params: BaselineParams, turn: int): Order =
  ## Sweep the room's patrol anchors in ascending id order, starting at the
  ## `(slot div 2)`-th; chase a known hider; shove an unlocked object out of
  ## the way; vault a locked one.
  let
    px = sim.players[slot].x
    py = sim.players[slot].y
    enemy = ctl.knownEnemy(sim, slot)
  if enemy.known and
      distSq(px, py, enemy.x, enemy.y) <=
        params.chaseRadius * params.chaseRadius:
    return order(slot, alias, intChase)
  let anchors = sim.patrolAnchors()
  if anchors.len == 0:
    return order(slot, alias, intWatch)
  let
    seat = sim.players[slot].joinOrder div 2
    pick = (seat + turn) mod anchors.len
    target = anchors[pick]
  # Blocked by furniture on the way? Shove it, or vault it if it is locked.
  let blocking = sim.objectAt((px + target.x) div 2, (py + target.y) div 2)
  if blocking >= 0:
    if sim.objects[blocking].lockedBy == lockNone:
      let obj = sim.objects[blocking]
      return order(slot, alias, intPush, obj = obj.id,
        toX = clamp(obj.x + obj.w div 2 + 80, 0, MapWidth - 1),
        toY = obj.y + obj.h div 2)
    let ramp = sim.nearestRamp(slot, px, py)
    if ramp.index >= 0 and sim.objects[ramp.index].lockedBy == lockNone:
      return order(slot, alias, intVault, obj = sim.objects[ramp.index].id)
  if turn mod 2 == 0:
    return order(slot, alias, intWatch, at = target.id,
      toX = target.x, toY = target.y)
  order(slot, alias, intMoveTo, at = target.id, toX = target.x, toY = target.y)

proc scatterHider(sim: SimServer, ctl: ControlState, slot: int,
                  alias: string, params: BaselineParams, turn: int): Order =
  ## Never touches the furniture: a moving target with no fort.
  let
    px = sim.players[slot].x
    py = sim.players[slot].y
    pockets = sim.allPockets()
  if pockets.len == 0:
    return order(slot, alias, intWatch)
  var ranked: seq[tuple[dist, index: int]] = @[]
  for i, pocket in pockets:
    var worst = high(int)
    for anchor in sim.gameMap.anchors:
      if anchor.kind == anchorPad and anchor.team == anchorSeekers:
        worst = min(worst, distSq(pocket.x, pocket.y, anchor.x, anchor.y))
    ranked.add((worst, i))
  for i in 1 ..< ranked.len:
    var j = i
    while j > 0 and ranked[j].dist > ranked[j - 1].dist:
      swap(ranked[j], ranked[j - 1])
      dec j
  let enemy = ctl.knownEnemy(sim, slot)
  if enemy.known and
      distSq(px, py, enemy.x, enemy.y) <=
        params.flinchRadius * params.flinchRadius:
    let pick = pockets[ranked[0].index]
    return order(slot, alias, intMoveTo, at = pick.id, toX = pick.x,
      toY = pick.y)
  let
    alternate = if ranked.len > 1 and turn mod 2 == 1: 1 else: 0
    pick = pockets[ranked[alternate].index]
  # `move_to`, never `hide`: scatter is A MOVING TARGET WITH NO FORT, and a
  # cog that keeps walking between two pockets crosses open ground twice a
  # turn. That is the whole difference in SHAPE the ladder wants — not a
  # weaker version of burrow, a different (and worse) idea.
  order(slot, alias, intMoveTo, at = pick.id, toX = pick.x, toY = pick.y)

proc scatterSeeker(sim: SimServer, ctl: ControlState, slot: int,
                   alias: string, params: BaselineParams, turn: int): Order =
  ## Split the patrol ring by slot and walk it one way; never grab, lock or
  ## vault.
  let
    px = sim.players[slot].x
    py = sim.players[slot].y
    enemy = ctl.knownEnemy(sim, slot)
  if enemy.known and
      distSq(px, py, enemy.x, enemy.y) <=
        params.chaseRadius * params.chaseRadius:
    return order(slot, alias, intChase)
  let anchors = sim.patrolAnchors()
  if anchors.len == 0:
    return order(slot, alias, intWatch)
  let
    seat = sim.players[slot].joinOrder div 2
    start = seat * anchors.len div 3
    pick = (start + turn) mod anchors.len
    target = anchors[pick]
  order(slot, alias, intMoveTo, at = target.id, toX = target.x, toY = target.y)

proc baselineOrder*(
  baseline: Baseline,
  sim: SimServer,
  ctl: ControlState,
  slot: int,
  alias: string,
  turn: int,
  params = DefaultBaselineParams
): Order =
  ## The one entry point. The decision engine's fallback path calls THIS with
  ## `blBurrow`, so the fallback and the published baseline cannot drift
  ## (`tests/test_hns_control.nim` asserts they resolve to the same proc).
  if slot < 0 or slot >= sim.players.len:
    return Order(slot: slot, id: alias, intent: intWatch, fromReply: true)
  let hiding = sim.players[slot].team == Red
  case baseline
  of blBurrow:
    if hiding: burrowHider(sim, ctl, slot, alias, params, turn)
    else: burrowSeeker(sim, ctl, slot, alias, params, turn)
  of blScatter:
    if hiding: scatterHider(sim, ctl, slot, alias, params, turn)
    else: scatterSeeker(sim, ctl, slot, alias, params, turn)

proc fallbackOrder*(
  sim: SimServer,
  ctl: ControlState,
  slot: int,
  alias: string,
  turn: int,
  params = DefaultBaselineParams
): Order =
  ## The server-side fallback: the SAME proc `burrow` uses, imported and never
  ## duplicated.
  baselineOrder(blBurrow, sim, ctl, slot, alias, turn, params)
