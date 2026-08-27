## The roster: join/auth/slot resolution, the identity names, the reward
## accounts, and the results document (`roomResultsJson`).
##
## Forked from coworld-ctf's `src/ctf/roster.nim` with two named edits
## (§The two named edits to roster.nim):
##
## 1. **Aliases.** `cogAlias(slot)` is `roleLabel(team) & "-" &
##    IdentityNames[slot div 2]`. The identity is fixed to the SEAT for the
##    whole episode and only the ROLE PREFIX flips at the side swap, so a
##    spectator can follow a policy while an in-game observation never leaks
##    one. `IdentityNames` itself is the starter's array, unchanged.
## 2. **`squadResultsJson` -> `roomResultsJson`** — one entry per seat, six
##    entries in every seat-indexed array, and the key set is CLOSED: adding
##    a key means updating the manifest's `results_schema` and
##    `tools/ci/docker_smoke.sh`'s expected-key set in the same commit.

import
  std/json,
  sim_types, sim_state, room, phase

const IdentityNames* = [
  "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"]
  ## Per-seat identities, assigned by slot order. The starter's array,
  ## unchanged.

const IdentityNameUnknown* = "?"

proc teamForSlot*(sim: SimServer, order: int): Team =
  ## Sides are dealt by slot parity and swap between the episode's two games.
  let slot =
    if order >= 0 and order < sim.config.slots.len:
      sim.config.slots[order]
    else:
      PlayerSlotConfig()
  if slot.hasTeam and sim.gameIndex == 0:
    slot.team
  else:
    sideOf(order, sim.gameIndex)

proc slotIdentityIndex*(order: int): int {.inline.} =
  ## The identity is FIXED TO THE SEAT for the whole episode: slots 0 and 1
  ## are alpha, 2 and 3 beta, 4 and 5 gamma, so the two trios always hold one
  ## of each name and the swap reads as a role change, not a rename.
  (order div 2) mod IdentityNames.len

proc cogAlias*(sim: SimServer, playerIndex: int): string =
  ## `<ROLE>-<identity>`. These aliases are the ONLY names in an observation,
  ## a prompt, an order, a shout, a radio line or a sprite label.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return IdentityNameUnknown
  roleLabel(sim.players[playerIndex].team) & "-" &
    IdentityNames[slotIdentityIndex(sim.players[playerIndex].joinOrder)]

proc aliasForSlot*(sim: SimServer, slot: int): string =
  let index = block:
    var found = -1
    for i, player in sim.players:
      if player.joinOrder == slot:
        found = i
        break
    found
  if index >= 0:
    sim.cogAlias(index)
  else:
    roleLabel(sideOf(slot, sim.gameIndex)) & "-" &
      IdentityNames[slotIdentityIndex(slot)]

proc shoutIdentityName*(sim: SimServer, shout: Shout): string =
  for i, player in sim.players:
    if player.address == shout.address:
      return sim.cogAlias(i)
  IdentityNameUnknown

proc playerSlotLimit*(config: GameConfig): int =
  if config.closedRoster: config.slots.len else: MaxPlayers

proc canAddPlayer*(sim: SimServer): bool =
  sim.players.len < sim.config.playerSlotLimit()

proc playerLimitError(config: GameConfig): string =
  if config.closedRoster:
    let limit = config.playerSlotLimit()
    return "Configured roster is full (" & $limit &
      (if limit == 1: " player)." else: " players).")
  "can't do more than " & $MaxPlayers & " players."

proc slotConfig(config: GameConfig, slotIndex: int): PlayerSlotConfig =
  if slotIndex >= 0 and slotIndex < config.slots.len:
    config.slots[slotIndex]
  else:
    PlayerSlotConfig()

proc slotRestricted(config: GameConfig, slotIndex: int): bool =
  let slot = config.slotConfig(slotIndex)
  slot.name.len > 0 or slot.token.len > 0

proc slotAuthMatches(
  config: GameConfig,
  slotIndex: int,
  address, token: string
): bool =
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    return false
  if slot.token.len > 0 and token != slot.token:
    return false
  true

