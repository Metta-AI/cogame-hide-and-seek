## Sim unit tests (design note §Tests, 1-15). Every one of these plays the
## real sim through the real control layer.

import std/[json, math, os, random, strutils, times, unicode]
import helpers

# --- 1. phase clock --------------------------------------------------------
block phaseClock:
  var h = newHarness()
  let prep = h.game.config.prepTicks
  var releases = 0
  var exposureDuringPrep = 0
  for tick in 1 .. h.game.config.maxTicks:
    let wasPrep = h.game.matchPhase == phasePrep
    h.stepOnce()
    if h.game.phase != Playing:
      break
    if wasPrep and h.game.matchPhase == phaseHunt:
      inc releases
      check h.game.gameTick() == prep,
        "release fired at tick " & $h.game.gameTick() & ", expected " & $prep
    if h.game.matchPhase == phasePrep:
      check h.game.huntTicksPlayed == 0, "exposure counted during prep"
      inc exposureDuringPrep
  check releases == 1, "release fired " & $releases & " times, expected once"
  check exposureDuringPrep > 0, "the prep phase never ran"

block frozenSeekerMasks:
  var h = newHarness()
  var seekerMoved = false
  let start = h.game.players[1].x
  for tick in 1 .. h.game.config.prepTicks:
    h.stepOnce()
    if h.game.players[1].x != start:
      seekerMoved = true
  check not seekerMoved, "a seeker moved during prep"

# --- 2. two games, sides swapped -------------------------------------------
block sideSwap:
  var h = newHarness()
  let firstSides = block:
    var s: seq[Team]
    for p in h.game.players: s.add(p.team)
    s
  let deal = block:
    var d: seq[(int, int)]
    for o in h.game.objects: d.add((o.spawnX, o.spawnY))
    d
  h.runEpisode()
  check h.game.gameMargins.len == 2, "the episode did not play two games"
  # After the swap every seat holds the other side.
  var swapped = 0
  for i, p in h.game.players:
    if p.team != firstSides[i]:
      inc swapped
  check swapped == h.game.players.len,
    "only " & $swapped & " seats swapped sides"
  for i, o in h.game.objects:
    check (o.spawnX, o.spawnY) == deal[i],
      "the object deal changed between the two games"
  check h.game.cogAlias(0).startsWith("SEEKER-"),
    "slot 0's alias did not re-prefix at the swap: " & h.game.cogAlias(0)

# --- 3. grab ---------------------------------------------------------------
block grab:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  let obj = 0
  # Park slot 0 just off the crate's west face, aimed east.
  let target = game.objects[obj]
  game.placePlayer(0, target.x - PlayerHalf - 8, target.y + target.h div 2)
  game.players[0].aimBrads = 0
  check game.grabProbe(0) == obj, "the probe did not find the crate in front"
  var inputs = newSeq[InputState](game.players.len)
  inputs[0].c = true
  game.step(inputs, newSeq[InputState](game.players.len))
  check game.players[0].holding == obj, "C did not bind the crate"
  check game.objects[obj].heldBy == 0, "the crate has no holder"
  # Nothing beyond the first object binds.
  check game.grabProbe(0) == obj, "the probe reached past the first object"
  # Releasing C drops it.
  var released = newSeq[InputState](game.players.len)
  game.step(released, inputs)
  check game.players[0].holding < 0, "releasing C did not drop the crate"
  check game.objects[obj].heldBy == -1, "the crate kept its holder"

block aPhaseChangeAndAGameEndDropTheHeldObject:
  ## Tick step 4: "`C` released (or … or the phase changed, or the game
  ## ended) -> the held object is dropped". A hider may not carry a crate
  ## across the release.
  proc grabTheCrate(game: var SimServer): seq[InputState] =
    let target = game.objects[0]
    game.placePlayer(0, target.x - PlayerHalf - 8, target.y + target.h div 2)
    game.players[0].aimBrads = 0
    result = newSeq[InputState](game.players.len)
    result[0].c = true
    game.step(result, newSeq[InputState](game.players.len))
    check game.players[0].holding == 0, "the fixture never took the crate"

  block:
    var game = newTestSim()
    game.seatAll()
    game.startGame()
    var held = game.grabTheCrate()
    # Hold C right through the prep -> hunt transition.
    while game.matchPhase == phasePrep:
      game.step(held, held)
    check game.players[0].holding < 0,
      "the release did not drop the held crate: a hider carried it into the hunt"
    check game.objects[0].heldBy == -1, "the crate kept its holder at the release"

  block:
    var game = newTestSim()
    game.seatAll()
    game.startGame()
    var held = game.grabTheCrate()
    game.finishGame(timeLimitReached = true)
    check game.players[0].holding < 0, "the game end did not drop the held crate"
    check game.objects[0].heldBy == -1, "the crate kept its holder at the game end"

