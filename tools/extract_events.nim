## Re-simulate a recorded replay and emit the tier-2 JSON-lines event stream.
##
## Forked from coworld-ctf's `tools/extract_events.nim` and cut to this game's
## sixteen event kinds. The live server emits the SAME rows as it plays (see
## `server.nim`), and both paths must produce byte-identical output: a consumer
## cannot be asked to tell them apart, and a second serializer would drift the
## moment a field is added.
##
##   nim r --hints:off -d:release --path:src tools/extract_events.nim \
##     <replay path> [out.jsonl]

import
  std/[json, os],
  hns/[sim, events, replays, replay_runtime]

when isMainModule:
  if paramCount() < 1:
    quit("usage: extract_events <replay path> [out.jsonl]", 1)
  let
    path = paramStr(1)
    outPath = if paramCount() >= 2: paramStr(2) else: ""
  var initialized = initReplayRuntime(
    loadReplay(path), mismatchQuit = false, gameEventLoggingEnabled = false)
  var
    game = move(initialized.sim)
    player = move(initialized.player)
  game.collectEvents = true
  var collected: seq[SimEvent] = @[]
  while player.playing and game.tickCount < player.replayMaxTick():
    player.stepReplay(game)
    for event in game.events:
      collected.add(event)
    game.events.setLen(0)
  var summary = newJObject()
  summary["room"] = %game.roomName
  summary["seed"] = %game.config.seed
  summary["games"] = %game.gameMargins.len
  let text = collected.eventsJsonl(game.tickCount, summary)
  if outPath.len > 0:
    writeFile(outPath, text)
    echo "wrote ", outPath, " (", collected.len, " events)"
  else:
    stdout.write(text)
