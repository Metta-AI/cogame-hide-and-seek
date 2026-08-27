## The board compositor: the Sprite v1 packet the broadcast client and the
## wasm replay viewer both draw from.
##
## Forked from coworld-ctf's `src/ctf/global.nim` and HEAVILY CUT — every
## weapon, paint, hill, flag, pickup, barrier, trench, perk and first-person
## family is deleted with the mechanics that produced it. What survives is the
## sprite-pool discipline, the per-viewer dedup (`addSpriteChanged`), the map
## BANDS (one 1.09 MB map sprite exceeds the hosted 1 MiB websocket frame cap
## and the viewer closes with 1009), the retained-mode object diff and the
## broadcast-chrome smuggling channel.
##
## THE THREE NAMED EDITS (design note, §The three named edits to global.nim):
## 1. **Object pools** — `ObjectSpriteBase` (objects x body + padlock overlay)
##    and `ConeOverlayBase` (six vision wedges), filled in id/slot order and
##    emitted incrementally like any other object family.
## 2. **Vision cones are broadcast** for EVERY cog every frame, with its
##    `coneDeg`, `range`, `aim` and an `on` flag (false for a frozen seeker
##    during prep), because the cones are the spectator's whole understanding
##    of the game.
## 3. **Baked room bed** — the floor is tiled and darkened and the wall faces
##    textured ONCE per room at install (`map_art.bakeRoom`), so the per-frame
##    cost is six cogs, eight objects and the overlays.

import
  std/[math, strutils, tables],
  bitworld/pixelfonts, bitworld/spriteprotocol,
  pixie,
  labels, sim

const
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 never-drawn sprite whose LABEL carries the broadcast
    ## chrome JSON. The chrome used to ride a separate opt-in TextMessage;
    ## that channel does NOT survive a hosted replay, so smuggling it through
    ## the SAME binary channel the board rides makes it survive every playback
    ## path (live serve, generic client, hosted replay).
  MapBandSpriteBase* = 30
  MapBandObjectBase = 40
  MapBandHeight = 192           ## px rows per band at 1x.
  FogLayerId = 4
  U16SpriteIdCeiling = 65535

  CogSpriteBase = 100           ## team x aim step.
  CogObjectBase = 1000
  ObjSpriteBase = 2000          ## object index x lock state.
  ObjObjectBase = 2200
  PadlockSpriteId = 2300
  PadlockObjectBase = 2320
  SpottedRingSpriteId = 2340
  SpottedRingObjectBase = 2350
  ConeSpriteBase = 2400         ## six vision wedges.
  ConeObjectBase = 2500
  TetherSpriteBase = 2600
  TetherObjectBase = 2650
  ShoutSpriteBase = 2700
  ShoutObjectBase = 2760
  ShoutMaxCount* = 8

  RenderScale* {.intdefine.} = 2
    ## The spectator/replay board renders at RenderScale x the sim's map-pixel
    ## space. The sim, the gameHash and the player observation stream all stay
    ## in 1x map pixels.
  MaxSupersampledMapPixels* {.intdefine.} = 8_000_000
  WasmViewerBudgetBytes* = 1_600_000_000

  ConeSteps = 24                ## wedge rasterisation resolution.
  PadlockPx = 14

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  ## Oversize boards emit at 1x rather than blow the wasm32 viewer's address
  ## space. This 720x400 room is never oversize, but the rule is kept so a
  ## future room class degrades instead of aborting.
  if mapWidth * mapHeight * RenderScale * RenderScale >
      MaxSupersampledMapPixels:
    1
  else:
    RenderScale

proc predictedViewerRenderBytes*(mapWidth, mapHeight: int): int64 =
  let k = int64(boardRenderScaleFor(mapWidth, mapHeight))
  int64(mapWidth) * int64(mapHeight) * k * k * 4 * 3

var boardScale = 1

