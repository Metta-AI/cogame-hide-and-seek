## 29-32. Record, then re-derive — for EVERY end reason, not just the healthy
## one; the bytes are self-sufficient; and the forensic summary is strict
## UTF-8 JSON with every capped field filled to its cap.

import std/[json, os, osproc, strutils, unicode]

proc scratch(name: string): string =
  ## A path nothing else in the suite can be holding: `tests.nim` runs every
  ## module in ONE process and CI runs every file twice, so a fixed temp name
  ## is a recording two runs can share.
  getTempDir() / ("hns-" & name & "-" & $getCurrentProcessId() & ".replay")
import helpers
import hns/[sim_types, replays, replay_runtime, directives, decide]
import test_hns_engine_support

proc reDerive(path: string): tuple[sim: SimServer, mismatch: int] =
  var initialized = initReplayRuntime(
    loadReplay(path), mismatchQuit = false, gameEventLoggingEnabled = false)
  var
    game = move(initialized.sim)
    player = move(initialized.player)
  while player.playing and game.tickCount < player.replayMaxTick():
    player.stepReplay(game)
  (game, player.hashMismatchTick)

block recordThenReDeriveFullTime:
  let path = scratch("full-time")
  let recorded = recordEpisode(path)
  let (played, mismatch) = reDerive(path)
  check mismatch < 0,
    "the full_time replay diverged at tick " & $mismatch
  # A shout is the one chat record that moves HASHED state (`recentShouts` is
  # in `gameHash`), so the recording must contain some for `mismatch < 0` to
  # mean anything about that path.
  var shouts = 0
  for player in recorded.players:
    shouts += player.shouts
  check shouts >= recorded.players.len,
    "the recording carried " & $shouts & " shouts: the hashed shout path is " &
    "not covered by the re-derivation"
  check played.tickCount >= recorded.tickCount - 2,
    "playback stopped early: " & $played.tickCount & " vs " &
    $recorded.tickCount
  check played.objects.len == recorded.objects.len,
    "playback re-derived a different object table"

block recordThenReDeriveWallClock:
  ## THE LOAD-BEARING STOP. A wall-clock fact cannot be re-derived from sim
  ## state, so it is written as one record and applied by the SAME proc on
  ## record and on playback (the particle-worlds 13c66d7 scar).
  let path = scratch("wall-clock")
  var stopped = recordEpisodeWithStop(path, EndRuleWallClock, 300)
  let (played, mismatch) = reDerive(path)
  check mismatch < 0, "the wall_clock replay diverged at tick " & $mismatch
  check played.endReason == ReasonDeadline,
    "playback did not re-derive `deadline`, it read " & played.endReason
  check played.endRule == EndRuleWallClock,
    "playback did not re-derive `wall_clock`, it read " & played.endRule
  check played.gameMargins.len == played.config.maxGames,
    "a stopped episode is not rankable after playback"

block recordThenReDeriveSimFault:
  let path = scratch("sim-fault")
  var stopped = recordEpisodeWithStop(path, EndRuleSimFault, 260)
  let (played, mismatch) = reDerive(path)
  check mismatch < 0, "the sim_fault replay diverged at tick " & $mismatch
  check played.endReason == ReasonFault,
    "playback did not re-derive `fault`, it read " & played.endReason
  check played.endRule == EndRuleSimFault,
    "playback did not re-derive `sim_fault`, it read " & played.endRule

block theBytesAreSelfSufficient:
  let path = scratch("self-sufficient")
  discard recordEpisode(path)
  let data = loadReplay(path)
  let config = parseJson(data.configJson)
  check config{"seed"}.getInt() != 0, "the bytes carry no seed"
  check config{"num_agents"}.getInt() == 6, "the bytes carry no seat count"
  check config{"mapSpec"}{"walls"}.len > 0,
    "the bytes carry no room document"
  check config{"players"}.len == 6, "the bytes carry no player names"
  check data.joins.len == 6, "the bytes carry no join records"
  check data.hashes.len > 0, "the bytes carry no hash chain"
  check data.chats.len > 0, "the bytes carry no chat records"
  # Deleting data/rooms from disk cannot change what the bytes render: the
  # runtime resolves the PINNED document, never the file.
  let resolved = resolveRoom(block:
    var c = defaultGameConfig()
    c.update(data.configJson)
    c)
  check resolved.walls.len > 0, "the pinned room did not resolve"
  check resolved.name == config{"mapSpec"}{"name"}.getStr(),
    "the resolved room is not the pinned one"

