#!/usr/bin/env python3
"""Renders for the Arsenal's shop cards (2026-10-04): item renders, so the cards' images and backgrounds
are less plain.

Each item is a 3D model generated in Studio (Roblox's text-to-mesh, MODELS below: the published
model asset of each and the start of the prompt that made it). The first set was toy-style on
purpose ("a giant chubby cartoon rocket") and came out too childlike (2026-10-05). This set is
military hardware (dark steel, hazard stripes, a jet, an armoured soldier), photographed as metal
under a low sun with the sky reflected in it.
This script photographs them in a Studio window in Edit mode and cuts them out:

  1. the model alone at the origin, lit, in front of a big flat unlit backdrop; one capture with
     the backdrop white and one with it black (tools/studio.py shot);
  2. difference matting: alpha = 1 - (white - black) / (backdrop white - backdrop black), colour =
     the black capture / alpha -- an exact cut-out with soft edges, whatever the model's colours;
  3. cropped, scaled to fit RENDER_PX, saved as assets/arsenal/renders/<key>.png, and shown together
     on build/arsenal_renders_sheet.png.

The window's Lighting is put back afterwards (the game needs its flat lighting). The models must be
in the window's Workspace (names starting with MODELS[key].name); --insert adds the missing ones
from their asset ids first. Upload with tools/assets/make_arsenal_art.py --upload.

Usage: STUDIO_MATCH=<place>.rbxl .venv/bin/python tools/assets/make_arsenal_renders.py [--only key,key]
"""
import argparse
import os
import subprocess
import sys

import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "arsenal", "renders")
TMP = os.path.join(ROOT, "build", "arsenal_renders")
PY = os.path.join(ROOT, ".venv", "bin", "python")
STUDIO = os.path.join(ROOT, "tools", "studio.py")
RENDER_PX = 384

# key -> the generated model: the start of its name in the Workspace, its published model asset,
# and how it is turned for the photograph (yaw, pitch in degrees; zoom > 1 = closer)
# metal: False for cloth and skin (the rest is photographed as metal); squad: the model stands
# three times, in a wedge; gain: its colours are multiplied (a model too dark for a dark card)
MODELS = {
    "mega": {"name": "massive heavy doomsday missile", "asset": 140147347197976, "yaw": 20, "pitch": 0, "roll": -16},
    "scatter": {"name": "realistic MIRV cluster", "asset": 124553848020361, "yaw": 30, "pitch": 0, "roll": -14},
    "reinforce": {"name": "one elite commando", "asset": 108690433470316, "yaw": 196, "pitch": 0, "metal": False, "squad": 3},
    "artillery": {"name": "realistic self-propelled heavy artillery", "asset": 112552977969618, "yaw": 225, "pitch": 0},
    "airfield": {"name": "realistic stealth bomber", "asset": 128851381282933, "yaw": 140, "pitch": 0, "roll": 10, "gain": 1.5},
    "railgun": {"name": "futuristic military railgun", "asset": 106015106387234, "yaw": 30, "pitch": 0},
    "stars2x": {"name": "military general's rank insignia", "asset": 124545561339246, "yaw": 15, "pitch": 0},
    "reload2x": {"name": "open military ammunition crate", "asset": 86144658933946, "yaw": 225, "pitch": 0},
}

