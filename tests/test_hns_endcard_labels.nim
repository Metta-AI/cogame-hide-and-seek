## 40. The endcard and chrome label re-mapping. A forked page silently ships
## the starter's vocabulary — nothing in the starter's tests, in
## viewer_smoke.mjs or in the label manifest covers spectator CHROME strings,
## because labels.nim deliberately scopes itself to the POLICY contract. So
## the re-labelings are enumerated here and enforced.

import std/[strutils]
import helpers

let page = readFile("client/replay_broadcast.html")
let core = readFile("client/broadcast_core.js")

proc visibleText(source: string): string =
  ## The page minus its comment blocks, so a comment that explains what was
  ## deleted is not itself a finding. Strips `/* … */`, `//` line tails and
  ## `<!-- … -->`.
  var i = 0
  while i < source.len:
    if i + 1 < source.len and source[i] == '/' and source[i + 1] == '*':
      let close = source.find("*/", i)
      i = if close < 0: source.len else: close + 2
    elif i + 3 < source.len and source[i .. i + 3] == "<!--":
      let close = source.find("-->", i)
      i = if close < 0: source.len else: close + 3
    elif i + 1 < source.len and source[i] == '/' and source[i + 1] == '/':
      let close = source.find('\n', i)
      i = if close < 0: source.len else: close
    else:
      result.add(source[i])
      inc i

let pageText = visibleText(page)
let coreText = visibleText(core)

const Forbidden = [
  "Lives left", "LIVES LEAD", "Clstr", "Hill time",
  "Filling hoppers with fresh paint", "In the locker room",
  "kills / flag story / winner", "hill coverage", "Hill coverage",
  "tags \u00B7", "paint pods", "banked hill time", "WIPES THE FIELD",
  "ON THE HILL", "MUTUAL WIPE", "HEART CAPTURE", "MERCY \u2014 LEAD"
]
  ## The user-visible strings a fork of this page ships by accident. Each one
  ## is a sentence a spectator would read, not an identifier: the inherited
  ## chrome legitimately keeps ids like `lives-num` and `flagicon` for the
  ## plate layout it also inherits, and renaming those would be a rewrite of
  ## the page rather than a re-labelling of it.

const Required = [
  ("<span>Cog</span><span>Unseen</span><span>Seen</span><span>Locks</span><span>Vaults</span>",
   "the endcard's re-mapped column header"),
  ("<span class=\"fl-cap\">Ticks unseen</span>",
   "the endcard's re-mapped team caption"),
  ("<span class=\"momentum-label\">HIDDEN LEAD</span>",
   "the momentum graph's re-mapped label"),
  ("<span class=\"hidden-label hns-lbl\">Unseen</span>",
   "the scorebug plate's re-mapped label"),
  ("aria-hidden=\"true\">Counting to twenty",
   "the locker room's re-mapped caption"),
  ("Before the door opens", "the clock's re-mapped caption"),
  ("Replay hash mismatch", "the integrity warning"),
  ("sightings / locks / vaults on the timeline",
   "the spoilers button's re-mapped title"),
  ("'BOTH SIDES HIDDEN \u2014 EXPOSURE DECIDED'",
   "the endcard's re-mapped win-condition chip")
]

block noPaintbotVocabularySurvives:
  for phrase in Forbidden:
    check phrase notin pageText,
      "the built page still says \"" & phrase & "\""
    check phrase notin coreText,
      "broadcast_core.js still says \"" & phrase & "\""

block everyReMappedStringIsPresentExactlyOnce:
  for (needle, what) in Required:
    let hits = countOccurrences(page, needle)
    check hits == 1,
      what & " appears " & $hits & " times, expected exactly once: " & needle

block theTeamWordsAreReMapped:
  check "String(s.teams[t].role).toUpperCase()" in page,
    "the plates and the endcard still show RED / BLUE instead of " &
    "HIDERS / SEEKERS"

echo "test_hns_endcard_labels: ok"
