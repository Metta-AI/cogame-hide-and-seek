## 18. The seeded setup stream: the room, the object deal and the hider pads
## are pure functions of the seed, and NOTHING a seat does can shift them.

import std/[json, strutils]
import helpers
import hns/[sim_types, room]

proc dealOf(game: SimServer): seq[string] =
  for obj in game.objects:
    result.add(obj.id & "@" & $obj.spawnX & "," & $obj.spawnY & ":" &
      objectKindText(obj.kind) & axisText(obj.axis))

block roomIsPoolModThree:
  for seed in [0, 1, 2, 3, 4, 5, 41, 42, 43]:
    var config = defaultGameConfig()
    config.seed = seed
    config.roomPool = "all"
    let picked = pickRoom("all", seed)
    check picked.name == RoomNames[seed mod 3],
      "seed " & $seed & " picked " & picked.name & ", expected " &
      RoomNames[seed mod 3]

block dealIsAPureFunctionOfSeedAndRoom:
  for seed in [42, 7, 1234]:
    let a = newTestSim(%*{"seed": seed, "roomPool": "all"})
    let b = newTestSim(%*{"seed": seed, "roomPool": "all"})
    check dealOf(a) == dealOf(b),
      "two sims on seed " & $seed & " dealt different furniture"
  let one = newTestSim(%*{"seed": 42, "roomPool": "warren"})
  let two = newTestSim(%*{"seed": 43, "roomPool": "warren"})
  check dealOf(one) != dealOf(two),
    "two different seeds dealt the identical furniture on one room"

block dealRespectsTheRequestedCounts:
  let game = newTestSim(%*{"seed": 42, "roomPool": "warren",
                           "crates": 4, "panels": 2, "ramps": 2})
  var crates, panels, ramps = 0
  for obj in game.objects:
    case obj.kind
    of okCrate: inc crates
    of okPanel: inc panels
    of okRamp: inc ramps
  check crates == 4, "dealt " & $crates & " crates, asked for 4"
  check panels == 2, "dealt " & $panels & " panels, asked for 2"
  check ramps == 2, "dealt " & $ramps & " ramps, asked for 2"

block hiderPadsComeFromTheSameStream:
  var a = newTestSim(%*{"seed": 42})
  a.seatAll()
  a.startGame()
  var b = newTestSim(%*{"seed": 42})
  b.seatAll()
  b.startGame()
  for slot in 0 ..< a.players.len:
    check (a.players[slot].homeX, a.players[slot].homeY) ==
      (b.players[slot].homeX, b.players[slot].homeY),
      "seed 42 dealt slot " & $slot & " two different pads"

block seatBehaviourCannotShiftTheDraw:
  ## The anti-collusion pin: the room and the deal are drawn BEFORE any seat
  ## connects, so a sim that seats nobody deals identically to one that seats
  ## six and plays a hundred ticks.
  let quiet = newTestSim(%*{"seed": 42})
  var busy = newTestSim(%*{"seed": 42})
  busy.seatAll()
  busy.startGame()
  check dealOf(quiet) == dealOf(busy),
    "seating cogs changed the object deal"
  check quiet.roomName == busy.roomName, "seating cogs changed the room"

block theReplayPinsTheDocumentNotTheName:
  var config = defaultGameConfig()
  config.update($(%*{"seed": 42, "roomPool": "warren", "num_agents": 6}))
  check config.mapSpec.len > 0, "the config did not pin a room document"
  let pinned = parseJson(config.mapSpec)
  check pinned{"name"}.getStr() == "warren",
    "the pinned document is not the picked room"
  check pinned{"walls"}.len > 0, "the pinned document carries no walls"
  # The echo carries it, so the replay bytes carry it.
  check "mapSpec" in config.configJson(),
    "the config echo dropped the room document"

echo "test_hns_seeding: ok"
