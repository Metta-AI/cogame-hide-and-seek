#!/usr/bin/env python3
"""Author the three committed rooms.

Rooms are authored, not generated (design note, §The room): the episode's
room is `pool[seed mod 3]` and the documents this script emits are the whole
board.  Re-run it only to change a room, and re-pin the sha256 literals in
`tests/test_hns_room.nim` in the same commit — a room change is a
GameVersion bump.

    python3 scripts/rooms/author_rooms.py

It fails loudly rather than writing a room that the engine's load-time
validator would reject: every wall is checked in bounds, every anchor and
object spawn is checked for a 12 px body's clearance, every object spawn is
checked to actually FIT the kinds it advertises at the axis it advertises,
every door is checked to join exactly two regions and to sit on floor, and
every region is checked reachable from every seeker pad over an 8 px grid.
"""

import json
import os
import sys

W, H = 720, 400
BORDER = 16
PLAYER_HALF = 6
FOV_CELL = 8

SIZES = {
    ("crate", "h"): (64, 64),
    ("crate", "v"): (64, 64),
    ("panel", "h"): (128, 32),
    ("panel", "v"): (32, 128),
    ("ramp", "h"): (80, 40),
    ("ramp", "v"): (40, 80),
}


def border_walls():
    return [
        [0, 0, W, BORDER],
        [0, H - BORDER, W, BORDER],
        [0, BORDER, BORDER, H - 2 * BORDER],
        [W - BORDER, BORDER, BORDER, H - 2 * BORDER],
    ]


def wall_at(walls, x, y):
    if x < 0 or y < 0 or x >= W or y >= H:
        return True
    for wx, wy, ww, wh in walls:
        if wx <= x < wx + ww and wy <= y < wy + wh:
            return True
    return False


def clear(walls, x, y, half=PLAYER_HALF):
    for dy in range(-half, half + 1):
        for dx in range(-half, half + 1):
            if wall_at(walls, x + dx, y + dy):
                return False
    return True


def box_clear(walls, cx, cy, w, h):
    x0, y0 = cx - w // 2, cy - h // 2
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w):
            if wall_at(walls, x, y):
                return False
    return True


def region(rid, name, box, doors):
    return {"id": rid, "name": name, "box": box, "doors": doors}


def door(did, at, width, axis):
    return {"id": did, "at": at, "w": width, "axis": axis}


def anchor(aid, kind, at, team=""):
    return {"id": aid, "kind": kind, "at": at, "team": team}


def spawn(at, kinds, axis):
    return {"at": at, "kinds": kinds, "axis": axis}


def warren():
    walls = border_walls()
    # Two vertical spines, each with a north and a south doorway, and one
    # horizontal spine with a single middle doorway: six small rooms, five
    # doors, and no sightline longer than a third of the board.
    for x in (248, 472):
        walls += [
            [x, 16, 16, 60],
            [x, 132, 16, 132],
            [x, 320, 16, 64],
        ]
    walls += [
        [16, 192, 324, 16],
        [396, 192, 308, 16],
    ]
    regions = [
        region("r1", "west closet", [16, 16, 232, 176], ["d1"]),
        region("r2", "north hall", [264, 16, 208, 176], ["d1", "d2", "d5"]),
        region("r3", "east nook", [488, 16, 216, 176], ["d2"]),
        region("r4", "south closet", [16, 208, 232, 176], ["d3"]),
        region("r5", "south hall", [264, 208, 208, 176], ["d3", "d4", "d5"]),
        region("r6", "boot room", [488, 208, 216, 176], ["d4"]),
    ]
    doors = [
        door("d1", [256, 104], 56, "v"),
        door("d2", [480, 104], 56, "v"),
        door("d3", [256, 292], 56, "v"),
        door("d4", [480, 292], 56, "v"),
        door("d5", [368, 200], 56, "h"),
    ]
    anchors = [
        anchor("h1", "pad", [80, 80], "hiders"),
        anchor("h2", "pad", [80, 320], "hiders"),
        anchor("h3", "pad", [600, 80], "hiders"),
        anchor("s1", "pad", [368, 152], "seekers"),
        anchor("s2", "pad", [616, 248], "seekers"),
        anchor("s3", "pad", [616, 336], "seekers"),
        anchor("p1", "pocket", [40, 40]),
        anchor("p2", "pocket", [224, 168]),
        anchor("p3", "pocket", [40, 360]),
        anchor("p4", "pocket", [224, 232]),
        anchor("p5", "pocket", [680, 40]),
        anchor("p6", "pocket", [512, 168]),
        anchor("p7", "pocket", [288, 40]),
        anchor("p8", "pocket", [288, 360]),
        anchor("q1", "patrol", [132, 104]),
        anchor("q2", "patrol", [368, 104]),
        anchor("q3", "patrol", [596, 104]),
        anchor("q4", "patrol", [132, 292]),
        anchor("q5", "patrol", [368, 292]),
        anchor("q6", "patrol", [596, 292]),
    ]
    spawns = [
        spawn([80, 72], ["crate", "ramp"], "v"),
        spawn([176, 72], ["crate", "ramp"], "h"),
        spawn([124, 152], ["panel"], "h"),
        spawn([80, 264], ["crate", "ramp"], "v"),
        spawn([176, 264], ["crate", "ramp"], "h"),
        spawn([124, 344], ["panel"], "h"),
        spawn([340, 72], ["crate", "ramp"], "v"),
        spawn([400, 128], ["crate", "ramp"], "h"),
        spawn([368, 96], ["panel"], "h"),
        spawn([340, 264], ["crate", "ramp"], "v"),
        spawn([400, 328], ["crate", "ramp"], "h"),
        spawn([368, 296], ["panel"], "h"),
        spawn([560, 72], ["crate", "ramp"], "v"),
        spawn([648, 72], ["crate", "ramp"], "h"),
        spawn([596, 152], ["panel"], "h"),
        spawn([560, 264], ["crate", "ramp"], "v"),
        spawn([540, 120], ["panel"], "v"),
        spawn([300, 300], ["panel"], "v"),
        spawn([124, 108], ["panel"], "h"),
        spawn([124, 300], ["panel"], "h"),
        spawn([368, 152], ["crate", "ramp"], "h"),
        spawn([368, 248], ["crate", "ramp"], "h"),
        spawn([176, 152], ["crate", "ramp"], "h"),
        spawn([176, 344], ["crate", "ramp"], "h"),
    ]
    return {
        "name": "warren",
        "w": W,
        "h": H,
        "symmetry": "symNone",
        "walls": walls,
        "regions": regions,
        "doors": doors,
        "anchors": anchors,
        "objectSpawns": spawns,
    }