SETUP = r'''
local Lighting = game:GetService("Lighting")
local key, prefix, yaw, pitch, roll, shade, metal, squad = "%s", "%s", %f, %f, %f, "%s", %s, %d
if workspace:GetAttribute("AR_saved") == nil then
	workspace:SetAttribute("AR_saved", string.format("%%f|%%f|%%f|%%s|%%s", Lighting.Brightness, Lighting.ClockTime,
		Lighting.EnvironmentDiffuseScale, tostring(Lighting.Ambient), tostring(Lighting.OutdoorAmbient)))
end
-- a low sun over a dim ambient, and the sky reflected in the metal
Lighting.Brightness = 3.2
Lighting.ClockTime = 15.6
Lighting.GeographicLatitude = 35
Lighting.Ambient = Color3.fromRGB(62, 66, 82)
Lighting.OutdoorAmbient = Color3.fromRGB(78, 84, 104)
Lighting.EnvironmentDiffuseScale = 0
Lighting.EnvironmentSpecularScale = 1
Lighting.GlobalShadows = false
-- (bloom would spill the white backdrop over the model's edge)
for _, e in Lighting:GetChildren() do
	if e:IsA("PostEffect") and e.Enabled then
		e.Enabled = false
		e:SetAttribute("AR_off", true)
	end
end
game:GetService("Selection"):Set({})
local old = workspace:FindFirstChild("AR_subject")
if old then
	old:Destroy()
end
local target = nil
for _, c in workspace:GetChildren() do
	if c:IsA("Model") then
		if string.sub(c.Name, 1, #prefix) == prefix then
			target = c
		else
			c:PivotTo(CFrame.new(0, -5000, 0))
		end
	end
end
if target == nil then
	return "missing " .. key
end
for _, d in target:GetDescendants() do
	if d:IsA("BasePart") then
		d.Anchored = true
		d.CastShadow = false
		d.Material = if metal then Enum.Material.Metal else Enum.Material.Plastic
	end
end
if squad > 1 then
	-- the one model three times: a leader and two behind its shoulders
	local _, s = target:GetBoundingBox()
	local spots = { Vector3.zero, Vector3.new(-s.X * 0.78, 0, s.Z * 1.1), Vector3.new(s.X * 0.78, 0, s.Z * 1.1) }
	local group = Instance.new("Model")
	group.Name = "AR_subject"
	target:PivotTo(CFrame.new())
	for i = 1, squad do
		local c = target:Clone()
		c:PivotTo(CFrame.new(spots[i]))
		c.Parent = group
	end
	group.Parent = workspace
	target:PivotTo(CFrame.new(0, -5000, 0))
	target = group
end
target:PivotTo(CFrame.new())
local _, size0 = target:GetBoundingBox()
target:PivotTo(CFrame.Angles(0, math.rad(yaw), 0) * CFrame.Angles(math.rad(pitch), 0, math.rad(roll)))
local cf, size = target:GetBoundingBox()
target:PivotTo(target:GetPivot() - cf.Position)
local radius = size0.Magnitude / 2
local cam = workspace.CurrentCamera
cam.FieldOfView = 20
local dir = Vector3.new(0.0, 0.32, 1).Unit
local dist = radius / math.sin(math.rad(10)) * 1.08
cam.CFrame = CFrame.lookAt(dir * dist, Vector3.zero)
cam.Focus = CFrame.new()
local back = workspace:FindFirstChild("AR_backdrop")
if back == nil then
	back = Instance.new("Part")
	back.Name = "AR_backdrop"
	back.Anchored = true
	back.CastShadow = false
	back.Material = Enum.Material.Neon
	back.Size = Vector3.new(600, 600, 1)
	back.Parent = workspace
end
back.CFrame = CFrame.lookAt(-dir * 80, Vector3.zero)
back.Color = if shade == "white" then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
return "ok " .. key .. " " .. shade .. " r=" .. string.format("%%.1f", radius)
'''

RESTORE = r'''
local Lighting = game:GetService("Lighting")
local s = workspace:GetAttribute("AR_saved")
if s ~= nil then
	Lighting.Brightness = 0
	Lighting.ClockTime = 12
	Lighting.EnvironmentDiffuseScale = 0
	Lighting.EnvironmentSpecularScale = 0
	Lighting.Ambient = Color3.new(1, 1, 1)
	Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
	Lighting.GlobalShadows = false
	workspace:SetAttribute("AR_saved", nil)
end
for _, e in Lighting:GetChildren() do
	if e:GetAttribute("AR_off") then
		e.Enabled = true
		e:SetAttribute("AR_off", nil)
	end
end
for _, name in { "AR_backdrop", "AR_subject" } do
	local b = workspace:FindFirstChild(name)
	if b then
		b:Destroy()
	end
end
local i = 0
for _, c in workspace:GetChildren() do
	if c:IsA("Model") then
		c:PivotTo(CFrame.new(i * 14, 20, 0))
		i += 1
	end
end
return "restored"
'''


def setup(key, shade):
    m = MODELS[key]
    metal = "true" if m.get("metal", True) else "false"
    return SETUP % (key, m["name"], m.get("yaw", 0), m.get("pitch", 0), m.get("roll", 0), shade, metal, m.get("squad", 1))


