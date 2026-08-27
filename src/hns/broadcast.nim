## The broadcast state channel.
##
## Derives the broadcast client's JSON chrome from the live sim, and DERIVES
## the beat/feed events from state deltas one sim step at a time, so they cost
## no replay bytes and are identical live and in replay. Forked from
## coworld-ctf's `src/ctf/broadcast.nim`: same structure, retargeted fields.
##
## The event vocabulary is a CLOSED ENUM (§Record and event vocabulary B) and
## `tests/test_hns_events.nim` asserts the emitted set equals it exactly.

import
  std/[json, sets, strutils],
  sim, global

const BroadcastEventKinds*: array[20, string] = [
  "phase", "gamestart", "release", "turn", "order", "say", "radio",
  "fallback", "grab", "drop", "lock", "unlock", "lockrefused", "vault",
  "spotted", "lost", "sealed", "unsealed", "gameover", "end"
]
  ## The nineteen in-game kinds plus the terminal `end` verdict. Nothing else
  ## may be emitted.

const BeatKinds*: array[7, string] = [
  "release", "spotted", "lock", "vault", "sealed", "fallback", "gameover"
]
  ## The ONLY kinds that make a scrubber marker. To keep the scrubber readable
  ## a `spotted` beat is emitted only for the FIRST spot of each hider in each
  ## game and for any spot that begins an exposure run of >= 48 ticks; the rest
  ## drive the feed only.

const LongExposureTicks* = 48

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    prevMatchPhase: MatchPhase
    prevGameIndex: int
    prevGames: int
    holding: seq[int]
    locked: seq[LockOwner]
    airborne: seq[bool]
    sealed: seq[bool]
    shoutTicks: seq[int]
    spotted: seq[bool]
    spottedSince: seq[int]
    firstSpot: seq[bool]
    startedGame: bool

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevPhase = Lobby
  result.prevGameIndex = -1

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.prevMatchPhase = sim.matchPhase
  tracker.prevGameIndex = sim.gameIndex
  tracker.prevGames = sim.gameMargins.len
  tracker.holding.setLen(sim.players.len)
  tracker.airborne.setLen(sim.players.len)
  tracker.sealed.setLen(sim.players.len)
  tracker.shoutTicks.setLen(sim.players.len)
  for i, player in sim.players:
    tracker.holding[i] = player.holding
    tracker.airborne[i] = player.airborne
    tracker.sealed[i] = player.sealed
    tracker.shoutTicks[i] = player.lastShoutTick
  tracker.locked.setLen(sim.objects.len)
  for i, obj in sim.objects:
    tracker.locked[i] = obj.lockedBy
  let pairs = sim.players.len * sim.players.len
  if tracker.spotted.len != pairs:
    tracker.spotted = newSeq[bool](pairs)
    tracker.spottedSince = newSeq[int](pairs)
  if tracker.firstSpot.len != sim.players.len:
    tracker.firstSpot = newSeq[bool](sim.players.len)

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## After a seek: adopt the current state without emitting anything.
  tracker.snapshot(sim)
  tracker.initialized = true

proc alias(sim: SimServer, index: int): string =
  if index >= 0 and index < sim.players.len: sim.cogAlias(index) else: "?"

proc slotOf(sim: SimServer, index: int): int =
  if index >= 0 and index < sim.players.len: sim.players[index].joinOrder
  else: -1