type
  SpriteDefinition = ref object
    spriteId: int
    width: int
    height: int
    label: string
    compressedPixels: seq[uint8]

  DebugOverlay* = object
    sprites*: Table[int, SpritePacketSpriteDef]
    objects*: Table[int, SpritePacketObject]

  GlobalViewerState* = object
    initialized*: bool
    objectIds*: seq[int]
    mouseX*: int
    mouseY*: int
    mouseLayer*: int
    mouseDown*: bool
    selectedJoinOrder*: int
    clickPending*: bool
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool
    fpMapSent*: bool
    shoutSlots*: array[ShoutMaxCount, string]
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = ref object
    initialized*: bool
    objectIds*: seq[int]
    ## Last placement payload sent per object id, flat-indexed by the u16 id
    ## (byte 11 = present flag). The protocol is RETAINED-MODE — a client
    ## keeps a placement until it is replaced or deleted — so an unchanged
    ## placement need never be re-sent. A flat array, not a Table: the
    ## per-object hashing was itself a profiler hot spot in the starter.
    sentPlacements*: seq[array[12, uint8]]
    pendingDebugSprites*: seq[seq[uint8]]
    debugSpriteLimitWarned*: bool
    spriteDefs: seq[SpriteDefinition]

proc initGlobalViewerState*(): GlobalViewerState =
  result.mouseLayer = MapLayerId
  result.selectedJoinOrder = -1
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc initPlayerViewerState*(): PlayerViewerState =
  new(result)

proc spriteDefinitionIndex(
  defs: openArray[SpriteDefinition],
  spriteId: int
): int =
  for i in 0 ..< defs.len:
    if defs[i].spriteId == spriteId:
      return i
  -1

proc addSpriteChanged(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string,
  changed = false
) =
  ## Appends a sprite definition when metadata or caller dirtiness changed.
  ## Every sprite MUST carry a non-empty label — the inspector and any wire
  ## reader both key off it, and an empty label silently re-sends forever.
  doAssert label.len > 0, "sprite " & $spriteId & " needs a non-empty label"
  doAssert spriteId >= 0 and spriteId <= U16SpriteIdCeiling,
    "sprite id " & $spriteId & " (" & label & ") crosses the u16 wire ceiling"
  let index = defs.spriteDefinitionIndex(spriteId)
  if index >= 0:
    if defs[index].width == width and
        defs[index].height == height and
        defs[index].label == label and
        not changed:
      return
    defs[index].width = width
    defs[index].height = height
    defs[index].label = label
  else:
    defs.add SpriteDefinition(
      spriteId: spriteId,
      width: width,
      height: height,
      label: label
    )
  packet.addSprite(spriteId, width, height, pixels, label)

proc addBoardObject(
  packet: var seq[uint8],
  objectId, x, y, z, layerId, spriteId: int
) =
  ## `addObject` for renderer emissions: placements on the zoomable board
  ## layers scale by boardScale; UI-layer placements pass through untouched.
  if layerId == MapLayerId or layerId == FogLayerId:
    packet.addObject(
      objectId, x * boardScale, y * boardScale, z, layerId, spriteId)
  else:
    packet.addObject(objectId, x, y, z, layerId, spriteId)

proc scaleSpritePixels(
  pixels: openArray[uint8],
  width, height, k: int
): seq[uint8] =
  ## Nearest-neighbour integer upscale of an RGBA sprite buffer.
  if k <= 1:
    return @pixels
  result = newSeq[uint8](width * k * height * k * 4)
  for y in 0 ..< height * k:
    let srcRow = (y div k) * width
    for x in 0 ..< width * k:
      let
        src = (srcRow + x div k) * 4
        dst = (y * width * k + x) * 4
      for c in 0 .. 3:
        result[dst + c] = pixels[src + c]

proc addBoardSpriteChanged(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  spriteId, width, height: int,
  pixels: openArray[uint8],
  label: string,
  changed = false,
  native = 1
) =
  ## `addSpriteChanged` for BOARD sprites: dimensions stay in logical map
  ## pixels and the wire sprite ships at boardScale x those dims. The dedup
  ## check runs BEFORE any upscale, so per-frame callers pay nothing when
  ## nothing changed.
  doAssert label.len > 0, "sprite " & $spriteId & " needs a non-empty label"
  let
    outW = width * boardScale
    outH = height * boardScale
  let index = defs.spriteDefinitionIndex(spriteId)
  if index >= 0 and defs[index].width == outW and
      defs[index].height == outH and
      defs[index].label == label and
      not changed:
    return
  if native == boardScale:
    packet.addSpriteChanged(defs, spriteId, outW, outH, pixels, label, changed)
  else:
    packet.addSpriteChanged(
      defs, spriteId, outW, outH,
      scaleSpritePixels(pixels, width, height, boardScale), label, changed)

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState,
  message: string
) =
  ## Applies one or more global protocol client messages.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = if item.hasLayer: item.layer else: MapLayerId
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      # Whole-string commands are intercepted before the legacy char-by-char
      # transport path, so a multi-digit tick is never mangled into speed
      # keystrokes.
      if item.text.startsWith("s:"):
        let tick = try: parseInt(item.text[2 .. ^1]) except ValueError: -1
        if tick >= 0:
          state.replaySeekTick = tick
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    of SpriteClientInputMessage:
      discard
    of SpriteClientReadyMessage, SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(
  state: var PlayerViewerState,
  message: string,
  inputMask: var uint8,
  pressedMask: var uint8,
  chatText: var string
) =
  ## Applies sprite player protocol input messages.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientInputMessage:
      pressedMask = pressedMask or (item.mask and not inputMask)
      inputMask = item.mask
    of SpriteClientDebugSpriteMessage:
      state.pendingDebugSprites.add(item.debugSprites)
    of SpriteClientMouseMoveMessage, SpriteClientMouseButtonMessage,
        SpriteClientReadyMessage:
      discard

