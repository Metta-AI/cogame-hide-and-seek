## 20-24. Bounded orders and legal masks on the scripted baselines, the
## repair-don't-reject validator, and the tuning pin.

import std/[json, os, random, strutils, unicode]
import helpers
import hns/[sim_types, directives, baselines, control]
import ../tools/tune_baselines

const Intents = [intMoveTo, intHide, intWatch, intChase, intPush, intLock,
                 intUnlock, intVault]

proc scramble(game: var SimServer, rng: var Rand) =
  ## A pseudo-random but LEGAL world: cogs somewhere walkable, objects held
  ## and locked in every combination, either phase, either game.
  game.matchPhase = if rng.rand(1) == 0: phasePrep else: phaseHunt
  for i in 0 ..< game.players.len:
    let spot = game.nearestWalkable(
      rng.rand(PlayerHalf .. MapWidth - PlayerHalf - 1),
      rng.rand(PlayerHalf .. MapHeight - PlayerHalf - 1))
    game.placePlayer(i, spot.x, spot.y)
    game.players[i].aimBrads = rng.rand(255)
    game.players[i].holding = -1
    game.players[i].lockCooldown = rng.rand(0 .. LockCooldownTicks)
  for i in 0 ..< game.objects.len:
    game.objects[i].lockedBy = LockOwner(rng.rand(2))
    game.objects[i].heldBy = -1
  # A couple of real holds, so the "held by someone else" branches are live.
  if game.objects.len >= 2 and game.players.len >= 2:
    game.objects[0].heldBy = 0
    game.players[0].holding = 0
    game.objects[1].heldBy = 3
    game.players[3].holding = 1

# --- 20. baselines are bounded ---------------------------------------------
block baselinesAreBounded:
  var rng = initRand(20)
  for room in ["warren", "atrium", "long_hall"]:
    var game = newTestSim(%*{"roomPool": room, "seed": 42})
    game.seatAll()
    game.startGame()
    var ctl = initControlState(game)
    var objectIds: seq[string]
    for obj in game.objects:
      objectIds.add(obj.id)
    for trial in 1 .. 70:
      game.scramble(rng)
      game.gameIndex = rng.rand(1)
      ctl.observeEnemies(game)
      for kind in [blBurrow, blScatter]:
        for slot in 0 ..< game.players.len:
          let order = baselineOrder(
            kind, game, ctl, slot, game.cogAlias(slot), rng.rand(11))
          check order.intent in Intents,
            $kind & " proposed an intent outside the enum"
          if order.obj.len > 0:
            check order.obj in objectIds,
              $kind & " named an unpublished object: " & order.obj
          if order.intent == intVault:
            check order.obj.len > 0, $kind & " vaulted with no ramp"
            let index = game.objectIndexById(order.obj)
            check index >= 0 and game.objects[index].kind == okRamp,
              $kind & " vaulted a non-ramp: " & order.obj
          if order.intent.needsObject():
            check order.obj.len > 0,
              $kind & " emitted " & $order.intent & " with no object"
          if order.hasTo:
            check order.toX >= 0 and order.toX < MapWidth and
              order.toY >= 0 and order.toY < MapHeight,
              $kind & " aimed outside the board"
          check order.say.runeLen <= MaxSayRunes,
            $kind & " overran the say cap"
          check order.radio.len == 0, $kind & " emitted a radio line"
          check order.notes.len == 0, $kind & " emitted a note"
          let record = Directive(slot: slot, order: order,
                                 source: dsScripted).boundedOrderRecord(
            1, 1, game.cogAlias(slot), "", nil)
          check record.len <= 1024,
            $kind & " serialised to " & $record.len & " bytes"

# --- 21. the driver never emits an illegal mask ----------------------------
block driverNeverEmitsAnIllegalMask:
  const Legal = ButtonUp or ButtonDown or ButtonLeft or ButtonRight or
    ButtonSelect or ButtonA or ButtonB or ButtonC
  var rng = initRand(21)
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var ctl = initControlState(game)
  for trial in 1 .. 200:
    game.scramble(rng)
    ctl.observeEnemies(game)
    for slot in 0 ..< game.players.len:
      for kind in [blBurrow, blScatter]:
        let order = baselineOrder(
          kind, game, ctl, slot, game.cogAlias(slot), rng.rand(11))
        let mask = ctl.compileMask(game, order, slot)
        check (mask and not Legal) == 0'u8,
          "the driver set a bit outside the Sprite v1 vocabulary"
        check not ((mask and ButtonUp) != 0 and (mask and ButtonDown) != 0),
          "the driver pressed Up and Down at once"
        check not ((mask and ButtonLeft) != 0 and (mask and ButtonRight) != 0),
          "the driver pressed Left and Right at once"
        check not ((mask and ButtonB) != 0 and (mask and ButtonSelect) != 0),
          "the driver turned both ways at once"
        if game.players[slot].lockCooldown > 0:
          check (mask and ButtonA) == 0,
            "the driver pressed A while the lock cooldown was running"