proc stepEvents*(
  sim: var SimServer,
  tracker: var BroadcastTracker,
  events: JsonNode
) =
  ## Derives this step's broadcast events from state deltas. Called once per
  ## sim step, live and in replay, so both tell the same story.
  if not tracker.initialized:
    tracker.resync(sim)
    return
  if sim.tickCount == tracker.prevTick:
    return

  if sim.phase != tracker.prevPhase:
    events.add(%*{"k": "phase", "phase": ($sim.phase).toLowerAscii,
      "tick": sim.tickCount})
    if sim.phase == Playing:
      events.add(%*{"k": "gamestart", "game": sim.gameIndex + 1,
        "tick": sim.tickCount})
      for i in 0 ..< tracker.firstSpot.len:
        tracker.firstSpot[i] = false

  if sim.matchPhase != tracker.prevMatchPhase and
      sim.matchPhase == phaseHunt:
    events.add(%*{"k": "release", "tick": sim.tickCount})

  if sim.config.turnTicks > 0 and sim.phase == Playing and
      (sim.tickCount - sim.gameStartTick) mod sim.config.turnTicks == 0:
    events.add(%*{
      "k": "turn",
      "n": (sim.tickCount - sim.gameStartTick) div sim.config.turnTicks,
      "phase": phaseText(sim.matchPhase),
      "tick": sim.tickCount
    })

  # Grab / drop.
  for i in 0 ..< min(sim.players.len, tracker.holding.len):
    let now = sim.players[i].holding
    let was = tracker.holding[i]
    if now == was:
      continue
    if now >= 0 and now < sim.objects.len:
      events.add(%*{"k": "grab", "slot": sim.slotOf(i),
        "alias": sim.alias(i), "object": sim.objects[now].id,
        "tick": sim.tickCount})
    elif was >= 0 and was < sim.objects.len:
      events.add(%*{"k": "drop", "slot": sim.slotOf(i),
        "alias": sim.alias(i), "object": sim.objects[was].id,
        "moved_px": sim.players[i].pushedPx, "tick": sim.tickCount})

  # Lock / unlock.
  for i in 0 ..< min(sim.objects.len, tracker.locked.len):
    let now = sim.objects[i].lockedBy
    if now == tracker.locked[i]:
      continue
    if now == lockNone:
      events.add(%*{"k": "unlock", "object": sim.objects[i].id,
        "team": lockText(tracker.locked[i]), "tick": sim.tickCount})
    else:
      events.add(%*{"k": "lock", "object": sim.objects[i].id,
        "team": lockText(now), "tick": sim.tickCount})

  # Vault: an airborne transition is the launch, the landing its end.
  for i in 0 ..< min(sim.players.len, tracker.airborne.len):
    if sim.players[i].airborne and not tracker.airborne[i]:
      events.add(%*{"k": "vault", "slot": sim.slotOf(i),
        "alias": sim.alias(i),
        "from": [sim.players[i].vaultFromX, sim.players[i].vaultFromY],
        "to": [sim.players[i].x, sim.players[i].y],
        "ok": true, "tick": sim.tickCount})

  # Shouts.
  for i in 0 ..< min(sim.players.len, tracker.shoutTicks.len):
    if sim.players[i].lastShoutTick == tracker.shoutTicks[i]:
      continue
    for shout in sim.recentShouts:
      if shout.address == sim.players[i].address and
          shout.tick == sim.players[i].lastShoutTick:
        events.add(%*{"k": "say", "slot": sim.slotOf(i),
          "alias": sim.alias(i), "text": shout.text,
          "x": shout.x, "y": shout.y, "tick": sim.tickCount})

  # Spotted / lost, and the sealed-fort transitions.
  if sim.matchPhase == phaseHunt and sim.phase == Playing:
    for s in 0 ..< sim.players.len:
      if sim.players[s].team != Blue:
        continue
      for h in 0 ..< sim.players.len:
        if sim.players[h].team != Red:
          continue
        let
          index = s * sim.players.len + h
          sees = sim.players[s].alive and sim.players[h].alive and
            sim.playerVisibleTo(s, h)
        if index >= tracker.spotted.len:
          continue
        if sees and not tracker.spotted[index]:
          tracker.spottedSince[index] = sim.tickCount
          events.add(%*{"k": "spotted", "seeker": sim.slotOf(s),
            "hider": sim.slotOf(h), "seekerAlias": sim.alias(s),
            "hiderAlias": sim.alias(h),
            "x": sim.players[h].x, "y": sim.players[h].y,
            "tick": sim.tickCount,
            "beat": (not tracker.firstSpot[h])})
          tracker.firstSpot[h] = true
        elif not sees and tracker.spotted[index]:
          events.add(%*{"k": "lost", "seeker": sim.slotOf(s),
            "hider": sim.slotOf(h), "hiderAlias": sim.alias(h),
            "ticks": sim.tickCount - tracker.spottedSince[index],
            "tick": sim.tickCount})
        tracker.spotted[index] = sees

  for i in 0 ..< min(sim.players.len, tracker.sealed.len):
    if sim.players[i].sealed == tracker.sealed[i]:
      continue
    events.add(%*{
      "k": (if sim.players[i].sealed: "sealed" else: "unsealed"),
      "hiders": sim.sealedCount(),
      "alias": sim.alias(i),
      "tick": sim.tickCount
    })

  if sim.gameMargins.len > tracker.prevGames and sim.gameMargins.len > 0:
    let index = sim.gameMargins.len - 1
    events.add(%*{
      "k": "gameover",
      "game": index + 1,
      "margin": sim.gameMargins[index],
      "hidden": sim.gameHidden[index],
      "seen": sim.gameSeen[index],
      "tick": sim.tickCount
    })
    if sim.gameMargins.len >= sim.config.maxGames:
      var scores = newJArray()
      for slot in 0 ..< sim.seatCount():
        scores.add(%(sim.scorePermille(slot).float / 1000.0))
      events.add(%*{
        "k": "end",
        "reason": sim.endReason,
        "endRule": sim.endRule,
        "scores": scores,
        "tick": sim.tickCount
      })

  tracker.snapshot(sim)