block grabTieGoesToLowerSlot:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  let target = game.objects[0]
  game.placePlayer(0, target.x - PlayerHalf - 8, target.y + target.h div 2)
  game.players[0].aimBrads = 0
  game.placePlayer(2, target.x + target.w + PlayerHalf + 8,
    target.y + target.h div 2)
  game.players[2].aimBrads = 128
  var inputs = newSeq[InputState](game.players.len)
  inputs[0].c = true
  inputs[2].c = true
  game.step(inputs, newSeq[InputState](game.players.len))
  check game.players[0].holding == 0, "the lower slot did not win the tie"
  check game.players[2].holding < 0, "both cogs hold the same object"

# --- 4. push ---------------------------------------------------------------
block push:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  # Find an object with room to the east.
  var obj = -1
  for i, o in game.objects:
    if o.kind == okCrate:
      obj = i
      break
  check obj >= 0, "no crate in the deal"
  let before = (game.objects[obj].x, game.objects[obj].y)
  game.placePlayer(0, game.objects[obj].x - PlayerHalf - 8,
    game.objects[obj].y + game.objects[obj].h div 2)
  game.players[0].aimBrads = 0
  var inputs = newSeq[InputState](game.players.len)
  inputs[0].c = true
  game.step(inputs, newSeq[InputState](game.players.len))
  check game.players[0].holding == obj, "the push test never grabbed"
  var moved = false
  var prev = inputs
  for tick in 1 .. 60:
    var step = newSeq[InputState](game.players.len)
    step[0].c = true
    step[0].right = true
    let cogBefore = game.players[0].x
    let objBefore = game.objects[obj].x
    game.step(step, prev)
    prev = step
    if game.objects[obj].x != objBefore:
      moved = true
      check game.objects[obj].x - objBefore == game.players[0].x - cogBefore,
        "the held object did not translate by the holder's delta"
  check moved, "a held crate never moved"
  check game.objects[obj].x > before[0], "the crate went the wrong way"
  check game.players[0].pushedPx > 0, "pushedPx never counted"

block carrySpeed:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  check game.config.maxSpeedFor(true) ==
    game.config.maxSpeed * game.config.carrySpeedPct div 100,
    "a holder's max speed is not carrySpeedPct of normal"
  check game.config.maxSpeedFor(true) < game.config.maxSpeedFor(false),
    "carrying is not slower than walking"

# --- 5. lock ---------------------------------------------------------------
block lock:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  let obj = 0
  let target = game.objects[obj]
  game.placePlayer(0, target.x - PlayerHalf - 8, target.y + target.h div 2)
  game.players[0].aimBrads = 0
  var press = newSeq[InputState](game.players.len)
  press[0].attack = true
  game.step(press, newSeq[InputState](game.players.len))
  check game.objects[obj].lockedBy == lockOwnerFor(game.players[0].team),
    "A did not lock the crate"
  check game.players[0].lockCooldown > 0, "the lock cooldown did not arm"
  # The other team may not touch it.
  let seeker = 1
  check not game.mayTouch(seeker, obj),
    "the other team may still touch a locked object"
  check game.mayTouch(0, obj), "the locking team may not touch its own lock"
  # A second toggle inside the cooldown is refused.
  let owner = game.objects[obj].lockedBy
  var again = newSeq[InputState](game.players.len)
  again[0].attack = true
  game.step(again, newSeq[InputState](game.players.len))
  check game.objects[obj].lockedBy == owner,
    "the lock toggled again inside its cooldown"
  # It is still solid and still opaque.
  check game.isObject(target.x + 2, target.y + 2), "a locked object is not solid"

