## The two-phase clock and the exposure score: `prepTicks`, `huntTicks`, the
## release transition, the per-game reset and the side swap, and the
## `exposed` evaluation with its `seenTicks` / `hiddenTicks` counters.
##
## The rule, from Baker et al. and unchanged here: every tick of the HUNT
## phase on which ANY seeker sees ANY hider costs the hiders a point and pays
## the seekers one; every tick on which all three hiders are unseen does the
## reverse. One hider caught in the open loses the tick for all three.
##
## INTEGER ONLY (`tests/test_hns_determinism.nim`).

import
  sim_types, sim_config, vision

proc sideOf*(slot, gameIndex: int): Team {.inline.} =
  ## Sides are dealt by SLOT PARITY and swap between the episode's two games.
  ## Game 1: slots 0, 2, 4 hide. Game 2: the same six seats, sides swapped.
  ## This is what makes the duel fair — hiding and seeking are not symmetric
  ## jobs, so a league that graded a seat on one of them would be grading the
  ## deal, not the policy.
  if (slot + gameIndex) mod 2 == 0: Red else: Blue

proc isHider*(sim: SimServer, slot: int): bool {.inline.} =
  sim.players[slot].team == Red

proc isSeeker*(sim: SimServer, slot: int): bool {.inline.} =
  sim.players[slot].team == Blue

proc phaseText*(phase: MatchPhase): string =
  case phase
  of phasePrep: "prep"
  of phaseHunt: "hunt"

proc gameTick*(sim: SimServer): int {.inline.} =
  ## Ticks into the CURRENT game.
  sim.tickCount - sim.gameStartTick

proc phaseTicksLeft*(sim: SimServer): int =
  let tick = sim.gameTick()
  case sim.matchPhase
  of phasePrep: max(0, sim.config.prepTicks - tick)
  of phaseHunt: max(0, sim.config.maxTicks - tick)

proc turnOfTick*(sim: SimServer, tick: int): int {.inline.} =
  tick div sim.config.turnTicks

proc frozenSeeker*(sim: SimServer, slot: int): bool {.inline.} =
  ## During PREP the seekers are frozen at their pads: their input masks are
  ## forced to zero, they take no LLM call, their fov is not computed and no
  ## scoring runs. Baker et al.'s preparation phase.
  sim.matchPhase == phasePrep and sim.players[slot].team == Blue

proc liveSeats*(sim: SimServer): seq[int] =
  ## The seats that get an observation and a call this turn: during prep the
  ## three hiders only (a frozen, unobserving seeker has nothing to decide
  ## and its call would be a wasted request against the rate cap), during
  ## hunt all six.
  for slot in 0 ..< sim.players.len:
    if not sim.frozenSeeker(slot):
      result.add(slot)

proc marginPermille*(hidden, seen, played: int): int =
  ## `(hiddenTicks - seenTicks) * 1000 div huntTicks`, in [-1000, +1000],
  ## written from the HIDING trio's point of view. A game that never reached
  ## its hunt phase contributes 0, so a deadline episode is still rankable
  ## and still zero-sum.
  if played <= 0:
    return 0
  (hidden - seen) * 1000 div played

proc currentMargin*(sim: SimServer): int =
  marginPermille(sim.hiddenTicks, sim.seenTicks, sim.huntTicksPlayed)

proc scorePermille*(sim: SimServer, slot: int): int =
  ## `( side(s,0) * margin[0] + side(s,1) * margin[1] ) div games`, where
  ## `side` is +1 when the seat HID in that game and -1 when it sought.
  ## Higher is better. Because every seat hides in exactly one game and
  ## seeks in the other, and the two trios are complementary, the six scores
  ## sum to exactly zero.
  if sim.gameMargins.len == 0:
    return 0
  var total = 0
  for game, margin in sim.gameMargins:
    let side = if sideOf(slot, game) == Red: 1 else: -1
    total += side * margin
  total div sim.gameMargins.len