# ---------------------------------------------------------------------------
# The chrome frame
# ---------------------------------------------------------------------------

proc plateJson(sim: SimServer, slot: int): JsonNode =
  ## One scorebug plate / endcard row. The KEY NAMES are the inherited
  ## chrome's (`s` = slot, `team`, `name`, `alias`, `pol`), because the plates,
  ## the squad strip and the endcard rows above the splice banner read them;
  ## the VALUES are this game's.
  ##
  ## `name` is the seat's REAL policy name and is SPECTATOR SIDE ONLY: it
  ## never appears in an observation, an order or a sprite label.
  let
    index = sim.playerIndexForSlot(slot)
    team = teamText(if index >= 0: sim.players[index].team
                    else: sideOf(slot, sim.gameIndex))
  result = %*{
    "s": slot,
    "team": team,
    "alias": sim.aliasForSlot(slot),
    "name": (if slot < sim.seatNames.len and sim.seatNames[slot].len > 0:
               sim.seatNames[slot] else: "Seat " & $(slot + 1)),
    "pol": (if slot < sim.seatNames.len and sim.seatNames[slot].len > 0:
              policyName(sim.seatNames[slot]) else: "Seat " & $(slot + 1)),
    "kind": (if slot < sim.seatPolicyKind.len: sim.seatPolicyKind[slot]
             else: "scripted"),
    "seen": 0,
    "unseen": 0,
    "locks": 0,
    "vaults": 0,
    "fb": (if slot < sim.fallbackTurns.len: sim.fallbackTurns[slot] else: 0),
    "holding": "",
    "sealed": false
  }
  if index >= 0:
    result["seen"] = %sim.players[index].seatSeenTicks
    result["unseen"] = %max(0,
      sim.huntTicksPlayed - sim.players[index].seatSeenTicks)
    result["locks"] = %sim.players[index].locks
    result["vaults"] = %sim.players[index].vaults
    result["sealed"] = %sim.players[index].sealed
    if sim.players[index].holding >= 0:
      result["holding"] = %sim.objects[sim.players[index].holding].id

proc teamsJson(sim: SimServer): JsonNode =
  ## The two trios, keyed by the engine's own team names so the inherited
  ## chrome's colour map and plate layout keep working unchanged. The WORDS on
  ## screen are re-mapped to HIDERS / SEEKERS by the game block.
  result = newJObject()
  for team in Team:
    var
      seen = 0
      unseen = 0
      sealedCogs = 0
      locked = sim.lockedCount(lockOwnerFor(team))
      names = newJArray()
      seenPolicies = initHashSet[string]()
    for player in sim.players:
      if player.team != team:
        continue
      seen += player.seatSeenTicks
      unseen += max(0, sim.huntTicksPlayed - player.seatSeenTicks)
      if player.sealed:
        inc sealedCogs
    for slot in 0 ..< sim.seatCount():
      let index = sim.playerIndexForSlot(slot)
      if index >= 0 and sim.players[index].team == team and
          slot < sim.seatNames.len:
        # DISTINCT policy identities, in join-slot order: the chrome headlines
        # a side with this list and prints one end-card group per entry, so a
        # side seating one policy across three seats must contribute one name.
        let policy = policyName(sim.seatNames[slot])
        if policy.len > 0 and not seenPolicies.containsOrIncl(policy):
          names.add(%policy)
    result[teamText(team)] = %*{
      "role": roleText(team),
      "seen": seen,
      "unseen": unseen,
      "locked": locked,
      "sealed": sealedCogs,
      "exposed": (team == Blue and sim.exposedNow) or
        (team == Red and sim.exposedNow),
      "policies": names
    }