# --- 6. keep-clear ---------------------------------------------------------
block keepClear:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var rng = initRand(7)
  for attempt in 1 .. 200:
    let index = rng.rand(game.objects.len - 1)
    var rect = objectRect(game.objects[index])
    rect.x = rng.rand(MapWidth - rect.w)
    rect.y = rng.rand(MapHeight - rect.h)
    if game.canPlaceObject(index, rect, -1):
      check not game.keepClearViolated(rect),
        "a placement inside a keep-clear disc was allowed"
  for obj in game.objects:
    check not game.keepClearViolated(objectRect(obj)),
      "the deal placed " & obj.id & " inside a keep-clear disc"

block noSequenceOfPushesReachesASeekerPad:
  ## The note's test 6 asks about PUSHES, not placements: the loop above can
  ## never fail, because `canPlaceObject` calls `keepClearViolated` itself
  ## (objects.nim:317). This walks each object toward a seeker pad through the
  ## SAME guard the push path uses, one pixel at a time, and asserts the disc
  ## actually STOPS it — the object ends outside every disc no matter how many
  ## pushes it is given.
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  proc rectDistSqTo(rect: MapRect, px, py: int): int =
    ## The keep-clear rule's own measure (objects.nim's private rectDistSq):
    ## squared distance from a point to the nearest pixel of a rectangle.
    var dx, dy = 0
    if px < rect.x: dx = rect.x - px
    elif px >= rect.x + rect.w: dx = px - (rect.x + rect.w - 1)
    if py < rect.y: dy = rect.y - py
    elif py >= rect.y + rect.h: dy = py - (rect.y + rect.h - 1)
    dx * dx + dy * dy
  var rng = initRand(6)
  let pads = game.gameMap.padsFor(anchorSeekers)
  check pads.len == SeekerPads, "the room published no seeker pads"
  for attempt in 1 .. 200:
    let
      index = rng.rand(game.objects.len - 1)
      pad = pads[rng.rand(pads.len - 1)]
    for push in 1 .. 400:
      let centre = objectCenter(game.objects[index])
      let
        dx = cmp(pad.x, centre.x)
        dy = cmp(pad.y, centre.y)
      if dx == 0 and dy == 0:
        break
      var rect = objectRect(game.objects[index])
      rect.x += dx
      rect.y += dy
      if not game.canPlaceObject(index, rect, -1):
        break
      game.moveObject(index, dx, dy)
      check not game.keepClearViolated(objectRect(game.objects[index])),
        "push " & $push & " of attempt " & $attempt & " put " &
        game.objects[index].id & " inside a keep-clear disc"
    check rectDistSqTo(objectRect(game.objects[index]), pad.x, pad.y) >=
        game.config.keepClearPx * game.config.keepClearPx,
      "pushing " & game.objects[index].id &
      " straight at a seeker pad reached inside the disc"
  # And a real push through the sim agrees: a cog holding an object cannot
  # walk it into the disc either.
  let pad = pads[0]
  var held = -1
  var bestDist = high(int)
  for i in 0 ..< game.objects.len:
    let d = rectDistSqTo(objectRect(game.objects[i]), pad.x, pad.y)
    if d < bestDist:
      bestDist = d
      held = i
  let obj = game.objects[held]
  game.placePlayer(0, clamp(obj.x - PlayerHalf - 2, PlayerHalf,
    MapWidth - PlayerHalf - 1), obj.y + obj.h div 2)
  game.objects[held].heldBy = 0
  game.players[0].holding = held
  var drive = newSeq[InputState](game.players.len)
  drive[0].right = pad.x > obj.x
  drive[0].left = pad.x < obj.x
  drive[0].down = pad.y > obj.y
  drive[0].up = pad.y < obj.y
  drive[0].c = true
  for tick in 1 .. 200:
    game.step(drive, drive)
    for i in 0 ..< game.objects.len:
      check not game.keepClearViolated(objectRect(game.objects[i])),
        "a driven push put " & game.objects[i].id & " inside a keep-clear disc"

