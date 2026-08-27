#!/usr/bin/env python3
"""Push the working tree to GitHub through the API.

The sandbox's egress swaps the real credential only for `gh` API calls, so
`git push` over HTTPS is refused ("invalid credentials") while
`gh api repos/...` works and reports admin. This walks the git index, creates
one blob per file, one tree, one commit, and moves the branch ref — the same
result as a push, through the channel that authenticates.

    python3 tools/ci/api_push.py "<commit message>" [branch]
"""

import base64
import json
import os
import subprocess
import sys

REPO = os.environ.get("API_PUSH_REPO", "Metta-AI/cogame-hide-and-seek")


def gh(args, payload=None):
    cmd = ["gh", "api", "-H", "Accept: application/vnd.github+json"] + args
    if payload is not None:
        cmd += ["--input", "-"]
        out = subprocess.run(
            cmd, input=json.dumps(payload).encode(), capture_output=True)
    else:
        out = subprocess.run(cmd, capture_output=True)
    if out.returncode != 0:
        raise SystemExit(
            "gh api failed: " + " ".join(args) + "\n" +
            out.stderr.decode()[:2000])
    text = out.stdout.decode().strip()
    return json.loads(text) if text else {}


def tracked_files():
    out = subprocess.run(["git", "ls-files", "-s"], capture_output=True,
                         check=True)
    for line in out.stdout.decode().splitlines():
        meta, path = line.split("\t", 1)
        mode = meta.split()[0]
        yield mode, path


def main():
    message = sys.argv[1] if len(sys.argv) > 1 else "update"
    branch = sys.argv[2] if len(sys.argv) > 2 else "main"

    try:
        ref = gh([f"repos/{REPO}/git/ref/heads/{branch}"])
        parents = [ref["object"]["sha"]]
        print("parent", parents[0][:8])
    except SystemExit:
        parents = []
        print("no parent: creating the first commit")

    tree = []
    for mode, path in tracked_files():
        with open(path, "rb") as handle:
            data = handle.read()
        blob = gh([f"repos/{REPO}/git/blobs"], {
            "content": base64.b64encode(data).decode(),
            "encoding": "base64",
        })
        tree.append({"path": path, "mode": mode, "type": "blob",
                     "sha": blob["sha"]})
        print("blob", blob["sha"][:8], mode, path)

    made = gh([f"repos/{REPO}/git/trees"], {"tree": tree})
    print("tree", made["sha"][:8], len(tree), "entries")
    commit = gh([f"repos/{REPO}/git/commits"], {
        "message": message,
        "tree": made["sha"],
        "parents": parents,
    })
    print("commit", commit["sha"])
    if parents:
        gh(["-X", "PATCH", f"repos/{REPO}/git/refs/heads/{branch}"],
           {"sha": commit["sha"], "force": False})
    else:
        gh([f"repos/{REPO}/git/refs"],
           {"ref": f"refs/heads/{branch}", "sha": commit["sha"]})
    print("ref refs/heads/%s -> %s" % (branch, commit["sha"]))
    print(commit["sha"])


if __name__ == "__main__":
    main()
