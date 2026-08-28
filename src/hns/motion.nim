## The motion half of the starter's `src/ctf/sim.nim`, forked: the fixed-point
## integrator (`applyInput`), the per-axis slide, and the player-player
## collision bounce — with the two additions this game needs.
##
## 1. A cog holding an object has its `MaxSpeed` scaled by `carrySpeedPct`.
## 2. The proposed displacement is applied to the cog AND, RIGIDLY, to its
##    held object; the move commits only if the object's rectangle then
##    overlaps no static wall, no other object, no cog other than the holder
##    and no keep-clear disc. Otherwise NEITHER moves, the velocity on the
##    blocked axis is zeroed, and `pushBlockedTicks` counts it.
##
## INTEGER ONLY, like objects.nim / phase.nim / fort.nim — everything here
## feeds `gameHash`.

import
  bitworld/spriteprotocol,
  sim_types, sim_state, objects

proc signOf*(value: int): int {.inline.} =
  if value < 0:
    return -1
  if value > 0:
    return 1
  0

proc slideScanRadius(sim: SimServer, carry, velocity: int): int =
  let
    pending = abs(carry) div sim.config.motionScale
    speed = (
      abs(velocity) + sim.config.motionScale - 1
    ) div sim.config.motionScale
  clamp(max(1, max(pending, speed)), 1, MovementSlideMaxScan)

proc playersOverlapAt(sim: SimServer, movingIndex, x, y: int): bool =
  for i in 0 ..< sim.players.len:
    if i == movingIndex or not sim.players[i].alive or sim.players[i].airborne:
      continue
    if max(abs(x - sim.players[i].x), abs(y - sim.players[i].y)) <=
        PlayerSolidSpan:
      return true
  false

proc blockingPlayerAt(
  sim: SimServer,
  movingIndex, fromX, fromY, toX, toY: int
): int =
  ## The index of a live cog whose body blocks this step, or -1. A step is
  ## blocked when it lands overlapping another body WITHOUT increasing the
  ## separation — moving apart is always allowed, so bodies that start
  ## overlapped can escape.
  for i in 0 ..< sim.players.len:
    if i == movingIndex or not sim.players[i].alive or sim.players[i].airborne:
      continue
    let toDist =
      max(abs(toX - sim.players[i].x), abs(toY - sim.players[i].y))
    if toDist > PlayerSolidSpan:
      continue
    let fromDist =
      max(abs(fromX - sim.players[i].x), abs(fromY - sim.players[i].y))
    if toDist <= fromDist:
      return i
  -1

proc bodyFits(sim: SimServer, movingIndex, x, y: int): bool =
  ## True when a cog's own footprint fits at (x, y). A holder's footprint may
  ## overlap the thing it holds — it is dragging it, not walking through it.
  let held = sim.players[movingIndex].holding
  if held >= 0:
    sim.canOccupyIgnoringObject(x, y, held)
  else:
    sim.canOccupy(x, y)

proc heldFits(sim: SimServer, movingIndex, dx, dy: int): bool =
  ## True when the held object may translate with its holder.
  let held = sim.players[movingIndex].holding
  if held < 0:
    return true
  var rect = objectRect(sim.objects[held])
  rect.x += dx
  rect.y += dy
  sim.canPlaceObject(held, rect, movingIndex)

proc commitStep(sim: var SimServer, movingIndex, dx, dy: int) =
  ## Moves the cog and, rigidly, whatever it holds.
  sim.players[movingIndex].x += dx
  sim.players[movingIndex].y += dy
  let held = sim.players[movingIndex].holding
  if held >= 0:
    sim.moveObject(held, dx, dy)
    sim.players[movingIndex].pushedPx += abs(dx) + abs(dy)

proc canSlideHorizontal(
  sim: SimServer,
  movingIndex, x, y, step, offset: int
): bool =
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.bodyFits(movingIndex, x, y + slideStep * i) or
        sim.playersOverlapAt(movingIndex, x, y + slideStep * i) or
        not sim.heldFits(movingIndex, 0, slideStep * i):
      return false
  sim.bodyFits(movingIndex, x + step, y + offset) and
    not sim.playersOverlapAt(movingIndex, x + step, y + offset) and
    sim.heldFits(movingIndex, step, offset)

proc canSlideVertical(
  sim: SimServer,
  movingIndex, x, y, step, offset: int
): bool =
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.bodyFits(movingIndex, x + slideStep * i, y) or
        sim.playersOverlapAt(movingIndex, x + slideStep * i, y) or
        not sim.heldFits(movingIndex, slideStep * i, 0):
      return false
  sim.bodyFits(movingIndex, x + offset, y + step) and
    not sim.playersOverlapAt(movingIndex, x + offset, y + step) and
    sim.heldFits(movingIndex, offset, step)

proc trySlideOffset(
  sim: var SimServer,
  movingIndex, step, offset: int,
  horizontal: bool
): bool =
  if horizontal:
    if not sim.canSlideHorizontal(movingIndex, sim.players[movingIndex].x,
        sim.players[movingIndex].y, step, offset):
      return false
    sim.commitStep(movingIndex, step, offset)
  else:
    if not sim.canSlideVertical(movingIndex, sim.players[movingIndex].x,
        sim.players[movingIndex].y, step, offset):
      return false
    sim.commitStep(movingIndex, offset, step)
  true

