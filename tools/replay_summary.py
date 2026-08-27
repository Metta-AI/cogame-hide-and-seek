#!/usr/bin/env python3
"""Summarise a hide-and-seek `.replay` as one strict-UTF-8 JSON object.

Python 3 standard library only: no Nim, no Docker, no emsdk. This is the JSON
view of the binary `COWLDHNS` replay the static wasm viewer parses, and it is
what phase 60's definition-of-done check reads instead of `jq .` on the raw
bytes:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                  # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.gameMargins' /tmp/ep.json
    jq -r '[.orders[]|select(.source=="llm")]|length, .fallbacks, (.radio|length)' /tmp/ep.json

The replay stays binary on purpose: a JSON replay would mean rewriting
replays.nim, replay_runtime.nim, static_replay_worker.js and
wasm_replay_smoke.cjs — the machinery this fork exists to reuse.

How it reads the file WITHOUT a decoder for the whole record stream:

* the header is ASCII up to the config JSON, so the config is recovered by
  BRACE-MATCHING from the first `{` (the technique the starter's AGENTS.md
  documents for prod forensics);
* the CONTROL records — `register`, `directive`, `fallback`,
  `budget_guard`, `result` — are UTF-8 JSON objects embedded verbatim in the
  chat records, so they are recovered the same way, by scanning the remaining
  bytes for balanced `{"k":...}` objects.

Nothing here needs the record framing, so it cannot drift when the framing
changes; it only needs the two things that are text.
"""

from __future__ import annotations

import json
import sys


def brace_match(data: bytes, start: int) -> tuple[dict | None, int]:
    """Decode one balanced ``{...}`` starting at ``start``.

    Returns ``(obj, end)`` where ``end`` is the index just past the object, or
    ``(None, start + 1)`` when the bytes there are not a decodable object.
    """
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(data)):
        ch = data[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == 0x5C:      # backslash
                escaped = True
            elif ch == 0x22:      # quote
                in_string = False
            continue
        if ch == 0x22:
            in_string = True
        elif ch == 0x7B:          # {
            depth += 1
        elif ch == 0x7D:          # }
            depth -= 1
            if depth == 0:
                chunk = data[start:i + 1]
                try:
                    return json.loads(chunk.decode("utf-8")), i + 1
                except (UnicodeDecodeError, json.JSONDecodeError):
                    return None, start + 1
        elif depth == 0:
            # A stray byte before any brace: not the start of an object.
            return None, start + 1
    return None, len(data)


def summarise(path: str) -> dict:
    data = open(path, "rb").read()
    header = data[:64]
    protocol = "hide-and-seek/v1"
    game_version = ""
    # The header is `magic + format version + gameName + gameVersion` before the
    # config; recover the version as the ASCII run right after the game name.
    try:
        head_text = header.decode("latin-1")
        # Split AFTER the magic ("COWLDHNS" itself ends in the game name), so
        # the digit scan runs from the gameName+gameVersion region.
        if "COWLDHNS" in head_text:
            head_text = head_text.split("COWLDHNS", 1)[1]
        if "hide-and-seek" in head_text:
            tail = head_text.split("hide-and-seek", 1)[1]
            digits = ""
            for ch in tail:
                if ch.isdigit():
                    digits += ch
                elif digits:
                    break
            game_version = digits
    except Exception:                                   # noqa: BLE001
        pass

    first = data.find(b"{")
    config: dict = {}
    cursor = 0
    if first >= 0:
        config, cursor = brace_match(data, first)
        config = config or {}

    directives: list[dict] = []
    fallbacks = 0
    registers: list[dict] = []
    budget_guards = 0
    stops: list[dict] = []
    results: dict = {}
    i = cursor
    while True:
        i = data.find(b'{"k":', i)
        if i < 0:
            break
        obj, nxt = brace_match(data, i)
        i = nxt
        if not isinstance(obj, dict):
            continue
        kind = obj.get("k")
        if kind == "directive":
            directives.append(obj)
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append(obj)
        elif kind == "budget_guard":
            budget_guards += 1
        elif kind == "result":
            results = obj.get("results", obj)
        elif kind == "stop":
            stops.append(obj)

    names = [p.get("name", "") for p in (config.get("players") or [])]
    seats = int(config.get("num_agents") or 6)
    identities = ("alpha", "beta", "gamma", "delta", "epsilon", "zeta")
    # Slot parity deals the sides in GAME 1, and the identity is fixed to the
    # SEAT for the whole episode: slots 0 and 1 are alpha, 2 and 3 beta, ...
    aliases = [
        ("HIDER" if slot % 2 == 0 else "SEEKER") + "-" + identities[
            (slot // 2) % len(identities)]
        for slot in range(seats)
    ]
    room = config.get("roomPool") or ""
    spec = config.get("mapSpec") or {}
    if isinstance(spec, dict) and spec.get("name"):
        room = spec["name"]
    if isinstance(results, dict) and results.get("room"):
        room = results["room"]

    ticks = 0
    if isinstance(results, dict) and isinstance(results.get("finalTick"), int):
        ticks = results["finalTick"]

    return {
        "protocol": protocol,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "room": room,
        "names": names,
        "aliases": aliases,
        "policyKinds": [r.get("kind", "") for r in registers],
        "tickCount": ticks,
        "orders": directives,
        "radio": [d["radio"] for d in directives if d.get("radio")],
        "shouts": [d["say"] for d in directives if d.get("say")],
        "fallbacks": fallbacks,
        "budgetGuards": budget_guards,
        "stops": stops,
        "results": results,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: replay_summary.py <path.replay>", file=sys.stderr)
        return 2
    out = summarise(argv[1])
    # ensure_ascii=False keeps a non-ASCII policy label or note as real UTF-8,
    # which is exactly what the strict-parse check downstream is testing.
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
