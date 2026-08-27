## Shared episode recorders for the engine and replay tests: one
## implementation, so the two can never disagree about what a recording IS.

import std/[json, os]
import helpers
import hns/[sim_types, replays, directives, decide]

proc writeRoster(writer: var ReplayWriter, game: var SimServer) =
  for slot in 0 ..< game.players.len:
    writer.writeJoin(tickTime(game.tickCount), slot,
      game.players[slot].address, slot, "")
    while writer.lastMasks.len < game.players.len:
      writer.lastMasks.add(0)
    writer.writeChat(tickTime(game.tickCount), slot,
      registerRecord(slot, game.cogAlias(slot),
        (if slot mod 2 == 0: "burrow" else: "scatter"), "scripted",
        (if slot mod 2 == 0: "burrow" else: "scatter")))

proc recordEpisode*(
  path: string,
  extra: JsonNode = nil,
  kinds: seq[Baseline] = @[],
  tickCap = 4000
): SimServer =
  ## Plays a real six-seat episode and writes a real `COWLDHNS` replay: the
  ## joins, the per-tick MASKS the control layer produced, one `gameHash` per
  ## tick, the chat records and the `result` document — exactly what
  ## `server.nim` writes, through the same procs.
  # The recording goes through the LOBBY, exactly as the server does: a
  # recorder that called startGame() itself would put the first Playing tick
  # one tick earlier than playback does, and the hash chain would diverge at
  # tick 1 with nothing else wrong.
  var h = newHarness(extra, kinds, startImmediately = false)
  var writer = openReplayWriter(path, h.game.config.configJson())
  writer.writeRoster(h.game)
  var ticks = 0
  while h.game.gameMargins.len < h.game.config.maxGames and ticks < tickCap:
    if h.game.phase == Playing:
      h.ctl.observeEnemies(h.game)
      let turnIndex = h.game.gameTick() div h.game.config.turnTicks
      if h.game.gameTick() mod h.game.config.turnTicks == 0:
        for cog in 0 ..< h.game.players.len:
          h.orders[cog] = baselineOrder(
            h.kinds[cog], h.game, h.ctl, cog, h.game.cogAlias(cog), turnIndex)
          let directive = Directive(slot: cog, order: h.orders[cog],
                                    source: dsScripted)
          writer.writeChat(tickTime(h.game.tickCount), cog,
            directive.boundedOrderRecord(h.game.gameIndex + 1, turnIndex,
              h.game.cogAlias(cog), "", nil))
    var inputs = newSeq[InputState](h.game.players.len)
    for cog in 0 ..< h.game.players.len:
      var mask = 0'u8
      if h.game.phase == Playing:
        mask = h.ctl.compileMask(h.game, h.orders[cog], cog)
        if h.game.frozenSeeker(cog):
          mask = 0
      inputs[cog] = decodeInputMask(mask)
      writer.writeInputMaskChange(tickTime(h.game.tickCount), cog, mask)
    h.game.step(inputs, h.prev)
    h.prev = inputs
    writer.writeHash(uint32(h.game.tickCount), h.game.gameHash())
    inc ticks
  h.game.settleEpisode()
  writer.writeChat(tickTime(h.game.tickCount), 0, resultRecord(h.game))
  writer.closeReplayWriter()
  h.game

proc recordEpisodeWithStop*(
  path: string,
  endRule: string,
  stopAtTick: int
): SimServer =
  ## The same recording, cut short by a LOAD-BEARING stop record. The stop is
  ## written and then applied through the very proc the playback path calls,
  ## which is what makes the record -> re-derive check pass for a wall-clock
  ## or fault ending as well as for full time.
  var h = newHarness(startImmediately = false)
  var writer = openReplayWriter(path, h.game.config.configJson())
  writer.writeRoster(h.game)
  var ticks = 0
  while ticks < stopAtTick:
    if h.game.phase == Playing:
      h.ctl.observeEnemies(h.game)
      let turnIndex = h.game.gameTick() div h.game.config.turnTicks
      if h.game.gameTick() mod h.game.config.turnTicks == 0:
        for cog in 0 ..< h.game.players.len:
          h.orders[cog] = baselineOrder(
            h.kinds[cog], h.game, h.ctl, cog, h.game.cogAlias(cog), turnIndex)
    var inputs = newSeq[InputState](h.game.players.len)
    for cog in 0 ..< h.game.players.len:
      var mask = 0'u8
      if h.game.phase == Playing:
        mask = h.ctl.compileMask(h.game, h.orders[cog], cog)
        if h.game.frozenSeeker(cog):
          mask = 0
      inputs[cog] = decodeInputMask(mask)
      writer.writeInputMaskChange(tickTime(h.game.tickCount), cog, mask)
    h.game.step(inputs, h.prev)
    h.prev = inputs
    writer.writeHash(uint32(h.game.tickCount), h.game.gameHash())
    inc ticks
  # THE STOP IS A RECORD, and a record is applied at the START of the step
  # that leaves its tick — so the recording has to leave one more tick for
  # playback to apply it in. Writing the stop, applying it through the same
  # proc, then stepping once and hashing that tick is what makes the
  # record -> re-derive check pass for a stopped episode.
  writer.writeChat(tickTime(h.game.tickCount), 0,
    $(%*{"k": "stop", "tick": h.game.tickCount, "endRule": endRule,
         "detail": "a forced " & endRule & " stop"}))
  if endRule == EndRuleWallClock:
    h.game.forceWallClockStop()
  else:
    h.game.forceFaultStop("a forced " & endRule & " stop")
    h.game.endRule = endRule
  block:
    let quiet = newSeq[InputState](h.game.players.len)
    for cog in 0 ..< h.game.players.len:
      writer.writeInputMaskChange(tickTime(h.game.tickCount), cog, 0)
    h.game.step(quiet, h.prev)
    writer.writeHash(uint32(h.game.tickCount), h.game.gameHash())
  writer.writeChat(tickTime(h.game.tickCount), 0, resultRecord(h.game))
  writer.closeReplayWriter()
  h.game