def atrium():
    walls = border_walls()
    # Four corner alcoves cut out of one central hall, plus a pillar the
    # cones have to walk around.
    walls += [
        [176, 16, 16, 72],
        [16, 128, 176, 16],
        [528, 16, 16, 72],
        [528, 128, 176, 16],
        [176, 312, 16, 72],
        [16, 256, 176, 16],
        [528, 312, 16, 72],
        [528, 256, 176, 16],
        [336, 176, 48, 48],
    ]
    regions = [
        region("a1", "north west alcove", [16, 16, 160, 112], ["d1"]),
        region("a2", "north east alcove", [544, 16, 160, 112], ["d2"]),
        region("a3", "south west alcove", [16, 272, 160, 112], ["d3"]),
        region("a4", "south east alcove", [544, 272, 160, 112], ["d4"]),
        region("a5", "atrium", [16, 16, 688, 368], ["d1", "d2", "d3", "d4"]),
    ]
    doors = [
        door("d1", [184, 108], 40, "v"),
        door("d2", [536, 108], 40, "v"),
        door("d3", [184, 292], 40, "v"),
        door("d4", [536, 292], 40, "v"),
    ]
    anchors = [
        anchor("h1", "pad", [80, 72], "hiders"),
        anchor("h2", "pad", [80, 328], "hiders"),
        anchor("h3", "pad", [620, 72], "hiders"),
        anchor("s1", "pad", [656, 200], "seekers"),
        anchor("s2", "pad", [624, 200], "seekers"),
        anchor("s3", "pad", [592, 200], "seekers"),
        anchor("p1", "pocket", [40, 40]),
        anchor("p2", "pocket", [148, 104]),
        anchor("p3", "pocket", [40, 360]),
        anchor("p4", "pocket", [148, 296]),
        anchor("p5", "pocket", [680, 40]),
        anchor("p6", "pocket", [680, 360]),
        anchor("p7", "pocket", [300, 200]),
        anchor("p8", "pocket", [420, 200]),
        anchor("q1", "patrol", [360, 60]),
        anchor("q2", "patrol", [360, 340]),
        anchor("q3", "patrol", [232, 200]),
        anchor("q4", "patrol", [488, 200]),
        anchor("q5", "patrol", [104, 200]),
        anchor("q6", "patrol", [616, 340]),
    ]
    spawns = [
        spawn([88, 64], ["crate", "ramp"], "v"),
        spawn([88, 336], ["crate", "ramp"], "h"),
        spawn([616, 64], ["crate", "ramp"], "v"),
        spawn([616, 336], ["crate", "ramp"], "h"),
        spawn([260, 72], ["crate", "ramp"], "h"),
        spawn([460, 72], ["crate", "ramp"], "v"),
        spawn([260, 328], ["crate", "ramp"], "h"),
        spawn([460, 328], ["crate", "ramp"], "v"),
        spawn([260, 200], ["panel"], "v"),
        spawn([460, 200], ["panel"], "v"),
        spawn([360, 80], ["panel"], "h"),
        spawn([360, 320], ["panel"], "h"),
        spawn([104, 200], ["crate", "ramp"], "v"),
        spawn([616, 200], ["crate", "ramp"], "v"),
        spawn([200, 200], ["ramp"], "h"),
        spawn([520, 200], ["ramp"], "h"),
        spawn([240, 120], ["crate", "ramp"], "h"),
        spawn([240, 288], ["crate", "ramp"], "h"),
        spawn([480, 120], ["crate", "ramp"], "h"),
        spawn([480, 288], ["crate", "ramp"], "h"),
        spawn([300, 264], ["crate", "ramp"], "v"),
        spawn([420, 264], ["crate", "ramp"], "v"),
        spawn([300, 136], ["crate", "ramp"], "v"),
    ]
    return {
        "name": "atrium",
        "w": W,
        "h": H,
        "symmetry": "symNone",
        "walls": walls,
        "regions": regions,
        "doors": doors,
        "anchors": anchors,
        "objectSpawns": spawns,
    }


