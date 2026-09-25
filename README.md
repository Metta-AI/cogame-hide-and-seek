# cogame-hide-and-seek

Three cogs hide. Three cogs seek. Nobody has a weapon.

A **720 x 400 room** with walls, doorways and eight pieces of movable
furniture — four crates, two panels, two ramps. The **hiders** get fifteen
seconds alone in it: drag the furniture, wall off a doorway, **lock** what you
built, and drag the ramps out of reach before anybody can use them. Then a door
opens and the **seekers** walk in with 70-degree torch cones and thirty seconds
to look.

Every tick in which **any** hider is inside **any** seeker's cone pays the
seekers a point; every tick in which all three hiders are unseen pays the
hiders. Then the two trios **swap sides** and play the same room and the same
furniture again, and the episode's score is the average of the two — so the
league grades the policy, not the deal.

Each seat sends one JSON order per 3.75-second turn
— `move_to`, `hide`, `watch`, `chase`, `push`, `lock`, `unlock`, `vault` — and a
deterministic driver carries it out. The same image ships two scripted
baselines (`burrow`, `scatter`) selected by an environment variable.

`PLAYER_NUMERIC_URL` runs a numeric `/actions` policy in the player container;
`PLAYER_JEV=1` runs Jev System One there. Both choose from the game's 107-slot
order catalog using that seat's observation and send the selected order over
the ordinary `/player` socket. The game validates the order, drives the cog,
scores the episode, and records the replay. `PLAYER_PROMPT` remains available
for prompt policies through the game-side LLM client.

`/bin/hide-and-seek-bridge` is the JSONL training entrypoint. It drives the
same seeded simulator and order parser across both sides of a match, exposing
356 visible numeric values, a masked action catalog, and the scripted `burrow`
teacher for other seats. Its default training episode uses two prep turns and
three hunt turns per side; the normal Coworld fixture keeps its own clock.

- Rules: [`docs/RULES.md`](docs/RULES.md)
- The object layer: [`docs/OBJECTS.md`](docs/OBJECTS.md)
- Wire protocol: [`docs/PROTOCOL.md`](docs/PROTOCOL.md)

## What it is a fork of

This repo is a fork of **[coworld-ctf](https://github.com/Metta-AI/coworld-ctf)**
(the paintbot / crewrift engine). It keeps that engine's continuous 2-D motion
with slide collision, its recursive-shadowcast fog of war and aim-carried vision
cone, its Sprite v1 protocol and mummy websocket server, its binary
`COWLD…` replay of per-tick input masks plus a per-tick `gameHash`
re-simulated by the SAME sim module compiled to wasm, and its broadcast chrome.

What it deletes, rather than disables: the gun, spray, grenades, med kits,
shields, barriers, hit points, lives, respawns, the flag/heart objective, floor
paint, King of the Hill, four-team play, the first-person inset, and the whole
procedural map generator with its pool, editor and mapkit.

What it adds: a dynamic **object layer** (grab, push, lock, vault, keep-clear
discs, dirty-rect occlusion rebuilds), a **two-phase clock** with a side swap,
and the **+/-1 per tick seen/unseen** team reward.

The rules idiom is Baker et al. 2019, *Emergent Tool Use From Multi-Agent
Autocurricula* (`openai/multi-agent-emergence-environments`). The five facts
borrowed from it are transcribed with their citations in
[`src/hns/upstream.nim`](src/hns/upstream.nim) and asserted by
`tests/test_hns_upstream.nim`. **Box surfing is deliberately not reproduced** —
it is an exploit of MuJoCo's 3-D contact dynamics with no meaning in a top-down
2-D sim.

## Layout

- `src/hide_and_seek.nim` — server entrypoint (the seed is randomised HERE,
  before `config.update`, so every seed-derived draw follows the final seed).
- `src/hide_and_seek_player.nim` — the player policy entrypoint
- `src/hns/numeric_bridge.nim` — the JSONL training bridge
  (`/bin/hide-and-seek-bridge`).
- `src/hns/` — the sim: `sim_types` (consts, wire types, `GameVersion`),
  `room` (the authored room documents and their validator), `objects` (the
  object layer), `phase` (the two-phase clock and the exposure counters),
  `fort` (the sealed-fort scan), `vision` (the shadowcast), `motion` (the
  fixed-point integrator), `sim` (the step loop), `server`, `broadcast`,
  `global` (the board compositor), `decide` / `directives` / `llm` /
  `baselines` / `control` (the commander layer), `replays`.
- `data/rooms/room_{warren,atrium,long_hall}.json` — the three committed rooms.
  Re-author them with `scripts/rooms/author_rooms.py`, and re-pin their sha256s
  in `tests/test_hns_room.nim` in the same commit.
- `scripts/art/` — the nano-banana source sheets and the split script that turn
  them into `data/cog_{hider,seeker}.png` and `data/obj_{crate,panel,ramp}.png`.
- `tests/` — run `nim c -r tests/tests.nim` from the repo ROOT.

## Building

Dependencies come from nimby; the `Dockerfile` is the canonical recipe.

```bash
nimby --global sync nimby.lock
nim c -r tests/tests.nim
docker compose build
```

The static replay viewer is built by `tools/build_replay_viewer.sh` through the
pinned `emscripten/emsdk:4.0.15` container in `Dockerfile.replay-viewer`. It is
the `coworld build` hook and must stay committed **executable**.

## Playing your own policy

```bash
coworld upload-policy coworld-hide-and-seek:latest --name my-hns \
  --run /bin/hide-and-seek-player \
  --env PLAYER_NUMERIC_URL="<your /actions endpoint>"
```
