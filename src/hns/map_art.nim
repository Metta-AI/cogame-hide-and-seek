## The room bake: one static image of floor and walls, produced once at
## install. Forked from coworld-ctf's `src/ctf/map_art.nim` and cut to the
## two surfaces this game has — there are no endzones, no pedestals, no
## trenches, no puddles and no spinning diamonds to bake.
##
## The floor is `data/arena_floor.png` tiled and darkened 18 %; wall faces are
## textured from `client/art/walls/{wall_h,wall_v}.jpg` with a lit top bevel
## and a shadow skirt, exactly the way the starter bakes its rooftops. One
## bake per room, so the per-frame cost is six cogs, eight objects and the
## overlays.

import
  std/[math, os],
  pixie,
  sim_types, room

const
  FloorDarken* = 82          ## percent of the source floor's brightness.
  WallBevel* = 4             ## px of lit top edge on a wall face.
  WallSkirt* = 6             ## px of shadow cast below a wall face.

proc clientDataDir*(): string =
  gameDir() / "data"

proc scaleColor(color: ColorRGBA, pct: int): ColorRGBA =
  rgba(
    uint8(int(color.r) * pct div 100),
    uint8(int(color.g) * pct div 100),
    uint8(int(color.b) * pct div 100),
    color.a
  )

proc tileSample(tex: Image, x, y: int): ColorRGBA =
  if tex.width <= 0 or tex.height <= 0:
    return rgba(60, 60, 68, 255)
  tex[((x mod tex.width) + tex.width) mod tex.width,
      ((y mod tex.height) + tex.height) mod tex.height]

proc nearestPaletteIndex*(color: ColorRGBA): uint8 =
  ## Nearest entry of the retro 16-colour palette, for the 1x pixel stream.
  var
    best = 0
    bestDist = high(int)
  for i, entry in Palette:
    let
      dr = int(color.r) - int(entry.r)
      dg = int(color.g) - int(entry.g)
      db = int(color.b) - int(entry.b)
      dist = dr * dr + dg * dg + db * db
    if dist < bestDist:
      bestDist = dist
      best = i
  uint8(best)

proc readOptionalImage(path: string): Image =
  if fileExists(path):
    try:
      return readImage(path)
    except CatchableError:
      discard
  newImage(1, 1)

var
  bakeCacheName: string
  bakeCacheRgba: seq[uint8]
  bakeCacheWall: seq[bool]

proc bakeRoom*(gameMap: HnsMap): tuple[rgba: seq[uint8], wall: seq[bool]] =
  ## Renders the room once: `rgba` is the board image, `wall` the static
  ## collision/occlusion mask. Both are pure functions of the room document,
  ## so the native server and the wasm viewer bake the identical board.
  # One bake per room per process. The room never changes inside an episode,
  # and a test suite that builds a hundred sims would otherwise re-rasterise
  # 288 000 pixels a hundred times.
  let cacheKey = gameMap.name & ":" & $gameMap.width & "x" & $gameMap.height &
    ":" & $gameMap.walls.len
  if bakeCacheName == cacheKey and bakeCacheRgba.len > 0:
    return (bakeCacheRgba, bakeCacheWall)
  let
    w = gameMap.width
    h = gameMap.height
    dir = gameDir()
    floorTex = readOptionalImage(dir / "data/arena_floor.png")
    wallH = readOptionalImage(dir / "client/art/walls/wall_h.jpg")
    wallV = readOptionalImage(dir / "client/art/walls/wall_v.jpg")
  var
    rgba = newSeq[uint8](w * h * 4)
    wall = gameMap.rasterizeWallMask()
  for y in 0 ..< h:
    for x in 0 ..< w:
      let index = y * w + x
      var color: ColorRGBA
      if wall[index]:
        # A wall rect wider than it is tall reads as a horizontal face.
        var horizontal = true
        for rect in gameMap.walls:
          if inRect(x, y, rect):
            horizontal = rect.w >= rect.h
            break
        let tex = if horizontal: wallH else: wallV
        color = tileSample(tex, x, y)
        if color.a == 0:
          color = rgba(92, 88, 96, 255)
        # A lit top bevel: the topmost few rows of a face catch the light.
        var depth = 0
        while depth < WallBevel and y - depth - 1 >= 0 and
            wall[(y - depth - 1) * w + x]:
          inc depth
        if depth < WallBevel:
          let lift = 100 + (WallBevel - depth) * 9
          color = scaleColor(color, lift)
        color.a = 255
      else:
        color = tileSample(floorTex, x, y)
        if color.a == 0:
          color = rgba(48, 50, 58, 255)
        color = scaleColor(color, FloorDarken)
        # The shadow skirt below a wall face.
        var above = 0
        for depth in 1 .. WallSkirt:
          if y - depth >= 0 and wall[(y - depth) * w + x]:
            above = WallSkirt - depth + 1
            break
        if above > 0:
          color = scaleColor(color, 100 - above * 5)
        color.a = 255
      let offset = index * 4
      rgba[offset] = color.r
      rgba[offset + 1] = color.g
      rgba[offset + 2] = color.b
      rgba[offset + 3] = color.a
  bakeCacheName = cacheKey
  bakeCacheRgba = rgba
  bakeCacheWall = wall
  (rgba, wall)

proc mapPixelsFromRgba*(rgba: seq[uint8]): seq[uint8] =
  ## The 1x retro pixel stream: one palette index per map pixel.
  result = newSeq[uint8](rgba.len div 4)
  for i in 0 ..< result.len:
    result[i] = nearestPaletteIndex(rgba(
      rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3]))

proc supersampledRoomRgba*(gameMap: HnsMap, base: seq[uint8],
                           scale: int): seq[uint8] =
  ## The spectator board at `scale` x map resolution. The room is flat art on
  ## a fixed 720x400 board, so a clean box upscale of the 1x bake is exactly
  ## what the starter's supersampled bake produces for flat surfaces, at a
  ## fraction of the cost — and it keeps the wasm viewer's peak allocation
  ## inside the budget on every supported board.
  let
    w = gameMap.width
    h = gameMap.height
    ow = w * scale
    oh = h * scale
  result = newSeq[uint8](ow * oh * 4)
  for y in 0 ..< oh:
    let sy = y div scale
    for x in 0 ..< ow:
      let
        sx = x div scale
        src = (sy * w + sx) * 4
        dst = (y * ow + x) * 4
      result[dst] = base[src]
      result[dst + 1] = base[src + 1]
      result[dst + 2] = base[src + 2]
      result[dst + 3] = base[src + 3]