def long_hall():
    walls = border_walls()
    # One long hall and two stub walls. Nothing here is hideable until
    # somebody builds it, which is the point of the second manifest variant.
    walls += [
        [264, 16, 16, 224],
        [440, 160, 16, 224],
    ]
    regions = [
        region("l1", "west end", [16, 16, 248, 368], ["d1"]),
        region("l2", "middle", [280, 16, 160, 368], ["d1", "d2"]),
        region("l3", "east end", [456, 16, 248, 368], ["d2"]),
    ]
    doors = [
        door("d1", [272, 312], 144, "v"),
        door("d2", [448, 88], 144, "v"),
    ]
    anchors = [
        anchor("h1", "pad", [64, 64], "hiders"),
        anchor("h2", "pad", [64, 336], "hiders"),
        anchor("h3", "pad", [160, 200], "hiders"),
        anchor("s1", "pad", [656, 200], "seekers"),
        anchor("s2", "pad", [656, 88], "seekers"),
        anchor("s3", "pad", [656, 312], "seekers"),
        anchor("p1", "pocket", [40, 40]),
        anchor("p2", "pocket", [40, 360]),
        anchor("p3", "pocket", [240, 40]),
        anchor("p4", "pocket", [240, 360]),
        anchor("p5", "pocket", [320, 200]),
        anchor("p6", "pocket", [400, 200]),
        anchor("p7", "pocket", [480, 40]),
        anchor("p8", "pocket", [480, 360]),
        anchor("q1", "patrol", [140, 104]),
        anchor("q2", "patrol", [140, 296]),
        anchor("q3", "patrol", [360, 104]),
        anchor("q4", "patrol", [360, 296]),
        anchor("q5", "patrol", [560, 104]),
        anchor("q6", "patrol", [560, 296]),
    ]
    spawns = [
        spawn([80, 72], ["crate", "ramp"], "v"),
        spawn([80, 200], ["crate", "ramp"], "h"),
        spawn([80, 328], ["crate", "ramp"], "v"),
        spawn([200, 72], ["crate", "ramp"], "h"),
        spawn([200, 200], ["panel"], "v"),
        spawn([200, 328], ["crate", "ramp"], "h"),
        spawn([360, 72], ["crate", "ramp"], "v"),
        spawn([360, 200], ["panel"], "v"),
        spawn([360, 328], ["crate", "ramp"], "v"),
        spawn([520, 72], ["crate", "ramp"], "h"),
        spawn([520, 200], ["panel"], "v"),
        spawn([520, 328], ["crate", "ramp"], "h"),
        spawn([160, 128], ["panel"], "h"),
        spawn([160, 272], ["panel"], "h"),
        spawn([360, 128], ["panel"], "h"),
        spawn([120, 72], ["crate", "ramp"], "h"),
        spawn([120, 328], ["crate", "ramp"], "h"),
        spawn([200, 136], ["crate", "ramp"], "v"),
        spawn([200, 264], ["crate", "ramp"], "v"),
        spawn([320, 72], ["crate", "ramp"], "h"),
        spawn([320, 328], ["crate", "ramp"], "h"),
        spawn([400, 128], ["crate", "ramp"], "v"),
        spawn([400, 272], ["crate", "ramp"], "v"),
        spawn([560, 128], ["crate", "ramp"], "v"),
        spawn([560, 272], ["crate", "ramp"], "v"),
    ]
    return {
        "name": "long_hall",
        "w": W,
        "h": H,
        "symmetry": "symNone",
        "walls": walls,
        "regions": regions,
        "doors": doors,
        "anchors": anchors,
        "objectSpawns": spawns,
    }


