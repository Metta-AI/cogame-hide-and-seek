# Rules — hide and seek

A **room**, 720 x 400 pixels, with walls, doorways and eight pieces of movable
furniture: four crates, two panels and two ramps. **Three hiders** get fifteen
seconds alone in it — they can drag the furniture, wall off a doorway, build a
fort, lock what they have built, and drag the ramps out of reach. Then a door
opens and **three seekers** walk in with torch-beam vision cones and thirty
seconds to look. Every tick in which **any** hider is inside **any** seeker's
cone costs the hiders a point and pays the seekers one; every tick in which all
three hiders are unseen does the reverse. Then the two trios swap sides and play
the room again, and the episode's score is the average.

There are no weapons and nobody can be killed: the only thing that happens in
this game is that somebody is looking and somebody else does not want to be
found.

## Seats, cogs, aliases

- **`num_agents` = 6**, always — in both manifest variants and in the
  certification fixture. One cog per seat: three hiders and three seekers.
- **Sides are dealt by slot parity and swap between the episode's two games.**
  Game 1: slots 0, 2, 4 hide; game 2: the same six seats, sides swapped. Hiding
  and seeking are not symmetric jobs, so a league that graded a seat on one of
  them would be grading the deal, not the policy.
- **Two name spaces.** In-game a cog is `<ROLE>-<identity>`: `HIDER-alpha`,
  `HIDER-beta`, `HIDER-gamma`, `SEEKER-alpha`, `SEEKER-beta`, `SEEKER-gamma`.
  The identity is fixed to the SEAT for the whole episode and only the role
  prefix flips at the swap. Those aliases are the only names in an observation,
  a prompt, an order, a shout, a radio line or a sprite label. The seats' real
  policy names live only in `results.names`, in the replay's join records and
  in the viewer's scorebug — `showPlayerLabels` is false in every variant.

## The clock

- **Tick** = 1/24 s. **Turn** = one order round every `turnTicks` = 90 ticks
  (3.75 s).
- **One game** = `prepTurns` 4 (360 ticks, 15.0 s) + `huntTurns` 8 (720 ticks,
  30.0 s) = 12 turns, `maxTicks` = 1080 ticks (45 s). `maxTicks` is DERIVED
  from the phase lengths and is not a config field, so the phase clock and the
  tick cap can never disagree.
- **One episode** = `maxGames` 2, sides swapped between them.
- **Prep**: seekers are frozen at their pads — their input masks are forced to
  zero, they take no LLM call, their fov is not computed, and no scoring runs.
- **Release**: at `tick == prepTicks` the seekers' torches come on, a `release`
  event fires and scoring starts on the first hunt tick.

## Vision

- **Forward cone**: half-angle `visionConeDeg` = 35 (a 70-degree beam) around
  the AIM angle, reaching `sightRange` = 340 px, with walls AND FURNITURE
  blocking it.
- **Bubble**: `visionBubble` = 48 px omnidirectional, still line-of-sight
  blocked.
- Aim carries vision: you see where you point, not where you walk. Both roles
  have the same eyes.

## Scoring

Per game `g`, over the hunt ticks actually played:

```
seenTicks[g]      = hunt ticks on which ANY seeker saw ANY hider
hiddenTicks[g]    = huntTicksPlayed[g] - seenTicks[g]
marginPermille[g] = (hiddenTicks[g] - seenTicks[g]) * 1000 div huntTicksPlayed[g]
```

`marginPermille[g]` is written from the HIDING trio's point of view. For each
seat `s`, with `side(s, g) = +1` when the seat hid in game `g` and `-1` when it
sought:

```
scorePermille[s] = ( side(s,0) * margin[0] + side(s,1) * margin[1] ) div 2
scores[s]        = scorePermille[s] / 1000.0        in [-1.0, +1.0]
```

**Higher is better.** Because every seat hides in exactly one game and seeks in
the other, and the two trios are complementary, **the six scores sum to exactly
zero**. `results.win[s]` is `scorePermille[s] > 0`; an all-zero margin is a draw
and every `win` is false. There is no `results.winner` key — the trios change
composition between games, so the only meaningful verdict is the per-seat
number.

**Everything else is measured and shown, never scored**: `seatSeenTicks`,
`sealedTicks`, `locks`, `grabs`, `vaults`, `pushedPx`, `shouts`.

## The reply schema

One JSON object per seat per turn:

```json
{"intent": "push", "object": "box2", "to": [188, 208], "at": "d1",
 "face": [300, 200], "say": "on it", "radio": "pan1 on d1, I take the gap",
 "notes": "then lock both"}
```

| Field | Cap / domain |
|---|---|
| `intent` | <= 12 runes; `move_to` \| `hide` \| `watch` \| `chase` \| `push` \| `lock` \| `unlock` \| `vault`. Unknown repairs to `watch` |
| `object` | <= 8 runes; required for `push`/`lock`/`unlock`/`vault`, and a ramp for `vault` |
| `to` | `[x, y]`, clamped into the board |
| `at` | <= 4 runes; a published anchor / door / region id. WINS over `to` |
| `face` | optional bearing the driver aims at once it arrives |
| `say` | <= 10 runes — an IN-WORLD SHOUT, heard by BOTH teams within 144 px |
| `radio` | <= 96 runes — the TEAM channel, delivered next turn, never audible |
| `notes` | <= 160 runes — private, echoed back to this seat only |
| whole reply | <= 4096 bytes read from the provider before parsing |

