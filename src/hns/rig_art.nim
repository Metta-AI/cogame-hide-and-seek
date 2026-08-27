## Broadcast-side art: the cog kits and the object sprites, composited from
## the committed masters. Forked from coworld-ctf's `src/ctf/rig_art.nim` and
## cut to the ROTATION COMPOSITOR — the articulated turret rig, the crew
## sheet, the gun, the spray can and the relic loaders went with the
## mechanics that used them.
##
## The masters are `data/cog_hider.png` and `data/cog_seeker.png`: nano-banana
## renders of the Softmax cog, one kit per role (a hooded blue hider, a
## red seeker with a headlamp visor and a shoulder torch), so ROLES READ AT
## BOARD SCALE WITHOUT LABELS. The same masters/pivots/scale plumbing the
## starter used for `soldier_{red,blue}.png`: a cog is baked to a 34 px body
## on a 72 px canvas, at RenderScale, in SoldierRotations facings.
##
## Everything here is BROADCAST-ONLY: no sim state, nothing in gameHash, no
## GameVersion bump for changes.

import
  std/[math, os],
  pixie,
  sim_types, room

const CogMasterPaths*: array[Team, string] = [
  Red: "data/cog_hider.png",
  Blue: "data/cog_seeker.png"
]

const ObjectMasterPaths*: array[ObjectKind, string] = [
  okCrate: "data/obj_crate.png",
  okPanel: "data/obj_panel.png",
  okRamp: "data/obj_ramp.png"
]

var
  cogMasters: array[Team, Image]
  cogPivotX, cogPivotY: array[Team, float]
  cogScale: array[Team, float]
  cogLoaded: array[Team, bool]
  cogRotCache: array[Team, array[SoldierRotations, seq[tuple[
    scale: int, pixels: seq[uint8]
  ]]]]
  objectMasters: array[ObjectKind, Image]
  objectLoaded: array[ObjectKind, bool]

proc fallbackCogMaster(team: Team): Image =
  ## Only reached if a master is missing from the image: a flat rectangle is
  ## never acceptable, so this draws a recognisable cog silhouette in the
  ## role's colour rather than a square.
  let
    size = 128
    body = rgba(
      if team == Red: 63 else: 224,
      if team == Red: 124 else: 82,
      if team == Red: 196 else: 58,
      255)
  result = newImage(size, size)
  let ctx = newContext(result)
  ctx.fillStyle = body
  ctx.fillRoundedRect(rect(24, 20, 80, 88), 22)
  ctx.fillStyle = rgba(18, 24, 40, 255)
  ctx.fillRoundedRect(rect(40, 44, 48, 26), 10)
  ctx.fillStyle = rgba(240, 244, 255, 255)
  ctx.fillCircle(circle(vec2(54, 57), 5))
  ctx.fillCircle(circle(vec2(74, 57), 5))

proc measureCogBody(team: Team, master: Image) =
  ## The body pivot and the master->canvas scale: the centroid and vertical
  ## span of the SOLID pixels (alpha >= 200), so the cog itself — not its
  ## baked drop shadow — is what centres and fills SoldierBodyPx.
  var
    sumX = 0.0
    sumY = 0.0
    n = 0
    top = master.height
    bot = -1
  for y in 0 ..< master.height:
    for x in 0 ..< master.width:
      if master.data[y * master.width + x].a >= 200:
        sumX += float(x)
        sumY += float(y)
        inc n
        top = min(top, y)
        bot = max(bot, y)
  if n == 0:
    cogPivotX[team] = float(master.width) / 2
    cogPivotY[team] = float(master.height) / 2
    cogScale[team] = float(SoldierBodyPx) / max(1.0, float(master.height))
  else:
    cogPivotX[team] = sumX / float(n)
    cogPivotY[team] = sumY / float(n)
    cogScale[team] = float(SoldierBodyPx) / max(1.0, float(bot - top + 1))

proc ensureCogLoaded(team: Team) =
  if cogLoaded[team]:
    return
  let path = gameDir() / CogMasterPaths[team]
  var master: Image
  if fileExists(path):
    try:
      master = readImage(path)
    except CatchableError:
      master = fallbackCogMaster(team)
  else:
    master = fallbackCogMaster(team)
  cogMasters[team] = master
  measureCogBody(team, master)
  cogLoaded[team] = true