# ---------------------------------------------------------------------------
# The board bed
# ---------------------------------------------------------------------------

var
  boardMapCache: seq[uint8]
  boardMapBandsCache: seq[uint8]
  boardMapBandsDefs: seq[SpriteDefinition]

proc invalidateBoardMapCaches*() =
  ## Drops every process-wide cache derived from the current room's pixels.
  ## Needed when the serve loop hot-switches replays: the new sim carries a
  ## new room, and these globals are keyed by nothing.
  boardMapCache = @[]
  boardMapBandsCache = @[]
  boardMapBandsDefs = @[]

proc boardMapPixels(sim: SimServer): seq[uint8] =
  if boardScale <= 1:
    return sim.mapRgba
  let expected = sim.gameMap.width * boardScale *
    sim.gameMap.height * boardScale * 4
  if boardMapCache.len != expected:
    boardMapCache = supersampledRoomRgba(sim.gameMap, sim.mapRgba, boardScale)
  boardMapCache

proc addMapBands(
  sim: SimServer,
  spriteDefs: var seq[SpriteDefinition],
  packet: var seq[uint8]
) =
  ## Emits the static room as a stack of horizontal bands instead of one giant
  ## sprite: each band is a full-width crop placed at its own y-offset on the
  ## map layer, and the client composites them into one seamless image. This
  ## keeps the room pixel-identical while ensuring no single sprite message
  ## approaches the hosted 1 MiB frame cap.
  let
    h = sim.gameMap.height
    outW = sim.gameMap.width * boardScale
    logicalBandH = max(1, MapBandHeight div (boardScale * boardScale))
  block:
    let sentinel = spriteDefs.spriteDefinitionIndex(MapBandSpriteBase)
    if sentinel >= 0 and spriteDefs[sentinel].width == outW:
      return
  if boardMapBandsCache.len > 0:
    for def in boardMapBandsDefs:
      let index = spriteDefs.spriteDefinitionIndex(def.spriteId)
      if index >= 0:
        spriteDefs[index] = def
      else:
        spriteDefs.add def
    packet.add boardMapBandsCache
    return
  let mapPixels = sim.boardMapPixels()
  var
    encoded: seq[uint8]
    encodedDefs: seq[SpriteDefinition]
    band = 0
    y0 = 0
  while y0 < h:
    let
      bandH = min(logicalBandH, h - y0)
      outBandH = bandH * boardScale
      outY0 = y0 * boardScale
    var bandPixels = newSeq[uint8](outW * outBandH * 4)
    copyMem(bandPixels[0].addr, mapPixels[outY0 * outW * 4].unsafeAddr,
      outW * outBandH * 4)
    let
      spriteId = MapBandSpriteBase + band
      objectId = MapBandObjectBase + band
    encoded.addSpriteChanged(
      encodedDefs, spriteId, outW, outBandH, bandPixels,
      LabelMapBand & " " & $band)
    encoded.addBoardObject(objectId, 0, y0, low(int16), MapLayerId, spriteId)
    inc band
    y0 += bandH
  boardMapBandsCache = encoded
  boardMapBandsDefs = encodedDefs
  for def in encodedDefs:
    let index = spriteDefs.spriteDefinitionIndex(def.spriteId)
    if index >= 0:
      spriteDefs[index] = def
    else:
      spriteDefs.add def
  packet.add encoded