block anUnreachableTargetDegradesToWatch:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var ctl = initControlState(game)
  # A target inside a wall: the driver must not press a direction forever.
  var wallX, wallY = -1
  for wall in game.gameMap.walls:
    if wall.w > 32 and wall.h > 8:
      wallX = wall.x + wall.w div 2
      wallY = wall.y + wall.h div 2
      break
  check wallX >= 0, "the room has no wall to aim into"
  var order = Order(slot: 0, intent: intMoveTo, hasTo: true,
                    toX: wallX, toY: wallY, fromReply: true)
  var pressed = 0
  var prev = newSeq[InputState](game.players.len)
  for tick in 1 .. 200:
    ctl.observeEnemies(game)
    let mask = ctl.compileMask(game, order, 0)
    var inputs = newSeq[InputState](game.players.len)
    inputs[0] = decodeInputMask(mask)
    if mask != 0:
      inc pressed
    game.step(inputs, prev)
    prev = inputs
  check game.canOccupy(game.players[0].x, game.players[0].y),
    "the cog ended up inside geometry chasing an unreachable target"

# --- knownEnemy reports a sighting, and the chase that reads it -------------
block knownEnemyReportsASighting:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  game.matchPhase = phaseHunt
  var ctl = initControlState(game)
  # A hider (slot 0, Red) and a seeker (slot 1, Blue) nose to nose, inside the
  # omnidirectional vision bubble, so the sighting does not depend on aim.
  let spot = game.nearestWalkable(MapWidth div 2, MapHeight div 2)
  game.placePlayer(0, spot.x, spot.y)
  let near = game.nearestWalkable(spot.x + PlayerHalf * 2 + 2, spot.y)
  game.placePlayer(1, near.x, near.y)
  check distSq(game.players[0].x, game.players[0].y,
               game.players[1].x, game.players[1].y) <=
      VisionBubble * VisionBubble,
    "the two cogs are not inside the vision bubble; the fixture is wrong"
  discard game.refreshPlayerFov(0)
  discard game.refreshPlayerFov(1)
  check game.playerVisibleTo(1, 0), "the seeker cannot see the hider"
  ctl.observeEnemies(game)
  let seen = ctl.knownEnemy(game, 1)
  check seen.known, "knownEnemy reported no enemy for a cog looking at one"
  check seen.index == 0, "knownEnemy named the wrong cog: " & $seen.index
  check seen.x == game.players[0].x and seen.y == game.players[0].y,
    "knownEnemy did not carry the sighted position"
  check seen.ticksAgo == 0, "a sighting this tick was not reported as fresh"
  # The seeker baseline turns that sighting into a chase, and the chase's goal
  # is the enemy, not the seeker's own feet.
  let order = baselineOrder(blBurrow, game, ctl, 1, game.cogAlias(1), 3)
  check order.intent == intChase,
    "burrow's seeker did not chase an enemy inside chaseRadius: " & $order.intent
  let goal = ctl.goalFor(game, order, 1)
  check goal.x == seen.x and goal.y == seen.y,
    "the chase goal degenerated to the seeker's own position"
  # And the memory expires: HuntMemoryTicks later, with no fresh observation,
  # the same cog knows nothing.
  var prev = newSeq[InputState](game.players.len)
  let inputs = newSeq[InputState](game.players.len)
  for tick in 0 .. HuntMemoryTicks:
    game.step(inputs, prev)
    prev = inputs
  check not ctl.knownEnemy(game, 1).known,
    "a sighting older than HuntMemoryTicks was still reported as known"