# --- 7. vault --------------------------------------------------------------
block vault:
  # The launch/airborne/landing assertions used to sit inside
  # `if game.vaultSpanClear(...)`, so a seeded deal that offered no clear span
  # asserted NOTHING and still printed ok. Search the three rooms for a ramp
  # that does offer one, and fail if none of them does.
  var
    game = newTestSim()
    ramp = -1
    brads = 0
    found = false
  for room in ["warren", "atrium", "long_hall"]:
    game = newTestSim(%*{"roomPool": room, "seed": 42})
    game.seatAll()
    game.startGame()
    for i, o in game.objects:
      if o.kind != okRamp:
        continue
      game.placePlayer(0, o.x + o.w div 2, o.y + o.h div 2)
      let head = rampHeadBrads(o, game.players[0].x, game.players[0].y)
      if game.vaultSpanClear(game.players[0].x, game.players[0].y, head,
          game.config.vaultSpanPx):
        ramp = i
        brads = head
        found = true
        break
    if found:
      break
  check found, "no ramp in any of the three rooms offers a clear vault span"
  let unit = AimUnit[brads]
  game.players[0].velX = unit.x * game.config.maxSpeed div AimUnitScale
  game.players[0].velY = unit.y * game.config.maxSpeed div AimUnitScale
  var inputs = newSeq[InputState](game.players.len)
  game.step(inputs, inputs)
  check game.players[0].airborne, "a full-speed run up a ramp did not launch"
  check game.objects[ramp].kind == okRamp, "the launch object is not a ramp"
  var airborneTicks = 0
  while game.players[0].airborne and airborneTicks < 40:
    game.step(inputs, inputs)
    inc airborneTicks
  check airborneTicks <= game.config.vaultTicks + 1,
    "the vault lasted " & $airborneTicks & " ticks"
  check game.canOccupy(game.players[0].x, game.players[0].y),
    "the vault landed inside geometry"
  # A too-thick span never triggers.
  check not game.vaultSpanClear(game.players[0].x, game.players[0].y, brads, 0),
    "a zero-thickness allowance still triggered a vault"

block airborneIsVisibleOverFurniture:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  # Put a hider directly behind a crate from a seeker's point of view.
  let obj = 0
  let o = game.objects[obj]
  let
    seeker = 1
    hider = 0
  game.placePlayer(seeker, o.x - 40, o.y + o.h div 2)
  game.players[seeker].aimBrads = 0
  game.placePlayer(hider, o.x + o.w + 20, o.y + o.h div 2)
  game.matchPhase = phaseHunt
  discard game.refreshPlayerFov(seeker)
  let hiddenBehind = game.playerVisibleTo(seeker, hider)
  game.players[hider].airborne = true
  let seenAirborne = game.playerVisibleTo(seeker, hider)
  check not hiddenBehind, "a hider behind a crate was visible"
  check seenAirborne, "an airborne hider was not visible over the crate"

# --- 8/9. vision -----------------------------------------------------------
block visionCone:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  check game.visionRange() == game.config.sightRange,
    "the cone reach is not sightRange"
  check game.config.visionConeDeg == 35, "the cone half-angle moved"
  check game.config.visionBubble == 48, "the bubble radius moved"

block incrementalGeometryEqualsFullRebuild:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var rng = initRand(11)
  for move in 1 .. 60:
    let index = rng.rand(game.objects.len - 1)
    let dx = rng.rand(-3 .. 3)
    let dy = rng.rand(-3 .. 3)
    var rect = objectRect(game.objects[index])
    rect.x += dx
    rect.y += dy
    if not game.canPlaceObject(index, rect, -1):
      continue
    game.moveObject(index, dx, dy)
  let incrementalMask = game.objectMask
  let incrementalFov = game.fovBlocked
  game.rasterizeObjects()
  check incrementalMask == game.objectMask,
    "the dirty-rect objectMask disagrees with a full rebuild"
  check incrementalFov == game.fovBlocked,
    "the dirty-rect fovBlocked disagrees with a full rebuild"

# --- 10. exposure counting -------------------------------------------------
block exposureCounting:
  var h = newHarness()
  h.runEpisode()
  for game in 0 ..< h.game.gameHidden.len:
    check h.game.gameHidden[game] + h.game.gameSeen[game] ==
      h.game.gameHuntPlayed[game],
      "hidden + seen != huntTicksPlayed in game " & $game
  var anySeat = 0
  for p in h.game.players:
    anySeat += p.seatSeenTicks
  check anySeat >= 0, "seatSeenTicks went negative"

# --- 11. sealed scan -------------------------------------------------------
block sealedScan:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  # A hider in the open is never sealed.
  let hider = 0
  game.placePlayer(hider, MapWidth div 2, MapHeight div 2)
  discard game.scanSealed()
  check not game.players[hider].sealed,
    "a hider standing in the middle of the room reads as sealed"