# ---------------------------------------------------------------------------
# The families
# ---------------------------------------------------------------------------

proc rgbaBuffer(w, h: int): seq[uint8] =
  newSeq[uint8](w * h * 4)

proc putPixel(buf: var seq[uint8], w, x, y: int, color: ColorRGBA) =
  let index = (y * w + x) * 4
  if index < 0 or index + 3 >= buf.len:
    return
  buf[index] = color.r
  buf[index + 1] = color.g
  buf[index + 2] = color.b
  buf[index + 3] = color.a

proc buildPadlockSprite(): seq[uint8] =
  ## The padlock glyph drawn on a locked object — the idea's "annotate locked
  ## objects" ask, and the one board annotation that must NEVER be dropped,
  ## even under `.tiny`.
  let n = PadlockPx
  result = rgbaBuffer(n, n)
  let
    body = rgba(250, 226, 120, 255)
    edge = rgba(40, 32, 12, 255)
  for y in n div 2 - 1 ..< n - 1:
    for x in 2 ..< n - 2:
      let onEdge = x == 2 or x == n - 3 or y == n div 2 - 1 or y == n - 2
      result.putPixel(n, x, y, if onEdge: edge else: body)
  # The shackle.
  for x in 4 ..< n - 4:
    result.putPixel(n, x, 2, edge)
  for y in 2 ..< n div 2 - 1:
    result.putPixel(n, 4, y, edge)
    result.putPixel(n, n - 5, y, edge)
  # The keyhole.
  result.putPixel(n, n div 2, n div 2 + 2, edge)
  result.putPixel(n, n div 2, n div 2 + 3, edge)

proc buildSpottedRingSprite(): seq[uint8] =
  ## The red ring a hider wears while any cone is on it.
  let n = SoldierBodyPx + 8
  result = rgbaBuffer(n, n)
  let
    c = n div 2
    outer = c - 1
    inner = c - 4
  for y in 0 ..< n:
    for x in 0 ..< n:
      let d2 = (x - c) * (x - c) + (y - c) * (y - c)
      if d2 <= outer * outer and d2 >= inner * inner:
        result.putPixel(n, x, y, rgba(236, 72, 60, 220))

proc buildConeSprite(range, coneDeg, aimBrads: int,
                     seeker: bool): tuple[w, h: int, pixels: seq[uint8]] =
  ## One cog's torch beam as a translucent wedge, drawn into a square canvas
  ## centred on the cog. The sim clips the cone against walls and furniture;
  ## the board draws the unclipped wedge UNDER the objects, so an object drawn
  ## on top of it reads as the thing that stopped it.
  let
    n = range * 2 + 2
    c = n div 2
    tint =
      if seeker: rgba(250, 196, 84, 54)
      else: rgba(120, 168, 236, 34)
  var pixels = rgbaBuffer(n, n)
  let
    half = float(coneDeg) * PI / 180.0
    (ax, ay) = aimVector(aimBrads)
    cosHalf = cos(half)
  for y in 0 ..< n:
    for x in 0 ..< n:
      let
        vx = float(x - c)
        vy = float(y - c)
        d2 = vx * vx + vy * vy
      if d2 > float(range * range) or d2 < 1.0:
        continue
      if vx * ax + vy * ay < cosHalf * sqrt(d2):
        continue
      var shade = tint
      let fade = 1.0 - sqrt(d2) / float(range)
      shade.a = uint8(float(tint.a) * (0.35 + 0.65 * fade))
      pixels.putPixel(n, x, y, shade)
  (n, n, pixels)

proc buildTetherSprite(dx, dy: int): tuple[w, h: int, pixels: seq[uint8]] =
  ## The line from a dragging cog to the object it holds.
  let
    w = max(2, abs(dx) + 2)
    h = max(2, abs(dy) + 2)
    steps = max(abs(dx), abs(dy))
  var pixels = rgbaBuffer(w, h)
  let
    x0 = if dx >= 0: 1 else: w - 2
    y0 = if dy >= 0: 1 else: h - 2
  for step in 0 .. steps:
    if (step div 3) mod 2 == 1:
      continue
    let
      px = x0 + (if steps == 0: 0 else: dx * step div steps)
      py = y0 + (if steps == 0: 0 else: dy * step div steps)
    pixels.putPixel(w, clamp(px, 0, w - 1), clamp(py, 0, h - 1),
      rgba(236, 232, 210, 190))
  (w, h, pixels)

