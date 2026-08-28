## 14 + 19. The determinism rails: no NEW float expression may feed a hashed
## value, and a replay must re-derive from its own bytes.

import std/[json, os, strutils, tables]
import helpers
import hns/[sim_types, replays, replay_runtime]

const IntegerOnlyModules = [
  "src/hns/objects.nim", "src/hns/phase.nim", "src/hns/fort.nim",
  "src/hns/motion.nim"
]
  ## Everything in these four feeds `gameHash`. The starter's fov cone filter
  ## is float and is kept EXACTLY as written (it is already the mechanism the
  ## native<->wasm hash chain survives); what must never happen is a NEW float
  ## expression feeding a hashed value.

proc codeLines(path: string): seq[string] =
  ## Source lines with `##`/`#` comment tails and string literals removed, so
  ## a comment that mentions a fraction is not a finding.
  for raw in readFile(path).splitLines():
    var line = ""
    var inString = false
    var escaped = false
    for i, ch in raw:
      if inString:
        if escaped: escaped = false
        elif ch == '\\': escaped = true
        elif ch == '"': inString = false
        continue
      if ch == '"':
        inString = true
        continue
      if ch == '#':
        break
      line.add(ch)
    result.add(line)

block noNewFloatsInHashedCode:
  for path in IntegerOnlyModules:
    check fileExists(path), "missing " & path
    for index, line in codeLines(path):
      let where = path & ":" & $(index + 1)
      check "sqrt" notin line, where & " uses sqrt: " & line.strip()
      check "float" notin line, where & " mentions float: " & line.strip()
      # Integer division is `div`; a bare `/` is float division. An import
      # path (`std/random`) is not an expression, so the import block is
      # skipped by looking for the operator SPACED as Nim styles it.
      check " / " notin line, where & " uses float division: " & line.strip()
      # A float LITERAL is a digit run with a dot and a digit after it.
      for j in 1 ..< line.len - 1:
        if line[j] == '.' and line[j - 1].isDigit() and line[j + 1].isDigit():
          check false, where & " has a float literal: " & line.strip()

block theFovConeFilterIsStillFloatAndStillWhitelisted:
  let vision = readFile("src/hns/vision.nim")
  check "coneCos" in vision, "applyFovCone's cone filter is gone"
  check "sqrt(d2)" in vision,
    "applyFovCone no longer uses the starter's sqrt expression; the " &
    "native<->wasm hash chain depends on it being byte-identical"

const FloatBearingProcs = {
  "castFovOctant": 4,
  "computeFovShadowcast": 2,
  "applyFovCone": 6,
  "playerVisibleTo": 4
}
  ## `src/hns/vision.nim` is NOT integer-only — it is the starter's float cone
  ## filter, kept because it is already the mechanism the native<->wasm hash
  ## chain survives. But it feeds `seenTicks`/`hiddenTicks`, which are hashed,
  ## so the rule that matters here is the note's: no NEW float expression may
  ## appear. The grep above cannot say that, so this pins WHERE the floats are
  ## and HOW MANY lines carry them, per proc. A float expression added anywhere
  ## else in the file — or an extra one inside these three — fails the build
  ## and has to be argued for in the diff.
  ##
  ## `playerVisibleTo`'s four are the airborne branch (design divergence 4): a
  ## vaulting cog is judged against the STATIC wall mask because its head is
  ## over the furniture. Its cone test is asserted below to be the SAME
  ## expression `applyFovCone` uses, so the two can never drift onto different
  ## libm calls.

block visionsFloatsAreOnlyWhereTheNoteSaysTheyAre:
  var current = ""
  var counted = initTable[string, int]()
  for index, line in codeLines("src/hns/vision.nim"):
    if line.startsWith("proc "):
      current = line[5 .. ^1].split({'*', '(', ' ', ':'})[0]
    var floaty = "float" in line or "sqrt" in line or "cos(" in line or
      "sin(" in line or " / " in line
    if not floaty:
      for j in 1 ..< max(1, line.len - 1):
        if line[j] == '.' and line[j - 1].isDigit() and line[j + 1].isDigit():
          floaty = true
    if not floaty:
      continue
    check current.len > 0, "a float expression outside every proc, at line " &
      $(index + 1) & ": " & line.strip()
    counted.mgetOrPut(current, 0) += 1
  for name, expected in FloatBearingProcs.items:
    check counted.getOrDefault(name) == expected,
      "src/hns/vision.nim's " & name & " carries " &
      $counted.getOrDefault(name) & " float-bearing lines, not the pinned " &
      $expected & ". A NEW float expression feeding a hashed value is how a " &
      "native<->wasm chain diverges: argue for it in the diff, then re-pin."
  for name, count in counted:
    var known = false
    for pinned, _ in FloatBearingProcs.items:
      if pinned == name:
        known = true
    check known, "src/hns/vision.nim's " & name & " is a NEW float-bearing " &
      "proc (" & $count & " lines) on the hashed path"

block theAirborneConeIsTheFovConeExpression:
  ## Divergence 4's cone test and applyFovCone's are the same expression, on
  ## the same libm, in the same order. If one is ever edited without the
  ## other, the airborne path becomes the NEW float expression the note
  ## forbids.
  let vision = readFile("src/hns/vision.nim")
  check countOccurrences(vision,
    "cos(float(sim.config.visionConeDeg) * PI / 180.0)") == 2,
    "the airborne branch and applyFovCone no longer compute coneCos with the " &
    "same expression"
  check countOccurrences(vision, "coneCos * sqrt(") == 2,
    "the airborne branch and applyFovCone no longer compare against " &
    "coneCos * sqrt(...) the same way"

block hashCoversTheObjectLayer:
  var h = newHarness()
  h.stepOnce()
  let before = h.game.gameHash()
  h.game.objects[0].x += 1
  check h.game.gameHash() != before, "moving an object did not move the hash"
  h.game.objects[0].x -= 1
  check h.game.gameHash() == before, "the hash is not a function of the state"
  h.game.objects[0].lockedBy = lockSeekers
  check h.game.gameHash() != before, "locking did not move the hash"
  h.game.objects[0].lockedBy = lockNone
  h.game.players[0].holding = 3
  check h.game.gameHash() != before, "holding did not move the hash"
  h.game.players[0].holding = -1
  h.game.sealedMask = 5'u64
  check h.game.gameHash() != before, "the sealed mask is not hashed"

block twoRunsOfOneSeedAgreeTickForTick:
  var a = newHarness()
  var b = newHarness()
  for tick in 1 .. 400:
    a.stepOnce()
    b.stepOnce()
    check a.game.gameHash() == b.game.gameHash(),
      "two runs of seed 42 diverged at tick " & $tick

echo "test_hns_determinism: ok"