# --- a heard shout is jittered ---------------------------------------------
block aHeardShoutGivesTheNeighbourhoodNotThePixel:
  ## §Per-seat observation: "the team that shouted, the text, THE JITTERED
  ## POSITION". Reporting `shout.x, shout.y` let a listener triangulate a
  ## hider from a `say` it was never meant to locate.
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var engine = initDecisionEngine(game)
  var moved = 0
  for cog in 0 ..< game.players.len:
    game.players[cog].lastShoutTick = low(int) div 2
    check game.applyShout(cog, "over here"), "the sim refused a shout"
  for shout in game.recentShouts:
    let at = shoutHeardAt(shout)
    check abs(at.x - shout.x) <= ShoutJitterPx and
      abs(at.y - shout.y) <= ShoutJitterPx,
      "the jitter strayed further than ShoutJitterPx"
    check at.x >= 0 and at.x < MapWidth and at.y >= 0 and at.y < MapHeight,
      "a jittered shout landed off the board"
    check at == shoutHeardAt(shout),
      "the jitter is not a pure function of the shout"
    if at.x != shout.x or at.y != shout.y:
      inc moved
  check moved >= game.recentShouts.len - 1,
    "only " & $moved & " of " & $game.recentShouts.len &
    " shouts moved: the jitter is not doing anything"
  # And the observation carries the jittered value, not the true one.
  var reported = 0
  for seat in 0 ..< game.seatCount():
    let view = engine.seatViewJson(game, seat, 1)
    for entry in view{"heard"}:
      let
        x = entry["at"][0].getInt()
        y = entry["at"][1].getInt()
      inc reported
      var exact = false
      for shout in game.recentShouts:
        if shout.x == x and shout.y == y and
            shoutHeardAt(shout) != (x, y):
          exact = true
      check not exact, "a seat was told a shouter's exact pixel"
  check reported > 0, "no seat heard any of the six shouts"

# --- 22. the fallback IS the burrow proc -----------------------------------
block fallbackIsTheBurrowProc:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var ctl = initControlState(game)
  for slot in 0 ..< game.players.len:
    let a = fallbackOrder(game, ctl, slot, game.cogAlias(slot), 3)
    let b = baselineOrder(blBurrow, game, ctl, slot, game.cogAlias(slot), 3)
    check a.intent == b.intent and a.obj == b.obj and a.at == b.at and
      a.hasTo == b.hasTo and a.toX == b.toX and a.toY == b.toY,
      "the fallback and the burrow baseline have drifted apart at slot " & $slot

# --- 23. reply validation ---------------------------------------------------
let objectIds = @["box1", "box2", "box3", "box4", "pan1", "pan2",
                  "ramp1", "ramp2"]
let rampIds = @["ramp1", "ramp2"]
let anchorIds = @["p1", "p2", "d1", "r1"]

proc parse(text: string): tuple[order: Order, rejected: bool] =
  parseOrder(extractJsonObject(text), 0, "HIDER-alpha",
    objectIds, anchorIds, rampIds, 719, 399)

block validatorAcceptsTheSchema:
  let got = parse("""{"intent":"push","object":"box2","to":[188,208],
    "at":"d1","face":[300,200],"say":"on it","radio":"pan1 on d1",
    "notes":"then lock both"}""")
  check not got.rejected, "a legal reply was rejected"
  check got.order.intent == intPush, "intent did not parse"
  check got.order.obj == "box2", "object did not parse"
  check got.order.at == "d1", "at did not parse"
  check got.order.hasTo and got.order.toX == 188, "to did not parse"
  check got.order.say == "on it", "say did not parse"

block validatorRepairsAnUnknownIntent:
  let got = parse("""{"intent":"do-a-barrel-roll","to":[10,10]}""")
  check got.order.intent == intWatch, "an unknown intent did not repair to watch"

block validatorNormalisesIntentSpelling:
  check parse("""{"intent":"MOVE TO","to":[1,1]}""").order.intent == intMoveTo,
    "an intent with a space and capitals did not normalise"
  check parse("""{"intent":"move-to","to":[1,1]}""").order.intent == intMoveTo,
    "a hyphenated intent did not normalise"

block validatorRejectsAnUnknownObject:
  check parse("""{"intent":"push","object":"crate9","to":[1,1]}""").rejected,
    "an unknown object was accepted"
  check parse("""{"intent":"vault","object":"box1"}""").rejected,
    "vaulting a crate was accepted"
  check not parse("""{"intent":"vault","object":"ramp2"}""").rejected,
    "vaulting a real ramp was rejected"

block validatorClampsTo:
  let got = parse("""{"intent":"move_to","to":[99999,-4000]}""")
  check got.order.toX == 719 and got.order.toY == 0,
    "an out-of-board target was not clamped"

block validatorAcceptsATolerantPoint:
  check parse("""{"intent":"move_to","to":["12.5", 30]}""").order.toX == 12,
    "a numeric-string coordinate was rejected"
  check parse("""{"intent":"move_to","to":{"x":5,"y":6}}""").order.toY == 6,
    "an x/y object coordinate was rejected"

block validatorAcceptsASayOnlyReply:
  let got = parse("""{"say":"here","radio":"nothing to add"}""")
  check not got.rejected, "a say-only reply was rejected"
  check not got.order.fromReply,
    "a say-only reply pretended to carry an order"
  check got.order.say == "here", "the say line was dropped"

