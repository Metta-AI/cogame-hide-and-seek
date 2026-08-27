## The sim's shared vocabulary: the core constants (including GameVersion
## and its changelog), the gameplay/wire types, the process-wide map
## dimension globals, and the pure helpers both sides of every seam need.
##
## Forked from coworld-ctf's `src/ctf/sim_types.nim` (the paintbot engine),
## heavily cut: every weapon, pickup, paint, hill, flag, perk, achievement and
## map-generator type is DELETED, not disabled, and the object layer
## (crates / panels / ramps, the lock and the vault), the two-phase clock and
## the exposure counters are appended in their place.
##
## MOVED VERBATIM from the starter: SimServer and friends are flatty-serialized
## POSITIONALLY into replay keyframes, so declaration/field order here is
## wire format — reorder nothing without a GameVersion bump.

import
  std/[math, random],
  bitworld/pixelfonts,
  bitworld/server,
  pixie

const
  GameName* = "hide-and-seek"
  GameVersion* = "1"  ## GV1 (first rules): HIDE AND SEEK. Three hiders get
    ## fifteen seconds alone in a 720x400 room with four crates, two panels
    ## and two ramps; then three seekers walk in with 70-degree torch cones
    ## and thirty seconds. Every hunt tick on which ANY seeker sees ANY hider
    ## pays the seekers, every tick all three are unseen pays the hiders, and
    ## the two trios then swap sides and play the same room again. Objects are
    ## draggable (grab on button C), lockable (button A, only the locking team
    ## may unlock), opaque to vision and solid to movement; a ramp lets a cog
    ## vault a barrier up to 112 px thick. The engine, the fixed-point motion
    ## integrator, the recursive-shadowcast fog of war, the Sprite v1
    ## protocol, the binary replay codec and the broadcast chrome are
    ## coworld-ctf's; the rules idiom is Baker et al. 2019 (see
    ## `src/hns/upstream.nim`). The version numbering restarts here: this is
    ## a new game, not a paintbot revision. Prepend-only changelog — say what
    ## the number means and what it obsoletes.

  Palette*: array[16, tuple[r, g, b: uint8]] = [
    (0'u8, 0'u8, 0'u8),          #  0 transparent / black
    (255'u8, 255'u8, 255'u8),    #  1 white
    (200'u8, 200'u8, 200'u8),    #  2 light grey
    (224'u8, 82'u8, 58'u8),      #  3 red      (SEEKERS)
    (140'u8, 60'u8, 44'u8),      #  4 dark red
    (110'u8, 82'u8, 46'u8),      #  5 dark brown
    (168'u8, 128'u8, 74'u8),     #  6 brown    (crate)
    (214'u8, 178'u8, 116'u8),    #  7 tan      (panel)
    (221'u8, 197'u8, 49'u8),     #  8 yellow   (torch)
    (36'u8, 62'u8, 72'u8),       #  9 dark teal
    (69'u8, 168'u8, 94'u8),      # 10 green    (unseen)
    (140'u8, 208'u8, 108'u8),    # 11 lime
    (18'u8, 24'u8, 40'u8),       # 12 dark navy
    (63'u8, 124'u8, 196'u8),     # 13 blue     (HIDERS)
    (116'u8, 168'u8, 255'u8),    # 14 light blue
    (176'u8, 206'u8, 236'u8),    # 15 pale blue
  ]

  ShadowMap*: array[16, uint8] = [
    0'u8, 2'u8, 9'u8, 4'u8, 4'u8, 0'u8, 5'u8, 6'u8,
    5'u8, 12'u8, 9'u8, 9'u8, 0'u8, 12'u8, 12'u8, 9'u8,
  ]

  ## --- Frame pacing and the sprite canvas (starter's, unchanged) ---
  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
  SpriteSize* = 12
  SoldierRotations* = 16      ## pre-rendered aim steps (16 brads apart).
  SoldierCanvas* = 72         ## px square sprite canvas.
  SoldierBodyPx* = 34         ## cog body target size on the map.
  SoldierDrawOff* = SoldierCanvas div 2

  ## --- Motion (starter's fixed-point integrator, unchanged) ---
  CollisionW* = 1
  CollisionH* = 1
  PlayerHalf* = 6             ## half-extent of the solid player footprint, px.
  MotionScale* = 256
  Accel* = 76
  FrictionNum* = 144
  FrictionDen* = 256
  MaxSpeed* = 704
  StopThreshold* = 8
  MovementSlideMaxScan* = 3
  PlayerSolidSpan* = 2 * PlayerHalf
  PlayerBouncePct* = 40

  ## --- Aim and vision ---
  AimBradsTurn* = 256         ## aim angle units per full turn (binary radians).
  AimTurnRate* = 6            ## brads/tick a held rotate button turns the aim.
  AimUnitScale* = 1024
  VisionConeDeg* = 35         ## vision cone HALF-angle around the aim angle.
  VisionBubble* = 48          ## omnidirectional vision radius in px.
  SightRange* = 340           ## cone reach in px (replaces the starter's
                              ## visionRange = gunRange * 3 div 2, which died
                              ## with the gun).
  FovCellSize* = 8            ## fog-of-war visibility grid cell size in px.

  ## --- The object layer (this game's own) ---
  CrateSize* = 64
  PanelLong* = 128
  PanelShort* = 32
  RampLong* = 80
  RampShort* = 40
  GrabReach* = 30             ## px the grab probe reaches past the body edge.
  LockReach* = 30             ## px an object may sit from the cog to be locked.
  LockCooldownTicks* = 24     ## ticks between two lock toggles by one cog.
  GrabBreakTicks* = 24        ## ticks dead-stopped against a refusal before a
                              ## held object is dropped.
  CarrySpeedPct* = 55         ## a holder's MaxSpeed, as a percent.
  KeepClearPx* = 96           ## no object may be moved this close to a pad.
  VaultSpanPx* = 112          ## thickest barrier a ramp can carry you over.
  VaultTicks* = 10            ## airborne ticks.
  VaultSpeed* = 5             ## px/tick while airborne.
  MaxObjects* = 16            ## hard ceiling on the object table.

  ## --- The clock ---
  DefaultTurnTicks* = 90      ## 3.75 s of sim time per decision turn.
  DefaultPrepTurns* = 4
  DefaultHuntTurns* = 8
  DefaultMaxGames* = 2
  StartWaitTicks* = 5 * TargetFps
  GameOverTicks* = 240
  MaxPlayers* = 32
  MinPlayers* = 6
  HuntMemoryTicks* = 72       ## how long a sighting stays in a seat's intel.

  ## --- Shouts (the starter's mechanic, verbatim) ---
  ShoutMaxChars* = 10
  ShoutTicks* = 3 * ReplayFps
  ShoutCooldownTicks* = ReplayFps

  ## --- Decision-layer deadlines (§Decisions) ---
  DefaultTurnBudgetMs* = 16_000
  DefaultAttempt1Ms* = 7000
  DefaultRetryMs* = 3000
  DefaultTurnSpacingMs* = 13_000
  DefaultWallClockBudgetSeconds* = 660
  DefaultLobbyJoinTimeoutTicks* = 2400
  DefaultMaxOutputTokens* = 700
  RateGuardWindowMs* = 60_000
  RateGuardMaxRequests* = 28

  ## --- Rune caps. EVERY recorded string is truncated on RUNE boundaries. ---
  MaxNoteRunes* = 160           ## private note cap, in RUNES (never bytes).
  MaxSayRunes* = ShoutMaxChars  ## a cog's in-world shout cap, in RUNES.
  MaxRadioRunes* = 96           ## the team channel cap, in RUNES.
  MaxPolicyLabelRunes* = 64     ## `register.policy` cap, in RUNES.
  MaxFallbackDetailRunes* = 200 ## `fallback.detail` cap, in RUNES.
  MaxDirectiveRunes* = 1400     ## whole serialized `directive` record cap.
  MaxPromptRunes* = 4000        ## PLAYER_PROMPT transport cap.
  MaxObjectIdRunes* = 8
  MaxIntentRunes* = 12
  MaxAnchorIdRunes* = 4
  MaxReplyBytes* = 4096         ## bytes read from the provider before parsing.

  ## --- End reasons (closed enums; §End conditions) ---
  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"
  EndRuleFullTime* = "full_time"
  EndRuleWallClock* = "wall_clock"
  EndRuleSimFault* = "sim_fault"
  EndRuleHostError* = "host_error"

  ## --- Sprite protocol ids ---
  TextLineHeight* = 7
  MapSpriteId* = 1
  MapObjectId* = 1
  MapLayerId* = 0
  MapLayerType* = 0
  ScoreboardLayerId* = 1
  ScoreboardLayerType* = 1
  BottomRightLayerId* = 3
  BottomRightLayerType* = 3
  ZoomableLayerFlag* = 1
  UiLayerFlag* = 2
  PlayerSpriteBase* = 100
  PlayerObjectBase* = 1000
  ObjectSpriteBase* = 2000      ## 8 objects x body + padlock overlay.
  ObjectObjectBase* = 2200
  ConeOverlayBase* = 2400       ## 6 vision wedges.
  ConeObjectBase* = 2500
  SelectedTextObjectId* = 4000

  RedTeamColor* = 3'u8          ## SEEKERS wear the starter's red.
  BlueTeamColor* = 13'u8        ## HIDERS wear the starter's blue.
  SpaceColor* = 0'u8
  TintColor* = 3'u8
  ShadeTintColor* = 9'u8
  OutlineColor* = 0'u8

  PlayerColors*: array[8, uint8] = [
    3'u8, 13'u8, 10'u8, 8'u8, 14'u8, 11'u8, 7'u8, 15'u8
  ]
  PlayerColorNames*: array[8, string] = [
    "red", "blue", "green", "yellow", "lightblue", "lime", "tan", "paleblue"
  ]

  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"
  RewardWebSocketPath* = "/reward"

## Runtime map dimensions. The room is installed once per process by
## `selectHnsMap` BEFORE any sim, mask or render work happens, and never
## changes afterwards — the render bakes rely on that invariant. Initialized
## to the default room so tools that never install one keep working.
var
  MapWidth* = 720
  MapHeight* = 400
  FovGridW* = (MapWidth + FovCellSize - 1) div FovCellSize
  FovGridH* = (MapHeight + FovCellSize - 1) div FovCellSize
  FovCellCount* = FovGridW * FovGridH
  ShoutRange* = MapWidth div 5  ## audible within 20% of the board width.

type
  Team* = enum
    ## Sides. `Red` is the HIDING trio of the current game and `Blue` the
    ## SEEKING trio; both flip at the side swap, so a seat's team changes
    ## between game 1 and game 2 while its identity name does not.
    Red
    Blue

  Skin* = enum
    DefaultSkin

  HnsError* = object of ValueError

  SimGuardError* = object of CatchableError
    ## A sim INVARIANT tripped: a cog outside the room, an object index out of
    ## range, exposure counters that cannot be true. The episode ends
    ## `fault` / `sim_fault` and the partial replay is still written; the
    ## server's tick loop is the only place that catches it.

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  MatchPhase* = enum
    ## The two-phase clock (Baker et al.'s preparation phase). Ordinals are
    ## wire format.
    phasePrep
    phaseHunt

  MapPoint* = object
    x*, y*: int

  MapRect* = object
    x*, y*, w*, h*: int

  ObjectKind* = enum
    ## Ordinals are wire format.
    okCrate
    okPanel
    okRamp

  ObjectAxis* = enum
    ## The orientation an object was DEALT with. Objects never rotate
    ## (§Out of scope). Ordinals are wire format.
    axH
    axV

  LockOwner* = enum
    ## Which team, if any, has locked an object. Only the locking team may
    ## unlock it, and the other team may neither grab nor move it.
    lockNone
    lockHiders
    lockSeekers

  GameObject* = object
    ## One piece of movable furniture. Every field here is in `gameHash`.
    id*: string                ## `box1`..`box4`, `pan1`, `pan2`, `ramp1`, ...
    kind*: ObjectKind
    axis*: ObjectAxis
    x*, y*: int                ## top-left, integer map pixels.
    w*, h*: int                ## derived from kind+axis at the deal.
    lockedBy*: LockOwner
    heldBy*: int               ## slot index of the holder, -1 = loose.
    spawnX*, spawnY*: int      ## the dealt position, re-applied each game.

  RoomRegion* = object
    ## A named part of the room the policies talk about.
    id*: string
    name*: string
    box*: MapRect
    doors*: seq[string]

  RoomDoor* = object
    ## A gap between two regions.
    id*: string
    x*, y*: int                ## centre of the gap.
    w*: int
    vertical*: bool            ## `axis: "v"` — the gap runs top-to-bottom.

  AnchorKind* = enum
    ## Ordinals are wire format.
    anchorPocket
    anchorPad
    anchorPatrol

  AnchorTeam* = enum
    anchorAnyTeam
    anchorHiders
    anchorSeekers

  RoomAnchor* = object
    id*: string
    kind*: AnchorKind
    x*, y*: int
    team*: AnchorTeam

  ObjectSpawn* = object
    ## A candidate position for the seeded object deal.
    x*, y*: int
    crate*, panel*, ramp*: bool
    axis*: ObjectAxis

  HnsMap* = object
    ## One authored room. Rooms are committed documents, never generated:
    ## the episode's room is `pool[seed mod 3]` (§Sim module).
    name*: string
    width*, height*: int
    mapLayer*, walkLayer*, wallLayer*: int
    center*: MapPoint
    walls*: seq[MapRect]
    regions*: seq[RoomRegion]
    doors*: seq[RoomDoor]
    anchors*: seq[RoomAnchor]
    objectSpawns*: seq[ObjectSpawn]

  RewardAccount* = object
    address*: string
    slotIndex*: int
    team*: Team
    hasTeam*: bool
    won*: bool
    abandoned*: bool
    reward*: int

  PlayerSlotConfig* = object
    name*: string
    token*: string
    team*: Team
    color*: uint8
    skin*: Skin
    hasTeam*: bool
    hasColor*: bool

  GameConfig* = object
    motionScale*: int
    accel*: int
    frictionNum*: int
    frictionDen*: int
    maxSpeed*: int
    stopThreshold*: int
    playerBouncePct*: int
    seed*: int
    speed*: int
    aimTurnRate*: int          ## brads/tick a held rotate button turns aim.
    sightRange*: int           ## cone reach in px.
    visionConeDeg*: int        ## cone HALF-angle in degrees.
    visionBubble*: int         ## omnidirectional radius in px.
    carrySpeedPct*: int        ## a holder's max speed, percent.
    grabReach*: int
    lockReach*: int
    vaultSpanPx*: int
    vaultTicks*: int
    keepClearPx*: int
    crates*: int
    panels*: int
    ramps*: int
    roomPool*: string          ## "all" | "warren" | "atrium" | "long_hall".
    turnTicks*: int
    prepTurns*: int
    huntTurns*: int
    maxGames*: int
    minPlayers*: int
    numAgents*: int            ## seats. Always 6 (§Packaging).
    startWaitTicks*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    showPlayerLabels*: bool
    fastMode*: bool
    closedRoster*: bool
    slots*: seq[PlayerSlotConfig]
    mapSpec*: string           ## the resolved room document, pinned into the
                               ## replay so a later edit to data/rooms/*.json
                               ## cannot change what an old replay renders.
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    model*: string
    maxOutputTokens*: int

  Player* = object
    ## One cog. Exactly one cog per seat; the slot index IS the seat.
    x*, y*: int
    homeX*, homeY*: int
    velX*, velY*: int
    carryX*, carryY*: int
    flipH*: bool
    aimBrads*: int             ## 0..255: 0 = east (+x), counter-clockwise.
    team*: Team
    alive*: bool
    holding*: int              ## object index held, -1 = nothing. HASHED.
    airborne*: bool            ## mid-vault. HASHED.
    vaultLeft*: int            ## airborne ticks remaining. HASHED.
    vaultDirBrads*: int        ## the vault heading. HASHED.
    vaultFromX*, vaultFromY*: int
    lockCooldown*: int         ## HASHED.
    pushBlockedTicks*: int     ## HASHED.
    lastShoutTick*: int
    joinOrder*: int
    address*: string
    color*: uint8
    skin*: Skin
    reward*: int
    ## Measured, never scored (§Scoring).
    seatSeenTicks*: int
    sealedTicks*: int
    grabs*: int
    locks*: int
    vaults*: int
    pushedPx*: int
    shouts*: int
    seat*: int                 ## which SEAT owns this cog; == the slot.
    sealed*: bool              ## unreachable from every seeker right now.

  PlayerFov* = object
    ## One player's cached fog-of-war visibility grid (FovGridW x FovGridH
    ## cells). The expensive shadowcast pass depends only on the viewer's
    ## CELL, so it is cached separately (cellVisible) from the final
    ## cone-filtered grid (visible): a viewer who only turns reuses the
    ## cached shadowcast and pays just the cone filter.
    valid*: bool
    originCx*, originCy*: int
    aimBrads*: int
    visible*: seq[bool]
    cellValid*: bool
    cellCx*, cellCy*: int
    cellVisible*: seq[bool]
    epoch*: int                ## geometryEpoch the cached cast was taken at.

  SimEventKind* = enum
    ## Tier-2 analysis event channel (the Logs substrate). Analysis-only:
    ## never enters gameHash.
    PhaseChange
    Release
    Grab
    Drop
    Lock
    Unlock
    LockRefused
    Vault
    Spotted
    Lost
    Sealed
    Unsealed
    ShoutEvent
    TurnStart
    Directive
    Fallback

  SimEvent* = object
    ## One tier-2 analysis event; never enters gameHash (replay-safe).
    tick*: int
    kind*: SimEventKind
    source*: int               ## acting cog's slot, -1 = n/a.
    target*: int               ## affected cog's slot, -1 = n/a.
    subject*: string           ## object id, phase name, cause; "" = n/a.
    amount*: int
    x*, y*: float
    headingBrads*: int
    content*: string           ## sanitized text, "" = n/a.

  Shout* = object
    ## One short cog message, audible within ShoutRange of where it was made
    ## BY EITHER TEAM. Cogs observe shouts, so they are gameplay state (in
    ## gameHash) and replays re-apply the recorded chat records.
    address*: string
    team*: Team
    text*: string              ## sanitized, at most ShoutMaxChars.
    tick*: int
    x*, y*: int

  ExposureRun* = object
    ## One contiguous span of hunt ticks the hiders spent exposed.
    game*: int
    startTick*, endTick*: int

  SimServer* = object
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    gameMap*: HnsMap
    mapPixels*: seq[uint8]
    mapRgba*: seq[uint8]
    walkMask*: seq[bool]
    wallMask*: seq[bool]       ## STATIC walls only.
    objectMask*: seq[bool]     ## the furniture, re-rasterised on a dirty rect.
    fovBlocked*: seq[bool]     ## FovGridW x FovGridH over wall OR object.
    fovCaches*: seq[PlayerFov]
    rng*: Rand
    setupRng*: Rand            ## the ONE seeded setup stream (§determinism).
    nextJoinOrder*: int
    tickCount*: int
    recentShouts*: seq[Shout]  ## live shouts; observable state, in gameHash.
    gameStartTick*: int
    startWaitTimer*: int
    lobbyWaitTimer*: int
    phase*: GamePhase
    asciiSprites*: PixelFont
    shoutFont*: PixelFont
    gameOverTimer*: int
    timeLimitReached*: bool
    needsReregister*: bool
    gameEventLoggingEnabled*: bool
    collectEvents*: bool
    events*: seq[SimEvent]
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int
    # --- the object layer ---
    objects*: seq[GameObject]
    geometryEpoch*: int        ## bumped whenever any object rectangle moved.
    # --- the two-phase clock and the exposure counters ---
    matchPhase*: MatchPhase
    gameIndex*: int            ## 0-based index of the game in the episode.
    hiddenTicks*: int          ## THIS game.
    seenTicks*: int            ## THIS game.
    huntTicksPlayed*: int      ## THIS game.
    exposedNow*: bool
    spottedPairs*: seq[bool]   ## numAgents*numAgents transition latch.
    sealedMask*: uint64
    gameMargins*: seq[int]     ## per finished game, permille, HIDERS' view.
    gameHidden*: seq[int]
    gameSeen*: seq[int]
    gameHuntPlayed*: seq[int]
    exposureRuns*: seq[ExposureRun]
    releaseEmitted*: bool
    # --- episode bookkeeping (never hashed) ---
    endReason*: string
    endRule*: string
    stopDetail*: string
    llmTurns*: seq[int]
    fallbackTurns*: seq[int]
    ordersRejected*: seq[int]
    deadSeats*: seq[bool]
    seatNames*: seq[string]    ## real policy names, SPECTATOR SIDE ONLY.
    seatPolicyKind*: seq[string]
    feedDirectives*: seq[string]
    roomName*: string
    turnIndex*: int

# Team display colours, shared by the map bake and the board FX.
const
  HiderColor* = rgba(63, 124, 196, 255)   ## team cerulean.
  SeekerColor* = rgba(224, 82, 58, 255)   ## team vermillion.

const AimUnit*: array[AimBradsTurn, tuple[x, y: int]] = block:
  ## The 256 aim headings as INTEGER unit vectors scaled by AimUnitScale,
  ## computed once at compile time. The object layer, the fort scan and the
  ## motion integrator are integer-only (`tests/test_hns_determinism.nim`
  ## greps them for float literals and division), so they read headings
  ## from here instead of calling `aimVector`.
  var table: array[AimBradsTurn, tuple[x, y: int]]
  for i in 0 ..< AimBradsTurn:
    let radians = float(i) * 2.0 * PI / float(AimBradsTurn)
    table[i] = (
      int(round(cos(radians) * float(AimUnitScale))),
      int(round(-sin(radians) * float(AimUnitScale)))
    )
  table

proc distSq*(ax, ay, bx, by: int): int =
  let
    dx = ax - bx
    dy = ay - by
  dx * dx + dy * dy

proc aimVector*(brads: int): tuple[x, y: float] =
  ## Unit vector for an aim angle in brads: 0 = east, counter-clockwise on
  ## screen (so screen y is negated).
  let radians = float(brads) * 2.0 * PI / float(AimBradsTurn)
  (cos(radians), -sin(radians))

proc bradsOfVector*(dx, dy: int): int =
  ## The brads heading of a screen-space delta.
  if dx == 0 and dy == 0:
    return 0
  let radians = arctan2(-float(dy), float(dx))
  var brads = int(round(radians * float(AimBradsTurn) / (2.0 * PI)))
  brads = brads mod AimBradsTurn
  if brads < 0:
    brads += AimBradsTurn
  brads

proc teamText*(team: Team): string =
  case team
  of Red: "red"
  of Blue: "blue"

proc roleText*(team: Team): string =
  ## The role a side plays. `Red` hides, `Blue` seeks — always, in both games;
  ## it is the SEATS that swap sides, not the sides that swap jobs.
  case team
  of Red: "hiders"
  of Blue: "seekers"

proc roleLabel*(team: Team): string =
  case team
  of Red: "HIDER"
  of Blue: "SEEKER"

proc teamColor*(team: Team): uint8 =
  case team
  of Red: RedTeamColor
  of Blue: BlueTeamColor

proc lockText*(owner: LockOwner): string =
  case owner
  of lockNone: "none"
  of lockHiders: "hiders"
  of lockSeekers: "seekers"

proc lockOwnerFor*(team: Team): LockOwner =
  case team
  of Red: lockHiders
  of Blue: lockSeekers

proc objectKindText*(kind: ObjectKind): string =
  case kind
  of okCrate: "crate"
  of okPanel: "panel"
  of okRamp: "ramp"

proc maxSpeedFor*(config: GameConfig, holding: bool): int =
  ## A cog dragging something moves at `carrySpeedPct` of normal.
  if holding:
    config.maxSpeed * config.carrySpeedPct div 100
  else:
    config.maxSpeed

proc policyName*(address: string): string =
  ## The policy part of a player address ("name#slot" -> "name").
  let hash = address.find('#')
  if hash < 0: address else: address[0 ..< hash]
