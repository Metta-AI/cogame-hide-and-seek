## 35-39, 41. The chrome is the STARTER'S, not a lookalike; the transport
## rules hold; the beat CSS matches exactly the kinds this game emits; the
## page is legible at 360 px; and the label vocabulary is the golden manifest.

import std/[algorithm, os, osproc, strutils]
import crunchy
import helpers
import hns/[sim_types, labels, broadcast, global]

const
  ChromeCommonSha =
    "9468c4b7fc1742146139224468eb3f68b7e9a8451e0319d1f6397146490aad2d"
    ## coworld-ctf's `client/chrome_common.js` plus the fleet-wide replay
    ## transport patch (0.5x speed chip + the game's own WIRE global).
    ## Everything else this game adds lives in the appended block below the
    ## splice banner; the file is otherwise NOT edited and NOT reformatted.
  ChromeCommonBytes = 40037
  SpliceBanner =
    "HIDE-AND-SEEK additions to the inherited coworld-ctf chrome"

proc sha256Hex(data: string): string =
  for b in sha256(data):
    result.add(toHex(b).toLowerAscii())

let page = readFile("client/replay_broadcast.html")
let core = readFile("client/broadcast_core.js")

# --- 35. chrome_common is byte-identical ------------------------------------
block chromeCommonIsByteIdentical:
  let common = readFile("client/chrome_common.js")
  check common.len == ChromeCommonBytes,
    "chrome_common.js is " & $common.len & " bytes, the starter's is " &
    $ChromeCommonBytes
  check sha256Hex(common) == ChromeCommonSha,
    "chrome_common.js was edited. It is copied BYTE FOR BYTE from the " &
    "starter; everything this game adds belongs in the appended block."

# --- 36. the broadcast page is the starter's page PLUS a block --------------
block thePageIsStarterPlusBlock:
  check countOccurrences(page, SpliceBanner) == 1,
    "the splice banner appears " & $countOccurrences(page, SpliceBanner) &
    " times, expected once"
  let marker = page.find(SpliceBanner)
  let inherited = page[0 ..< marker]
  let appended = page[marker .. ^1]
  # The inherited region still carries the starter's structure.
  for id in ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
             "chrome", "scorebug", "plates-l", "plates-r", "clock",
             "clock-time", "clock-caption", "bannerlane", "killfeed",
             "mmwarn", "transport", "btn-restart", "btn-back", "btn-play",
             "btn-fwd", "btn-end", "btn-loop", "btn-skip", "btn-spoilers",
             "ffwd-chip", "win-chip", "tick-clock", "speedchips", "scrub",
             "momentum", "scrub-fill", "lulls", "scrub-win", "scrub-head",
             "endcard", "ec-headline", "ec-wincond", "ec-how", "ec-teams",
             "ec-replay", "status"]:
    check "id=\"" & id & "\"" in inherited or "'" & id & "'" in inherited,
      "the inherited chrome lost #" & id
  # The game block only APPENDS: the inherited region carries the whole
  # starter page, ending in its own closing </script>.
  check inherited.strip().endsWith("</script>\n<!-- ====" &
      "========================================================") or
    inherited.strip().endsWith("</script>") or
    inherited.contains("core.start();"),
    "the game block was spliced into the middle of the inherited page"
  check appended.strip().endsWith("</html>"),
    "the appended block does not close the document"
  check "window.PaintballChrome" in inherited,
    "the starter's install hook is gone from the inherited page"
  check "install: function (ctx)" in appended,
    "the appended block does not install through the starter's hook"

# --- the removed elements ---------------------------------------------------
block removedElementsAreGone:
  for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-in",
             "zoom-out", "zoom-slider", "zoom-read", "povBadge", "fpv",
             "fpv-canvas", "fpv-hud", "fpv-name", "fpv-hp", "fpv-gear",
             "fpv-map", "fpv-map-canvas", "fpv-cap", "fpv-grip"]:
    check "id=\"" & id & "\"" notin page,
      "#" & id & " is still in the page; the design note removes it"
  check "attachMinimap" notin page,
    "the page still attaches a minimap"
  check "renderFpv" notin page, "the first-person pipeline is still wired"

