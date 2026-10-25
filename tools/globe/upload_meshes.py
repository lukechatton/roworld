#!/usr/bin/env python3
"""Static globe meshes (no EditableMesh budget at runtime): generated as glTF binaries, uploaded as
Model assets with the Open Cloud Assets API, then opened in Studio (InsertService:LoadAsset in the
Edit data model of our own place) to read the imported MeshPart's mesh id. Ids + the local bounds
the runtime needs are written to build/globe_meshes.json and merged into Assets/Globe.luau by
make_globe.py (write_manifest).

Meshes (globe radius R = 100 studs, lon 0 faces +Z, east +X, V = 0 at the north edge):
  patch_n   lon -180..-90, lat 90..0, 32 x 32 quads, UV 0..1 over the patch (rotate about Y by
            90 * i degrees for the other lon quarters)
  patch_s   lon -180..-90, lat 0..-90
  sphere    the whole sphere, 128 x 64 quads, equirect UV (seam duplicated)
  cap_n/s   polar discs |lat| >= 80 with azimuthal UVs
  moon      the moon (radius MOON_R0) MOON_K studs down local -Z, UVs equirect in WORLD directions for
            the moon frame CFrame.lookAt(origin, MOON_DIR) (up +Y), plus a speck at local z = +2. The
            runtime puts the local origin at the camera (SpaceSky): the part's bounds contain the camera.

Every globe mesh also carries two specks (0.01-stud triangles) at (-PAD, -PAD, -PAD) and (PAD, PAD,
PAD): Roblox skips objects whose bounds are farther than ~300 studs from the camera (measured in
Studio Play: parts culled whole, no per-pixel far clip), so every globe part's bounds must contain
the camera (<= 4 R from the centre).

Usage: .venv/bin/python tools/globe/upload_meshes.py [--studio-id ID]
The API key is read from .secrets/roblox_api_key and only sent in the x-api-key header.
"""
import argparse
import json
import math
import os
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "assets", "globe")
KEYFILE = os.path.join(ROOT, ".secrets", "roblox_api_key")
CACHE = os.path.join(ROOT, "build", "globe_meshes.json")
API = "https://apis.roblox.com/assets/v1"
CREATOR_USER_ID = "22641473"
R = 100.0
PAD = 450.0
MOON_DIR = (-0.61, 0.12, -0.79)
MOON_K = 1000.0
MOON_R0 = 10.0


def sphere_grid(lon0, lon1, lat0, lat1, nx, ny, radius=R, inset=0.0):
    """Vertices (pos, uv) and triangles for a lat/lon grid (a=(i,j), b=(i+1,j), c=(i,j+1)):
    (a, c, b), (b, c, d) — the same order as EditableMesh (PORT.md §5). Verified in Studio: the
    importer also turns the mesh 180 degrees about Y around its bounds centre (see GlobeLayer)."""
    pos, nrm, uv = [], [], []
    for j in range(ny + 1):
        lat = math.radians(lat0 + (lat1 - lat0) * j / ny)
        for i in range(nx + 1):
            lon = math.radians(lon0 + (lon1 - lon0) * i / nx)
            d = (math.cos(lat) * math.sin(lon), math.sin(lat), math.cos(lat) * math.cos(lon))
            pos.append(tuple(c * radius for c in d))
            nrm.append(d)
            uv.append((inset + (1 - 2 * inset) * i / nx, inset + (1 - 2 * inset) * j / ny))
    tris = []
    n = nx + 1
    for j in range(ny):
        for i in range(nx):
            a = j * n + i
            b, c = a + 1, a + n
            d = c + 1
            tris += [(a, c, b), (b, c, d)]
    return pos, nrm, uv, tris


# base patch UVs stay 1.5 texels (of 1024) inside the image: textures wrap, and the bilinear /
# mip filter at an edge would otherwise pull in the opposite edge (a light line along the equator)
PATCH_INSET = 1.5 / 1024