def validate(room):
    name = room["name"]
    walls = room["walls"]
    problems = []
    for i, (x, y, w, h) in enumerate(walls):
        if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > W or y + h > H:
            problems.append(f"wall {i} out of bounds: {[x, y, w, h]}")
    door_ids = {d["id"] for d in room["doors"]}
    for d in room["doors"]:
        joined = sum(1 for r in room["regions"] if d["id"] in r["doors"])
        if joined != 2:
            problems.append(f"door {d['id']} joins {joined} regions")
        if wall_at(walls, d["at"][0], d["at"][1]):
            problems.append(f"door {d['id']} is inside a wall")
        if not clear(walls, d["at"][0], d["at"][1]):
            problems.append(f"door {d['id']} has no body clearance")
    for r in room["regions"]:
        for did in r["doors"]:
            if did not in door_ids:
                problems.append(f"region {r['id']} names unknown door {did}")
    pockets = [a for a in room["anchors"] if a["kind"] == "pocket"]
    hider_pads = [
        a for a in room["anchors"]
        if a["kind"] == "pad" and a["team"] == "hiders"
    ]
    seeker_pads = [
        a for a in room["anchors"]
        if a["kind"] == "pad" and a["team"] == "seekers"
    ]
    if len(pockets) < 6:
        problems.append(f"only {len(pockets)} pockets")
    if len(hider_pads) != 3:
        problems.append(f"{len(hider_pads)} hider pads")
    if len(seeker_pads) != 3:
        problems.append(f"{len(seeker_pads)} seeker pads")
    for a in room["anchors"]:
        if not clear(walls, a["at"][0], a["at"][1]):
            problems.append(f"anchor {a['id']} has no clearance")
    if len(room["objectSpawns"]) < 14:
        problems.append(f"only {len(room['objectSpawns'])} objectSpawns")
    for i, s in enumerate(room["objectSpawns"]):
        cx, cy = s["at"]
        if not clear(walls, cx, cy):
            problems.append(f"objectSpawn {i} has no body clearance")
        for kind in s["kinds"]:
            w, h = SIZES[(kind, s["axis"])]
            if not box_clear(walls, cx, cy, w, h):
                problems.append(
                    f"objectSpawn {i} at {s['at']} cannot fit a "
                    f"{s['axis']} {kind} ({w}x{h})")
    # Reachability from every seeker pad over the 8 px grid, no objects.
    gw, gh = (W + FOV_CELL - 1) // FOV_CELL, (H + FOV_CELL - 1) // FOV_CELL
    walkable = [
        clear(walls, cx * FOV_CELL + FOV_CELL // 2,
              cy * FOV_CELL + FOV_CELL // 2)
        for cy in range(gh) for cx in range(gw)
    ]
    for pad in seeker_pads:
        start = (pad["at"][1] // FOV_CELL) * gw + pad["at"][0] // FOV_CELL
        seen = [False] * (gw * gh)
        seen[start] = True
        queue = [start]
        head = 0
        while head < len(queue):
            i = queue[head]
            head += 1
            cx, cy = i % gw, i // gw
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = cx + dx, cy + dy
                if 0 <= nx < gw and 0 <= ny < gh:
                    j = ny * gw + nx
                    if not seen[j] and walkable[j]:
                        seen[j] = True
                        queue.append(j)
        for r in room["regions"]:
            x0, y0, rw, rh = r["box"]
            hit = any(
                seen[cy * gw + cx]
                for cy in range(y0 // FOV_CELL,
                                min((y0 + rh - 1) // FOV_CELL + 1, gh))
                for cx in range(x0 // FOV_CELL,
                                min((x0 + rw - 1) // FOV_CELL + 1, gw))
            )
            if not hit:
                problems.append(
                    f"region {r['id']} unreachable from pad {pad['id']}")
    if problems:
        print(f"room {name} is invalid:", file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return False
    return True


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "..", "data", "rooms")
    os.makedirs(out, exist_ok=True)
    ok = True
    for builder in (warren, atrium, long_hall):
        room = builder()
        if not validate(room):
            ok = False
            continue
        path = os.path.join(out, f"room_{room['name']}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(room, handle, indent=2, sort_keys=False)
            handle.write("\n")
        print(f"wrote {path}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