block replaySummaryIsStrictUtf8Json:
  ## Every capped field filled to EXACTLY its cap with 4-byte emoji.
  const Emoji = "\u{1F600}"
  var
    radio = ""
    notes = ""
  for i in 0 ..< MaxRadioRunes:
    radio.add(Emoji)
  for i in 0 ..< MaxNoteRunes:
    notes.add(Emoji)
  let path = scratch("summary")
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var writer = openReplayWriter(path, game.config.configJson())
  for slot in 0 ..< game.players.len:
    writer.writeJoin(tickTime(0), slot, game.players[slot].address, slot, "")
    while writer.lastMasks.len < game.players.len:
      writer.lastMasks.add(0)
    writer.writeChat(tickTime(0), slot,
      registerRecord(slot, game.cogAlias(slot), "quartermaster", "llm", ""))
    var order = Order(slot: slot, id: game.cogAlias(slot), intent: intPush,
      obj: "box1", hasTo: true, toX: 100, toY: 100,
      say: sanitizeSay("hello"), radio: sanitizeRadio(radio),
      notes: sanitizeNote(notes), fromReply: true)
    let directive = Directive(slot: slot, order: order, source: dsLlm,
                              latencyMs: 1234)
    writer.writeChat(tickTime(0), slot,
      directive.boundedOrderRecord(1, 1, game.cogAlias(slot), "pushing", nil))
  writer.writeHash(0'u32, game.gameHash())
  game.settleEpisode()
  writer.writeChat(tickTime(0), 0, resultRecord(game))
  writer.closeReplayWriter()

  let outcome = execCmdEx("python3 tools/replay_summary.py " & quoteShell(path))
  check outcome.exitCode == 0,
    "replay_summary.py exited " & $outcome.exitCode & ": " & outcome.output
  check validateUtf8(outcome.output) < 0,
    "replay_summary.py emitted invalid UTF-8"
  let summary = parseJson(outcome.output)
  check summary{"protocol"}.getStr() == "hide-and-seek/v1",
    "the summary's protocol is " & summary{"protocol"}.getStr()
  check summary{"orders"}.len == 6,
    "the summary reports " & $summary{"orders"}.len & " orders, " &
    $summary{"policyKinds"}.len & " policy kinds and " &
    $summary{"radio"}.len & " radio lines; replay is " &
    $getFileSize(path) & " bytes. Output head: " &
    outcome.output[0 ..< min(600, outcome.output.len)]
  check summary{"radio"}.len == 6, "the summary lost the radio lines"
  check summary{"policyKinds"}.len == 6, "the summary lost the policy kinds"
  check summary{"results"}{"reason"}.getStr().len > 0,
    "the summary carries no results"
  for line in summary{"radio"}:
    check line.getStr().runeLen == MaxRadioRunes,
      "a radio line was not exactly at its rune cap after the round trip"

block theSummarySurvivesABraceInTheBinaryHeader:
  ## The header writes a wall-clock millisecond `u64` and two `u16` length
  ## prefixes BEFORE the config, so about one recording in a hundred carries a
  ## literal `{` (0x7B) inside binary — and a summary that brace-matched from
  ## the first `{` in the file then ran off the end and reported an empty
  ## replay (CI run 33124948568). Reproduce it exactly: plant the byte.
  let source = scratch("brace-source")
  discard recordEpisode(source)
  var bytes = readFile(source)
  let configStart = bytes.find("{\"")
  check configStart > 8, "no config object in the recorded header"
  # `configStart - 3` is the last byte of the timestamp `u64`, one byte ahead
  # of the config string's own length prefix.
  bytes[configStart - 3] = '{'
  let planted = scratch("brace-planted")
  writeFile(planted, bytes)
  let outcome = execCmdEx("python3 tools/replay_summary.py " & quoteShell(planted))
  check outcome.exitCode == 0,
    "replay_summary.py exited " & $outcome.exitCode & ": " & outcome.output
  let summary = parseJson(outcome.output)
  check summary{"names"}.len == 6,
    "a `{` in the header lost the config: " &
    outcome.output[0 ..< min(400, outcome.output.len)]
  check summary{"results"}{"reason"}.getStr().len > 0,
    "a `{` in the header lost the records"
  check summary{"gameVersion"}.getStr() == GameVersion,
    "the summary read the game version as \"" &
    summary{"gameVersion"}.getStr() & "\", not \"" & GameVersion & "\""

block everyCommittedFixtureCarriesTheCurrentGameVersion:
  ## The starter's sweep, kept: a straggler fixture shows up in the native
  ## shards rather than three jobs later.
  var checked = 0
  for kind, path in walkDir("tests"):
    if kind != pcFile:
      continue
    if not (path.endsWith(".replay") or path.endsWith(".bitreplay")):
      continue
    let data = loadReplay(path)
    check data.gameVersion == GameVersion,
      path & " carries GameVersion " & data.gameVersion & ", current is " &
      GameVersion
    inc checked
  echo "  (", checked, " committed fixtures swept)"

echo "test_hns_replay: ok"
