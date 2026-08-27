## 33. The manifest pins. Every claim the design note makes about the shipped
## manifest is asserted here, INCLUDING that every variant's game_config
## actually constructs a valid GameConfig, loads its room pool, deals its
## objects and produces the counts and phase lengths it advertises (the
## collab-cooking 0.1.1 scar: test every variant, not just the fixture).

import std/[json, os, strutils]
import helpers
import hns/[sim_types, sim_config, room]

let manifest = parseJson(readFile("coworld_manifest_template.json"))
let game = manifest{"game"}

block topLevel:
  check manifest.hasKey("$schema"), "the manifest has no $schema"
  check manifest{"tags"}.len >= 3, "fewer than three top-level tags"
  check manifest.hasKey("episode_timeout_minutes"),
    "episode_timeout_minutes is not at the TOP level"
  check not game.hasKey("episode_timeout_minutes"),
    "episode_timeout_minutes must not live under game"
  check not game.hasKey("tags"), "game.tags must not exist (pistonball 0.1.0)"
  check not manifest.hasKey("version"), "no top-level version is allowed"
  check not game.hasKey("display_name"), "game.display_name is not allowed"
  check game{"name"}.getStr() == "hide-and-seek",
    "game.name must equal the slug"
  check game{"owner"}.getStr().len > 0, "game.owner is required"
  check game{"description"}.getStr().len > 0, "game.description is required"
  check game{"runnable"}{"type"}.getStr() == "game", "runnable.type is wrong"
  check game{"runnable"}{"run"}[0].getStr() == "/bin/hide-and-seek",
    "runnable.run does not name the game binary"
  check game{"runnable"}{"image"}.getStr() == "{{HIDE_AND_SEEK_IMAGE}}",
    "the image placeholder is not derived from the compose service name"
  check game{"runnable"}{"env"}{"ANTHROPIC_API_KEY_URI"}.getStr() ==
    "secret://coworld/hide-and-seek/anthropic_api_key",
    "the secret namespace does not agree with game.name"
  check game{"replay_viewer"}{"bundle"}.getStr() == "static-replay-viewer",
    "the replay viewer is not the static bundle, or is not under game"

block protocolsCarryBoth:
  for key in ["player", "global"]:
    let entry = game{"protocols"}{key}
    check entry != nil and entry.kind == JObject,
      "game.protocols." & key & " is missing or is a bare string"
    check entry{"type"}.getStr() == "uri",
      "game.protocols." & key & " is not a {type, value} object"
    check entry{"value"}.getStr().startsWith("https://"),
      "game.protocols." & key & " has no URL"

block docsAreInlinedText:
  let docs = game{"docs"}
  check docs{"readme"}{"type"}.getStr() == "text", "docs.readme is not text"
  check docs{"readme"}{"value"}.getStr().len > 400, "docs.readme is empty"
  check docs{"pages"}.len == 3, "docs.pages is not three pages"
  for page in docs{"pages"}:
    check page{"id"}.getStr().len > 0, "a docs page has no id"
    check page{"title"}.getStr().len > 0, "a docs page has no title"
    check page{"content"}{"type"}.getStr() == "text",
      "a docs page is not inlined text"
    check page{"content"}{"value"}.getStr().len > 200,
      "docs page " & page{"id"}.getStr() & " is empty"

block configSchemaIsClosedAndBounded:
  let schema = game{"config_schema"}
  check schema{"additionalProperties"}.getBool() == false,
    "config_schema is not closed"
  var required: seq[string]
  for item in schema{"required"}:
    required.add(item.getStr())
  check "tokens" in required and "players" in required,
    "config_schema must still REQUIRE tokens and players"
  for name, prop in schema{"properties"}:
    if prop{"type"}.getStr() == "array":
      check prop.hasKey("minItems") and prop.hasKey("maxItems"),
        "config_schema." & name & " is an array with no minItems/maxItems"
  let seats = schema{"properties"}{"num_agents"}
  check seats{"minimum"}.getInt() == 6 and seats{"maximum"}.getInt() == 6,
    "num_agents is not pinned to exactly 6"
  check not schema{"properties"}.hasKey("maxTicks"),
    "maxTicks must be DERIVED, not a config field"

block resultsSchemaIsClosed:
  let schema = game{"results_schema"}
  check schema{"additionalProperties"}.getBool() == false,
    "results_schema is not closed"
  var reasons: seq[string]
  for item in schema{"properties"}{"reason"}{"enum"}:
    reasons.add(item.getStr())
  check reasons == @["complete", "deadline", "fault"],
    "results.reason is not the closed three-value enum: " & $reasons
  var rules: seq[string]
  for item in schema{"properties"}{"endRule"}{"enum"}:
    rules.add(item.getStr())
  check rules == @["full_time", "wall_clock", "sim_fault", "host_error"],
    "results.endRule is not the closed four-value enum: " & $rules

block declaredPlayers:
  let players = manifest{"player"}
  check players.len == 2, "the manifest declares " & $players.len & " players"
  var ids: seq[string]
  for entry in players:
    ids.add(entry{"id"}.getStr())
    check entry{"run"}[0].getStr() == "/bin/hide-and-seek-player",
      "a declared player does not run the seat registrar"
    check entry{"resources"}{"limits"}{"cpu"}.getStr() == "1",
      "player limits.cpu must be at least \"1\" (pistonball 0.1.1)"
    check entry{"source_url"}.getStr().len > 0,
      "a declared player has no source_url"
  var seated: seq[string]
  for entry in manifest{"certification"}{"players"}:
    seated.add(entry{"player_id"}.getStr())
  for id in ids:
    check id in seated,
      "declared player " & id & " occupies no certification slot"

