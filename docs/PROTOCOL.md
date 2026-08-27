# hide-and-seek wire protocol — Sprite v1 plus this game's extensions

Both the player endpoints (`/player`, POV observation streams) and the
global/spectator endpoint speak
[Sprite v1](https://github.com/Metta-AI/bitworld/blob/master/docs/sprite_v1.md).
This document lists everything hide-and-seek adds or changes relative to that
base document; anything not mentioned here matches Sprite v1 exactly. Game
semantics — mechanics, sprite labels, tuning defaults — live in
[`RULES.md`](RULES.md), and the object layer in
[`OBJECTS.md`](OBJECTS.md).

**The forked-from note.** This file is coworld-ctf's `docs/PROTOCOL.md`,
FORKED, not rewritten: the bit-7 row becomes the GRAB row, the `own aim`
readback marker and the frame-pacing / lobby-detection sections are kept
verbatim, and the Player Ready warning is kept for the same reason the
starter carries it.

## Player input: bit 7 is the C button — HOLD TO GRAB

Sprite v1 reserves player-input bit `7` ("must be sent as 0"). This game
assigns it:

| Bit | Value | Meaning |
| ---: | ---: | --- |
| `7` | `0x80` (128) | C button — HOLD to grab the object in reach, release to drop |

`A` (`0x04`) is the LOCK / UNLOCK toggle, not a trigger: there are no weapons
in this game. The d-pad is locomotion and never changes aim; `B` and `Select`
rotate the aim counter-clockwise and clockwise at `aimTurnRate` brads/tick.

**In league play a seat sends NO inputs at all.** The server computes every
actuator mask from the seat's ORDER (see `RULES.md` § The reply schema); the
input bits above are the wire the server writes into the replay, not a
channel a policy drives.

## Player Ready (`0x85`) is supported — but do NOT send it in league play

The server understands the Sprite v1 Player Ready packet (`0x85`): after each
rendered frame a player client may send it to signal "done thinking", which
lets the server pace fast-mode games by readiness instead of the wall clock.
Sending it is optional; clients that never send it are paced by timeouts.

**Warning (measured, not theoretical), kept from the starter:** on a
wall-clock-paced server, sending ready every frame corrupts input-application
timing for a client that drives its own inputs, because its dead-reckoned aim
random-walks between frames.

**It is irrelevant here, and the seat registrar sends it deliberately.** A
hide-and-seek seat sends no inputs at all — the server computes every mask —
so the dead-reckoning hazard cannot arise, `fastMode` is on in every shipped
variant, and `0x85` is what lets the server advance the tick as soon as every
seat has acknowledged the frame.

## Your own aim: read the `own aim` marker; dead-reckon between frames

The player stream carries an absolute readback of your own aim angle: an
invisible 1×1 HUD marker labeled `own aim <brads>` (256 brads per turn,
0 = east, counter-clockwise), stating your turret angle as of the rendered
tick. Match the label by the `own aim ` prefix and parse the tail. (An
earlier build's "aim dot" label was a previous form of this readback; the
engine retired it, and between the two the observation carried none — bots
from that era dead-reckon open-loop.)

The marker is exact only for the rendered tick, so a client still integrates
between frames:

- Spawn aim points into the room (hiders east, seekers west).
- Each held rotate button turns the continuous aim by the server's
  `aimTurnRate` (default 6 brads per tick, about 8.4 degrees) for **every elapsed
  sim tick** — including ticks you
  never saw a frame for. If you process frames with `frameAdvance > 1`
  (see below), integrate the rotation across all advanced ticks, then let the
  next frame's marker correct the estimate.
- The grab probe reads the CURRENT aim: a `C` press binds the first object the
  segment from the cog's centre along its aim meets inside `grabReach`, with the aim as of the tick it was compiled on.

## Frame pacing: drain the backlog, act on the latest frame

The server keeps applying your **last sent input mask** on every sim tick,
whether or not you sent anything — inputs are level-based state, not events.
If your client falls behind the frame stream, acting on a stale frame means
reacting to a world that has already moved on while your held buttons kept
applying. The reference client drains the socket backlog each loop iteration
(up to 128 buffered frames), decides on the **latest** frame only, and tracks
how many sim ticks elapsed since the previous decision (`frameAdvance`) so
dead-reckoned state (like the aim, above) stays consistent. Only *changes* to
the input mask need to be sent.

## Lobby and interstitial detection

There is no explicit "game phase" message on the player stream. The in-game
signal is the **map camera object** (object id `1`, sprite id `1`): while it
is present, a match is running and its `(x, y)` is the camera anchor; the
server deletes it during the lobby and the game-over interstitial. The
reference client treats "map object deleted" as leave-game (reset transient
state) and "map object defined" as enter-game. The walkability mask arrives
as its own labeled sprite (see `RULES.md`) and is only valid in-game.

## Observation render scale

- **Player/POV streams are 1× map resolution.** Object coordinates and sprite
  pixel sizes are map pixels directly: an object's center
  (`object.x + sprite.width / 2`, same for y) IS its map point on the
  720x400 room. No divisor is needed.
- **Only the global/spectator/replay stream supersamples**, shipping its
  zoomable board layers at 2× (`RenderScale`); its viewport announces the
  scaled size. The sim, the gameHash, and every value quoted in `RULES.md`
  stay in 1× map pixels.
## The replay records MASKS, not orders

The determinism boundary sits between the control layer and the sim: the
server records the per-tick actuator MASKS the control layer produced (plus
one `gameHash` per tick), and the static wasm viewer re-steps the SAME sim
module from those masks and checks the hash every tick. Orders, prompts and
LLM replies are never re-run at playback — they ride the chat stream as
redacted CONTROL RECORDS (`register`, `directive`, `fallback`,
`budget_guard`, `stop`, `result`) that drive the broadcast feed and can never
affect the simulation. The one exception is `stop`, the load-bearing
wall-clock / fault record: a wall-clock fact cannot be re-derived from sim
state, so it is written once and applied by the SAME proc on record and on
playback.
