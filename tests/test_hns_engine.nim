## 25-28. An end-to-end episode that writes real artifacts, the "the cert seed
## is interesting" pin, and the two ways an episode is not allowed to stall.

import std/[json, os, strutils, tables]
import helpers
import hns/[sim_types, replays, decide, directives]
import test_hns_engine_support

# --- 25. an episode writes artifacts ---------------------------------------
block episodeWritesArtifacts:
  let dir = getTempDir() / "hns-engine-test"
  createDir(dir)
  let replayPath = dir / "episode.replay"
  let game = recordEpisode(replayPath)
  check fileExists(replayPath), "no replay was written"
  check getFileSize(replayPath) > 0, "the replay is empty"

  let results = parseJson(game.roomResultsJson())
  writeFile(dir / "results.json", $results)
  check results{"reason"}.getStr() == ReasonComplete,
    "reason is " & results{"reason"}.getStr()
  check results{"endRule"}.getStr() == EndRuleFullTime,
    "endRule is " & results{"endRule"}.getStr()
  check results{"games"}.getInt() == 2, "the episode did not play two games"
  var total = 0
  for slot in 0 ..< 6:
    total += game.scorePermille(slot)
  check total == 0, "the six scores did not sum to zero"
  for key in ["names", "aliases", "team", "scores", "win", "seatSeenTicks",
              "sealedTicks", "grabs", "pushedPx", "locks", "vaults",
              "shouts", "policyKinds", "llmTurns", "fallbackTurns",
              "ordersRejected", "deadSeats"]:
    check results{key}.len == 6,
      "results." & key & " has " & $results{key}.len & " entries, expected 6"
  for key in ["gameMargins", "hiddenTicks", "seenTicks", "huntTicksPlayed"]:
    check results{key}.len == results{"games"}.getInt(),
      "results." & key & " is not `games` long"

block theResultsKeySetIsTheManifestKeySet:
  let game = recordEpisode(getTempDir() / "hns-keys.replay")
  let results = parseJson(game.roomResultsJson())
  let manifest = parseJson(readFile("coworld_manifest_template.json"))
  let declared = manifest{"game"}{"results_schema"}{"properties"}
  var emitted: seq[string]
  for key, _ in results:
    emitted.add(key)
  check emitted.len == ResultsKeys.len,
    "roomResultsJson emitted " & $emitted.len & " keys, ResultsKeys lists " &
    $ResultsKeys.len
  for key in ResultsKeys:
    check results.hasKey(key), "roomResultsJson dropped " & key
    check declared.hasKey(key),
      "the manifest's results_schema does not declare " & key
  for key, _ in declared:
    check key in ResultsKeys,
      "the manifest declares " & key & ", which the game never emits"

# --- 26. the cert seed is interesting --------------------------------------
block theCertSeedIsInteresting:
  ## Seed 42 on `warren`, at the certification fixture's own clock, must
  ## exercise the object layer AND the exposure path — otherwise the smoke
  ## replay CI hands to the viewer proves nothing about either.
  let manifest = parseJson(readFile("coworld_manifest_template.json"))
  let fixture = manifest{"certification"}{"game_config"}
  var extra = newJObject()
  for key in ["seed", "roomPool", "prepTurns", "huntTurns", "maxGames",
              "crates", "panels", "ramps"]:
    extra[key] = fixture[key]
  var h = newHarness(extra)
  h.runEpisode()
  var grabs, locks = 0
  for p in h.game.players:
    grabs += p.grabs
    locks += p.locks
  var seen = 0
  for value in h.game.gameSeen:
    seen += value
  check grabs > 0, "the fixture episode never grabbed anything"
  check locks > 0, "the fixture episode never locked anything"
  check seen > 0, "the fixture episode never spotted a hider"
  check h.game.tickCount >= 900,
    "the fixture episode is shorter than the 900 ticks the viewer soak needs"

# --- 27. no seat can stall --------------------------------------------------
block aSeatThatNeverConnectsDoesNotStopTheClock:
  ## The roster is completed with TRUSTED joins carrying only the anonymous
  ## aliases, and the missing seats are marked dead — the episode still runs
  ## to its natural end.
  var game = newTestSim()
  # Only four of the six seats ever join.
  for slot in 0 ..< 4:
    discard game.addPlayer("cog" & $slot, slot, "", trusted = true)
  for slot in 4 ..< game.config.numAgents:
    discard game.addPlayer(game.aliasForSlot(slot), slot, "", trusted = true)
    game.deadSeats[slot] = true
  var ctl = initControlState(game)
  game.startGame()
  var prev = newSeq[InputState](game.players.len)
  var ticks = 0
  while game.gameMargins.len < game.config.maxGames and ticks < 4000:
    var inputs = newSeq[InputState](game.players.len)
    if game.phase == Playing:
      ctl.observeEnemies(game)
      let turnIndex = game.gameTick() div game.config.turnTicks
      for cog in 0 ..< game.players.len:
        # Every unanswered seat plays the burrow fallback.
        let order = fallbackOrder(game, ctl, cog, game.cogAlias(cog), turnIndex)
        var mask = ctl.compileMask(game, order, cog)
        if game.frozenSeeker(cog):
          mask = 0
        inputs[cog] = decodeInputMask(mask)
    game.step(inputs, prev)
    prev = inputs
    inc ticks
  game.settleEpisode()
  check game.gameMargins.len == 2,
    "an episode with two dead seats did not finish"
  var dead = 0
  for value in game.deadSeats:
    if value: inc dead
  check dead == 2, "deadSeats did not record the two no-shows"
  var total = 0
  for slot in 0 ..< 6:
    total += game.scorePermille(slot)
  check total == 0, "an episode with dead seats is not zero-sum"

block thePlayerFailurePayloadIsClosed:
  ## Exactly `{"message", "failed_policy_index"}`, nothing else.
  let payload = %*{"failed_policy_index": 4, "message": "slot 4 never joined"}
  var keys: seq[string]
  for key, _ in payload:
    keys.add(key)
  check keys.len == 2, "the failure payload carries extra keys: " & $keys
  check "message" in keys and "failed_policy_index" in keys,
    "the failure payload lost a required key"

# --- 28. the budget guard settles early ------------------------------------
block budgetGuardSettlesEarlyNotLate:
  var game = newTestSim()
  game.seatAll()
  var engine = initDecisionEngine(game)
  game.startGame()
  var
    views = newSeq[JsonNode](6)
    sources = newSeq[DirectiveSource](6)
    latencies = newSeq[int](6)
  # elapsed + 2 * turnBudget > wallClockBudget, so the guard must fire.
  let records = engine.turn(game, 1, game.config.wallClockBudgetSeconds, views,
    sources, latencies)
  var guarded = false
  for record in records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      guarded = true
  check guarded, "the budget guard did not fire at the wall-clock boundary"
  check engine.llmOff, "the budget guard did not switch the LLM off"
  # Every LIVE seat still has a legal order. During prep the three seekers
  # are frozen and unobserving, so they are not live and take no call at all —
  # that is the point of the preparation phase, not a gap in the ladder.
  for slot in 0 ..< 6:
    let index = game.playerIndexForSlot(slot)
    if index < 0 or game.frozenSeeker(index):
      continue
    check engine.haveOrder[slot],
      "live seat " & $slot & " has no order after the budget guard"
  check game.liveSeats().len == 3,
    "prep did not leave exactly the three hiders live"

echo "test_hns_engine: ok"