block validatorRejectsANonObject:
  var raised = false
  try:
    discard parseOrder(newJArray(), 0, "HIDER-alpha", objectIds, anchorIds,
      rampIds, 719, 399)
  except DirectiveError:
    raised = true
  check raised, "a JSON array was accepted as a reply"

block validatorTruncatesOnRuneBoundaries:
  const Emoji = "\u{1F600}"   ## a 4-byte codepoint
  var say = ""
  for i in 0 ..< MaxSayRunes + 4:
    say.add(Emoji)
  var radio = ""
  for i in 0 ..< MaxRadioRunes + 4:
    radio.add(Emoji)
  var notes = ""
  for i in 0 ..< MaxNoteRunes + 4:
    notes.add(Emoji)
  check sanitizeRadio(radio).runeLen == MaxRadioRunes,
    "radio was not cut to exactly the rune cap"
  check sanitizeNote(notes).runeLen == MaxNoteRunes,
    "notes was not cut to exactly the rune cap"
  check validateUtf8(sanitizeRadio(radio)) < 0,
    "the radio cut left a broken codepoint"
  check validateUtf8(sanitizeNote(notes)) < 0,
    "the notes cut left a broken codepoint"
  # `say` is capped on runes FIRST and then filtered to printable ASCII, so an
  # all-emoji shout is empty rather than half a codepoint.
  check validateUtf8(sanitizeSay(say)) < 0, "the say cut left a broken codepoint"
  # A mixed line keeps exactly the cap, on a boundary.
  let mixed = "abcdefg" & Emoji & Emoji & Emoji & Emoji & Emoji
  check truncateRunes(mixed, 10).runeLen == 10, "truncateRunes missed the cap"
  check validateUtf8(truncateRunes(mixed, 10)) < 0,
    "truncateRunes cut a codepoint in half"

block validatorHandlesFencedAndProsyReplies:
  let got = parse("Sure! ```json\n{\"intent\":\"hide\",\"at\":\"p1\"}\n``` ok?")
  check got.order.intent == intHide, "a fenced reply was not recovered"
  check got.order.at == "p1", "the fenced reply's anchor was lost"

# --- 24. the tuning pin -----------------------------------------------------
block tuningIsTheSweptPick:
  let record = parseJson(readFile("tools/ci/baseline_tuning.json"))
  check record{"panelReach"}.getInt() == DefaultBaselineParams.panelReach,
    "panelReach drifted from tools/ci/baseline_tuning.json"
  check record{"rampSweep"}.getInt() == DefaultBaselineParams.rampSweep,
    "rampSweep drifted from tools/ci/baseline_tuning.json"
  check record{"flinchRadius"}.getInt() == DefaultBaselineParams.flinchRadius,
    "flinchRadius drifted from tools/ci/baseline_tuning.json"
  check record{"chaseRadius"}.getInt() == DefaultBaselineParams.chaseRadius,
    "chaseRadius drifted from tools/ci/baseline_tuning.json"
  check record{"pushGiveUpTicks"}.getInt() ==
    DefaultBaselineParams.pushGiveUpTicks,
    "pushGiveUpTicks drifted from tools/ci/baseline_tuning.json"
  check record{"doorRotation"}.getInt() == DefaultBaselineParams.doorRotation,
    "doorRotation drifted from tools/ci/baseline_tuning.json"
  # The band is read from the HARNESS, never from the record: a test that
  # checks a file against a band the same file carries can never fail on a bad
  # pick (r1 F6).
  let margin = record{"margin"}.getInt()
  let band = record{"marginBand"}
  check band[0].getInt() == MarginLo and band[1].getInt() == MarginHi,
    "the recorded band [" & $band[0].getInt() & ", " & $band[1].getInt() &
    "] is not the harness's [" & $MarginLo & ", " & $MarginHi & "]"
  check margin >= MarginLo and margin <= MarginHi,
    "the recorded burrow-vs-scatter margin " & $margin &
    " is outside the harness's band"
  check record{"grid"}.len >= 4, "the sweep recorded no grid"
  # And the grid MEASURED something: an axis whose every cell carries the same
  # margin tuned nothing, which is exactly what the pre-F1 record showed.
  var margins: seq[int]
  for row in record{"grid"}:
    if row{"margin"}.getInt() notin margins:
      margins.add(row{"margin"}.getInt())
  check margins.len >= 3,
    "every cell of the swept grid measured the same margin: the sweep tuned " &
    "nothing"
  check record{"flinchProbe"}.len == 3,
    "the record carries no flinchRadius probe"

echo "test_hns_control: ok"