proc hasConfiguredToken(config: GameConfig, token: string): bool =
  for slot in config.slots:
    if slot.token.len > 0 and slot.token == token:
      return true
  false

proc hasConfiguredTokens(config: GameConfig): bool =
  for slot in config.slots:
    if slot.token.len > 0:
      return true
  false

proc validatePlayerSlot(
  config: GameConfig,
  slotIndex: int,
  address, token: string
) =
  let slot = config.slotConfig(slotIndex)
  if slot.name.len > 0 and address != slot.name:
    raise newException(HnsError,
      "Player name does not match configured slot " & $slotIndex & ".")
  if slot.token.len > 0 and token != slot.token:
    raise newException(HnsError,
      "Player token does not match configured slot " & $slotIndex & ".")

proc configuredPlayerName*(config: GameConfig, requestedSlot: int,
                           token: string): string =
  if token.len == 0:
    return ""
  if requestedSlot >= 0 and requestedSlot < config.slots.len:
    let slot = config.slots[requestedSlot]
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
    return ""
  for slot in config.slots:
    if slot.name.len > 0 and slot.token.len > 0 and slot.token == token:
      return slot.name
  ""

proc playerJoinAllowed*(
  config: GameConfig,
  address: string,
  requestedSlot: int,
  token: string
): bool =
  if requestedSlot >= config.playerSlotLimit():
    return false
  if token.len > 0 and config.hasConfiguredTokens() and
      not config.hasConfiguredToken(token):
    return false
  if requestedSlot >= 0:
    return config.slotAuthMatches(requestedSlot, address, token)
  for i in 0 ..< config.slots.len:
    let slot = config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if matchedName or matchedToken:
      return config.slotAuthMatches(i, address, token)
  not config.closedRoster

proc slotOccupied(sim: SimServer, slotIndex: int): bool =
  for player in sim.players:
    if player.joinOrder == slotIndex:
      return true
  false

proc matchingConfiguredSlot(sim: SimServer, address, token: string): int =
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let couldMatchName = slot.name.len > 0 and slot.name == address
    let couldMatchToken = slot.token.len > 0 and slot.token == token
    if (couldMatchName or couldMatchToken) and
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc conflictingConfiguredSlot(sim: SimServer, address, token: string): int =
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    let matchedName = slot.name.len > 0 and slot.name == address
    let matchedToken =
      slot.token.len > 0 and token.len > 0 and slot.token == token
    if (matchedName or matchedToken) and
        not sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc namedConfiguredSlot(sim: SimServer, address: string): int =
  for i in 0 ..< sim.config.slots.len:
    if sim.slotOccupied(i):
      continue
    let slot = sim.config.slots[i]
    if slot.name.len > 0 and slot.name == address:
      return i
  -1

proc nextAutoSlot(sim: SimServer, address, token: string): int =
  let slotLimit = sim.config.playerSlotLimit()
  for i in sim.nextJoinOrder ..< slotLimit:
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  for i in 0 ..< sim.nextJoinOrder:
    if i >= slotLimit:
      break
    if sim.slotOccupied(i):
      continue
    if not sim.config.slotRestricted(i) or
        sim.config.slotAuthMatches(i, address, token):
      return i
  -1

proc advanceJoinOrder(sim: var SimServer) =
  while sim.nextJoinOrder < MaxPlayers and
      sim.slotOccupied(sim.nextJoinOrder):
    inc sim.nextJoinOrder