def polar_cap_mesh(sign, rings=24, segs=128, cap_lat=80.0, radius=R):
    """Disc of the sphere for |lat| >= cap_lat with azimuthal UVs (make_globe.polar_cap):
    u = 0.5 + 0.5 r sin(lon * sign), v = 0.5 - 0.5 r cos(lon * sign), r = (90 - |lat|) / (90 - cap)."""
    pos, nrm, uv = [], [], []
    for j in range(rings + 1):
        r = j / rings
        lat = math.radians(sign * (90.0 - r * (90.0 - cap_lat)))
        for i in range(segs + 1):
            lonr = math.radians(-180.0 + 360.0 * i / segs)
            d = (math.cos(lat) * math.sin(lonr), math.sin(lat), math.cos(lat) * math.cos(lonr))
            pos.append(tuple(c * radius for c in d))
            nrm.append(d)
            a = lonr * sign
            uv.append((0.5 + 0.5 * r * math.sin(a), 0.5 - 0.5 * r * math.cos(a)))
    tris = []
    n = segs + 1
    for j in range(rings):
        for i in range(segs):
            a = j * n + i
            b, c = a + 1, a + n
            d = c + 1
            # rows go from the pole outward: for the north cap that is southward (like the grid), for
            # the south cap northward — flip the winding there
            if sign > 0:
                tris += [(a, c, b), (b, c, d)]
            else:
                tris += [(a, b, c), (b, d, c)]
    return pos, nrm, uv, tris


def add_specks(pos, nrm, uv, tris, points):
    """Tiny triangles (0.01 stud) at `points`: they only widen the mesh bounds (sub-pixel)."""
    pos, nrm, uv, tris = list(pos), list(nrm), list(uv), list(tris)
    for p in points:
        base = len(pos)
        for d in ((0, 0, 0), (0.01, 0, 0), (0, 0.01, 0)):
            pos.append((p[0] + d[0], p[1] + d[1], p[2] + d[2]))
            nrm.append((0.0, 1.0, 0.0))
            uv.append((0.5, 0.5))
        tris.append((base, base + 1, base + 2))
    return pos, nrm, uv, tris


def moon_mesh(nx=48, ny=24):
    """Moon sphere in the moon frame (see the module doc)."""
    n = math.sqrt(sum(c * c for c in MOON_DIR))
    look = tuple(c / n for c in MOON_DIR)
    up0 = (0.0, 1.0, 0.0)
    right = (look[1] * up0[2] - look[2] * up0[1], look[2] * up0[0] - look[0] * up0[2], look[0] * up0[1] - look[1] * up0[0])
    rn = math.sqrt(sum(c * c for c in right))
    right = tuple(c / rn for c in right)
    up = (right[1] * look[2] - right[2] * look[1], right[2] * look[0] - right[0] * look[2], right[0] * look[1] - right[1] * look[0])
    back = tuple(-c for c in look)
    pos, nrm, uv, tris = sphere_grid(-180, 180, 90, -90, nx, ny, radius=1.0)
    dot = lambda a, b: a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    lp, ln = [], []
    for d in nrm:
        l = (dot(d, right), dot(d, up), dot(d, back))
        ln.append(l)
        lp.append((l[0] * MOON_R0, l[1] * MOON_R0, l[2] * MOON_R0 - MOON_K))
    return add_specks(lp, ln, uv, tris, [(0.0, 0.0, 2.0)])


def padded(geo):
    return add_specks(*geo, [(-PAD, -PAD, -PAD), (PAD, PAD, PAD)])


def write_glb(path, pos, nrm, uv, tris):
    pb = b"".join(struct.pack("<3f", *p) for p in pos)
    nb = b"".join(struct.pack("<3f", *p) for p in nrm)
    ub = b"".join(struct.pack("<2f", *p) for p in uv)
    ib = b"".join(struct.pack("<3I", *t) for t in tris)
    views, off, blob = [], 0, b""
    for data, target in ((pb, 34962), (nb, 34962), (ub, 34962), (ib, 34963)):
        views.append({"buffer": 0, "byteOffset": off, "byteLength": len(data), "target": target})
        blob += data
        off += len(data)
        pad = (-off) % 4
        blob += b"\0" * pad
        off += pad
    mn = [min(p[k] for p in pos) for k in range(3)]
    mx = [max(p[k] for p in pos) for k in range(3)]
    gl = {
        "asset": {"version": "2.0", "generator": "rofront tools/globe/upload_meshes.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": os.path.splitext(os.path.basename(path))[0]}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3}]}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": len(pos), "type": "VEC3", "min": mn, "max": mx},
            {"bufferView": 1, "componentType": 5126, "count": len(nrm), "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": len(uv), "type": "VEC2"},
            {"bufferView": 3, "componentType": 5125, "count": len(tris) * 3, "type": "SCALAR"},
        ],
        "bufferViews": views,
        "buffers": [{"byteLength": len(blob)}],
    }
    js = json.dumps(gl).encode()
    js += b" " * ((-len(js)) % 4)
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<I4s", len(js), b"JSON") + js)
        f.write(struct.pack("<I4s", len(blob), b"BIN\0") + blob)
    return {"center": [(a + b) / 2 for a, b in zip(mn, mx)], "size": [b - a for a, b in zip(mn, mx)]}


def _key():
    return open(KEYFILE).read().strip()


