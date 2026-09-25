## External player orders use the same fogged view and game parser as prompts.

import std/[json, strutils]
import helpers
import hns/policy_actions

block externalSeatsUseTheNormalOrderDriver:
  var game = newTestSim()
  game.seatAll()
  game.startGame()
  var engine = initDecisionEngine(game, enableLlm = false)
  for seat in 0 ..< game.config.numAgents:
    engine.seats[seat].isExternal = true
  var sends = 0
  var malformed = false
  engine.externalDispatch = proc(turn, deadlineMs: int,
                                 requests: seq[ExternalRequest]) =
    inc sends
    check turn == 0, "opening turn is not zero"
    check deadlineMs == game.config.turnBudgetMs, "deadline changed"
    check requests.len == 3, "frozen seekers received orders"
    for request in requests:
      check request.view["you"].getStr().startsWith("HIDER"),
        "player saw another role"
      check request.view["room"]["patrol"].len == 6,
        "public patrol anchors missing"
      check request.view{"policy"}.isNil,
        "the seat learned a policy identity"
      check actionChoices(request.view).len == ActionCount,
        "action catalog changed shape"
      check values(request.view).len == 356,
        "numeric observation changed shape"
      var objectIds, rampIds, anchorIds: seq[string]
      for obj in game.objects:
        objectIds.add(obj.id)
        if obj.kind == okRamp: rampIds.add(obj.id)
      for anchor in game.gameMap.anchors: anchorIds.add(anchor.id)
      for door in game.gameMap.doors: anchorIds.add(door.id)
      for region in game.gameMap.regions: anchorIds.add(region.id)
      for choice in actionChoices(request.view):
        if choice.kind == JNull: continue
        let parsed = parseOrder(choice, request.seat,
          game.cogAlias(game.playerIndexForSlot(request.seat)),
          objectIds, anchorIds, rampIds, MapWidth - 1, MapHeight - 1)
        check not parsed.rejected and parsed.order.fromReply,
          "catalog order was rejected by the game parser"
  engine.externalCollect = proc(turn, deadlineMs: int,
                                requests: seq[ExternalRequest]): seq[string] =
    discard turn
    discard deadlineMs
    for request in requests:
      result.add(if malformed: "invalid" else:
        $actionChoices(request.view)[2])
  var views = newSeq[JsonNode](6)
  var sources = newSeq[DirectiveSource](6)
  var latencies = newSeq[int](6)
  let records = engine.turn(game, 0, 0, views, sources, latencies)
  check records.len == 0, "valid external orders fell back"
  check sends == 1, "external batch was not sent"
  for seat in [0, 2, 4]:
    check sources[seat] == dsExternal, "model order lost its source"
    check engine.orders[seat].intent == intHide,
      "player order did not reach the game driver"
  malformed = true
  let failures = engine.turn(game, 0, 0, views, sources, latencies)
  check failures.len == 3, "invalid orders did not fall back"
  for seat in [0, 2, 4]:
    check sources[seat] == dsFallback,
      "invalid external order was recorded as successful"

echo "test_hns_external: ok"