Unknown top-level keys are ignored. A reply with a valid `say`/`radio` but no
`intent` is USABLE: the cog keeps its standing order and the line is delivered.
An intent whose required argument is missing or unresolvable is REPAIRED to the
previous order, counted in `ordersRejected`, and reported next turn in `result`.

**Every string that lands in the replay is truncated on RUNE boundaries.** Byte
truncation is what makes a replay that renders in a browser fail a strict UTF-8
parser.

## The driver

| Intent | What the driver does | Finishes with |
|---|---|---|
| `move_to` | flow-field nav to the point; stop inside `ArriveRadius` | `moving` -> `arrived`, `no_route` |
| `hide` | nav there, stop dead, aim at `face` else the nearest door | `arrived` -> `holding` |
| `watch` | never moves; sweeps +/-32 brads around the bearing | `holding` |
| `chase` | nav to the last known enemy position, then `watch` it | `chasing` -> `arrived` |
| `push` | standoff -> grab -> drag the OBJECT's centre to the target -> release | `pushing` -> `pushed`, `push_stuck`, `grab_failed` |
| `lock` / `unlock` | standoff, then press `A` inside `lockReach` | `locked` / `unlocked` / `lock_refused` |
| `vault` | standoff at the ramp's foot, then drive along the axis | `vaulted` / `vault_failed` |

No intent can leave a cog unactuated: an unreachable target degrades to `watch`
on the current bearing, which is a legal mask.

## Scripted baselines

`burrow` (`PLAYER_SCRIPTED=burrow`) walls a doorway, locks what it placed and
drags the ramps away; `scatter` (`PLAYER_SCRIPTED=scatter`) never touches the
furniture and keeps moving between pockets. Both implement BOTH ROLES, because
sides swap mid-episode. `burrow` is also the server-side fallback when a seat's
LLM call fails twice — the same proc, imported, never duplicated.

## End conditions

`results.reason` is a closed enum and the game emits nothing else:

- **`complete`** — both games played to `maxTicks`. `endRule = "full_time"`.
- **`deadline`** — the wall clock reached `wallClockBudgetSeconds` (660 s). The
  engine stops at the current tick and settles with the REAL numbers so far.
  `endRule = "wall_clock"`.
- **`fault`** — caught; the episode is settled from the last completed tick,
  `endRule` in `{sim_fault, host_error}`, `stopDetail` names it.

A seat that never connects, disconnects, or fails every decision **does not end
the episode**: its cog is driven by `burrow` and the episode runs to its natural
end with `deadSeats[s] = true`.

## Divergences from Baker et al. 2019

The rules idiom is *Emergent Tool Use From Multi-Agent Autocurricula*
(`openai/multi-agent-emergence-environments`); the five facts this game borrows
are transcribed with their citations in `src/hns/upstream.nim`. What differs:

1. **This is a rules-idiom reimplementation, not a port.** MuJoCo physics, the
   3-D geometry, the RL observation vectors and BOX SURFING are not reproduced.
   Box surfing is an artefact of MuJoCo's 3-D contact model with no meaning in a
   top-down 2-D sim; the autocurriculum this game ships is fort -> ramp -> lock.
2. **Teammates are not fogged.** The starter fogs everyone. Three cogs
   coordinating a fort at a 3.75 s cadence cannot do it blind, and the `radio`
   channel already gives them a voice. Enemies are fogged exactly as the starter
   fogs them.
3. **Objects are dynamic occluders**, which the starter's static `fovBlocked`
   grid never had to be. The dirty-rect rebuild and the `geometryEpoch` cache
   invalidation are the whole cost.
4. **An airborne cog is visible over furniture.** Visibility of a vaulting
   target uses `lineOfSightClear` against the STATIC wall mask. Without it the
   vault — the one dramatic act in the game — would happen invisibly behind the
   crate it is jumping.
5. **Keep-clear discs around the seeker pads.** Upstream's seekers start outside
   the arena; here, without this rule, the dominant hider strategy is to brick
   the seekers in, which is a 1000-permille win and a boring replay.
6. **`maxGames = 2` with a side swap**, and the episode score is the mean.
   Upstream trains both roles across episodes; a league needs the comparison
   inside one episode.
7. **The 15 s prep / 30 s hunt split** is this repo's, sized by the wall clock,
   not upstream's step counts.

## Sprite labels

The emitted board vocabulary is the contract in `src/hns/labels.nim`, pinned by
`tests/label_manifest.txt`: `cog`, `crate`, `panel`, `ramp`, `locked crate`,
`locked panel`, `locked ramp`, `padlock`, `vision cone`, `carry tether`,
`vault arc`, `shout bubble`, `map band`, `broadcast chrome`, `spotted ring`,
plus the `own aim <brads>` readback marker.
