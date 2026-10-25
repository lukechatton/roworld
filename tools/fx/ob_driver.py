#!/usr/bin/env python3
"""Drive the overlays-b dev harness (src/client/Dev/OverlaysB.luau) in the overlaysb Studio place:
sync, set the scene attributes, start Play, capture a screenshot for every AF_OB_SHOT marker the
harness raises, print the harness's [OB] lines, stop Play.

Usage: STUDIO_ID=<id> .venv/bin/python tools/fx/ob_driver.py <scenes> [--ts 1.0] [--out DIR]
       [--timeout 300] [--no-sync]
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import studio  # noqa: E402


def luau(c, sid, dm, code):
    res = c.call("execute_luau", {"code": code, "datamodel_type": dm, "studio_id": sid})
    return studio.text_of(res)


def shot(c, sid, path):
    res = c.call("screen_capture", {"studio_id": sid, "capture_id": "ob"})
    for cont in res.get("content", []):
        if cont.get("type") == "image":
            with open(path, "wb") as f:
                f.write(base64.b64decode(cont["data"]))
            return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenes")
    ap.add_argument("--ts", type=float, default=1.0)
    ap.add_argument("--out", default="/private/tmp/airfront-shots/rofront-overlaysb")
    ap.add_argument("--timeout", type=float, default=300)
    ap.add_argument("--no-sync", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    if not a.no_sync:
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sync.py")], check=True, stdout=subprocess.DEVNULL)
    c = studio.Client()
    try:
        sid = studio.pick_studio(c)
        luau(c, sid, "Edit", f'workspace:SetAttribute("AF_DEV","OverlaysB"); workspace:SetAttribute("AF_OB_SCENE",{json.dumps(a.scenes)}); workspace:SetAttribute("AF_OB_TS",{a.ts}); return "ok"')
        c.call("start_stop_play", {"is_start": True, "studio_id": sid})
        t0 = time.time()
        seen = set()
        done = False
        while time.time() - t0 < a.timeout:
            try:
                txt = luau(c, sid, "Client", 'return {workspace:GetAttribute("AF_OB_SHOT") or "", workspace:GetAttribute("AF_OB_DONE") == true}')
                data = json.loads(txt)
            except Exception:
                time.sleep(0.5)
                continue
            tag = data.get("1", "") if isinstance(data, dict) else data[0]
            done = data.get("2", False) if isinstance(data, dict) else data[1]
            if tag and tag not in seen:
                seen.add(tag)
                name = tag.split("#")[0]
                path = os.path.join(a.out, name + ".png")
                ok = shot(c, sid, path)
                luau(c, sid, "Client", f'workspace:SetAttribute("AF_OB_ACK", {json.dumps(tag)}); return "ok"')
                print(("shot " if ok else "SHOT FAILED ") + path, flush=True)
            if done:
                break
            time.sleep(0.03)
        out = studio.text_of(c.call("get_console_output", {"studio_id": sid}))
        for line in out.splitlines():
            if "[OB]" in line or "rror" in line or "Stack" in line or "Script '" in line:
                print(line)
        c.call("start_stop_play", {"is_start": False, "studio_id": sid})
        print("done" if done else "TIMEOUT")
    finally:
        c.close()


if __name__ == "__main__":
    main()