block aWalledInHiderIsSealedAndOnlyWhileTheWallHolds:
  ## The note's test 11: the walled-in POSITIVE case, the same wall unlocked,
  ## the cog-sized gap, and "only at turn boundaries". The old block asserted
  ## only the negative case.
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  # `warren`'s region r1 (16,16 232x176) has exactly one door, d1 at (256,104),
  # 56 px tall. A hider-locked 32x128 panel laid over it seals the region.
  var panel = -1
  for i, obj in game.objects:
    if obj.id == "pan2":
      panel = i
  check panel >= 0, "the warren deal no longer carries pan2"
  proc placeWall(game: var SimServer, y: int, locked: LockOwner) =
    game.objects[panel].x = 248
    game.objects[panel].y = y
    game.objects[panel].lockedBy = locked
    game.rasterizeObjects()
  for slot in 0 ..< game.players.len:
    if game.players[slot].team == Red:
      game.placePlayer(slot, 120, 100)      # inside r1
    else:
      game.placePlayer(slot, 600, 300)      # inside r6, the far corner
  # 1. Walled in by a HIDER-LOCKED object: sealed.
  game.placeWall(72, lockHiders)
  let sealedChange = game.scanSealed()
  check game.players[0].sealed, "a hider walled into r1 does not read as sealed"
  check game.sealedCount() == 3, "the whole hiding trio in r1 is not sealed"
  check 0 in sealedChange.sealed, "the scan reported no sealed transition"
  # 2. The SAME wall unlocked: a seeker can shove it, so it is not a wall.
  game.placeWall(72, lockNone)
  let unsealedChange = game.scanSealed()
  check not game.players[0].sealed,
    "an UNLOCKED object still sealed the fort: a seeker can shove it"
  check 0 in unsealedChange.unsealed, "the scan reported no unsealed transition"
  # 3. Locked again, but shifted to leave a cog-sized gap in the doorway.
  game.placeWall(112, lockHiders)
  discard game.scanSealed()
  check not game.players[0].sealed,
    "a doorway with a cog-sized gap left in it still read as sealed"
  # 4. The scan runs only at turn boundaries: closing the wall mid-turn does
  #    not change `sealed` until the next boundary tick.
  game.placeWall(72, lockHiders)
  let turnTicks = game.config.turnTicks
  check turnTicks > 2, "the fixture has no room inside a turn"
  var inputs = newSeq[InputState](game.players.len)
  var ticksToBoundary = 0
  while (game.gameTick() + 1) mod turnTicks != 0:
    game.step(inputs, inputs)
    inc ticksToBoundary
    check not game.players[0].sealed,
      "the sealed scan ran mid-turn, at tick " & $game.gameTick()
    for slot in 0 ..< game.players.len:
      if game.players[slot].team == Red:
        game.placePlayer(slot, 120, 100)
      else:
        game.placePlayer(slot, 600, 300)
  check ticksToBoundary > 0, "the fixture never spent a tick inside a turn"
  game.step(inputs, inputs)
  check game.players[0].sealed,
    "the turn-boundary scan did not pick the sealed fort up"

# --- 12. scoring -----------------------------------------------------------
block scoringFormula:
  check marginPermille(720, 0, 720) == 1000, "an unseen game is not +1000"
  check marginPermille(0, 720, 720) == -1000, "a seen game is not -1000"
  check marginPermille(360, 360, 720) == 0, "an even game is not 0"
  check marginPermille(0, 0, 0) == 0, "an unplayed game is not 0"

block scoringIsZeroSum:
  var rng = initRand(3)
  var game = newTestSim()
  game.seatAll()
  for trial in 1 .. 500:
    game.gameMargins.setLen(0)
    game.gameHidden.setLen(0)
    game.gameSeen.setLen(0)
    game.gameHuntPlayed.setLen(0)
    let hunt = rng.rand(1 .. 719)
    for g in 0 .. 1:
      let seen = rng.rand(0 .. hunt)
      game.gameMargins.add(marginPermille(hunt - seen, seen, hunt))
      game.gameHidden.add(hunt - seen)
      game.gameSeen.add(seen)
      game.gameHuntPlayed.add(hunt)
    var total = 0
    for slot in 0 ..< 6:
      let score = game.scorePermille(slot)
      check score >= -1000 and score <= 1000,
        "scorePermille out of range: " & $score
      total += score
    check total == 0, "the six scores summed to " & $total & ", not 0"
    # `win` IS the sign of the score, and nothing else (note test 12). Read it
    # off the emitted results document, which is what the league reads.
    let results = parseJson(game.roomResultsJson())
    for slot in 0 ..< 6:
      check results{"win"}[slot].getBool() == (game.scorePermille(slot) > 0),
        "results.win[" & $slot & "] disagrees with the sign of its score"