def _req(method, url, body=None, headers=None, timeout=120):
    h = {"x-api-key": _key()}
    h.update(headers or {})
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {url.split('?')[0]} -> HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:600]}")


def upload_model(path, name):
    boundary = "----rofront" + uuid.uuid4().hex
    meta = {"assetType": "Model", "displayName": name[:50], "description": "AIRFRONT globe mesh",
            "creationContext": {"creator": {"userId": CREATOR_USER_ID}}}
    data = open(path, "rb").read()
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\n"
        f"Content-Type: application/json\r\n\r\n".encode(), json.dumps(meta).encode(), b"\r\n",
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; "
        f"filename=\"{os.path.basename(path)}\"\r\nContent-Type: model/gltf-binary\r\n\r\n".encode(), data, b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ])
    _, op = _req("POST", API + "/assets", body, {"Content-Type": f"multipart/form-data; boundary={boundary}"}, 600)
    op_id = op.get("operationId") or op.get("path", "").split("/")[-1]
    delay = 1.0
    for _ in range(90):
        if op.get("done"):
            break
        time.sleep(delay)
        delay = min(delay * 1.5, 8.0)
        _, op = _req("GET", f"{API}/operations/{op_id}")
    if "error" in op or not op.get("done"):
        raise RuntimeError(f"upload {name} failed: {json.dumps(op)[:600]}")
    resp = op.get("response", {})
    return str(resp.get("assetId") or resp.get("path", "").split("/")[-1])


LOAD_LUAU = """
local InsertService = game:GetService("InsertService")
local out = {}
for name, id in %s do
	local ok, model = pcall(function() return InsertService:LoadAsset(tonumber(id)) end)
	if not ok then
		out[name] = "ERR " .. tostring(model)
	else
		local mp = model:FindFirstChildWhichIsA("MeshPart", true)
		out[name] = if mp then (mp.MeshId .. "|" .. tostring(mp.Size)) else "no meshpart"
		model:Destroy()
	end
end
return game:GetService("HttpService"):JSONEncode(out)
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--studio-id", default=os.environ.get("STUDIO_ID", ""))
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}
    specs = {
        "patch_n": (-180, -90, 90, 0, 32, 32),
        "patch_s": (-180, -90, 0, -90, 32, 32),
        "sphere": (-180, 180, 90, -90, 128, 64),
    }
    todo = {}
    specs["cap_n"] = ("cap", 1)
    specs["cap_s"] = ("cap", -1)
    specs["moon"] = ("moon", MOON_K, MOON_R0)
    for name, sp in specs.items():
        path = os.path.join(OUT, f"mesh_{name}.glb")
        if sp[0] == "moon":
            geo = moon_mesh()
        else:
            inset = PATCH_INSET if name.startswith("patch") else 0.0
            geo = padded(polar_cap_mesh(sp[1]) if sp[0] == "cap" else sphere_grid(*sp, inset=inset))
        bounds = write_glb(path, *geo)
        key = json.dumps([sp, bounds, "winding-acb-v4-pad"] + (["inset", PATCH_INSET] if name.startswith("patch") else []))
        if cache.get(name, {}).get("key") == key and cache[name].get("mesh_id"):
            continue
        if cache.get(name, {}).get("key") == key and cache[name].get("model_id"):
            todo[name] = cache[name]["model_id"]  # uploaded, mesh id not read yet
            continue
        model_id = upload_model(path, f"AF globe {name}")
        cache[name] = {"key": key, "model_id": model_id, "center": bounds["center"], "size": bounds["size"]}
        todo[name] = model_id
        print("uploaded", name, "model", model_id)
    json.dump(cache, open(CACHE, "w"), indent=1)
    if todo:
        if not args.studio_id:
            sys.exit("need --studio-id (our own Studio place) to read the imported mesh ids")
        lua = LOAD_LUAU % ("{" + ", ".join(f'{k} = "{v}"' for k, v in todo.items()) + "}")
        env = dict(os.environ, STUDIO_ID=args.studio_id)
        res = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "studio.py"), "luau", "Edit", "-"],
                             input=lua.encode(), capture_output=True, env=env)
        txt = res.stdout.decode().strip()
        print(txt)
        got = json.loads(txt[txt.index("{"):])
        for k, v in got.items():
            if v.startswith("rbxassetid://") or v.startswith("http"):
                mesh, size = v.split("|")
                cache[k]["mesh_id"] = mesh
                cache[k]["import_size"] = size
        json.dump(cache, open(CACHE, "w"), indent=1)
    print(json.dumps({k: v.get("mesh_id") for k, v in cache.items()}, indent=1))


if __name__ == "__main__":
    main()
