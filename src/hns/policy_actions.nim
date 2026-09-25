## Fixed game-owned order catalog and numeric view for ordinary seat policies.

import std/json
import sim_types

const ActionCount* = 107

proc actionChoices*(view: JsonNode): JsonNode =
  result = newJArray()
  result.add(%*{"intent": "watch"})
  result.add(%*{"intent": "chase"})
  let room = view["room"]
  for index in 0 ..< 8:
    if index < room["pockets"].len:
      result.add(%*{"intent": "hide", "at": room["pockets"][index]["id"]})
    else: result.add(newJNull())
  for index in 0 ..< 6:
    if index < room["regions"].len:
      result.add(%*{"intent": "move_to", "at": room["regions"][index]["id"]})
    else: result.add(newJNull())
  for index in 0 ..< 5:
    if index < room["doors"].len:
      result.add(%*{"intent": "move_to", "at": room["doors"][index]["id"]})
    else: result.add(newJNull())
  for index in 0 ..< 6:
    if index < room["patrol"].len:
      result.add(%*{"intent": "move_to", "at": room["patrol"][index]["id"]})
    else: result.add(newJNull())
  let objects = view["objects"]
  let ownLock = if view["role"].getStr() == "hider": "hiders"
    else: "seekers"
  for kind in ["lock", "unlock", "vault", "push", "push_far"]:
    for index in 0 ..< MaxObjects:
      if index >= objects.len:
        result.add(newJNull())
        continue
      let obj = objects[index]
      let lock = obj["locked"].getStr()
      let holder = obj["held_by"]
      let available = holder.kind == JNull or
        holder.getStr() == view["you"].getStr()
      let canTouch = lock == "none" or lock == ownLock
      let legal = case kind
        of "lock": lock == "none"
        of "unlock": lock == ownLock
        of "vault": obj["kind"].getStr() == "ramp"
        else: available and canTouch
      if not legal:
        result.add(newJNull())
        continue
      var action = %*{"intent": (if kind == "push_far": "push" else: kind),
        "object": obj["id"]}
      if kind == "push":
        let box = obj["box"]
        let x = box[0].getInt() + box[2].getInt() div 2
        let y = box[1].getInt() + box[3].getInt() div 2
        var best = high(int)
        for door in room["doors"]:
          let at = door["at"]
          let dx = x - at[0].getInt()
          let dy = y - at[1].getInt()
          if dx * dx + dy * dy < best:
            best = dx * dx + dy * dy
            action["to"] = at
      elif kind == "push_far":
        let box = obj["box"]
        let x = box[0].getInt() + box[2].getInt() div 2
        let y = box[1].getInt() + box[3].getInt() div 2
        var best = -1
        for pocket in room["pockets"]:
          let at = pocket["at"]
          let dx = x - at[0].getInt()
          let dy = y - at[1].getInt()
          if dx * dx + dy * dy > best:
            best = dx * dx + dy * dy
            action["to"] = at
      result.add(action)
  doAssert result.len == ActionCount

proc values*(view: JsonNode): JsonNode =
  result = newJArray()
  for role in ["hider", "seeker"]:
    result.add(%(if view["role"].getStr() == role: 1 else: 0))
  for phase in ["prep", "hunt"]:
    result.add(%(if view["phase"].getStr() == phase: 1 else: 0))
  for field in ["game", "of", "turn", "turns"]: result.add(view[field])
  let clock = view["clock"]
  for field in ["phase_left_s", "hunt_len_s"]: result.add(clock[field])
  let own = view["you_at"]
  for coordinate in own["pos"]: result.add(coordinate)
  result.add(own["aim"])
  result.add(%(if own["airborne"].getBool(): 1 else: 0))
  result.add(%(if own["holding"].kind == JString: 1 else: 0))
  let exposure = view["exposure"]
  for field in ["team_seen_ticks", "team_hidden_ticks", "margin",
                "you_seen_ticks", "hunt_ticks_left"]: result.add(exposure[field])
  result.add(%(if exposure["seen_now"].getBool(): 1 else: 0))
  let fort = view["fort"]
  for field in ["locked_by_us", "locked_by_them"]: result.add(fort[field])
  let room = view["room"]
  for name in ["warren", "atrium", "long_hall"]:
    result.add(%(if room["name"].getStr() == name: 1 else: 0))
  for field in ["w", "h", "keep_clear_px"]: result.add(room[field])
  for index in 0 ..< 16:
    if index < room["walls"].len:
      for coordinate in room["walls"][index]: result.add(coordinate)
    else:
      for _ in 0 ..< 4: result.add(%(-1))
  for index in 0 ..< 5:
    if index < room["doors"].len:
      for coordinate in room["doors"][index]["at"]:
        result.add(coordinate)
    else:
      for _ in 0 ..< 2: result.add(%(-1))
  for index in 0 ..< 6:
    if index < room["regions"].len:
      for coordinate in room["regions"][index]["box"]:
        result.add(coordinate)
    else:
      for _ in 0 ..< 4: result.add(%(-1))
  for index in 0 ..< 8:
    if index < room["pockets"].len:
      for coordinate in room["pockets"][index]["at"]:
        result.add(coordinate)
    else:
      for _ in 0 ..< 2: result.add(%(-1))
  for index in 0 ..< 6:
    if index < room["patrol"].len:
      for coordinate in room["patrol"][index]["at"]:
        result.add(coordinate)
    else:
      for _ in 0 ..< 2: result.add(%(-1))
  for index in 0 ..< MaxObjects:
    if index < view["objects"].len:
      let obj = view["objects"][index]
      result.add(%1)
      for kind in ["crate", "panel", "ramp"]:
        result.add(%(if obj["kind"].getStr() == kind: 1 else: 0))
      for coordinate in obj["box"]: result.add(coordinate)
      for lock in ["none", "hiders", "seekers"]:
        result.add(%(if obj["locked"].getStr() == lock: 1 else: 0))
      result.add(%(if obj["held_by"].kind == JString: 1 else: 0))
    else:
      for _ in 0 ..< 12: result.add(%(-1))
  for index in 0 ..< 2:
    if index < view["teammates"].len:
      for coordinate in view["teammates"][index]["pos"]:
        result.add(coordinate)
      result.add(%(if view["teammates"][index]["holding"].kind == JString:
        1 else: 0))
    else:
      for _ in 0 ..< 3: result.add(%(-1))
  if view["seen_enemies"].len > 0:
    for coordinate in view["seen_enemies"][0]["pos"]:
      result.add(coordinate)
    result.add(view["seen_enemies"][0]["ticks_ago"])
  else:
    for _ in 0 ..< 3: result.add(%(-1))
