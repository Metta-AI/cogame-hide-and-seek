## The room: geometry, the authored spec document, the load-time validator,
## the static wall mask and the process-wide install choke point.
##
## Forked from coworld-ctf's `src/ctf/arena.nim` and HEAVILY CUT: the terrain
## generator, the curated pool, the symmetry lift, the endzones, the puddles,
## the trenches and the spinning diamonds are all DELETED with the mechanics
## that needed them. What survives is the part this game uses — the map-install
## choke point (`selectHnsMap`), the spec document (`mapSpecJson` /
## `mapFromSpecJson`), `inRect`, the wall-mask rasteriser and the walkability
## sweep — plus the four new spec arrays this game's rooms carry
## (`regions`, `doors`, `anchors`, `objectSpawns`).
##
## Rooms are AUTHORED, never generated: the episode's room is
## `pool[seed mod 3]` and the three documents are committed under
## `data/rooms/`. A replay pins the resolved document, not the room's name, so
## a later edit to a committed room cannot change what an old replay renders.

import
  std/[json, os, tables],
  sim_types

const
  RoomWallThickness* = 16
  RoomDoorWidth* = 56
  RoomNames*: array[3, string] = ["warren", "atrium", "long_hall"]
  MinObjectSpawns* = 14
  MinPocketAnchors* = 6
  HiderPads* = 3
  SeekerPads* = 3

var
  RoomMapG*: HnsMap  ## the installed room; read through the accessors below.

proc inRect*(x, y: int, rect: MapRect): bool {.inline.} =
  x >= rect.x and x < rect.x + rect.w and
    y >= rect.y and y < rect.y + rect.h

proc rectsIntersect*(a, b: MapRect): bool {.inline.} =
  a.x < b.x + b.w and b.x < a.x + a.w and
    a.y < b.y + b.h and b.y < a.y + a.h

proc anchorKindText*(kind: AnchorKind): string =
  case kind
  of anchorPocket: "pocket"
  of anchorPad: "pad"
  of anchorPatrol: "patrol"

proc parseAnchorKind(text: string): AnchorKind =
  case text
  of "pocket": anchorPocket
  of "pad": anchorPad
  of "patrol": anchorPatrol
  else: raise newException(HnsError, "unknown anchor kind: " & text)

proc anchorTeamText*(team: AnchorTeam): string =
  case team
  of anchorAnyTeam: ""
  of anchorHiders: "hiders"
  of anchorSeekers: "seekers"

proc parseAnchorTeam(node: JsonNode): AnchorTeam =
  if node == nil or node.kind == JNull:
    return anchorAnyTeam
  case node.getStr()
  of "", "null": anchorAnyTeam
  of "hiders": anchorHiders
  of "seekers": anchorSeekers
  else: raise newException(HnsError, "unknown anchor team: " & node.getStr())

proc axisText*(axis: ObjectAxis): string =
  case axis
  of axH: "h"
  of axV: "v"

proc parseAxis(text: string): ObjectAxis =
  case text
  of "h": axH
  of "v": axV
  else: raise newException(HnsError, "unknown axis: " & text)

proc rect(x, y, w, h: int): MapRect = MapRect(x: x, y: y, w: w, h: h)

# ---------------------------------------------------------------------------
# Queries against a room that is NOT installed (pure functions of the map).
# ---------------------------------------------------------------------------

proc mapWallAt*(gameMap: HnsMap, x, y: int): bool =
  ## Static wall at one map pixel. Outside the board is wall.
  if x < 0 or y < 0 or x >= gameMap.width or y >= gameMap.height:
    return true
  for wall in gameMap.walls:
    if inRect(x, y, wall):
      return true
  false

proc footprintClear*(gameMap: HnsMap, x, y: int, half = PlayerHalf): bool =
  ## True when a solid body centred here clears every static wall.
  for dy in -half .. half:
    for dx in -half .. half:
      if gameMap.mapWallAt(x + dx, y + dy):
        return false
  true

