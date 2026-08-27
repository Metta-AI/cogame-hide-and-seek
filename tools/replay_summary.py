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

* the config JSON is recovered by BRACE-MATCHING (the technique the starter's
  AGENTS.md documents for prod forensics), trying each `{` in turn because the
  header's timestamp and length prefixes are binary and can hold a `{` byte;
* the CONTROL records — `register`, `directive`, `fallback`,
  `budget_guard`, `result` — are UTF-8 JSON objects embedded verbatim in the
  chat records, so they are recovered the same way, by scanning the remaining
  bytes for balanced `{"k":...}` objects.

Nothing here reads the RECORD framing, so it cannot drift when the record
framing changes; the fixed header prefix is read only to recover the
gameVersion, the one field with no self-describing text around it.
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


def find_config(data: bytes) -> tuple[dict, int]:
    """Recover the header's config object, and the index just past it.

    The bytes BEFORE the config are not all text: the header carries a
    wall-clock millisecond `u64` and two `u16` length prefixes, so roughly one
    recording in a hundred has a `{` (0x7B) inside one of them. Brace-matching
    from the FIRST `{` in the file then starts inside binary, runs off the end
    of the record stream and reports an empty replay. So try each candidate in
    turn and take the first that decodes to the config we recognise.
    """
    start = 0
    while True:
        at = data.find(b"{", start)
        if at < 0:
            return {}, 0
        obj, end = brace_match(data, at)
        if isinstance(obj, dict) and (
                "num_agents" in obj or "seed" in obj or "players" in obj):
            return obj, end
        start = at + 1


def read_game_version(data: bytes) -> str:
    """Read the header's gameVersion string.

    The one place the framing IS read, because it is the one field with no
    self-describing text around it: `magic(8) + formatVersion(u16) +
    len(u16)+gameName + len(u16)+gameVersion`. Scanning for a digit run
    instead would append whatever byte of the following wall-clock timestamp
    happens to be an ASCII digit ("1" reading as "18").
    """
    if not data.startswith(b"COWLDHNS"):
        return ""
    at = 8 + 2
    field = b""
    for _ in range(2):
        if at + 2 > len(data):
            return ""
        size = int.from_bytes(data[at:at + 2], "little")
        at += 2
        field = data[at:at + size]
        at += size
    return field.decode("utf-8", "replace")


def summarise(path: str) -> dict:
    data = open(path, "rb").read()
    protocol = "hide-and-seek/v1"
    game_version = read_game_version(data)
    config, cursor = find_config(data)

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