block anAllZeroMarginLeavesEveryWinFalse:
  ## The other half of test 12: a drawn episode has no winners, not six.
  var game = newTestSim()
  game.seatAll()
  for g in 0 .. 1:
    game.gameMargins.add(0)
    game.gameHidden.add(360)
    game.gameSeen.add(360)
    game.gameHuntPlayed.add(720)
  let results = parseJson(game.roomResultsJson())
  for slot in 0 ..< 6:
    check game.scorePermille(slot) == 0,
      "an all-zero margin scored " & $game.scorePermille(slot) & " at slot " & $slot
    check not results{"win"}[slot].getBool(),
      "an all-zero margin left slot " & $slot & " marked a winner"

# --- 13. end conditions ----------------------------------------------------
block endConditions:
  var h = newHarness()
  h.runEpisode()
  check h.game.endReason == ReasonComplete, "a clean episode is not complete"
  check h.game.endRule == EndRuleFullTime, "a clean episode is not full_time"

block wallClockStop:
  var h = newHarness()
  for tick in 1 .. h.game.config.prepTicks + 20:
    h.stepOnce()
  h.game.forceWallClockStop()
  check h.game.endReason == ReasonDeadline, "the stop did not set deadline"
  check h.game.endRule == EndRuleWallClock, "the stop did not set wall_clock"
  check h.game.gameMargins.len == h.game.config.maxGames,
    "a deadline episode is not rankable: " & $h.game.gameMargins.len & " games"
  var total = 0
  for slot in 0 ..< 6:
    total += h.game.scorePermille(slot)
  check total == 0, "a deadline episode is not zero-sum"

block faultStop:
  var h = newHarness()
  h.stepOnce()
  h.game.forceFaultStop("a tripped invariant")
  check h.game.endReason == ReasonFault, "the fault stop did not set fault"
  check h.game.endRule == EndRuleSimFault, "the fault stop did not set sim_fault"
  check h.game.stopDetail.len > 0, "the fault stop recorded no detail"

block faultStopDetailIsRuneTruncated:
  ## `stopDetail` carries a caught exception's `msg` and reaches the results
  ## document (roster.nim) and from there the replay's `result` record, so it
  ## obeys the same cap as every other recorded string (checklist 9).
  const Emoji = "\u{1F600}"   ## a 4-byte codepoint
  var detail = ""
  for i in 0 ..< MaxFallbackDetailRunes + 40:
    detail.add(Emoji)
  var h = newHarness()
  h.stepOnce()
  h.game.forceFaultStop(detail)
  check h.game.stopDetail.runeLen == MaxFallbackDetailRunes,
    "stopDetail was not cut to the rune cap: " & $h.game.stopDetail.runeLen
  check validateUtf8(h.game.stopDetail) < 0,
    "the stopDetail cut left a broken codepoint"
  let results = parseJson(h.game.roomResultsJson())
  check results{"stopDetail"}.getStr().runeLen == MaxFallbackDetailRunes,
    "the results document carried an untruncated stopDetail"
  check validateUtf8(results{"stopDetail"}.getStr()) < 0,
    "the results document carried invalid UTF-8 in stopDetail"

# --- 15. tick budget -------------------------------------------------------
# Release only: a debug build is 10-50x slower through the per-pixel code, so
# a wall-clock budget measured there says nothing about the shipped binary.
when defined(release):
 block tickBudget:
  var h = newHarness(%*{"prepTurns": 4, "huntTurns": 8})
  let started = epochTime()
  h.runEpisode()
  let elapsed = epochTime() - started
  check h.game.gameMargins.len == 2, "the budget episode did not finish"
  check elapsed < 15.0,
    "a full episode took " & $elapsed & "s, over the 15 s budget"

echo "test_hns_sim: ok"
