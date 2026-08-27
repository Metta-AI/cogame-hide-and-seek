## Expand a recorded replay into a readable per-turn timeline.
##
## Forked from coworld-ctf's `tools/expand_replay.nim` and retargeted: the
## columns are this game's (phase, exposure, locks, sealed) rather than lives
## and flags. Pure forensics — it re-simulates the bytes and prints; it never
## writes anything the platform reads.
##
##   nim r --hints:off -d:release --path:src tools/expand_replay.nim \
##     <replay path> [every-n-ticks]

import
  std/[os, strformat, strutils],
  hns/[sim, replays, replay_runtime]

when isMainModule:
  if paramCount() < 1:
    quit("usage: expand_replay <replay path> [every-n-ticks]", 1)
  let
    path = paramStr(1)
    every = if paramCount() >= 2: parseInt(paramStr(2)) else: 90
  var initialized = initReplayRuntime(
    loadReplay(path), mismatchQuit = false, gameEventLoggingEnabled = false)
  var
    game = move(initialized.sim)
    player = move(initialized.player)
  echo "room=", game.roomName, " seed=", game.config.seed,
    " objects=", game.objects.len
  echo "tick   game phase  hidden  seen  margin  locked sealed  cogs"
  while player.playing and game.tickCount < player.replayMaxTick():
    player.stepReplay(game)
    if game.tickCount mod max(1, every) != 0:
      continue
    echo &"{game.tickCount:<6} {game.gameIndex + 1:<4} " &
      &"{phaseText(game.matchPhase):<6} {game.hiddenTicks:<7} " &
      &"{game.seenTicks:<5} {game.currentMargin():<7} " &
      &"{game.lockedCount(lockHiders) + game.lockedCount(lockSeekers):<6} " &
      &"{game.sealedCount():<6} {game.players.len}"
  echo "final: margins=", game.gameMargins, " reason=", game.endReason,
    " endRule=", game.endRule
  if player.hashMismatchTick >= 0:
    echo "HASH MISMATCH at tick ", player.hashMismatchTick