proc exposedNow*(sim: var SimServer): bool =
  ## `exists seeker s, exists hider h : playerVisibleTo(s, h)`. An airborne
  ## hider uses the static-mask test inside `playerVisibleTo`.
  for s in 0 ..< sim.players.len:
    if sim.players[s].team != Blue or not sim.players[s].alive:
      continue
    for h in 0 ..< sim.players.len:
      if sim.players[h].team != Red or not sim.players[h].alive:
        continue
      if sim.playerVisibleTo(s, h):
        return true
  false

proc pairIndex(sim: SimServer, seeker, hider: int): int {.inline.} =
  seeker * sim.players.len + hider

proc ensurePairLatch*(sim: var SimServer) =
  let want = sim.players.len * sim.players.len
  if sim.spottedPairs.len != want:
    sim.spottedPairs = newSeq[bool](want)

proc scoreExposure*(sim: var SimServer): tuple[
    spotted, lost: seq[tuple[seeker, hider: int]]] =
  ## Tick step 10, HUNT PHASE ONLY. Counts the tick once — a tick with two
  ## seekers seeing two hiders is still ONE seen tick — accumulates the
  ## per-hider counter, and reports the (seeker, hider) pairs that changed
  ## state so the caller can emit `spotted` / `lost`.
  sim.ensurePairLatch()
  var anySeen = false
  for s in 0 ..< sim.players.len:
    if sim.players[s].team != Blue:
      continue
    for h in 0 ..< sim.players.len:
      if sim.players[h].team != Red:
        continue
      let
        index = pairIndex(sim, s, h)
        sees = sim.players[s].alive and sim.players[h].alive and
          sim.playerVisibleTo(s, h)
      if sees and not sim.spottedPairs[index]:
        result.spotted.add((s, h))
      elif not sees and sim.spottedPairs[index]:
        result.lost.add((s, h))
      sim.spottedPairs[index] = sees
      if sees:
        anySeen = true
  for h in 0 ..< sim.players.len:
    if sim.players[h].team != Red:
      continue
    var seen = false
    for s in 0 ..< sim.players.len:
      if sim.players[s].team == Blue and sim.spottedPairs[pairIndex(sim, s, h)]:
        seen = true
    if seen:
      inc sim.players[h].seatSeenTicks
  inc sim.huntTicksPlayed
  if anySeen:
    inc sim.seenTicks
    if not sim.exposedNow:
      sim.exposureRuns.add(ExposureRun(
        game: sim.gameIndex,
        startTick: sim.tickCount,
        endTick: sim.tickCount
      ))
    else:
      sim.exposureRuns[^1].endTick = sim.tickCount
  else:
    inc sim.hiddenTicks
  sim.exposedNow = anySeen

proc archiveGame*(sim: var SimServer) =
  ## Files the finished game's numbers. `marginPermille` is written from the
  ## hiding trio's point of view; the seat-side swap turns it into a per-seat
  ## score at the end of the episode.
  sim.gameMargins.add(
    marginPermille(sim.hiddenTicks, sim.seenTicks, sim.huntTicksPlayed))
  sim.gameHidden.add(sim.hiddenTicks)
  sim.gameSeen.add(sim.seenTicks)
  sim.gameHuntPlayed.add(sim.huntTicksPlayed)

proc resetGameCounters*(sim: var SimServer) =
  sim.hiddenTicks = 0
  sim.seenTicks = 0
  sim.huntTicksPlayed = 0
  sim.exposedNow = false
  sim.matchPhase = phasePrep
  sim.releaseEmitted = false
  sim.sealedMask = 0
  sim.ensurePairLatch()
  for i in 0 ..< sim.spottedPairs.len:
    sim.spottedPairs[i] = false

proc applySideSwap*(sim: var SimServer) =
  ## Deals every seat its side for the CURRENT `gameIndex`.
  for slot in 0 ..< sim.players.len:
    sim.players[slot].team = sideOf(slot, sim.gameIndex)
    sim.players[slot].color = teamColor(sim.players[slot].team)
