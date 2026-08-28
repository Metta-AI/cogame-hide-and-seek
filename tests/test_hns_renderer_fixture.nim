## 44. The worst-case renderer fixture's FRAME.
##
## `tools/ci/docker_smoke.sh` runs with no `ANTHROPIC_API_KEY`, so every seat
## in every replay CI can produce plays scripted: `scatter` emits nothing and
## `burrow` emits at most one five-character shout per game, and neither ever
## emits a `radio` line. So no CI artifact carries a full-cap remark, and the
## whole class of chrome that exists only to show what a model said — the
## board's speech bubbles and the feed's say/radio rows — is untested by the
## viewer smoke, by the soak and by the screenshot (the cogchemists
## 2026-08-24 scar; prompts/30-review-loop.md checklist item 15).
##
## This file builds the frame that hurts and commits it as
## `tools/ci/renderer_fixture_state.json`, which `tools/ci/renderer_fixture.html`
## hands to the REAL page in a browser. The frame is built by the SHIPPED
## `buildStateJson` off a real sim, never hand-written, so it cannot drift
## from the state the server actually broadcasts: change a field name in
## `src/hns/broadcast.nim` and this test fails until the fixture is
## regenerated.
##
##   nim r --hints:off --path:src tests/test_hns_renderer_fixture.nim
##     compares the committed frame against a freshly built one
##   HNS_WRITE_RENDERER_FIXTURE=1 nim r … tests/test_hns_renderer_fixture.nim
##     rewrites it

import std/[json, os, strutils, unicode]
import helpers
import hns/[sim_types, broadcast]

const
  FixturePath = "tools/ci/renderer_fixture_state.json"
  Says = ["WWWWWWWWWW", "MMMMMMMMMM", "@@@@@@@@@@",
          "0000000000", "iiiiiiiiii", "WWWWMMMM@@"]
    ## Six DISTINCT full-cap shouts, one per seat, so the fixture can tell
    ## which seat's remark went missing. Ten runes is `MaxSayRunes`.

proc fullRadio(seat: int): string =
  ## A full-cap 96-rune radio line, distinct per seat and ending in a marker
  ## the fixture greps for, so a silently SHORTENED line fails the browser
  ## check instead of passing it.
  let head = "seat " & $seat & " radio "
  result = head
  while result.runeLen < MaxRadioRunes - 4:
    result.add("WM")
  while result.runeLen < MaxRadioRunes - 4:
    result.add("W")
  result.add("[" & $seat & "]")
  while result.runeLen < MaxRadioRunes:
    result.add("W")