proc trySlideMove(
  sim: var SimServer,
  movingIndex, step, radius, preferredSlide: int,
  horizontal: bool
): bool =
  ## The starter's per-axis slide, applied to the cog AND its held object as
  ## one pair, so a crate runs along a wall instead of sticking to it.
  if radius <= 0:
    return false
  let preferred = signOf(preferredSlide)
  for distance in 1 .. radius:
    if preferred != 0:
      if sim.trySlideOffset(movingIndex, step, preferred * distance,
          horizontal):
        return true
      if sim.trySlideOffset(movingIndex, step, -preferred * distance,
          horizontal):
        return true
    else:
      if sim.trySlideOffset(movingIndex, step, -distance, horizontal):
        return true
      if sim.trySlideOffset(movingIndex, step, distance, horizontal):
        return true
  false

proc bouncePlayers(sim: var SimServer, a, b: int, horizontal: bool) =
  ## A slightly elastic equal-mass collision response along one axis: the
  ## axis velocities average out (the shove) plus playerBouncePct percent of
  ## the closing speed rebounds (the bounce). The starter's, unchanged.
  let
    pct = sim.config.playerBouncePct
    v1 = if horizontal: sim.players[a].velX else: sim.players[a].velY
    v2 = if horizontal: sim.players[b].velX else: sim.players[b].velY
    total = v1 + v2
    rebound = (v1 - v2) * pct div 100
  if horizontal:
    sim.players[a].velX = (total - rebound) div 2
    sim.players[b].velX = (total + rebound) div 2
  else:
    sim.players[a].velY = (total - rebound) div 2
    sim.players[b].velY = (total + rebound) div 2

proc applyMomentumAxis(
  sim: var SimServer,
  playerIndex, preferredSlide: int,
  horizontal: bool
) =
  ## One fixed-point movement axis with collision sliding. Walls absorb
  ## blocked motion; another cog's body blocks the same way but answers with
  ## a slightly elastic shove.
  let velocity =
    if horizontal: sim.players[playerIndex].velX
    else: sim.players[playerIndex].velY
  var carry =
    (if horizontal: sim.players[playerIndex].carryX
     else: sim.players[playerIndex].carryY) + velocity
  while abs(carry) >= sim.config.motionScale:
    let
      step = if carry < 0: -1 else: 1
      dx = if horizontal: step else: 0
      dy = if horizontal: 0 else: step
      nx = sim.players[playerIndex].x + dx
      ny = sim.players[playerIndex].y + dy
    var blocker = -1
    let fits = sim.bodyFits(playerIndex, nx, ny) and sim.heldFits(playerIndex, dx, dy)
    if fits:
      blocker = sim.blockingPlayerAt(
        playerIndex, sim.players[playerIndex].x, sim.players[playerIndex].y,
        nx, ny)
    if fits and blocker < 0:
      sim.commitStep(playerIndex, dx, dy)
      carry -= step * sim.config.motionScale
    else:
      let radius = sim.slideScanRadius(carry, velocity)
      if sim.trySlideMove(playerIndex, step, radius, preferredSlide,
          horizontal):
        carry -= step * sim.config.motionScale
      else:
        if blocker >= 0:
          sim.bouncePlayers(playerIndex, blocker, horizontal)
        elif sim.players[playerIndex].holding >= 0:
          # The note's tick step 6, for the HELD pair only: "neither moves
          # this tick, the cog's velocity on the blocked axis is zeroed, and
          # pushBlockedTicks[slot] += 1". Zeroing the carry alone left the
          # velocity standing, so a cog that had been shoving a crate into a
          # wall resumed at FULL speed the instant the refusal cleared. A
          # plain wall bump keeps the starter's behaviour.
          inc sim.players[playerIndex].pushBlockedTicks
          if horizontal:
            sim.players[playerIndex].velX = 0
          else:
            sim.players[playerIndex].velY = 0
        carry = 0
        break
  if horizontal:
    sim.players[playerIndex].carryX = carry
  else:
    sim.players[playerIndex].carryY = carry

proc applyAim*(sim: var SimServer, playerIndex: int, input: InputState) =
  ## Tick step 3. Aim rotation is decoupled from locomotion: holding B turns
  ## the aim counter-clockwise, holding Select clockwise; holding both
  ## cancels out, and the d-pad never changes the aim.
  template player: untyped = sim.players[playerIndex]
  if input.b != input.select:
    let turn =
      if input.b: sim.config.aimTurnRate else: -sim.config.aimTurnRate
    player.aimBrads =
      ((player.aimBrads + turn) mod AimBradsTurn + AimBradsTurn) mod
        AimBradsTurn
  player.flipH =
    player.aimBrads > AimBradsTurn div 4 and
    player.aimBrads < AimBradsTurn * 3 div 4

proc applyInput*(
  sim: var SimServer,
  playerIndex: int,
  input: InputState
) =
  ## Tick step 6. Applies one cog's movement input.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  template player: untyped = sim.players[playerIndex]
  if not player.alive or player.airborne:
    return

  var
    inputX = 0
    inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

  let
    maxSpeed = sim.config.maxSpeedFor(player.holding >= 0)
    # `carrySpeedPct` scales the SPEED CAP and nothing else (note, tick step
    # 6: "a cog holding an object has its `MaxSpeed` scaled by
    # `carrySpeedPct = 55`"). Scaling the acceleration too made a holder take
    # three times as long to reach a cap that is already 55 % of normal.
    accel = sim.config.accel

  if inputX != 0:
    player.velX = clamp(player.velX + inputX * accel, -maxSpeed, maxSpeed)
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    player.velY = clamp(player.velY + inputY * accel, -maxSpeed, maxSpeed)
  else:
    player.velY =
      (player.velY * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velY) < sim.config.stopThreshold:
      player.velY = 0

  let
    preferredSlideY = if inputY != 0: inputY else: signOf(player.velY)
    preferredSlideX = if inputX != 0: inputX else: signOf(player.velX)
  sim.applyMomentumAxis(playerIndex, preferredSlideY, true)
  sim.applyMomentumAxis(playerIndex, preferredSlideX, false)