proc resolvePlayerSlot*(
  sim: SimServer,
  address, token: string,
  requestedSlot: int
): int =
  if requestedSlot >= MaxPlayers:
    raise newException(HnsError, "Player slot is out of range.")
  if token.len > 0 and sim.config.hasConfiguredTokens() and
      not sim.config.hasConfiguredToken(token):
    raise newException(HnsError, "Player token is not configured.")
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(HnsError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(HnsError,
        "Player slot " & $requestedSlot & " is already occupied.")
    sim.config.validatePlayerSlot(requestedSlot, address, token)
    return requestedSlot
  result = sim.matchingConfiguredSlot(address, token)
  if result >= 0:
    return result
  let conflict = sim.conflictingConfiguredSlot(address, token)
  if conflict >= 0:
    raise newException(HnsError,
      "Player credentials do not match configured slot " & $conflict & ".")
  result = sim.nextAutoSlot(address, token)
  if result < 0:
    raise newException(HnsError, "No available player slot.")

proc nextPlayerSlot*(sim: SimServer): int =
  sim.players.len

proc resolveTrustedPlayerSlot(
  sim: SimServer,
  address: string,
  requestedSlot: int
): int =
  ## A replay's join records are trusted: they carry no token.
  if requestedSlot >= MaxPlayers:
    raise newException(HnsError, "Player slot is out of range.")
  if requestedSlot >= 0:
    if requestedSlot >= sim.config.playerSlotLimit():
      raise newException(HnsError, "Player slot is outside configured roster.")
    if sim.slotOccupied(requestedSlot):
      raise newException(HnsError,
        "Player slot " & $requestedSlot & " is already occupied.")
    return requestedSlot
  result = sim.namedConfiguredSlot(address)
  if result >= 0:
    return result
  result = sim.nextAutoSlot(address, "")
  if result < 0:
    raise newException(HnsError, "No available player slot.")

proc rewardAccountIndex(sim: SimServer, address: string): int =
  for i in 0 ..< sim.rewardAccounts.len:
    if sim.rewardAccounts[i].address == address:
      return i
  -1

proc ensureRewardAccount(sim: var SimServer, address: string): int =
  result = sim.rewardAccountIndex(address)
  if result < 0:
    sim.rewardAccounts.add RewardAccount(
      address: address,
      slotIndex: -1,
      reward: 0
    )
    result = sim.rewardAccounts.high

proc bindRewardAccountSlot(sim: var SimServer, accountIndex, slotIndex: int) =
  if accountIndex < 0 or accountIndex >= sim.rewardAccounts.len:
    return
  for i in 0 ..< sim.rewardAccounts.len:
    if i != accountIndex and sim.rewardAccounts[i].slotIndex == slotIndex:
      sim.rewardAccounts[i].slotIndex = -1
  sim.rewardAccounts[accountIndex].slotIndex = slotIndex

proc playerIndexForSlot*(sim: SimServer, slotIndex: int): int =
  for i in 0 ..< sim.players.len:
    if sim.players[i].joinOrder == slotIndex:
      return i
  -1

proc playerAddressOccupied*(sim: SimServer, address: string): bool =
  for player in sim.players:
    if player.address == address:
      return true
  false

proc removePlayerAt*(sim: var SimServer, playerIndex: int) =
  ## Removes one live cog and keeps index-keyed state aligned. Anything it
  ## held is dropped where it stands.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let held = sim.players[playerIndex].holding
  if held >= 0 and held < sim.objects.len:
    sim.objects[held].heldBy = -1
  for i in 0 ..< sim.objects.len:
    if sim.objects[i].heldBy > playerIndex:
      dec sim.objects[i].heldBy
  sim.players.delete(playerIndex)
  if playerIndex < sim.fovCaches.len:
    sim.fovCaches.delete(playerIndex)

proc padPosition*(sim: SimServer, team: Team, order: int): tuple[x, y: int] =
  ## The pad this cog starts a game on. Hider pads are dealt from the seeded
  ## stream (§determinism step 3) and stored in `homeX/homeY`; this is the
  ## fallback used at JOIN time, before the game's deal is applied.
  let pads = sim.gameMap.padsFor(
    if team == Red: anchorHiders else: anchorSeekers)
  if pads.len == 0:
    return (sim.gameMap.width div 2, sim.gameMap.height div 2)
  let pad = pads[order mod pads.len]
  (pad.x, pad.y)

proc addPlayer*(
  sim: var SimServer,
  address: string,
  requestedSlot = -1,
  token = "",
  trusted = false
): int =
  if not sim.canAddPlayer():
    raise newException(HnsError, sim.config.playerLimitError())
  if sim.playerAddressOccupied(address):
    raise newException(HnsError, "Player name is already connected.")
  let
    order =
      if trusted:
        sim.resolveTrustedPlayerSlot(address, requestedSlot)
      else:
        sim.resolvePlayerSlot(address, token, requestedSlot)
    nextSlot = sim.nextPlayerSlot()
  if not trusted and order != nextSlot:
    raise newException(HnsError,
      "Player slot " & $order & " cannot join before slot " & $nextSlot & ".")
  let
    slot = sim.config.slotConfig(order)
    team = sideOf(order, sim.gameIndex)
    color = if slot.hasColor: slot.color else: teamColor(team)
    accountIndex = sim.ensureRewardAccount(address)
    spawn = sim.padPosition(team, order div 2)
  sim.bindRewardAccountSlot(accountIndex, order)
  sim.rewardAccounts[accountIndex].hasTeam = false
  sim.rewardAccounts[accountIndex].won = false
  sim.rewardAccounts[accountIndex].abandoned = false
  sim.players.add Player(
    x: spawn.x,
    y: spawn.y,
    homeX: spawn.x,
    homeY: spawn.y,
    aimBrads: spawnAimBrads(team),
    team: team,
    alive: true,
    holding: -1,
    joinOrder: order,
    seat: order,
    address: address,
    color: color,
    skin: slot.skin,
    lastShoutTick: -1,
    reward: sim.rewardAccounts[accountIndex].reward
  )
  sim.fovCaches.add PlayerFov(
    valid: false,
    visible: newSeq[bool](FovCellCount)
  )
  sim.advanceJoinOrder()
  sim.players.high

proc addReward*(sim: var SimServer, playerIndex, amount: int) =
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let address = sim.players[playerIndex].address
  let index = sim.ensureRewardAccount(address)
  sim.bindRewardAccountSlot(index, sim.players[playerIndex].joinOrder)
  sim.rewardAccounts[index].reward += amount
  sim.players[playerIndex].reward = sim.rewardAccounts[index].reward

proc seatCount*(sim: SimServer): int {.inline.} =
  max(sim.config.numAgents, sim.players.len)

proc jsonInts(values: openArray[int]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc jsonBools(values: openArray[bool]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc jsonStrings(values: openArray[string]): JsonNode =
  result = newJArray()
  for value in values:
    result.add(%value)

proc roomResultsJson*(sim: SimServer): string =
  ## The results document (§Server). CLOSED SCHEMA: exactly these keys, every
  ## seat-indexed array exactly `num_agents` long, every per-game array
  ## exactly `games` long. The league ranks by `scores`.
  let seats = sim.seatCount()
  var
    names = newSeq[string](seats)
    aliases = newSeq[string](seats)
    teams = newSeq[string](seats)
    scores = newJArray()
    wins = newSeq[bool](seats)
    seatSeen = newSeq[int](seats)
    sealedTicks = newSeq[int](seats)
    grabs = newSeq[int](seats)
    pushedPx = newSeq[int](seats)
    locks = newSeq[int](seats)
    vaults = newSeq[int](seats)
    shouts = newSeq[int](seats)
    policyKinds = newSeq[string](seats)
    llmTurns = newSeq[int](seats)
    fallbackTurns = newSeq[int](seats)
    ordersRejected = newSeq[int](seats)
    deadSeats = newSeq[bool](seats)
    sawLlm = false
    sawScripted = false
  for slot in 0 ..< seats:
    names[slot] =
      if slot < sim.seatNames.len and sim.seatNames[slot].len > 0:
        sim.seatNames[slot]
      else:
        "Seat " & $(slot + 1)
    # `team[s]` is the seat's GAME-1 side; its game-2 side is the other one,
    # by construction.
    teams[slot] = roleText(sideOf(slot, 0))
    aliases[slot] = roleLabel(sideOf(slot, 0)) & "-" &
      IdentityNames[slotIdentityIndex(slot)]
    policyKinds[slot] =
      if slot < sim.seatPolicyKind.len and sim.seatPolicyKind[slot].len > 0:
        sim.seatPolicyKind[slot]
      else:
        "scripted"
    if policyKinds[slot] == "llm": sawLlm = true else: sawScripted = true
    if slot < sim.llmTurns.len: llmTurns[slot] = sim.llmTurns[slot]
    if slot < sim.fallbackTurns.len:
      fallbackTurns[slot] = sim.fallbackTurns[slot]
    if slot < sim.ordersRejected.len:
      ordersRejected[slot] = sim.ordersRejected[slot]
    if slot < sim.deadSeats.len: deadSeats[slot] = sim.deadSeats[slot]
    let index = sim.playerIndexForSlot(slot)
    if index >= 0:
      seatSeen[slot] = sim.players[index].seatSeenTicks
      sealedTicks[slot] = sim.players[index].sealedTicks
      grabs[slot] = sim.players[index].grabs
      pushedPx[slot] = sim.players[index].pushedPx
      locks[slot] = sim.players[index].locks
      vaults[slot] = sim.players[index].vaults
      shouts[slot] = sim.players[index].shouts
    let permille = sim.scorePermille(slot)
    scores.add(%(permille.float / 1000.0))
    wins[slot] = permille > 0
  let node = %*{
    "names": jsonStrings(names),
    "aliases": jsonStrings(aliases),
    "team": jsonStrings(teams),
    "scores": scores,
    "win": jsonBools(wins),
    "reason": (if sim.endReason.len > 0: sim.endReason else: ReasonComplete),
    "endRule": (if sim.endRule.len > 0: sim.endRule else: EndRuleFullTime),
    "games": sim.gameMargins.len,
    "gameMargins": jsonInts(sim.gameMargins),
    "hiddenTicks": jsonInts(sim.gameHidden),
    "seenTicks": jsonInts(sim.gameSeen),
    "huntTicksPlayed": jsonInts(sim.gameHuntPlayed),
    "seatSeenTicks": jsonInts(seatSeen),
    "sealedTicks": jsonInts(sealedTicks),
    "grabs": jsonInts(grabs),
    "pushedPx": jsonInts(pushedPx),
    "locks": jsonInts(locks),
    "vaults": jsonInts(vaults),
    "shouts": jsonInts(shouts),
    "room": sim.roomName,
    "policyKinds": jsonStrings(policyKinds),
    "crossPlay": sawLlm and sawScripted,
    "llmTurns": jsonInts(llmTurns),
    "fallbackTurns": jsonInts(fallbackTurns),
    "ordersRejected": jsonInts(ordersRejected),
    "deadSeats": jsonBools(deadSeats),
    "finalTick": sim.tickCount,
    "seed": sim.config.seed,
    "stopDetail": sim.stopDetail
  }
  $node

const ResultsKeys* = [
  "names", "aliases", "team", "scores", "win", "reason", "endRule", "games",
  "gameMargins", "hiddenTicks", "seenTicks", "huntTicksPlayed",
  "seatSeenTicks", "sealedTicks", "grabs", "pushedPx", "locks", "vaults",
  "shouts", "room", "policyKinds", "crossPlay", "llmTurns", "fallbackTurns",
  "ordersRejected", "deadSeats", "finalTick", "seed", "stopDetail"]
  ## The CLOSED key set. `tests/test_hns_engine.nim` asserts the emitted
  ## document's keys equal this exactly and that it equals the manifest's
  ## `results_schema` key set.

proc recordGameAbandon*(sim: var SimServer, playerIndex: int) =
  ## A seat that walked out is marked on its reward account. It does NOT end
  ## the episode: the cog is driven by `burrow` and the game runs to its
  ## natural end with `deadSeats[s] = true`.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  let index = sim.rewardAccountIndex(sim.players[playerIndex].address)
  if index >= 0:
    sim.rewardAccounts[index].abandoned = true
  let slot = sim.players[playerIndex].joinOrder
  while sim.deadSeats.len <= slot:
    sim.deadSeats.add(false)
  sim.deadSeats[slot] = true