proc buildWorstCaseFrame(): string =
  ## Six seats all shouting at their cap, all six directives carrying a
  ## full-cap radio line, three objects locked, a fort sealed, a vault in
  ## flight and a full exposure ribbon — in one frame.
  var h = newHarness()
  h.game.matchPhase = phaseHunt
  # A hunt tick, so the spotted/sealed machinery is live.
  for tick in 1 .. h.game.config.prepTicks + 4:
    h.stepOnce()

  var tracker = initBroadcastTracker()
  var settle = newJArray()
  h.game.stepEvents(tracker, settle)      # resync: emits nothing

  # Every cog shouts at the cap, on the same tick.
  for cog in 0 ..< h.game.players.len:
    h.game.players[cog].lastShoutTick = low(int) div 2
    check h.game.applyShout(cog, Says[cog mod Says.len]),
      "the sim refused a full-cap shout at cog " & $cog
  # Exactly three objects locked, by both teams.
  var locked = 0
  for i in 0 ..< h.game.objects.len:
    h.game.objects[i].lockedBy = lockNone
  for i in 0 ..< h.game.objects.len:
    if locked >= 3:
      break
    if h.game.objects[i].lockedBy == lockNone:
      h.game.objects[i].lockedBy =
        if locked == 2: lockSeekers else: lockHiders
      inc locked
  check locked == 3, "the deal offered fewer than three lockable objects"
  # A vault in flight, and a sealed fort.
  for cog in 0 ..< h.game.players.len:
    if h.game.players[cog].team == Blue:
      h.game.players[cog].airborne = true
      h.game.players[cog].vaultFromX = h.game.players[cog].x
      h.game.players[cog].vaultFromY = h.game.players[cog].y
      break
  for cog in 0 ..< h.game.players.len:
    if h.game.players[cog].team == Red:
      h.game.players[cog].sealed = true

  # Six directives, each with a full-cap radio line, through the SHIPPED
  # record builder and the shipped feed queue.
  for seat in 0 ..< h.game.players.len:
    let cog = h.game.playerIndexForSlot(seat)
    var order = Order(slot: seat, intent: intHide, at: "p1", fromReply: true,
      say: Says[seat mod Says.len], radio: fullRadio(seat))
    let record = Directive(slot: seat, order: order, source: dsLlm,
      latencyMs: 1234).boundedOrderRecord(
        1, 3, h.game.cogAlias(max(cog, 0)), "", nil)
    check parseJson(record){"radio"}.getStr().runeLen == MaxRadioRunes,
      "the record builder shortened a full-cap radio line at seat " & $seat
    h.game.pushFeedDirective(record)

  inc h.game.tickCount
  var events = newJArray()
  h.game.stepEvents(tracker, events)

  # A full exposure ribbon: [firstTick, run, bit, run, bit, …].
  var ribbon = @[h.game.config.prepTicks]
  for run in 0 ..< 24:
    ribbon.add(9)
    ribbon.add(run mod 2)

  h.game.buildStateJson(
    events = events,
    playing = true,
    speed = 1,
    maxTick = h.game.config.maxTicks * 2,
    looping = false,
    transportEnabled = true,
    mismatchTick = -1,
    startTick = 0,
    lullSpans = @[[10, 40]],
    exposureRibbon = ribbon)

let built = buildWorstCaseFrame()

block theFrameCarriesEverySeatsFullCapText:
  let frame = parseJson(built)
  var sayEvents = 0
  for event in frame{"events"}:
    if event{"k"}.getStr() == "say":
      inc sayEvents
      check event{"text"}.getStr().runeLen == MaxSayRunes,
        "a say event carried " & $event{"text"}.getStr().runeLen &
        " runes, not the cap"
  check sayEvents == 6, "the frame carries " & $sayEvents & " say events, not 6"
  var radios = 0
  for record in frame{"directives"}:
    check record{"radio"}.getStr().runeLen == MaxRadioRunes,
      "a directive carried a shortened radio line"
    inc radios
  check radios == 6, "the frame carries " & $radios & " directives, not 6"
  var locks = 0
  for obj in frame{"objects"}:
    if obj{"locked"}.getStr() != "none":
      inc locks
  check locks == 3, "the frame carries " & $locks & " locked objects, not 3"
  var vaults = 0
  for event in frame{"events"}:
    if event{"k"}.getStr() == "vault":
      inc vaults
  check vaults == 1, "the frame carries no vault in flight"
  check frame{"ribbon"}.len > 8, "the frame carries no exposure ribbon"
  check frame{"roster"}.len == 6, "the frame carries " &
    $frame{"roster"}.len & " roster rows, not 6"

block theCommittedFixtureIsCurrent:
  ## The committed frame is regenerated in the same commit as any change to
  ## the broadcast state builder — the fixture is only evidence if it is the
  ## state the server actually sends.
  if getEnv("HNS_WRITE_RENDERER_FIXTURE").len > 0:
    writeFile(FixturePath, parseJson(built).pretty() & "\n")
    echo "  (wrote ", FixturePath, ")"
  check fileExists(FixturePath), FixturePath & " is missing"
  let committed = readFile(FixturePath).strip()
  check committed == parseJson(built).pretty(),
    FixturePath & " is stale. Regenerate it in this commit:\n" &
    "  HNS_WRITE_RENDERER_FIXTURE=1 nim r --hints:off --path:src " &
    "tests/test_hns_renderer_fixture.nim"

echo "test_hns_renderer_fixture: ok"
