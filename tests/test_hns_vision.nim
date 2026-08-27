## 8/9 in detail: the fog of war with DYNAMIC occluders, which is the one
## thing the starter's static grid never had to do.

import std/[json, random, strutils]
import helpers
import hns/[sim_types, objects, vision]

proc clearTheFloor(game: var SimServer, keep = 1) =
  ## Keep `keep` objects and park them out of the way, so a sightline test
  ## measures the thing it is about rather than whatever the deal happened to
  ## drop in the middle of the hall.
  game.objects.setLen(keep)
  for i in 0 ..< game.objects.len:
    game.objects[i].x = 24
    game.objects[i].y = 24 + i * 72
  game.rasterizeObjects()
  inc game.geometryEpoch
  game.invalidateFovCaches()

proc placeCrateBetween(game: var SimServer, seeker, hider: int): int =
  ## Drops the first crate exactly between the two cogs and returns its index.
  for i, obj in game.objects:
    if obj.kind != okCrate:
      continue
    # Every other cog must be out of the way of the drop.
    let
      cx = (game.players[seeker].x + game.players[hider].x) div 2
      cy = (game.players[seeker].y + game.players[hider].y) div 2
    var rect = objectRect(obj)
    let dx = cx - (rect.x + rect.w div 2)
    let dy = cy - (rect.y + rect.h div 2)
    game.moveObject(i, dx, dy)
    return i
  -1

block aCrateHidesAHiderAndDraggingItAsideRevealsThem:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  game.matchPhase = phaseHunt
  game.clearTheFloor(keep = 1)
  let
    seeker = 1
    hider = 0
  # A clear stretch of the hall, seeker aiming east at the hider.
  game.placePlayer(seeker, 300, 300)
  game.players[seeker].aimBrads = 0
  game.placePlayer(hider, 420, 300)
  discard game.refreshPlayerFov(seeker)
  check game.playerVisibleTo(seeker, hider),
    "the seeker cannot see a hider 120 px straight ahead on open floor"
  let crate = game.placeCrateBetween(seeker, hider)
  check crate >= 0, "no crate to place"
  discard game.refreshPlayerFov(seeker)
  check not game.playerVisibleTo(seeker, hider),
    "a crate between them did not block the sightline"
  # Drag it aside: the dirty-rect rebuild and the epoch invalidation mean the
  # hider is visible again on the VERY NEXT tick.
  let epochBefore = game.geometryEpoch
  game.moveObject(crate, 0, -200)
  check game.geometryEpoch > epochBefore,
    "moving an object did not bump geometryEpoch"
  discard game.refreshPlayerFov(seeker)
  check game.playerVisibleTo(seeker, hider),
    "dragging the crate aside did not restore the sightline"

block theBubbleDoesNotSeeThroughAWall:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  game.matchPhase = phaseHunt
  game.clearTheFloor(keep = 0)
  # Find a wall with floor on both sides, and put a cog either side of it.
  var placed = false
  for wall in game.gameMap.walls:
    if wall.w != 16 or wall.h < 64:
      continue
    let
      west = wall.x - PlayerHalf - 4
      east = wall.x + wall.w + PlayerHalf + 4
      y = wall.y + wall.h div 2
    if not game.canOccupy(west, y) or not game.canOccupy(east, y):
      continue
    game.placePlayer(1, west, y)
    game.players[1].aimBrads = 0
    game.placePlayer(0, east, y)
    discard game.refreshPlayerFov(1)
    check not game.playerVisibleTo(1, 0),
      "the 48 px bubble saw straight through a 16 px wall"
    placed = true
    break
  check placed, "the room has no wall to test the bubble against"

block afrozenSeekersFovIsNeverComputed:
  var h = newHarness()
  # During prep the seekers are skipped entirely by the fov refresh.
  for tick in 1 .. 30:
    h.stepOnce()
  check h.game.matchPhase == phasePrep, "the harness left prep too early"
  for slot in 0 ..< h.game.players.len:
    if h.game.players[slot].team != Blue:
      continue
    check not h.game.fovCaches[slot].valid,
      "a frozen seeker's fov was computed during prep"

block aFullRebuildAndAnIncrementalOneAgreeCellForCell:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var rng = initRand(9)
  for move in 1 .. 500:
    let index = rng.rand(game.objects.len - 1)
    let dx = rng.rand(-2 .. 2)
    let dy = rng.rand(-2 .. 2)
    var rect = objectRect(game.objects[index])
    rect.x += dx
    rect.y += dy
    if not game.canPlaceObject(index, rect, -1):
      continue
    game.moveObject(index, dx, dy)
  let mask = game.objectMask
  let fov = game.fovBlocked
  game.rasterizeObjects()
  var maskDiffs, fovDiffs = 0
  for i in 0 ..< mask.len:
    if mask[i] != game.objectMask[i]:
      inc maskDiffs
  for i in 0 ..< fov.len:
    if fov[i] != game.fovBlocked[i]:
      inc fovDiffs
  check maskDiffs == 0,
    $maskDiffs & " objectMask cells differ after 500 incremental moves"
  check fovDiffs == 0,
    $fovDiffs & " fovBlocked cells differ after 500 incremental moves"

echo "test_hns_vision: ok"
