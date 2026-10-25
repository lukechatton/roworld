#!/usr/bin/env python3
"""Build the shipping place with Rojo and publish it to Roblox via Open Cloud.

Usage:
  .venv/bin/python tools/publish.py --universe <universeId> --place <placeId> [--saved] [--meta]

  --saved   upload as a Saved version (not live) instead of Published
  --meta    also set the experience's display name and description (Open Cloud v2 universes)

IDs can also come from build/publish.json: {"universe": 123, "place": 456}.
The API key is read from .secrets/roblox_api_key (needs universe-places:write for that experience;
--meta needs universe:write). Never prints the key.

Before the first publish, in the Creator Dashboard (only the owner can do these):
  - the owner must be 13+ age verified and ID verified, then toggle "Enable Mesh / Image APIs"
    (Experience > Settings > Security) — the globe needs EditableImage/EditableMesh.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "airfront-release.rbxl")
TITLE = "Airfront"
DESCRIPTION = (
    "Real-time territory conquest on a 3D Earth. Start as a single nation and expand, attack, build "
    "cities, ports and factories, sail invasions, form alliances, and launch nukes against 88 real-world "
    "AI nations and hundreds of tribes. Conquer 80% of the world to win. Play solo at three difficulties "
    "or jump into a shared multiplayer match."
)


def key():
    return open(os.path.join(ROOT, ".secrets", "roblox_api_key")).read().strip()


def request(method, url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("x-api-key", key())
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--universe", type=int)
    ap.add_argument("--place", type=int)
    ap.add_argument("--saved", action="store_true")
    ap.add_argument("--meta", action="store_true")
    a = ap.parse_args()
    cfg_path = os.path.join(ROOT, "build", "publish.json")
    cfg = json.load(open(cfg_path)) if os.path.exists(cfg_path) else {}
    universe = a.universe or cfg.get("universe")
    place = a.place or cfg.get("place")
    if not universe or not place:
        sys.exit("need --universe and --place (or build/publish.json)")

    # release.project.json must be default.project.json + globIgnorePaths (Dev harnesses excluded).
    dev = json.load(open(os.path.join(ROOT, "default.project.json")))
    rel = json.load(open(os.path.join(ROOT, "release.project.json")))
    rel_cmp = {k: v for k, v in rel.items() if k != "globIgnorePaths"}
    if dev != rel_cmp:
        sys.exit("release.project.json drifted from default.project.json; copy the tree over first")
    subprocess.check_call([os.path.join(ROOT, ".bin", "rojo"), "build", "release.project.json", "-o", OUT], cwd=ROOT)
    data = open(OUT, "rb").read()
    vtype = "Saved" if a.saved else "Published"
    status, body = request(
        "POST",
        f"https://apis.roblox.com/universes/v1/{universe}/places/{place}/versions?versionType={vtype}",
        data, {"Content-Type": "application/octet-stream"})
    print(f"place upload ({vtype}, {len(data) / 1e6:.1f} MB): HTTP {status} {body[:300]}")
    if status != 200:
        sys.exit(1)

    if a.meta:
        payload = json.dumps({"displayName": TITLE, "description": DESCRIPTION}).encode()
        status, body = request(
            "PATCH",
            f"https://apis.roblox.com/cloud/v2/universes/{universe}?updateMask=displayName,description",
            payload, {"Content-Type": "application/json"})
        print(f"universe metadata: HTTP {status} {body[:300]}")


if __name__ == "__main__":
    main()