# --- 37. no shadowed chrome aliases ----------------------------------------
block noShadowedChromeAliases:
  let marker = page.find(SpliceBanner)
  let appended = page[marker .. ^1]
  # chrome_common.js declares these with hoisted `var`s; a game-block function
  # of the same name is silently swallowed by them (cogame-tandem 2026-08-23).
  for alias in ["markBeat", "renderBeatMarkers", "ingestBeats", "renderClock",
                "renderTransport", "ingestLullSpans", "renderMomentum",
                "pushFeed", "banner", "teamCol", "rosterName", "shortName"]:
    check "function " & alias & "(" notin appended,
      "the appended block re-declares the chrome alias " & alias
  check "function hnsBeat(" in appended,
    "the beat builder is not named hnsBeat"
  # Comments may NAME markBeat (they explain why it is never used); a CALL is
  # `markBeat(`.
  check "markBeat(" notin appended,
    "the appended block calls markBeat; it must use hnsBeat so every marker " &
    "is a labelled, clickable button"

# --- 38. the beat CSS matches exactly the kinds emitted --------------------
block beatCssMatchesEmittedKinds:
  var declared: seq[string]
  var index = 0
  while true:
    let hit = page.find(".beat-marker.", index)
    if hit < 0:
      break
    index = hit + 13
    var kind = ""
    var i = index
    while i < page.len and (page[i].isAlphaNumeric() or page[i] == '-'):
      kind.add(page[i])
      inc i
    if kind.len > 0 and kind notin declared:
      declared.add(kind)
  # `.lock.seekers` and friends are side modifiers, not kinds.
  var kinds: seq[string]
  for kind in declared:
    if kind in ["hiders", "seekers", "red", "blue"]:
      continue
    kinds.add(kind)
  kinds.sort()
  var expected: seq[string]
  for kind in BeatKinds:
    expected.add(kind)
  expected.sort()
  check kinds == expected,
    "the beat CSS declares " & $kinds & " but the sim emits " & $expected

# --- 39. transport, endcard and the 360 px rules ---------------------------
block transportRules:
  check "function relayout()" in page,
    "the page lost relayout(), which owns --hudscale / --topband / --band"
  check "#endcard { bottom: var(--band" in page or
    "bottom: var(--band, 0px)" in page,
    "the endcard does not stop at var(--band)"
  check "--hudscale" in page, "relayout() does not set --hudscale"
  check "--band" in page, "relayout() does not set --band"
  check "--topband" in page, "relayout() does not set --topband"
  check "root.style.setProperty('--band'" in page,
    "--band is not set on :root"
  check "classList.remove('on')" in page,
    "the endcard is never dismissed by a seek"

block noGameBlockOverlaySitsInTheBand:
  let marker = page.find(SpliceBanner)
  let appended = page[marker .. ^1]
  # The one absolutely-positioned addition is the exposure ribbon, and it
  # stops ABOVE the band.
  check "bottom: calc(var(--band, 0px) + 1px)" in appended,
    "the exposure ribbon does not stop above the transport band"
  check countOccurrences(appended, "position: absolute") <= 1,
    "the game block adds more than one absolutely-positioned overlay"

block theFour360PxRules:
  let marker = page.find(SpliceBanner)
  let appended = page[marker .. ^1]
  check ".plate-name {" in appended and "flex: 1 1 auto" in appended and
    "min-width: 3.2em" in appended,
    "the plate-name rule that keeps a policy name legible at 360 px is gone"
  check "#stage.tiny .hns-tags" in appended,
    "the .tiny plate rule is missing"
  check "#stage.tiny #hns-fort .fort-ramps" in appended,
    "the fort panel does not shrink under .tiny"
  check "#stage.tiny #hns-ribbon" in appended,
    "the exposure ribbon does not halve in height under .tiny"
  check "#stage.tiny #killfeed" in appended,
    "the feed does not drop a row under .tiny"

# --- broadcast_core keeps the starter's kept procs -------------------------
block broadcastCoreKeepsItsSignatures:
  for signature in ["function BroadcastCore(config)", "function composite(",
                    "function parse(bytes)", "function connect(",
                    "function ingest(bytes)", "function draw(",
                    "function updateNativeSize(", "function computeFit(",
                    "function setViewportSize(width, height, dpr)",
                    "function clickMap(mapX, mapY)"]:
    check signature in core,
      "broadcast_core.js lost the starter's " & signature
  check "window.HNS_WIRE" in core,
    "broadcast_core.js was not renamed to the HNS wire constants"
  check "window.CTF_WIRE" notin core,
    "broadcast_core.js still reads the starter's wire constants"

# --- 41. the label manifest -------------------------------------------------
block labelManifestIsTheGoldenVocabulary:
  var golden: seq[string]
  for line in readFile("tests/label_manifest.txt").splitLines():
    let text = line.strip()
    if text.len == 0 or text.startsWith("#"):
      continue
    golden.add(text)
  golden.sort()
  var emitted: seq[string]
  for label in LabelVocabulary:
    emitted.add(label)
  emitted.sort()
  check emitted == golden,
    "the emitted label vocabulary " & $emitted &
    " does not equal tests/label_manifest.txt " & $golden
  check LabelAimPrefix == "own aim ",
    "the own-aim readback marker's prefix changed; docs/PROTOCOL.md pins it"