proc rasterizeWallMask*(gameMap: HnsMap): seq[bool] =
  ## `mapWallAt` for every pixel at once, bit-identical to querying them one
  ## at a time. Painting each rect over its own box costs area + the sum of
  ## the box areas instead of area x rects.
  let
    w = gameMap.width
    h = gameMap.height
  result = newSeq[bool](w * h)
  for wall in gameMap.walls:
    let
      x0 = max(wall.x, 0)
      y0 = max(wall.y, 0)
      x1 = min(wall.x + wall.w - 1, w - 1)
      y1 = min(wall.y + wall.h - 1, h - 1)
    for y in y0 .. y1:
      for x in x0 .. x1:
        result[y * w + x] = true

proc regionAt*(gameMap: HnsMap, x, y: int): int =
  ## Index of the region containing this point, or -1.
  for i, region in gameMap.regions:
    if inRect(x, y, region.box):
      return i
  -1

proc regionById*(gameMap: HnsMap, id: string): int =
  for i, region in gameMap.regions:
    if region.id == id:
      return i
  -1

proc doorById*(gameMap: HnsMap, id: string): int =
  for i, door in gameMap.doors:
    if door.id == id:
      return i
  -1

proc anchorById*(gameMap: HnsMap, id: string): int =
  for i, anchor in gameMap.anchors:
    if anchor.id == id:
      return i
  -1

proc anchorsOf*(gameMap: HnsMap, kind: AnchorKind,
                team = anchorAnyTeam): seq[RoomAnchor] =
  for anchor in gameMap.anchors:
    if anchor.kind == kind and (team == anchorAnyTeam or anchor.team == team):
      result.add(anchor)

proc padsFor*(gameMap: HnsMap, team: AnchorTeam): seq[RoomAnchor] =
  gameMap.anchorsOf(anchorPad, team)

proc resolvePoint*(gameMap: HnsMap, id: string): tuple[x, y: int, ok: bool] =
  ## Resolves a published anchor / door / region id to a point. This is what
  ## a reply's `at` field means, and it WINS over `to`.
  let anchor = gameMap.anchorById(id)
  if anchor >= 0:
    return (gameMap.anchors[anchor].x, gameMap.anchors[anchor].y, true)
  let door = gameMap.doorById(id)
  if door >= 0:
    return (gameMap.doors[door].x, gameMap.doors[door].y, true)
  let region = gameMap.regionById(id)
  if region >= 0:
    let box = gameMap.regions[region].box
    return (box.x + box.w div 2, box.y + box.h div 2, true)
  (0, 0, false)

# ---------------------------------------------------------------------------
# The spec document
# ---------------------------------------------------------------------------

proc mapSpecJson*(gameMap: HnsMap): string =
  ## The room as the document a replay pins. Field order is stable so the
  ## same room always serialises to the same bytes.
  var walls = newJArray()
  for wall in gameMap.walls:
    walls.add(%*[wall.x, wall.y, wall.w, wall.h])
  var regions = newJArray()
  for region in gameMap.regions:
    var doors = newJArray()
    for door in region.doors:
      doors.add(%door)
    regions.add(%*{
      "id": region.id,
      "name": region.name,
      "box": [region.box.x, region.box.y, region.box.w, region.box.h],
      "doors": doors
    })
  var doors = newJArray()
  for door in gameMap.doors:
    doors.add(%*{
      "id": door.id,
      "at": [door.x, door.y],
      "w": door.w,
      "axis": (if door.vertical: "v" else: "h")
    })
  var anchors = newJArray()
  for anchor in gameMap.anchors:
    anchors.add(%*{
      "id": anchor.id,
      "kind": anchorKindText(anchor.kind),
      "at": [anchor.x, anchor.y],
      "team": anchorTeamText(anchor.team)
    })
  var spawns = newJArray()
  for spawn in gameMap.objectSpawns:
    var kinds = newJArray()
    if spawn.crate: kinds.add(%"crate")
    if spawn.panel: kinds.add(%"panel")
    if spawn.ramp: kinds.add(%"ramp")
    spawns.add(%*{
      "at": [spawn.x, spawn.y],
      "kinds": kinds,
      "axis": axisText(spawn.axis)
    })
  let node = %*{
    "name": gameMap.name,
    "w": gameMap.width,
    "h": gameMap.height,
    "symmetry": "symNone",
    "walls": walls,
    "regions": regions,
    "doors": doors,
    "anchors": anchors,
    "objectSpawns": spawns
  }
  $node

