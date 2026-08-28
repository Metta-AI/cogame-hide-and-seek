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

# --- 7. vault --------------------------------------------------------------
block vault:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var ramp = -1
  for i, o in game.objects:
    if o.kind == okRamp:
      ramp = i
      break
  check ramp >= 0, "no ramp in the deal"
  let r = game.objects[ramp]
  game.placePlayer(0, r.x + r.w div 2, r.y + r.h div 2)
  let brads = rampHeadBrads(r, game.players[0].x, game.players[0].y)
  let unit = AimUnit[brads]
  game.players[0].velX = unit.x * game.config.maxSpeed div AimUnitScale
  game.players[0].velY = unit.y * game.config.maxSpeed div AimUnitScale
  if game.vaultSpanClear(game.players[0].x, game.players[0].y, brads,
      game.config.vaultSpanPx):
    var inputs = newSeq[InputState](game.players.len)
    game.step(inputs, inputs)
    check game.players[0].airborne, "a full-speed run up a ramp did not launch"
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