block thePageExecutesWithNoMissingGlobals:
  ## A DELETE-HEAVY fork of a 4 000-line page produces ReferenceErrors, not
  ## syntax errors: removing #viewpanel and the first-person inset also
  ## removed the `var $ = C.$;` and `var COG_BASE = …` declarations that
  ## happened to sit inside the same regions, and the page then died at load
  ## with one line — "$ is not defined" — while the viewer smoke timed out
  ## ninety seconds later saying only `data-replay-loaded=null`. This runs the
  ## page's own script blocks against a dumb DOM stub and fails on the first
  ## missing global. Skipped where node is unavailable; CI always has it.
  if findExe("node").len == 0:
    echo "  (node not found: page_smoke skipped)"
  else:
    let outcome = execCmdEx("node tools/ci/page_smoke.mjs")
    check outcome.exitCode == 0,
      "tools/ci/page_smoke.mjs failed:\n" & outcome.output

block shoutBubblesStayInsideTheBoard:
  ## The bubble is laid out RELATIVE to a cog (checklist 15): it grows upward
  ## from the shouter's head, and the `hide` intent parks hiders on `pocket`
  ## anchors that sit on the top row of every committed room. Placed
  ## unclamped, the body lands at a negative y and the sentence renders as a
  ## sliver — invisible to the load signal, the soak and the screenshot.
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  const FullCap = "WWWWWWWWWW"   ## MaxSayRunes of the widest glyph.
  check FullCap.len == MaxSayRunes, "the fixture is not a full-cap say"
  let art = buildShoutBubble(game.shoutFont, FullCap)
  var pockets = 0
  var anchors = @[(0, 0), (game.gameMap.width - 1, 0),
                  (0, game.gameMap.height - 1),
                  (game.gameMap.width - 1, game.gameMap.height - 1),
                  (game.gameMap.width div 2, game.gameMap.height div 2)]
  for anchor in game.gameMap.anchors:
    if anchor.kind == anchorPocket:
      anchors.add((anchor.x, anchor.y))
      inc pockets
  check pockets > 0, "the room published no pocket anchors"
  for (x, y) in anchors:
    let place = game.shoutBubblePlacement(x, y - SoldierBodyPx, art.w, art.h)
    check place.x >= 0 and place.y >= 0,
      "a full-cap shout at (" & $x & "," & $y & ") was placed off the board " &
      "at (" & $place.x & "," & $place.y & ")"
    check place.x + art.w <= game.gameMap.width and
      place.y + art.h <= game.gameMap.height,
      "a full-cap shout at (" & $x & "," & $y & ") overran the board edge"

block theVisionConeStopsAtAWall:
  ## Readout 2: the cone is "clipped by walls and objects exactly as the sim
  ## clips it". The wedge used to be drawn unclipped and layered under the
  ## objects — but a WALL is part of the baked room bed, not an object, so the
  ## beam ran through walls and told the spectator a seeker could see through
  ## them.
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  game.matchPhase = phaseHunt
  # warren: a seeker in r3 aimed WEST at the solid wall between r3 and r2.
  # (The one door on that wall, d2, is at y = 104; y = 160 is masonry.)
  let seeker = 1
  game.placePlayer(seeker, 620, 160)
  game.players[seeker].aimBrads = 128
  check game.canOccupy(620, 160), "the fixture cog is standing in geometry"
  check game.isWall(480, 160), "the fixture is not aimed at a wall"
  discard game.refreshPlayerFov(seeker)
  let cone = game.buildConeSprite(seeker, game.config.sightRange,
    game.config.visionConeDeg, game.players[seeker].aimBrads, true)
  proc alphaAt(x, y: int): int =
    let
      ox = game.players[seeker].x + cone.offX
      oy = game.players[seeker].y + cone.offY
    if x - ox < 0 or y - oy < 0 or x - ox >= cone.w or y - oy >= cone.h:
      return 0
    int(cone.pixels[((y - oy) * cone.w + (x - ox)) * 4 + 3])
  check alphaAt(560, 160) > 0,
    "the cone is not drawn on the near side of the wall"
  check alphaAt(440, 160) == 0,
    "the cone is drawn THROUGH a wall: it is not clipped as the sim clips it"
  check alphaAt(300, 160) == 0, "the cone reaches two rooms through a wall"

echo "test_hns_viewer: ok"
