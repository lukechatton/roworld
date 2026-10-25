#!/usr/bin/env python3
"""Captures the game a frame at a time for the trailer (2026-10-12: a trailer for the experience's details
page), from the Studio window's play session, with the
client's Studio-only film mode (src/client/Dev/Film.luau): each frame moves the game's time on by
exactly 1/FPS s and is captured once drawn (Studio MCP screen_capture), so footage plays back smooth.

As a module:
    f = Film(studio_id)
    f.diag("solo 1")                      # a dev command (src/client/Dev/SessionDiag.luau)
    f.diag("film start 30")
    f.frames("build/trailer/raw/shot1", 90, on_frame=lambda i: ...)   # 90 frames -> shot1/00000.jpg ...
    f.close()

The play session needs workspace attribute AF_DIAG (Studio) and the Dev folder synced
(tools/sync.py --full after a publish).
"""
import base64
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import studio  # noqa: E402

DIAG = r'''
local p = game:GetService("Players").LocalPlayer
p:SetAttribute("af_cmd_result", nil)
p:SetAttribute("af_cmd", %s)
local t0 = os.clock()
while p:GetAttribute("af_cmd_result") == nil and os.clock() - t0 < %f do task.wait(0.05) end
return tostring(p:GetAttribute("af_cmd_result"))
'''

STEP = r'''
local k = %d
workspace:SetAttribute("af_film_req", k)
local t0 = os.clock()
while workspace:GetAttribute("af_film_done") ~= k and os.clock() - t0 < 10 do task.wait() end
task.wait()
return tostring(workspace:GetAttribute("af_film_done") == k)
'''


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Film:
    def __init__(self, studio_id):
        self.c = studio.Client()
        self.sid = studio_id
        self.k = int(time.time()) % 1000000 * 10  # request numbers always grow

    def luau(self, code, ctx="Client"):
        res = self.c.call("execute_luau", {"studio_id": self.sid, "datamodel_type": ctx, "code": code})
        return studio.text_of(res)

    def diag(self, cmd, wait=10.0):
        return self.luau(DIAG % (lua_str(cmd), wait))

    def step(self):
        self.k += 1
        ok = self.luau(STEP % self.k)
        if "true" not in ok:
            raise RuntimeError("film step %d not acknowledged: %s" % (self.k, ok))

    def shot(self, path):
        res = self.c.call("screen_capture", {"studio_id": self.sid, "capture_id": "film"})
        for cont in res.get("content", []):
            if cont.get("type") == "image":
                with open(path, "wb") as fh:
                    fh.write(base64.b64decode(cont["data"]))
                return True
        raise RuntimeError("no image: " + studio.text_of(res))

    def frames(self, out_dir, n, on_frame=None, start=0):
        """n frames: step, capture. on_frame(i) runs before frame i is stepped (camera moves, commands)."""
        os.makedirs(out_dir, exist_ok=True)
        t0 = time.time()
        for i in range(start, start + n):
            if on_frame is not None:
                on_frame(i)
            self.step()
            self.shot(os.path.join(out_dir, "%05d.jpg" % i))
            if (i - start + 1) % 30 == 0:
                el = time.time() - t0
                print("  %s: %d/%d frames, %.2f s/frame" % (os.path.basename(out_dir), i - start + 1, n, el / (i - start + 1)), flush=True)

    def close(self):
        self.c.close()