block everyVariantAndTheFixtureCarryNumAgents:
  var configs: seq[(string, JsonNode)]
  for variant in manifest{"variants"}:
    check not variant.hasKey("num_agents"),
      "variant " & variant{"id"}.getStr() &
      " declares num_agents at its TOP level"
    configs.add((variant{"id"}.getStr(), variant{"game_config"}))
  configs.add(("certification", manifest{"certification"}{"game_config"}))
  check configs.len == 3, "expected two variants and one fixture"
  for (name, config) in configs:
    check config{"num_agents"}.getInt() == 6,
      name & ".game_config.num_agents is not 6"
    check not config.hasKey("tokens"),
      name & ".game_config carries a runner-managed tokens array"
    check config{"slots"}.len == 6, name & ".slots is not six long"
    var index = 0
    for slot in config{"slots"}:
      let want = if index mod 2 == 0: "red" else: "blue"
      check slot{"team"}.getStr() == want,
        name & ".slots does not alternate red/blue at " & $index
      inc index
    check config{"wallClockBudgetSeconds"}.getInt() <= 660,
      name & " exceeds the 660 s engine stop"
    check config{"showPlayerLabels"}.getBool() == false,
      name & " would draw player labels on the board"

block certificationSeatsAgree:
  let cert = manifest{"certification"}
  check cert{"players"}.len == 6, "the fixture does not seat six players"
  check cert{"game_config"}{"players"}.len == 6,
    "the fixture's game_config does not name six players"

block everyVariantActuallyConstructs:
  var configs: seq[(string, JsonNode)]
  for variant in manifest{"variants"}:
    configs.add((variant{"id"}.getStr(), variant{"game_config"}))
  configs.add(("certification", manifest{"certification"}{"game_config"}))
  for (name, node) in configs:
    var body = copy(node)
    # `tokens` is runner-injected; the smoke adds it, so add it here too.
    var tokens = newJArray()
    for i in 0 ..< 6:
      tokens.add(%("token-" & $i))
    body["tokens"] = tokens
    var config = defaultGameConfig()
    config.update($body)
    check config.numAgents == 6, name & " did not construct with six seats"
    check config.maxTicks ==
      (config.prepTurns + config.huntTurns) * config.turnTicks,
      name & "'s derived maxTicks does not match its phase lengths"
    check config.maxTicks <= 3000,
      name & "'s derived maxTicks is " & $config.maxTicks & ", over 3000"
    var built = initSimServer(config)
    built.gameEventLoggingEnabled = false
    var crates, panels, ramps = 0
    for obj in built.objects:
      case obj.kind
      of okCrate: inc crates
      of okPanel: inc panels
      of okRamp: inc ramps
    check crates == config.crates,
      name & " dealt " & $crates & " crates, its config asks for " &
      $config.crates
    check panels == config.panels,
      name & " dealt " & $panels & " panels, its config asks for " &
      $config.panels
    check ramps == config.ramps,
      name & " dealt " & $ramps & " ramps, its config asks for " &
      $config.ramps
    check built.roomName.len > 0, name & " loaded no room"
    if node{"roomPool"}.getStr() notin ["", "all"]:
      check built.roomName == node{"roomPool"}.getStr(),
        name & " pinned " & node{"roomPool"}.getStr() & " and loaded " &
        built.roomName

block theComposeServiceNameDerivesThePlaceholder:
  let compose = readFile("compose.yaml")
  check "  hide-and-seek:" in compose,
    "the compose service is not named after the slug"
  check "image: coworld-hide-and-seek:latest" in compose,
    "the compose image does not match <IMAGE>:latest"
  check "platform: linux/amd64" in compose, "the compose platform is missing"
  check "network: host" in compose, "the compose build has no host network"

block policiesJsonIsTheShippedSet:
  let policies = parseJson(readFile("tools/ci/policies.json"))
  check policies.len == 4, "policies.json does not carry four entries"
  var prompts, scripted, owned = 0
  for entry in policies:
    check entry{"run"}.getStr() == "/bin/hide-and-seek-player",
      "a policy does not run the seat registrar"
    if entry{"env"}.hasKey("PLAYER_PROMPT"):
      inc prompts
      check entry{"env"}{"PLAYER_PROMPT"}.getStr().len > 200,
        "a champion's prompt is too short to be a strategy"
    if entry{"env"}.hasKey("PLAYER_SCRIPTED"):
      inc scripted
      check entry{"env"}{"PLAYER_SCRIPTED"}.getStr() in ["burrow", "scatter"],
        "a scripted policy names an unpublished baseline"
    if entry.hasKey("player"):
      inc owned
      check entry{"player"}.getStr().startsWith("ply_"),
        "the per-policy owner field is not a ply_ id"
  check prompts == 2, "there must be exactly two LLM prompt policies"
  check scripted == 2, "there must be two scripted baselines"
  check owned == 1, "champion #2 must carry the ply_ owner field"
  check policies[1]{"player"}.getStr() ==
    "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
    "champion #2 is not owned by daveey-1"

echo "test_hns_manifest: ok"