proc cogRotPixels*(team: Team, rot: int, renderScale = 1): seq[uint8] =
  ## One pre-rendered cog sprite (SoldierCanvas * renderScale square,
  ## straight-alpha RGBA), rotated to aim step `rot`. The master's FACE side
  ## (south) leads the aim, so a spectator reads the heading off the visor.
  let r = ((rot mod SoldierRotations) + SoldierRotations) mod SoldierRotations
  for cached in cogRotCache[team][r]:
    if cached.scale == renderScale:
      return cached.pixels
  ensureCogLoaded(team)
  let
    master = cogMasters[team]
    outCanvas = SoldierCanvas * renderScale
    angle = float(r) * 2.0 * PI / float(SoldierRotations)
    s = cogScale[team] * float(renderScale)
    center = float32(outCanvas) / 2
  var canvas = newImage(outCanvas, outCanvas)
  let mat =
    translate(vec2(center, center)) *
    rotate(float32(-angle)) *
    rotate(float32(-PI / 2)) *
    scale(vec2(float32(s), float32(s))) *
    translate(vec2(float32(-cogPivotX[team]), float32(-cogPivotY[team])))
  canvas.draw(master, mat)
  var pixels = newSeq[uint8](outCanvas * outCanvas * 4)
  for i in 0 ..< outCanvas * outCanvas:
    let c = canvas.data[i].rgba()
    pixels[i * 4] = c.r
    pixels[i * 4 + 1] = c.g
    pixels[i * 4 + 2] = c.b
    pixels[i * 4 + 3] = c.a
  cogRotCache[team][r].add((scale: renderScale, pixels: pixels))
  pixels

proc cogRotIndex*(aimBrads: int): int =
  ## Quantizes an aim angle to the nearest pre-rotated sprite step.
  ((aimBrads + AimBradsTurn div (SoldierRotations * 2)) *
    SoldierRotations div AimBradsTurn) mod SoldierRotations

proc fallbackObjectMaster(kind: ObjectKind): Image =
  let size = 128
  result = newImage(size, size)
  let ctx = newContext(result)
  case kind
  of okCrate:
    ctx.fillStyle = rgba(168, 128, 74, 255)
    ctx.fillRect(rect(0, 0, 128, 128))
    ctx.strokeStyle = rgba(110, 82, 46, 255)
    ctx.lineWidth = 8
    ctx.strokeRect(rect(4, 4, 120, 120))
    ctx.strokeSegment(segment(vec2(4, 4), vec2(124, 124)))
    ctx.strokeSegment(segment(vec2(124, 4), vec2(4, 124)))
  of okPanel:
    ctx.fillStyle = rgba(214, 178, 116, 255)
    ctx.fillRect(rect(0, 0, 128, 128))
    ctx.strokeStyle = rgba(150, 118, 72, 255)
    ctx.lineWidth = 6
    for i in 0 .. 3:
      ctx.strokeSegment(segment(vec2(0, float32(i * 32 + 16)),
        vec2(128, float32(i * 32 + 16))))
  of okRamp:
    ctx.fillStyle = rgba(140, 146, 156, 255)
    ctx.fillRect(rect(0, 0, 128, 128))
    ctx.fillStyle = rgba(196, 202, 214, 255)
    for i in 0 .. 5:
      ctx.fillRect(rect(0, float32(i * 22), 128, float32(6 + i)))

proc ensureObjectLoaded(kind: ObjectKind) =
  if objectLoaded[kind]:
    return
  let path = gameDir() / ObjectMasterPaths[kind]
  var master: Image
  if fileExists(path):
    try:
      master = readImage(path)
    except CatchableError:
      master = fallbackObjectMaster(kind)
  else:
    master = fallbackObjectMaster(kind)
  objectMasters[kind] = master
  objectLoaded[kind] = true

proc objectPixels*(kind: ObjectKind, w, h: int): seq[uint8] =
  ## The furniture sheet's tile for one object, nine-sliced to the object's
  ## rectangle (a stretched crate reads as a longer crate, not a blurred one).
  ensureObjectLoaded(kind)
  let master = objectMasters[kind]
  var canvas = newImage(max(w, 1), max(h, 1))
  canvas.draw(master, translate(vec2(0, 0)) * scale(vec2(
    float32(w) / float32(max(master.width, 1)),
    float32(h) / float32(max(master.height, 1))
  )))
  result = newSeq[uint8](max(w, 1) * max(h, 1) * 4)
  for i in 0 ..< max(w, 1) * max(h, 1):
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc cogIconPixels*(team: Team, sizePx: int): seq[uint8] =
  ## A compact roster chip: the face-on cog scaled so the body fills the icon.
  ensureCogLoaded(team)
  let
    master = cogMasters[team]
    s = float(sizePx) / float(SoldierBodyPx) * cogScale[team]
  var canvas = newImage(sizePx, sizePx)
  canvas.draw(master,
    translate(vec2(float32(sizePx) / 2, float32(sizePx) / 2)) *
    scale(vec2(float32(s), float32(s))) *
    translate(vec2(float32(-cogPivotX[team]), float32(-cogPivotY[team]))))
  result = newSeq[uint8](sizePx * sizePx * 4)
  for i in 0 ..< sizePx * sizePx:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a
