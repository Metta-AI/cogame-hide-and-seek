# Agent operating guide — cogame-hide-and-seek

Orientation for coding agents working in this repo. Gameplay rules live in
[docs/RULES.md](docs/RULES.md) and the object layer in
[docs/OBJECTS.md](docs/OBJECTS.md); this file covers the workflows that are
easy to get wrong.

## What this repo is a fork of

`Metta-AI/coworld-ctf` (the paintbot / crewrift engine). Read
[README.md](README.md) § "What it is a fork of" first: what was KEPT, what was
DELETED (not disabled) and what was ADDED are all listed there, and a change
that reintroduces a deleted mechanic is a change to the game, not a fix.

## Layout

- `src/hide_and_seek.nim` — server entrypoint. **The seed is randomised HERE,
  before `config.update`**, so every seed-derived draw (the room pick and its
  replay-pinned `mapSpec`) follows the final seed.
- `src/hns/` — the sim modules. `sim.nim` imports and RE-EXPORTS all of them,
  so `import hns/sim` still sees everything.
- `tests/` — run `nim c -r tests/tests.nim` from the repo **ROOT** (assets
  resolve via `data/`). Use `-d:release` for anything heavy; debug builds are
  10-50x slower through the per-pixel room bake. CI runs every `tests/*.nim`
  twice, debug and release.
- Dependencies come from nimby (`nimby --global sync nimby.lock`); the
  `Dockerfile` is the canonical build recipe.

## The four rails that break silently

**1. The determinism boundary.** The control layer and the LLM sit OUTSIDE it:
the replay records the per-tick actuator MASKS and one `gameHash` per tick,
and the wasm viewer re-steps the SAME sim module from those masks. So:

- `src/hns/{objects,phase,fort,motion}.nim` are **integer only**.
  `tests/test_hns_determinism.nim` greps them for float literals, `sqrt` and
  ` / `. A new float expression feeding a hashed value is exactly how a
  native/wasm chain diverges.
- `src/hns/vision.nim`'s `applyFovCone` IS float, deliberately, and is kept
  byte-for-byte from the starter: it is already the mechanism the starter's
  own hash chain survives.
- `gameHash` field order is wire format. APPEND, never insert.

**2. A wall-clock fact cannot be re-derived.** The wall-clock stop and the
fault stop are written as one `stop` RECORD and applied by the SAME proc on
record and on playback (`sim.forceWallClockStop` / `sim.forceFaultStop`), and
the recorder then steps ONE MORE TICK and hashes it — a record is applied at
the start of the step that leaves its tick, so without that extra tick
playback never applies it. `tests/test_hns_replay.nim` runs the
record → re-derive check for **every** end reason.

**3. Two name spaces.** In-game a cog is `HIDER-alpha` … `SEEKER-gamma` and
nothing else. Real policy names live only in `results.names`, in the replay's
join records and in the viewer's scorebug. `showPlayerLabels` is false in
every variant.

**4. Rune boundaries.** Every recorded string is truncated on RUNE boundaries
(`truncateRunes` / `runeSubStr`), never by byte index. A byte-truncated
codepoint renders fine in a browser and then fails a strict UTF-8 parser.

## GameVersion

`src/hns/sim_types.nim`'s `GameVersion` gates replay compatibility, and its
changelog comment is **prepend-only**: say what the number means and what it
obsoletes, in the `GVnn (short rule name): HEADLINE` shape.
`tools/ci/check_gameversion.sh origin/main` diffs the headline, not the digits.

A change to any of `data/rooms/*.json` is a GameVersion bump AND a re-pin of
the sha256 literals in `tests/test_hns_room.nim`, in the same commit: an old
replay's pinned `mapSpec` would otherwise no longer be what the file says.

## The rooms

Rooms are AUTHORED, never generated. Re-author them with
`python3 scripts/rooms/author_rooms.py`, which refuses to write a room the
engine's load-time validator would reject and additionally checks that every
`objectSpawn` can actually FIT the kinds it advertises.

## The art

`data/cog_{hider,seeker}.png` and `data/obj_{crate,panel,ramp}.png` are split
out of the committed nano-banana sheets under `scripts/art/source/` by
`python3 scripts/art/split_cog_sheet.py`. Regenerate the sheets only through
`playbooks/art-nanobanana.md`'s recipe; never hand-edit the derived PNGs.

## The viewer

`client/chrome_common.js` is the starter's file **byte for byte** and its
sha256 is pinned by `tests/test_hns_viewer.nim`. Everything this game adds
lives BELOW the splice banner in `client/replay_broadcast.html`
(`HIDE-AND-SEEK additions to the inherited coworld-ctf chrome`). The game
block never calls `markBeat` — it builds labelled, clickable `<button>`
markers with `hnsBeat`, because chrome_common's hoisted `var markBeat` would
otherwise silently swallow a same-named function.