proc buildShoutBubble(font: PixelFont, text: string):
    tuple[w, h: int, pixels: seq[uint8]] =
  ## The starter's chunky speech bubble, kept verbatim in shape: this is why
  ## `MaxSayRunes` stays at 10.
  let
    textW = max(1, font.textWidth(text))
    w = textW + 8
    h = font.height + 10
  var pixels = rgbaBuffer(w, h)
  for y in 0 ..< h - 4:
    for x in 0 ..< w:
      let border = x == 0 or x == w - 1 or y == 0 or y == h - 5
      pixels.putPixel(w, x, y,
        if border: rgba(24, 26, 34, 240) else: rgba(244, 244, 236, 235))
  for i in 0 ..< 4:
    for x in w div 2 - 3 + i ..< w div 2 + 3 - i:
      pixels.putPixel(w, x, h - 5 + i, rgba(244, 244, 236, 235))
  var penX = 4
  for ch in text:
    let glyph = font.glyphAt(ch)
    for gy in 0 ..< glyph.height:
      for gx in 0 ..< glyph.width:
        if glyph.glyphPixel(gx, gy):
          pixels.putPixel(w, penX + gx, 4 + gy, rgba(24, 26, 34, 255))
    penX += glyph.width + font.spacing
  (w, h, pixels)

proc objectLabel(obj: GameObject): string =
  case obj.kind
  of okCrate:
    if obj.lockedBy == lockNone: LabelCrate else: LabelLockedCrate
  of okPanel:
    if obj.lockedBy == lockNone: LabelPanel else: LabelLockedPanel
  of okRamp:
    if obj.lockedBy == lockNone: LabelRamp else: LabelLockedRamp

proc buildObjectSprite(obj: GameObject): seq[uint8] =
  ## The object's furniture tile, with a 2 px outline in the locking team's
  ## colour when it is locked.
  result = objectPixels(obj.kind, obj.w, obj.h)
  if obj.lockedBy == lockNone:
    return
  let outline =
    if obj.lockedBy == lockHiders: rgba(63, 124, 196, 255)
    else: rgba(224, 82, 58, 255)
  for y in 0 ..< obj.h:
    for x in 0 ..< obj.w:
      if x < 2 or y < 2 or x >= obj.w - 2 or y >= obj.h - 2:
        result.putPixel(obj.w, x, y, outline)

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

