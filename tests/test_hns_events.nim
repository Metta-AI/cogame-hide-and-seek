## 42. The broadcast event vocabulary is a CLOSED ENUM, and the tier-2
## analysis stream is the reduced kind set.

import std/[json, strutils]
import helpers
import hns/[sim_types, broadcast, events]

block theClosedEnumIsWhatTheNoteLists:
  const Expected = [
    "phase", "gamestart", "release", "turn", "order", "say", "radio",
    "fallback", "grab", "drop", "lock", "unlock", "lockrefused", "vault",
    "spotted", "lost", "sealed", "unsealed", "gameover", "end"
  ]
  check BroadcastEventKinds.len == Expected.len,
    "the broadcast enum changed size"
  for kind in Expected:
    var found = false
    for candidate in BroadcastEventKinds:
      if candidate == kind:
        found = true
    check found, "the broadcast enum lost " & kind

block beatsAreASubsetOfTheEnum:
  for beat in BeatKinds:
    var found = false
    for kind in BroadcastEventKinds:
      if kind == beat:
        found = true
    check found, "beat kind " & beat & " is not in the event enum"
  check BeatKinds.len == 7, "the scrubber beat set changed size"

block everyEmittedKindIsInTheEnum:
  var h = newHarness()
  var tracker = initBroadcastTracker()
  tracker.resync(h.game)
  var seen: seq[string]
  h.runEpisode(tickCap = 4000)
  # Replay the episode through the tracker so stepEvents actually runs.
  var replayHarness = newHarness()
  var replayTracker = initBroadcastTracker()
  replayTracker.resync(replayHarness.game)
  for tick in 1 .. 1400:
    if replayHarness.game.gameMargins.len >= 2:
      break
    replayHarness.stepOnce()
    let events = newJArray()
    replayHarness.game.stepEvents(replayTracker, events)
    for event in events:
      let kind = event{"k"}.getStr()
      var known = false
      for candidate in BroadcastEventKinds:
        if candidate == kind:
          known = true
      check known, "stepEvents emitted an undeclared kind: " & kind
      if kind notin seen:
        seen.add(kind)
  check "phase" in seen or "turn" in seen,
    "an entire episode emitted no phase or turn event"

block tierTwoKindsAreTheReducedSet:
  const Expected = [
    "phase", "release", "grab", "drop", "lock", "unlock", "lock_refused",
    "vault", "spotted", "lost", "sealed", "unsealed", "shout", "turn",
    "directive", "fallback"
  ]
  var emitted: seq[string]
  for kind in SimEventKind:
    emitted.add(kind.key())
  check emitted.len == Expected.len,
    "SimEventKind changed size: " & $emitted
  for want in Expected:
    check want in emitted, "the tier-2 stream lost " & want

block theSummaryRowIsMandatory:
  let text = eventsJsonl(@[], 123)
  let lines = text.strip().splitLines()
  check lines.len == 1, "an empty stream did not emit exactly the summary row"
  let summary = parseJson(lines[^1])
  check summary{"type"}.getStr() == "summary", "the trailing row is not a summary"
  check summary{"ticks"}.getInt() == 123, "the summary lost the tick count"
  check summary{"gameVersion"}.getStr() == GameVersion,
    "the summary does not carry the GameVersion"

block theStateNeverFeedsTheInheritedPaintbotChrome:
  ## The inherited page still carries dead paintbot chrome — `buildFlag` and
  ## its flag SVG, the `.ec-heart` endcard glyphs, `.squad-pip`, the `ACH_FOCUS`
  ## achievement plumbing (r1 F14). Every one of them is gated on a STATE
  ## FIELD this game does not emit, which is why none of them can ever draw:
  ## `s.ach`, a roster row's `lives`/`alive`, and a `capture` beat. That was an
  ## inference in the review; this asserts it, over the full worst-case frame
  ## `tools/ci/renderer_fixture_state.json` — six seats, every readout
  ## populated — so the day one of those fields appears, the build says so
  ## instead of the chrome quietly lighting up.
  let state = parseJson(readFileText("tools/ci/renderer_fixture_state.json"))
  for key in ["ach", "flags", "hearts", "lives", "caps", "hills", "paint"]:
    check state{key} == nil,
      "the broadcast state carries `" & key &
      "`, which wakes the inherited paintbot chrome"
  check state{"roster"}.len == 6, "the fixture frame lost its roster"
  for row in state{"roster"}:
    for key in ["lives", "alive", "kills", "hp", "perks", "carry"]:
      check row{key} == nil,
        "a roster row carries `" & key & "`, which the inherited plate " &
        "renderer reads to draw lives, pips and the flag carrier tag"
  let beats = state{"beats"}
  if beats != nil:
    for beat in beats:
      check beat{"k"}.getStr() != "capture",
        "a `capture` beat would draw an .ec-heart endcard glyph"
  for kind in BeatKinds:
    check kind != "capture", "`capture` is back in the beat vocabulary"

echo "test_hns_events: ok"
