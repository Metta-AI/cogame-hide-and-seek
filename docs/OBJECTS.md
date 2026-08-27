# Boxes, ramps and the lock

Eight objects per game, all axis-aligned rectangles, all **opaque to vision**
and all **solid to movement**:

| Id | Kind | Size (px) | Count | Notes |
|---|---|---|---|---|
| `box1`…`box4` | crate | 64 x 64 | 4 | the fort bricks |
| `pan1`, `pan2` | panel | 128 x 32 (`h`) or 32 x 128 (`v`) | 2 | one panel covers a 56 px door with room to spare |
| `ramp1`, `ramp2` | ramp | 40 x 80 (`v`) or 80 x 40 (`h`) | 2 | the only way over a locked wall |

Every object carries `pos` (integer px, top-left), `kind`, `axis`,
`lockedBy` in `{none, hiders, seekers}` and `heldBy` (slot index or -1). All of
it is in `gameHash`.

## The deal is seeded, not authored

The room's `objectSpawns` are shuffled by the episode's `setupRng` and the first
`crates` crate-capable, `panels` panel-capable and `ramps` ramp-capable
candidates are taken in that fixed order, each object taking its candidate's
axis. **The same deal is used for both games of the episode** — the two trios
play the same room and the same furniture, which is what makes the swap a fair
comparison — and it is pinned into the replay config.

The draw happens **before any seat connects**, so nothing a seat does can shift
it. Neither can the room: the episode's room is `pool[seed mod 3]`.

A candidate is skipped if the object would overlap a static wall, another
object, a spawn pad, or a keep-clear disc.

## Grab (button `C`, bit 7)

Hold `C` to grab, release to drop. On a fresh press, a segment is probed from
the cog's centre **along its aim**, from the body edge out to `grabReach` = 30
px. The FIRST object the segment meets binds — nothing beyond it. An object
locked by the OTHER team refuses and emits `lock_refused`; an object already
held by another cog refuses. Ties (two cogs in the same tick) go to the lower
slot; the loser gets a `grab_failed`.

A held object is dropped when `C` is released, when the cog has been dead
stopped against a refusal for `grabBreakTicks` = 24 ticks, when the phase
changes, or when the game ends.

## Push

A holder moves at `carrySpeedPct` = 55 % of normal speed, and its held object
translates **rigidly** with it. The move commits only if, after it, the object's
rectangle overlaps no static wall, no other object, no cog other than the
holder, and no keep-clear disc; otherwise **neither** moves this tick, the
velocity on the blocked axis is zeroed, and `pushBlockedTicks` counts it. The
starter's per-axis slide is applied to the PAIR, so a crate runs along a wall
instead of sticking to it.

### Keep-clear discs

No object may be moved to within `keepClearPx` = 96 px of a **seeker pad**.
Without this a hider trio can wall the seekers in during prep and win 1000
permille with no game played; with it, sealing a *fort* is legal and sealing
*the door the seekers come out of* is not. The refusal is the ordinary push
refusal, so it degrades into "the crate stops here".

## Lock (button `A`)

`A` toggles the lock on the held object, else on the object nearest the cog's
centre within `lockReach` = 30 px of its rectangle.

- `lockedBy == none` -> `lockedBy = your team`, `lock` event.
- `lockedBy == your team` -> `lockedBy = none`, `unlock` event.
- `lockedBy == the other team` -> refused, `lock_refused` event.

Either way `lockCooldown` = 24 ticks. **Locking is the whole game**: an unlocked
wall is a wall for ten seconds, a locked wall is a wall for the rest of the
hunt. A locked object is still solid and still opaque to both teams.

## Vault

A cog that holds nothing, whose centre is inside a **ramp's** rectangle, whose
velocity along the ramp axis toward its head is at least `MaxSpeed div 2`, and
for which the first blocking span beyond the head is at most `vaultSpanPx` = 112
px thick, goes **airborne**: `vaultTicks` = 10 ticks at 5 px/tick (50 px in
all), ignoring wall and object collisions. On the last airborne tick it lands at
the first clear position along the axis; if none is clear it is refunded to the
ramp's foot (`vault_failed`).

While airborne a cog cannot grab or lock, **and it is visible over the
furniture**: visibility of an airborne target is tested against the STATIC WALL
MASK only, because its head is above the crates. Vaulting is how you get in;
being seen doing it is what it costs.

## The sealed-fort scan

At every turn boundary and at the release tick, a breadth-first fill runs over
the 8 px fog grid from every seeker's cell, blocked by static walls and by
objects the **hiders have locked**. Unlocked objects are passable — a seeker can
shove them. Every hider the fill does not reach is `sealed`, and `sealedTicks`
accumulates the hunt ticks it spent that way.

`sealed` is **measured, never scored**. A sealed fort that nobody can see into
is already winning on the exposure counter; paying twice for it would break the
exact zero sum the league ranks on.