proc trackObject(ids: var seq[int], objectId: int) =
  ids.add(objectId)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  overlays: seq[DebugOverlay],
  tick: int,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int
): seq[uint8] =
  ## One frame of the board for one viewer: the room bands (once), then the
  ## cones, the objects with their padlocks, the cogs, the tethers and the
  ## shout bubbles, all diffed against what this viewer already holds.
  boardScale = boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height)
  nextState = state
  var
    packet: seq[uint8] = @[]
    ids: seq[int] = @[]
  if not nextState.initialized:
    nextState.initialized = true
    packet.addU8(0x04)
    packet.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    packet.addViewport(
      MapLayerId,
      sim.gameMap.width * boardScale,
      sim.gameMap.height * boardScale)
  sim.addMapBands(nextState.spriteDefs, packet)

  # --- 2. vision cones, for EVERY cog every frame -------------------------
  for i, player in sim.players:
    let
      slot = player.joinOrder
      frozen = sim.frozenSeeker(i)
      spriteId = ConeSpriteBase + slot
      objectId = ConeObjectBase + slot
    if frozen or not player.alive:
      continue
    let
      seeker = player.team == Blue
      cone = buildConeSprite(sim.config.sightRange, sim.config.visionConeDeg,
        player.aimBrads, seeker)
      label = LabelVisionCone & " " & $slot & " aim " & $player.aimBrads &
        " deg " & $sim.config.visionConeDeg & " range " &
        $sim.config.sightRange & " on"
    packet.addBoardSpriteChanged(nextState.spriteDefs, spriteId,
      cone.w, cone.h, cone.pixels, label)
    packet.addBoardObject(objectId, player.x - cone.w div 2,
      player.y - cone.h div 2, -900, MapLayerId, spriteId)
    ids.trackObject(objectId)

  # --- 1. the object pools ------------------------------------------------
  for i, obj in sim.objects:
    let
      spriteId = ObjSpriteBase + i
      objectId = ObjObjectBase + i
      label = objectLabel(obj) & " " & obj.id
    packet.addBoardSpriteChanged(nextState.spriteDefs, spriteId,
      obj.w, obj.h, buildObjectSprite(obj), label)
    packet.addBoardObject(objectId, obj.x, obj.y, obj.y, MapLayerId, spriteId)
    ids.trackObject(objectId)
    if obj.lockedBy != lockNone:
      let padlockObject = PadlockObjectBase + i
      packet.addBoardSpriteChanged(nextState.spriteDefs, PadlockSpriteId,
        PadlockPx, PadlockPx, buildPadlockSprite(), LabelPadlock)
      packet.addBoardObject(padlockObject,
        obj.x + obj.w div 2 - PadlockPx div 2,
        obj.y + obj.h div 2 - PadlockPx div 2,
        obj.y + 1, MapLayerId, PadlockSpriteId)
      ids.trackObject(padlockObject)

  # --- the cogs -----------------------------------------------------------
  for i, player in sim.players:
    if not player.alive:
      continue
    let
      slot = player.joinOrder
      rot = cogRotIndex(player.aimBrads)
      spriteId = CogSpriteBase + ord(player.team) * SoldierRotations + rot
      objectId = CogObjectBase + slot
      label = LabelCog & " " & roleLabel(player.team) & " " &
        LabelAimPrefix & $player.aimBrads
    packet.addSpriteChanged(nextState.spriteDefs, spriteId,
      SoldierCanvas * boardScale, SoldierCanvas * boardScale,
      cogRotPixels(player.team, rot, boardScale), label)
    packet.addBoardObject(objectId,
      player.x - SoldierDrawOff, player.y - SoldierDrawOff,
      player.y + (if player.airborne: 500 else: 2), MapLayerId, spriteId)
    ids.trackObject(objectId)
    # A hider inside a cone wears the ring.
    if player.team == Red:
      var seenNow = false
      for j in 0 ..< sim.players.len:
        if sim.players[j].team == Blue and sim.players[j].alive and
            not sim.frozenSeeker(j) and sim.playerVisibleTo(j, i):
          seenNow = true
      if seenNow:
        let ringObject = SpottedRingObjectBase + slot
        packet.addBoardSpriteChanged(nextState.spriteDefs, SpottedRingSpriteId,
          SoldierBodyPx + 8, SoldierBodyPx + 8, buildSpottedRingSprite(),
          LabelSpottedRing)
        packet.addBoardObject(ringObject,
          player.x - (SoldierBodyPx + 8) div 2,
          player.y - (SoldierBodyPx + 8) div 2,
          player.y + 3, MapLayerId, SpottedRingSpriteId)
        ids.trackObject(ringObject)
    # A cog dragging something gets a tether line to it.
    if player.holding >= 0 and player.holding < sim.objects.len:
      let
        obj = sim.objects[player.holding]
        dx = obj.x + obj.w div 2 - player.x
        dy = obj.y + obj.h div 2 - player.y
        tether = buildTetherSprite(dx, dy)
        tetherSprite = TetherSpriteBase + slot
        tetherObject = TetherObjectBase + slot
      packet.addBoardSpriteChanged(nextState.spriteDefs, tetherSprite,
        tether.w, tether.h, tether.pixels,
        LabelTether & " " & $slot & " " & $dx & "," & $dy, changed = true)
      packet.addBoardObject(tetherObject,
        min(player.x, obj.x + obj.w div 2) - 1,
        min(player.y, obj.y + obj.h div 2) - 1,
        player.y + 1, MapLayerId, tetherSprite)
      ids.trackObject(tetherObject)

  # --- the shout bubbles --------------------------------------------------
  var bubble = 0
  for shout in sim.recentShouts:
    if bubble >= ShoutMaxCount:
      break
    let
      art = buildShoutBubble(sim.shoutFont, shout.text)
      spriteId = ShoutSpriteBase + bubble
      objectId = ShoutObjectBase + bubble
    packet.addBoardSpriteChanged(nextState.spriteDefs, spriteId,
      art.w, art.h, art.pixels,
      LabelShoutBubble & " " & shout.text, changed = true)
    packet.addBoardObject(objectId,
      shout.x - art.w div 2, shout.y - SoldierBodyPx - art.h,
      shout.y + 400, MapLayerId, spriteId)
    ids.trackObject(objectId)
    inc bubble

  # --- retained-mode diff: delete what this viewer holds and we did not
  #     place this frame ----------------------------------------------------
  for objectId in state.objectIds:
    var stillThere = false
    for kept in ids:
      if kept == objectId:
        stillThere = true
        break
    if not stillThere:
      packet.addDeleteObject(objectId)
  nextState.objectIds = ids
  discard overlays
  discard tick
  discard playing
  discard speed
  discard maxTick
  discard looping
  discard transportEnabled
  discard mismatchTick
  packet