def luau(code):
    p = subprocess.run([PY, STUDIO, "luau", "Edit", "-"], input=code, capture_output=True, text=True)
    return (p.stdout + p.stderr).strip()


def shot(path):
    subprocess.run([PY, STUDIO, "shot", path], capture_output=True, text=True, check=True)


def matte(white_path, black_path, gain=1.0):
    w = np.asarray(Image.open(white_path).convert("RGB"), dtype=np.float64) / 255.0
    b = np.asarray(Image.open(black_path).convert("RGB"), dtype=np.float64) / 255.0
    # the backdrop's own colours, from the frame's corners
    h, wd = w.shape[:2]
    k = 24
    wb = np.median(np.concatenate([w[:k, :k].reshape(-1, 3), w[:k, -k:].reshape(-1, 3)]), axis=0)
    bb = np.median(np.concatenate([b[:k, :k].reshape(-1, 3), b[:k, -k:].reshape(-1, 3)]), axis=0)
    span = np.maximum(wb - bb, 1e-3)
    alpha = 1.0 - np.clip(((w - b) / span).mean(axis=2), 0.0, 1.0)
    alpha = np.clip((alpha - 0.04) / 0.92, 0.0, 1.0)  # (JPEG noise off the backdrop; solid insides)
    rgb = np.clip((b - bb * (1.0 - alpha[..., None])) / np.maximum(alpha[..., None], 1e-3), 0.0, 1.0)
    out = np.dstack([np.clip(rgb * gain, 0.0, 1.0), alpha])
    img = Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")
    # the model's box: from a coarse copy, so a stray speck of the mesh (text-to-mesh leaves some)
    # neither widens the frame nor stays in it
    k = 8
    hc, wc = h // k, wd // k
    coarse = alpha[: hc * k, : wc * k].reshape(hc, k, wc, k).mean(axis=(1, 3)) > 0.35
    solid = coarse.copy()
    solid[1:-1, 1:-1] &= coarse[:-2, 1:-1] | coarse[2:, 1:-1] | coarse[1:-1, :-2] | coarse[1:-1, 2:]
    ys, xs = np.nonzero(solid)
    if len(xs) == 0:
        return None
    ys, xs = ys * k, xs * k
    pad = 6 + k
    box = (max(xs.min() - pad, 0), max(ys.min() - pad, 0), min(xs.max() + k + pad, wd), min(ys.max() + k + pad, h))
    img = img.crop(box)
    s = RENDER_PX / max(img.size)
    return img.resize((max(1, round(img.size[0] * s)), max(1, round(img.size[1] * s))), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    args = ap.parse_args()
    only = {s for s in args.only.split(",") if s}
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(TMP, exist_ok=True)
    done = []
    try:
        for key, m in MODELS.items():
            if only and key not in only:
                continue
            paths = {}
            for shade in ("white", "black"):
                r = luau(setup(key, shade))
                if not r.startswith("ok"):
                    print(key, "->", r)
                    paths = None
                    break
                paths[shade] = os.path.join(TMP, f"{key}_{shade}.png")
                shot(paths[shade])
            if not paths:
                continue
            img = matte(paths["white"], paths["black"], m.get("gain", 1.0))
            if img is None:
                print(key, "-> nothing in frame")
                continue
            img.save(os.path.join(OUT, key + ".png"), optimize=True)
            done.append(key)
            print(key, img.size)
    finally:
        print(luau(RESTORE))
    keys = [k for k in MODELS if os.path.exists(os.path.join(OUT, k + ".png"))]
    sheet = Image.new("RGBA", (4 * 400, 2 * 400), (24, 30, 52, 255))
    for i, k in enumerate(keys):
        im = Image.open(os.path.join(OUT, k + ".png"))
        sheet.alpha_composite(im, ((i % 4) * 400 + (400 - im.size[0]) // 2, (i // 4) * 400 + (400 - im.size[1]) // 2))
    sheet.save(os.path.join(ROOT, "build", "arsenal_renders_sheet.png"))
    print("rendered", ", ".join(done), "-> build/arsenal_renders_sheet.png")


if __name__ == "__main__":
    main()
