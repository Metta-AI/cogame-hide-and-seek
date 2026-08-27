## The tier-2 event WIRE FORMAT, shared by live emission and re-simulation.
## Forked from coworld-ctf's `src/ctf/events.nim`: the same JSON-lines shape
## and the same mandatory trailing summary row, with `SimEventKind` reduced
## to this game's sixteen kinds.
##
## `SimEvent` never enters `gameHash`, so nothing here can affect determinism.

import std/json

import ./sim

proc key*(kind: SimEventKind): string =
  ## The JSON event key for one tier-2 event kind.
  case kind
  of PhaseChange: "phase"
  of Release: "release"
  of Grab: "grab"
  of Drop: "drop"
  of Lock: "lock"
  of Unlock: "unlock"
  of LockRefused: "lock_refused"
  of Vault: "vault"
  of Spotted: "spotted"
  of Lost: "lost"
  of Sealed: "sealed"
  of Unsealed: "unsealed"
  of ShoutEvent: "shout"
  of TurnStart: "turn"
  of Directive: "directive"
  of Fallback: "fallback"

proc jsonRow*(event: SimEvent): JsonNode =
  ## One JSON-lines row for a tier-2 sim event.
  result = newJObject()
  result["tick"] = %event.tick
  result["kind"] = %event.kind.key()
  result["source"] = %event.source
  result["target"] = %event.target
  result["subject"] = %event.subject
  result["amount"] = %event.amount
  result["x"] = %event.x
  result["y"] = %event.y
  result["heading_brads"] = %event.headingBrads
  result["content"] = %event.content

proc eventsJsonl*(
    events: openArray[SimEvent], ticks: int, summaryExtra: JsonNode = nil
): string =
  ## The full JSON-lines stream: one row per event, then a summary.
  ##
  ## The trailing summary row is part of the contract, not decoration — it is
  ## how a reader distinguishes "this episode had no events" from "the file
  ## was truncated", and it carries the GameVersion the events were produced
  ## under so a consumer never has to infer it.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