proc buildSpriteProtocolPlayerUpdates*(
  sim: var SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState,
  spritesOff = false
): seq[uint8] =
  ## The frame a SEAT's websocket gets. Seats send no inputs at all in this
  ## game — the server computes every mask — so this is the minimum the
  ## Sprite v1 contract requires: one layer, one viewport, and the seat's own
  ## aim readback marker.
  boardScale = 1
  nextState = if state.isNil: initPlayerViewerState() else: state
  var packet: seq[uint8] = @[]
  discard spritesOff
  if not nextState.initialized:
    nextState.initialized = true
    packet.addU8(0x04)
    packet.addLayer(MapLayerId, MapLayerType, ZoomableLayerFlag)
    packet.addViewport(MapLayerId, sim.gameMap.width, sim.gameMap.height)
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return packet
  let
    player = sim.players[playerIndex]
    rot = cogRotIndex(player.aimBrads)
    spriteId = CogSpriteBase + ord(player.team) * SoldierRotations + rot
  packet.addSpriteChanged(nextState.spriteDefs, spriteId,
    SoldierCanvas, SoldierCanvas, cogRotPixels(player.team, rot, 1),
    LabelCog & " " & roleLabel(player.team) & " " &
      LabelAimPrefix & $player.aimBrads)
  packet.addObject(CogObjectBase + player.joinOrder,
    player.x - SoldierDrawOff, player.y - SoldierDrawOff, player.y,
    MapLayerId, spriteId)
  packet

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one sprite-protocol packet into websocket-frame-sized chunks AT
  ## MESSAGE BOUNDARIES. The client parses each binary message independently
  ## and accumulates state across them, so a packet delivered as N frames is
  ## equivalent to one frame — as long as no frame is cut mid-message. Needed
  ## because the hosted replay closes any frame over 1 MiB (1009).
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    chunkStart = 0
  while offset < packet.len:
    let msgStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:  # sprite: id,w,h (6) + clen (4) + pixels + llen (2) + label
      let clen = packet.readU32(offset + 6)
      offset += 10 + clen
      let llen = packet.readU16(offset)
      offset += 2 + llen
    of 0x02: offset += 11   # object
    of 0x03: offset += 2    # delete object
    of 0x04: discard        # clear objects
    of 0x05: offset += 5    # viewport
    of 0x06: offset += 3    # layer
    else:
      break
    if offset - chunkStart > maxBytes and msgStart > chunkStart:
      result.add(packet[chunkStart ..< msgStart])
      chunkStart = msgStart
  if chunkStart < packet.len:
    result.add(packet[chunkStart ..< packet.len])

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Bakes the board bands before the first viewer connects, so the certifier's
  ## first frame is not a stall.
  boardScale = boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height)
  discard sim.boardMapPixels()
  for team in Team:
    for rot in 0 ..< SoldierRotations:
      discard cogRotPixels(team, rot, boardScale)

proc validateDebugSpritePacket*(packet: openArray[uint8]) =
  ## The debug-sprite channel is accepted and dropped: this game's seats send
  ## no inputs and no overlays.
  discard packet

proc applyDebugSpritePacket*(
  overlay: var DebugOverlay,
  packet: openArray[uint8]
) =
  discard overlay
  discard packet

proc boardObjectPoolName*(objectId: int): string =
  ## Which pool one board object id belongs to, for the traffic counters.
  if objectId >= MapBandObjectBase and objectId < MapBandObjectBase + 60:
    "map band"
  elif objectId >= CogObjectBase and objectId < CogObjectBase + MaxPlayers:
    "cog"
  elif objectId >= ObjObjectBase and objectId < ObjObjectBase + MaxObjects:
    "furniture"
  elif objectId >= PadlockObjectBase and
      objectId < PadlockObjectBase + MaxObjects:
    "padlock"
  elif objectId >= SpottedRingObjectBase and
      objectId < SpottedRingObjectBase + MaxPlayers:
    "spotted ring"
  elif objectId >= ConeObjectBase and objectId < ConeObjectBase + MaxPlayers:
    "vision cone"
  elif objectId >= TetherObjectBase and
      objectId < TetherObjectBase + MaxPlayers:
    "tether"
  elif objectId >= ShoutObjectBase and
      objectId < ShoutObjectBase + ShoutMaxCount:
    "shout bubble"
  else:
    "other"