proc readRect(node: JsonNode, what: string): MapRect =
  if node == nil or node.kind != JArray or node.len != 4:
    raise newException(HnsError, what & " must be [x, y, w, h]")
  rect(node[0].getInt(), node[1].getInt(), node[2].getInt(), node[3].getInt())

proc readPointNode(node: JsonNode, what: string): tuple[x, y: int] =
  if node == nil or node.kind != JArray or node.len != 2:
    raise newException(HnsError, what & " must be [x, y]")
  (node[0].getInt(), node[1].getInt())

proc validateRoom*(gameMap: HnsMap) =
  ## LOAD-TIME VALIDATION (§The room). `tests/test_hns_room.nim` runs this
  ## over every committed room and the server refuses to start on a failure.
  if gameMap.width <= 0 or gameMap.height <= 0:
    raise newException(HnsError, "room " & gameMap.name & " has no extent")
  for i, wall in gameMap.walls:
    if wall.w <= 0 or wall.h <= 0:
      raise newException(HnsError,
        "room " & gameMap.name & " wall " & $i & " is empty")
    if wall.x < 0 or wall.y < 0 or
        wall.x + wall.w > gameMap.width or wall.y + wall.h > gameMap.height:
      raise newException(HnsError,
        "room " & gameMap.name & " wall " & $i & " leaves the board")
  # Every region id is unique and every region's doors exist.
  var seenRegions = initTable[string, int]()
  for i, region in gameMap.regions:
    if region.id in seenRegions:
      raise newException(HnsError,
        "room " & gameMap.name & " region id " & region.id & " is duplicated")
    seenRegions[region.id] = i
    for doorId in region.doors:
      if gameMap.doorById(doorId) < 0:
        raise newException(HnsError,
          "room " & gameMap.name & " region " & region.id &
          " names unknown door " & doorId)
  # Every door is a real gap between EXACTLY TWO regions.
  for door in gameMap.doors:
    var joined = 0
    for region in gameMap.regions:
      if door.id in region.doors:
        inc joined
    if joined != 2:
      raise newException(HnsError,
        "room " & gameMap.name & " door " & door.id & " joins " & $joined &
        " regions, must join exactly 2")
    if gameMap.mapWallAt(door.x, door.y):
      raise newException(HnsError,
        "room " & gameMap.name & " door " & door.id & " is inside a wall")
  # Anchors and object spawns are on walkable floor with the full footprint.
  for anchor in gameMap.anchors:
    if not gameMap.footprintClear(anchor.x, anchor.y):
      raise newException(HnsError,
        "room " & gameMap.name & " anchor " & anchor.id &
        " has no clearance for a 12 px body")
  for i, spawn in gameMap.objectSpawns:
    if not spawn.crate and not spawn.panel and not spawn.ramp:
      raise newException(HnsError,
        "room " & gameMap.name & " objectSpawn " & $i & " accepts no kind")
    if not gameMap.footprintClear(spawn.x, spawn.y):
      raise newException(HnsError,
        "room " & gameMap.name & " objectSpawn " & $i & " is not on floor")
  if gameMap.objectSpawns.len < MinObjectSpawns:
    raise newException(HnsError,
      "room " & gameMap.name & " has " & $gameMap.objectSpawns.len &
      " objectSpawns, needs " & $MinObjectSpawns)
  if gameMap.anchorsOf(anchorPocket).len < MinPocketAnchors:
    raise newException(HnsError,
      "room " & gameMap.name & " has fewer than " & $MinPocketAnchors &
      " pocket anchors")
  if gameMap.padsFor(anchorHiders).len != HiderPads:
    raise newException(HnsError,
      "room " & gameMap.name & " must have exactly " & $HiderPads &
      " hider pads")
  if gameMap.padsFor(anchorSeekers).len != SeekerPads:
    raise newException(HnsError,
      "room " & gameMap.name & " must have exactly " & $SeekerPads &
      " seeker pads")

