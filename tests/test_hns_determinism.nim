## 14 + 19. The determinism rails: no NEW float expression may feed a hashed
## value, and a replay must re-derive from its own bytes.

import std/[json, os, strutils]
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