proc stripSpritePixels*(
  packet: seq[uint8],
  keepLabel = ""
): seq[uint8] =
  ## Rewrites one sprite-protocol packet for a Sprites Off (0x87) client:
  ## sprite definitions keep id, dimensions, and label but ship a zero-length
  ## pixel payload; every other message passes through untouched. A sprite
  ## whose label equals keepLabel keeps its pixels.
  result = newSeqOfCap[uint8](packet.len)
  var offset = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:  # sprite: id,w,h (6) + clen (4) + pixels + llen (2) + label
      let compressedLen = packet.readU32(offset + 6)
      let labelStart = offset + 10 + compressedLen
      let labelLen = packet.readU16(labelStart)
      let messageEnd = labelStart + 2 + labelLen
      var label = newString(labelLen)
      for i in 0 ..< labelLen:
        label[i] = char(packet[labelStart + 2 + i])
      if keepLabel.len > 0 and label == keepLabel:
        for i in messageStart ..< messageEnd:
          result.add(packet[i])
      else:
        for i in messageStart ..< offset + 6:
          result.add(packet[i])
        result.addU32(0)
        for i in labelStart ..< messageEnd:
          result.add(packet[i])
      offset = messageEnd
    of 0x02, 0x03, 0x04, 0x05, 0x06:
      offset += (
        case messageType
        of 0x02: 11
        of 0x03: 2
        of 0x05: 5
        of 0x06: 3
        else: 0
      )
      for i in messageStart ..< offset:
        result.add(packet[i])
    else:
      # Unknown message: we can't measure it, so ship the remainder whole —
      # mirrors chunkSpritePacket's bail-out.
      for i in messageStart ..< packet.len:
        result.add(packet[i])
      break

proc dedupObjectPlacements*(
  packet: seq[uint8],
  sentPlacements: var seq[array[12, uint8]]
): seq[uint8] =
  ## Drops Define Object messages whose full payload matches what this
  ## viewer was already sent. The sprite protocol is retained-mode — the
  ## client keeps every placement until it is replaced or deleted — so
  ## re-sending an identical placement is pure wire noise. Deletes and
  ## clear-objects update the memory so re-appearing objects re-send.
  ##
  ## Kept bytes are coalesced into pass-through runs and block-copied:
  ## only a SKIPPED placement breaks a run, so a packet with nothing to
  ## drop costs one copyMem — per-byte appends here were once the hottest
  ## proc in the whole server.
  result = newSeqOfCap[uint8](packet.len)
  if sentPlacements.len == 0:
    sentPlacements.setLen(65536)
  var
    offset = 0
    keepStart = 0
  template flushKept(upTo: int) =
    if upTo > keepStart:
      let start = result.len
      result.setLen(start + upTo - keepStart)
      copyMem(addr result[start], unsafeAddr packet[keepStart],
        upTo - keepStart)
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:  # sprite: id,w,h (6) + clen (4) + pixels + llen (2) + label
      offset += 10 + packet.readU32(offset + 6)
      offset += 2 + packet.readU16(offset)
    of 0x02:  # object: id (2) + x,y,z (6) + layer (1) + sprite (2)
      var payload: array[12, uint8]
      copyMem(addr payload[0], unsafeAddr packet[offset], 11)
      payload[11] = 1
      offset += 11
      let objectId = int(payload[0]) or (int(payload[1]) shl 8)
      if sentPlacements[objectId] == payload:
        flushKept(messageStart)
        keepStart = offset
      else:
        sentPlacements[objectId] = payload
    of 0x03:  # delete object
      sentPlacements[packet.readU16(offset)][11] = 0
      offset += 2
    of 0x04:  # clear objects
      zeroMem(addr sentPlacements[0], sentPlacements.len * 12)
    of 0x05, 0x06:
      offset += (if messageType == 0x05: 5 else: 3)
    else:
      # Unknown message: ship the remainder whole — mirrors
      # chunkSpritePacket's bail-out.
      offset = packet.len
  flushKept(packet.len)