proc validateMapWalkability*(gameMap: HnsMap) =
  ## Every region is reachable from every seeker pad over walkable floor
  ## WITH NO OBJECTS PLACED. A flood fill on the 8 px fov grid, the same
  ## granularity the sealed-fort scan uses, so the two agree about what a
  ## body can fit through.
  let
    cell = FovCellSize
    gw = (gameMap.width + cell - 1) div cell
    gh = (gameMap.height + cell - 1) div cell
  var open = newSeq[bool](gw * gh)
  for cy in 0 ..< gh:
    for cx in 0 ..< gw:
      let
        px = cx * cell + cell div 2
        py = cy * cell + cell div 2
      open[cy * gw + cx] = gameMap.footprintClear(px, py, PlayerHalf)
  for pad in gameMap.padsFor(anchorSeekers):
    var
      seen = newSeq[bool](gw * gh)
      queue = @[(pad.x div cell, pad.y div cell)]
    seen[(pad.y div cell) * gw + pad.x div cell] = true
    var head = 0
    while head < queue.len:
      let (cx, cy) = queue[head]
      inc head
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= gw or ny >= gh:
          continue
        let index = ny * gw + nx
        if seen[index] or not open[index]:
          continue
        seen[index] = true
        queue.add((nx, ny))
    for region in gameMap.regions:
      var reached = false
      let
        x0 = region.box.x div cell
        y0 = region.box.y div cell
        x1 = min((region.box.x + region.box.w - 1) div cell, gw - 1)
        y1 = min((region.box.y + region.box.h - 1) div cell, gh - 1)
      for cy in y0 .. y1:
        for cx in x0 .. x1:
          if seen[cy * gw + cx]:
            reached = true
      if not reached:
        raise newException(HnsError,
          "room " & gameMap.name & ": region " & region.id &
          " is unreachable from seeker pad " & pad.id)

