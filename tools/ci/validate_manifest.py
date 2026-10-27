#!/usr/bin/env python3
"""Load `coworld_manifest_template.json` through the INSTALLED coworld CLI's
own loader (design note test 34; r1 F15).

`coworld build` runs only at release time, so until this step existed nothing
in CI ran the code the platform will run on the manifest: a template that the
repo's own `tests/test_hns_manifest.nim` is happy with can still be rejected by
`validate_upload_manifest` for a rule the Nim test does not know about (0.1.42
wants `game.replay_viewer`, no top-level `version`, no `game.display_name`,
`game.owner` required, no runner-managed `tokens` -- the collab-cooking
2026-08-25 scar). This calls `_load_template_manifest`, which substitutes the
compose image placeholders and then calls `validate_upload_manifest` itself.

The compose services are read with PyYAML rather than `docker compose config`
so the check needs no docker and can run in the `test` job.

    python3 tools/ci/validate_manifest.py
"""

import json
import sys

import yaml
from jsonschema import ValidationError, validate
from coworld.bundle import _load_template_manifest


def validate_controller_results(schema: dict) -> None:
    """Exercise result validation for every controller emitted by policyKind."""
    result = {
        "names": [f"policy-{i}" for i in range(6)],
        "aliases": ["HIDER-alpha", "SEEKER-alpha", "HIDER-beta",
                    "SEEKER-beta", "HIDER-gamma", "SEEKER-gamma"],
        "team": ["hiders", "seekers"] * 3,
        "scores": [0.0] * 6,
        "win": [False] * 6,
        "reason": "complete",
        "endRule": "full_time",
        "games": 2,
    }
    for kind in ("llm", "scripted", "external"):
        result["policyKinds"] = [kind] * 6
        validate(result, schema)
    result["policyKinds"] = ["llm", "external", "scripted"] * 2
    validate(result, schema)
    result["policyKinds"][0] = "unknown-controller"
    try:
        validate(result, schema)
    except ValidationError:
        pass
    else:
        raise AssertionError("results schema accepted an unknown controller kind")


def main() -> int:
    template = json.load(open("coworld_manifest_template.json"))
    validate_controller_results(template["game"]["results_schema"])
    compose = yaml.safe_load(open("compose.yaml"))
    placeholders = {
        "{{%s_IMAGE}}" % name.upper().replace("-", "_"): service["image"]
        for name, service in compose["services"].items()
    }
    manifest = _load_template_manifest(template, "0.0.0", placeholders)
    name = getattr(getattr(manifest, "game", None), "name", "?")
    print(f"manifest OK under the installed coworld CLI: {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
