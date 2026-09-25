## The hide-and-seek player container runs numeric and Jev policies over the
## ordinary seat socket. Prompt policies use the game-side LLM client.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      burrow | scatter            -> this seat is scripted
##   PLAYER_NUMERIC_URL   an /actions endpoint         -> numeric seat
##   PLAYER_JEV=1         System One candidate choice  -> Jev seat
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `burrow`. To field your own policy, reuse
## this image and set PLAYER_PROMPT:
##
##   coworld upload-policy <hide-and-seek-image> --name my-hns \
##     --run /bin/hide-and-seek-player \
##     --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, random, strutils, times, unicode],
  bitworld/spriteprotocol,
  whisky,
  hns/numeric_policy, hns/jev_policy

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24     ## ~1 s of frames at 24 Hz.
  ReconnectAttempts = 6      ## 6 x 500 ms of re-dialling after a live socket
                             ## dies, before accepting the game is gone.
  MaxPromptRunes = 4000      ## PLAYER_PROMPT transport cap, in RUNES.
  MaxPolicyLabelRunes = 64   ## `register.policy` cap, in RUNES.

proc truncateRunes(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. Never a byte
  ## slice: a byte-truncated multi-byte character renders fine in a browser
  ## and then fails a strict UTF-8 parser downstream.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc registrationBlob(prompt, scripted, policy: string,
                      external: bool): string =
  ## The one registration message. `scripted` is JSON null when the seat is
  ## an LLM seat, so the server can tell "no baseline named" from "burrow
  ## named explicitly".
  var node = %*{
    "type": "register",
    "prompt": prompt.truncateRunes(MaxPromptRunes),
    "policy": policy.truncateRunes(MaxPolicyLabelRunes)
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  if external:
    node["mode"] = %"external"
  blobFromSpriteChat($node)

proc orderBlob(request, order: JsonNode): string =
  blobFromSpriteChat("orders:" & $request["observation"]["game"].getInt() &
    ":" & $request["turn"].getInt() & ":" & $order)

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## not for an ordinary player client: this seat sends NO inputs at all (the
  ## server computes every actuator mask), so the dead-reckoning hazard
  ## docs/PROTOCOL.md warns about cannot arise, and a fastMode server can
  ## advance the tick as soon as every seat has acknowledged the frame.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    numeric = getEnv("PLAYER_NUMERIC_URL").strip().len > 0
    jev = getEnv("PLAYER_JEV") == "1"
    external = numeric or jev
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif jev: "jev"
      elif numeric: "numeric"
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "burrow"
  echo "hide-and-seek player: kind=",
    (if external: "external" elif prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "burrow"),
    " label=", label
  if external and (prompt.len > 0 or scripted.len > 0) or numeric and jev:
    quit("Choose exactly one player policy mode", 1)
  randomize()
  let session = "hns:" & $getCurrentProcessId() & ":" &
    $getTime().toUnix() & ":" & $rand(high(int))

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The game bakes its supersampled board render caches
    ## BEFORE it opens the listener (a viewer's first-message clock starts at
    ## connect, so nothing may be accepted until every frame can be assembled
    ## instantly), and the episode runner starts the players at the same
    ## instant as the game — so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "hide-and-seek player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("hide-and-seek player: game never accepted a connection", 1)
  echo "hide-and-seek player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES — so the game's own quit(0) can outrun the flushed frame. A naive
  # player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). Exiting 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE. Joins are slot-sequential, so a
  # seat whose slot is not the next open one is not admitted until the lower
  # slots have joined — and the lobby sends frames to a socket before it is
  # admitted, so the first registration AND a single re-send keyed on the first
  # received frame can both land while the seat has no index yet. The server
  # dropped them and the champion played the scripted baseline for the whole
  # episode (the paintball 2026-08-25 slot-sequential-join scar). The server now holds an
  # unappliable registration, and this end keeps re-sending it for the first
  # ~10 s of frames, which covers the lobby whichever seat connects first.
  # Registering twice is harmless: the server just re-reads the same fields.
  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(prompt, scripted, label, external),
        BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(prompt, scripted, label, external),
            BinaryMessage)
        if external and received.get().kind == TextMessage:
          let request = parseJson(received.get().data)
          if request["type"].getStr() == "decision":
            let order = if numeric: chooseNumericOrder(request, session)
              else: chooseJevOrder(request)
            socket.send(orderBlob(request, order), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "hide-and-seek player: socket closed (", error.msg, ")"
    # NEVER exit while the game is still serving: a seat that drops keeps its
    # cogs for the whole episode and revives on reconnect, so a dropped socket
    # mid-episode is worth re-dialling and re-registering. Bounded on both
    # counts — a session that never received a frame means the game is winding
    # down (its shutdown grace still answers the route), and the re-dial is
    # capped — so this can never outlive the game or spin: the runner waits on
    # process exit either way.
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "hide-and-seek player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "hide-and-seek player: game is no longer listening, exiting cleanly"
      break
    echo "hide-and-seek player: reconnected, re-registering"
  quit(0)
