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

echo "test_hns_events: ok"