proc mapFromSpecJson*(text: string): HnsMap =
  ## Parses a room document and validates it. This is the ONLY way a room
  ## enters the engine, live or on playback.
  let node =
    try: parseJson(text)
    except CatchableError as error:
      raise newException(HnsError, "room spec is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(HnsError, "room spec must be a JSON object")
  result.name = node{"name"}.getStr("room")
  result.width = node{"w"}.getInt(0)
  result.height = node{"h"}.getInt(0)
  result.center = MapPoint(x: result.width div 2, y: result.height div 2)
  result.mapLayer = MapLayerId
  result.walkLayer = MapLayerId
  result.wallLayer = MapLayerId
  if node.hasKey("walls"):
    for wall in node["walls"]:
      result.walls.add(readRect(wall, "wall"))
  if node.hasKey("regions"):
    for region in node["regions"]:
      var entry = RoomRegion(
        id: region{"id"}.getStr(),
        name: region{"name"}.getStr(),
        box: readRect(region{"box"}, "region box")
      )
      if region.hasKey("doors"):
        for door in region["doors"]:
          entry.doors.add(door.getStr())
      result.regions.add(entry)
  if node.hasKey("doors"):
    for door in node["doors"]:
      let at = readPointNode(door{"at"}, "door at")
      result.doors.add(RoomDoor(
        id: door{"id"}.getStr(),
        x: at.x,
        y: at.y,
        w: door{"w"}.getInt(RoomDoorWidth),
        vertical: door{"axis"}.getStr("v") == "v"
      ))
  if node.hasKey("anchors"):
    for anchor in node["anchors"]:
      let at = readPointNode(anchor{"at"}, "anchor at")
      result.anchors.add(RoomAnchor(
        id: anchor{"id"}.getStr(),
        kind: parseAnchorKind(anchor{"kind"}.getStr()),
        x: at.x,
        y: at.y,
        team: parseAnchorTeam(anchor{"team"})
      ))
  if node.hasKey("objectSpawns"):
    for spawn in node["objectSpawns"]:
      let at = readPointNode(spawn{"at"}, "objectSpawn at")
      var entry = ObjectSpawn(
        x: at.x,
        y: at.y,
        axis: parseAxis(spawn{"axis"}.getStr("h"))
      )
      if spawn.hasKey("kinds"):
        for kind in spawn["kinds"]:
          case kind.getStr()
          of "crate": entry.crate = true
          of "panel": entry.panel = true
          of "ramp": entry.ramp = true
          else:
            raise newException(HnsError,
              "unknown objectSpawn kind: " & kind.getStr())
      result.objectSpawns.add(entry)
  result.validateRoom()
  result.validateMapWalkability()

# ---------------------------------------------------------------------------
# Loading the committed rooms
# ---------------------------------------------------------------------------

proc gameDir*(): string =
  ## The directory `data/` lives under. The Docker image puts the binary at
  ## /bin and the assets at the WORKDIR, so a relative `data/` works there;
  ## a dev run from the repo root works too.
  if dirExists("data"):
    return "."
  let exeDir = getAppDir()
  if dirExists(exeDir / "data"):
    return exeDir
  if dirExists(exeDir / ".." / "data"):
    return exeDir / ".."
  "."

proc roomPath*(name: string): string =
  gameDir() / "data" / "rooms" / ("room_" & name & ".json")

proc loadRoomByName*(name: string): HnsMap =
  let path = roomPath(name)
  if not fileExists(path):
    raise newException(HnsError, "room document not found: " & path)
  mapFromSpecJson(readFile(path))

proc roomPool*(poolName: string): seq[string] =
  ## The names a config's `roomPool` selects between.
  if poolName.len == 0 or poolName == "all":
    @[RoomNames[0], RoomNames[1], RoomNames[2]]
  else:
    for name in RoomNames:
      if name == poolName:
        return @[poolName]
    raise newException(HnsError, "unknown roomPool: " & poolName)

proc pickRoom*(poolName: string, seed: int): HnsMap =
  ## `room = pool[seed mod 3]` — the idea's "room layout seeded", without the
  ## implementation-defined behaviour of a procedural generator.
  let pool = roomPool(poolName)
  var index = seed mod pool.len
  if index < 0:
    index += pool.len
  loadRoomByName(pool[index])

proc selectHnsMap*(gameMap: HnsMap) =
  ## Installs one room as THE room for this process: dimensions, the fog
  ## grid, and the map-relative ranges. Runs before any sim, mask or render
  ## work; the render bakes assume the room never changes afterwards.
  RoomMapG = gameMap
  MapWidth = gameMap.width
  MapHeight = gameMap.height
  FovGridW = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount = FovGridW * FovGridH
  ShoutRange = MapWidth div 5

proc resolveRoom*(config: GameConfig): HnsMap =
  ## The room a config plays on: the pinned `mapSpec` document if it has one
  ## (every replay does), else the seeded pick from the pool.
  if config.mapSpec.len > 0:
    mapFromSpecJson(config.mapSpec)
  else:
    pickRoom(config.roomPool, config.seed)

proc loadHnsMap*(config: GameConfig): HnsMap =
  result = resolveRoom(config)
  selectHnsMap(result)

proc installDefaultRoom*() =
  ## Installs the first committed room into the process-wide globals, for
  ## code that touches them before building a sim (tests, tools).
  selectHnsMap(loadRoomByName(RoomNames[0]))
