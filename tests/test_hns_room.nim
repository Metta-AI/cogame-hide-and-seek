## 16. The three committed rooms: pinned bytes, a parse through the real
## loader, and every load-time invariant the server refuses to start without.

import std/[os, strutils]
import crunchy
import helpers
import hns/[sim_types, room]

const RoomShas = [
  ("warren", "f323d25fac07ccd599e3167666ee2a1f6eb656917293925385bea9853f39802b"),
  ("atrium", "b37ebaa922da612717bb0f0f58973de5152f778ef6274ce88d25c2b01023848e"),
  ("long_hall", "1df111b14e23f372fd3c8a4949dc8a5f8c405d0d9706e296510b9bee1ebd6027")
]
  ## Re-author a room with `scripts/rooms/author_rooms.py` and re-pin its
  ## digest HERE in the same commit — a room change is a GameVersion bump,
  ## because an old replay's pinned mapSpec would no longer be what the file
  ## says.

proc sha256Hex(data: string): string =
  var hex = ""
  for b in sha256(data):
    hex.add(toHex(b).toLowerAscii())
  hex

block pinnedBytes:
  for (name, want) in RoomShas:
    let path = "data/rooms/room_" & name & ".json"
    check fileExists(path), "missing room document " & path
    let got = sha256Hex(readFile(path))
    check got == want,
      "room " & name & " changed: sha256 is " & got & ", pinned " & want &
      ". Re-pin it here IN THE SAME COMMIT and bump GameVersion."

block everyRoomLoadsAndValidates:
  for (name, _) in RoomShas:
    let gameMap = loadRoomByName(name)
    check gameMap.name == name, "room " & name & " names itself " & gameMap.name
    check gameMap.width == 720 and gameMap.height == 400,
      "room " & name & " is not 720x400"
    for wall in gameMap.walls:
      check wall.x >= 0 and wall.y >= 0 and
        wall.x + wall.w <= gameMap.width and
        wall.y + wall.h <= gameMap.height,
        "room " & name & " has a wall outside the board"
    check gameMap.objectSpawns.len >= MinObjectSpawns,
      "room " & name & " has too few objectSpawns"
    check gameMap.anchorsOf(anchorPocket).len >= MinPocketAnchors,
      "room " & name & " has too few pockets"
    check gameMap.padsFor(anchorHiders).len == HiderPads,
      "room " & name & " does not have exactly three hider pads"
    check gameMap.padsFor(anchorSeekers).len == SeekerPads,
      "room " & name & " does not have exactly three seeker pads"
    for door in gameMap.doors:
      var joined = 0
      for region in gameMap.regions:
        if door.id in region.doors:
          inc joined
      check joined == 2,
        "room " & name & " door " & door.id & " joins " & $joined & " regions"
      check not gameMap.mapWallAt(door.x, door.y),
        "room " & name & " door " & door.id & " is inside a wall"
    for anchor in gameMap.anchors:
      check gameMap.footprintClear(anchor.x, anchor.y),
        "room " & name & " anchor " & anchor.id & " has no body clearance"
    for i, spawn in gameMap.objectSpawns:
      check gameMap.footprintClear(spawn.x, spawn.y),
        "room " & name & " objectSpawn " & $i & " is not on floor"
    # The walkability sweep the server runs at load.
    gameMap.validateMapWalkability()

block specRoundTrips:
  for (name, _) in RoomShas:
    let original = loadRoomByName(name)
    let reparsed = mapFromSpecJson(mapSpecJson(original))
    check reparsed.walls == original.walls, name & " walls did not round-trip"
    check reparsed.doors.len == original.doors.len,
      name & " doors did not round-trip"
    check reparsed.objectSpawns.len == original.objectSpawns.len,
      name & " objectSpawns did not round-trip"

block badSpecsAreRejected:
  var rejected = 0
  try:
    discard mapFromSpecJson("""{"name":"bad","w":720,"h":400,
      "walls":[[0,0,9999,16]],"regions":[],"doors":[],"anchors":[],
      "objectSpawns":[]}""")
  except HnsError:
    inc rejected
  check rejected == 1, "a wall leaving the board was accepted"
  try:
    discard mapFromSpecJson("not json at all")
    check false, "a non-JSON spec was accepted"
  except HnsError:
    discard

echo "test_hns_room: ok"