proc rosterJson(sim: SimServer): JsonNode =
  result = newJArray()
  for slot in 0 ..< sim.seatCount():
    result.add(sim.plateJson(slot))

proc objectsJson(sim: SimServer): JsonNode =
  result = newJArray()
  for obj in sim.objects:
    result.add(%*{
      "id": obj.id,
      "kind": objectKindText(obj.kind),
      "box": [obj.x, obj.y, obj.w, obj.h],
      "locked": lockText(obj.lockedBy),
      "held": obj.heldBy >= 0
    })

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  leadSeries: seq[seq[int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil,
  exposureRibbon: seq[int] = @[]
): string =
  ## The broadcast chrome frame. Board-derived STATE is always present, so a
  ## frame reached by a seek still hydrates the scorebug and the endcard with
  ## no events at all.
  var state = %*{
    "t": sim.tickCount,
    "mt": sim.config.maxTicks * max(1, sim.config.maxGames),
    "ph": ($sim.phase).toLowerAscii,
    "mp": phaseText(sim.matchPhase),
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": boardRenderScaleFor(sim.gameMap.width, sim.gameMap.height),
    "game": sim.gameIndex + 1,
    "games": max(1, sim.config.maxGames),
    "turn": (if sim.config.turnTicks > 0:
               max(0, sim.tickCount - sim.gameStartTick) div
                 sim.config.turnTicks + 1
             else: 1),
    "turns": sim.config.turnsPerGame,
    "phaseLeft": sim.phaseTicksLeft() div TargetFps,
    "room": sim.roomName,
    "hidden": sim.hiddenTicks,
    "seen": sim.seenTicks,
    "margin": sim.currentMargin(),
    "sealed": sim.sealedCount(),
    "hiders": 3,
    "lockedHiders": sim.lockedCount(lockHiders),
    "lockedSeekers": sim.lockedCount(lockSeekers),
    "rampsLocked": sim.lockedRamps(),
    "ramps": (block:
      var n = 0
      for obj in sim.objects:
        if obj.kind == okRamp: inc n
      n),
    "objects": sim.objectsJson(),
    "teams": sim.teamsJson(),
    "roster": sim.rosterJson(),
    "pov": -1,
    "events": (if events.isNil: newJArray() else: events)
  }

  # The commander lines. This is where a spectator SEES the LLM playing.
  if sim.feedDirectives.len > 0:
    var records = newJArray()
    for record in sim.feedDirectives:
      try:
        records.add(parseJson(record))
      except CatchableError:
        discard
    state["directives"] = records

  if leadSeries.len > 0:
    var pts = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      pts.add(row)
    state["lead"] = pts
  if exposureRibbon.len > 0:
    var ribbon = newJArray()
    for run in exposureRibbon:
      ribbon.add(%run)
    state["ribbon"] = ribbon
  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents
  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  # The endcard is STATE, not an event: present on every game-over frame so a
  # viewer who seeks straight to the end still sees the verdict.
  if sim.phase == GameOver or sim.gameMargins.len > 0:
    var margins = newJArray()
    for value in sim.gameMargins:
      margins.add(%value)
    var scores = newJArray()
    for slot in 0 ..< sim.seatCount():
      scores.add(%(sim.scorePermille(slot).float / 1000.0))
    state["over"] = %*{
      "gameMargins": margins,
      "scores": scores,
      "reason": sim.endReason,
      "endRule": sim.endRule,
      "game": sim.gameIndex + 1,
      "games": max(1, sim.config.maxGames),
      "done": sim.gameMargins.len >= sim.config.maxGames
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds

  $state
