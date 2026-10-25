#!/usr/bin/env python3
"""Convert AIRFRONT's audio to Roblox-ready files, upload them with Open Cloud, write the manifest.

Sources (never modified): ~/games/airfront/assets/audio/sfx/*.wav      (29 one-shots)
                          ~/games/airfront/assets/audio/music/theme_{menu,war}.wav  (seamless loops)
Outputs: assets/audio/{sfx,music}/<name>.flac   lossless (bit-exact PCM, same loudness, loop points
                                                 intact: FLAC has no encoder delay/padding)
         build/audio_cache.json                  {cache_key: {asset_id, name, state, ...}}
         src/shared/Assets/Audio.luau            manifest (see build/notes/assets.md)

Upload: Open Cloud Assets API (POST https://apis.roblox.com/assets/v1/assets, assetType "Audio",
creator userId 22641473), then the returned operation is polled until done and the asset's
moderation state is read back. The API key is read from .secrets/roblox_api_key and only ever sent
in the x-api-key header — never printed or logged. The cache key is sha256(source WAV) + the
conversion settings, so re-running re-uploads only sounds whose source changed.

Monthly audio-upload quotas: `--sprite` packs every SFX into one "audio sprite" file (0.5 s silent
gaps) and the manifest then gives {sprite, start, stop, length} per sound for Sound.PlaybackRegion.

Usage:
  .venv/bin/python tools/assets/upload_audio.py                 # convert + upload missing + manifest
  .venv/bin/python tools/assets/upload_audio.py --only ui_click  # just some sounds (keys, comma-sep)
  .venv/bin/python tools/assets/upload_audio.py --dry-run        # convert only, no network
  .venv/bin/python tools/assets/upload_audio.py --status         # refresh moderation state of cached ids
  .venv/bin/python tools/assets/upload_audio.py --sprite         # SFX as one sprite (quota fallback)
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.expanduser("~/games/airfront/assets/audio")
OUT = os.path.join(ROOT, "assets", "audio")
CACHE = os.path.join(ROOT, "build", "audio_cache.json")
KEYFILE = os.path.join(ROOT, ".secrets", "roblox_api_key")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "Audio.luau")
CREATOR_USER_ID = "22641473"
# --group <id> uploads as that group instead (for group-owned experiences); cache keys get a prefix.
CREATOR = {"userId": CREATOR_USER_ID}
CACHE_PREFIX = ""
API = "https://apis.roblox.com/assets/v1"
FORMAT = "flac-l12-v1"          # bump when conversion settings change (invalidates the cache)
SPRITE_GAP = 0.5                # seconds of silence between sprite regions
MUSIC = {"menu": "theme_menu", "war": "theme_war"}


# ------------------------------------------------------------------------------------------------
# sources / conversion
# ------------------------------------------------------------------------------------------------

def wav_info(path):
    with wave.open(path, "rb") as w:
        return {"rate": w.getframerate(), "channels": w.getnchannels(), "frames": w.getnframes(),
                "width": w.getsampwidth()}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sources():
    """[(group, key, wav_path)] — group 'music' or 'sfx'."""
    out = [("music", k, os.path.join(SRC, "music", f + ".wav")) for k, f in MUSIC.items()]
    d = os.path.join(SRC, "sfx")
    out += [("sfx", f[:-4], os.path.join(d, f)) for f in sorted(os.listdir(d)) if f.endswith(".wav")]
    return out


def convert(wav, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-map_metadata", "-1", "-c:a", "flac",
                    "-compression_level", "12", dst], check=True)
    return dst


def sources_sfx():
    return [(k, w) for g, k, w in sources() if g == "sfx"]


def build_sprite(sfx):
    """Concatenate SFX (upmixed to stereo) with silent gaps. Returns (flac_path, regions, cache_key)."""
    import numpy as np
    rate = 44100
    parts, regions, t = [], {}, 0.0
    gap = np.zeros((int(SPRITE_GAP * rate), 2), np.int16)
    h = hashlib.sha256(FORMAT.encode() + b"sprite")
    for key, wav in sfx:
        info = wav_info(wav)
        assert info["rate"] == rate and info["width"] == 2, wav
        with wave.open(wav, "rb") as w:
            a = np.frombuffer(w.readframes(info["frames"]), np.int16).reshape(-1, info["channels"])
        if a.shape[1] == 1:
            a = np.repeat(a, 2, axis=1)
        h.update(key.encode() + sha256(wav).encode())
        start = t
        parts += [a, gap]
        t += (len(a) + len(gap)) / rate
        regions[key] = (round(start, 6), round(start + len(a) / rate, 6), round(len(a) / rate, 6))
    pcm = np.concatenate(parts)
    tmp = os.path.join(OUT, "sfx_sprite.wav")
    os.makedirs(OUT, exist_ok=True)
    with wave.open(tmp, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    dst = convert(tmp, os.path.join(OUT, "sfx_sprite.flac"))
    os.remove(tmp)
    return dst, regions, h.hexdigest()


# ------------------------------------------------------------------------------------------------
# Open Cloud
# ------------------------------------------------------------------------------------------------

class ApiError(RuntimeError):
    pass


def _key():
    with open(KEYFILE) as f:
        return f.read().strip()


def _req(method, url, body=None, headers=None, timeout=120):
    """One API call. GETs are retried on network errors (timeouts, resets); a POST is not (it may
    have gone through: the caller decides)."""
    h = {"x-api-key": _key()}
    h.update(headers or {})
    tries = 5 if method == "GET" else 1
    for attempt in range(tries):
        req = urllib.request.Request(url, data=body, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            txt = e.read().decode("utf-8", "replace")
            raise ApiError(f"{method} {url.split('?')[0]} -> HTTP {e.code}: {txt[:600]}") from None
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            if attempt + 1 >= tries:
                raise ApiError(f"{method} {url.split('?')[0]} -> network error: {e}") from None
            time.sleep(2.0 * (attempt + 1))


def upload(path, display_name, description):
    return upload_wait(upload_start(path, display_name, description))


def upload_start(path, display_name, description, asset_type="Audio"):
    """POST the asset; returns the operation id (poll it with upload_wait). asset_type "Image" for
    PNG / JPEG images (tools/assets/make_flags.py)."""
    boundary = "----rofront" + uuid.uuid4().hex
    meta = {"assetType": asset_type, "displayName": display_name[:50], "description": description,
            "creationContext": {"creator": CREATOR}}
    data = open(path, "rb").read()
    ctype = {"flac": "audio/flac", "ogg": "audio/ogg", "mp3": "audio/mpeg", "wav": "audio/wav",
             "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg"}[path.rsplit(".", 1)[1].lower()]
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\n"
        f"Content-Type: application/json\r\n\r\n".encode(), json.dumps(meta).encode(), b"\r\n",
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; "
        f"filename=\"{os.path.basename(path)}\"\r\nContent-Type: {ctype}\r\n\r\n".encode(), data, b"\r\n",
        f"--{boundary}--\r\n".encode(),
    ])
    _, op = _req("POST", API + "/assets", body, {"Content-Type": f"multipart/form-data; boundary={boundary}"},
                 timeout=600)
    op_id = op.get("operationId") or op.get("path", "").split("/")[-1]
    if not op_id:
        raise ApiError(f"POST /assets: no operation in response: {json.dumps(op)[:400]}")
    return op_id


def upload_wait(op_id):
    """Poll an upload's operation until done; (asset_id, response)."""
    op = {}
    delay = 1.0
    for _ in range(90):
        if op.get("done"):
            break
        time.sleep(delay)
        delay = min(delay * 1.5, 8.0)
        _, op = _req("GET", f"{API}/operations/{op_id}")
    if not op.get("done"):
        raise ApiError(f"operation {op_id} not done after polling")
    if "error" in op:
        raise ApiError(f"operation {op_id} failed: {json.dumps(op['error'])[:600]}")
    resp = op.get("response", {})
    asset_id = resp.get("assetId") or resp.get("path", "").split("/")[-1]
    if not asset_id:
        raise ApiError(f"operation {op_id}: no assetId in {json.dumps(op)[:400]}")
    return str(asset_id), resp


def asset_state(asset_id):
    _, a = _req("GET", f"{API}/assets/{asset_id}?readMask=moderationResult,state,displayName")
    return (a.get("moderationResult") or {}).get("moderationState", "?"), a.get("state", "?")


# ------------------------------------------------------------------------------------------------
# cache / manifest
# ------------------------------------------------------------------------------------------------

def load_cache():
    return json.load(open(CACHE)) if os.path.exists(CACHE) else {}


def save_cache(c):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    json.dump(c, open(tmp, "w"), indent=1, sort_keys=True)
    os.replace(tmp, CACHE)


def fmt(x):
    s = f"{x:.6f}".rstrip("0").rstrip(".")
    return s if s else "0"


def write_manifest(music, sfx, note):
    L = ["-- GENERATED by tools/assets/upload_audio.py — do not edit by hand.",
         "-- Audio ids + exact lengths (seconds). Sources: ~/games/airfront/assets/audio/{music,sfx}/*.wav,",
         "-- uploaded losslessly (FLAC) so levels match the original and the music loops stay seamless",
         "-- (play music with Sound.Looped = true). Missing keys = not uploaded yet: callers must skip.",
         "-- sfx entries are {id, length}, or {sprite, start, stop, length} for audio-sprite regions",
         "-- (Sound.PlaybackRegionsEnabled = true; PlaybackRegion = NumberRange.new(start, stop)).",
         ]
    if note:
        L.append("-- " + note)
    L += ["return {", "\tmusic = {"]
    for k in sorted(music):
        e = music[k]
        L.append(f'\t\t{k} = {{ id = "{e["id"]}", length = {fmt(e["length"])} }},')
    L += ["\t},", "\tsfx = {"]
    for k in sorted(sfx):
        e = sfx[k]
        if "sprite" in e:
            L.append(f'\t\t{k} = {{ sprite = "{e["sprite"]}", start = {fmt(e["start"])}, stop = {fmt(e["stop"])}, '
                     f'length = {fmt(e["length"])} }},')
        else:
            L.append(f'\t\t{k} = {{ id = "{e["id"]}", length = {fmt(e["length"])} }},')
    L += ["\t},", "}"]
    os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
    with open(MANIFEST, "w") as f:
        f.write("\n".join(L) + "\n")


# ------------------------------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--sprite", action="store_true")
    ap.add_argument("--group", default="", help="upload as this group id (group-owned experiences)")
    args = ap.parse_args()
    global CREATOR, CACHE_PREFIX
    if args.group:
        CREATOR = {"groupId": str(args.group)}
        CACHE_PREFIX = f"g{args.group}:"
    only = set(filter(None, args.only.split(",")))

    cache = load_cache()
    srcs = sources()
    lengths = {}
    for g, k, wav in srcs:
        i = wav_info(wav)
        lengths[(g, k)] = i["frames"] / i["rate"]

    if args.status:
        for ck, e in sorted(cache.items(), key=lambda kv: kv[1]["name"]):
            try:
                e["moderation"], e["state"] = asset_state(e["asset_id"])
            except ApiError as ex:
                e["moderation"] = f"error: {ex}"
            print(f'{e["name"]:>28}  {e["asset_id"]:>16}  {e["moderation"]}  {e.get("state", "")}')
        save_cache(cache)
        return

    failures = []
    blocked = []   # set once an upload fails with a quota/limit error: stop spending requests

    def ensure(cache_key, path, name, desc):
        e = cache.get(cache_key)
        if e and e.get("asset_id"):
            return e["asset_id"]
        if args.dry_run or blocked:
            return None
        print(f"uploading {name} ({os.path.getsize(path) / 1e6:.2f} MB) …", flush=True)
        try:
            aid, resp = upload(path, name, desc)
        except ApiError as ex:
            print("  FAILED:", ex, flush=True)
            failures.append((name, str(ex)))
            if any(w in str(ex).lower() for w in ("quota", "limit", "429", "too many")):
                blocked.append(name)
            return None
        mod = (resp.get("moderationResult") or {}).get("moderationState", "?")
        cache[cache_key] = {"asset_id": aid, "name": name, "file": os.path.relpath(path, ROOT),
                            "moderation": mod, "uploaded": time.strftime("%Y-%m-%d %H:%M:%S")}
        save_cache(cache)
        print(f"  -> rbxassetid://{aid}  moderation={mod}", flush=True)
        return aid

    def single(g, k, wav):
        dst = os.path.join(OUT, g, k + ".flac")
        ck = f"{CACHE_PREFIX}{FORMAT}:{sha256(wav)}"
        if ck not in cache or not os.path.exists(dst):
            convert(wav, dst)
        name = f"AIRFRONT {'music' if g == 'music' else 'sfx'} {k}"
        desc = ("AIRFRONT theme (original, procedurally synthesized), seamless loop" if g == "music"
                else "AIRFRONT sound effect (original, procedurally synthesized)")
        return ensure(ck, dst, name, desc)

    music, sfx = {}, {}
    todo = [(g, k, w) for g, k, w in srcs if not only or k in only]
    # 1) music first (essential), 2) all SFX as one sprite (quota-proof fallback, 1 upload),
    # 3) individual SFX (preferred; any that cannot be uploaded fall back to their sprite region).
    for g, k, wav in todo:
        if g == "music":
            aid = single(g, k, wav)
            if aid:
                music[k] = {"id": f"rbxassetid://{aid}", "length": lengths[(g, k)]}
    sfx_items = [(k, wav) for g, k, wav in todo if g == "sfx"]
    singles_cached = all(f"{CACHE_PREFIX}{FORMAT}:{sha256(w)}" in cache for _, w in sfx_items)
    regions, sprite_id = {}, None
    if sfx_items and (args.sprite or not singles_cached) and not only:
        dst, regions, ck = build_sprite([(k, w) for k, w in sources_sfx()])
        ck = CACHE_PREFIX + ck
        sprite_id = ensure(ck, dst, "AIRFRONT sfx sprite", "AIRFRONT sound effects (original), packed sprite")
    for k, wav in sfx_items:
        aid = None if args.sprite else single("sfx", k, wav)
        if aid:
            sfx[k] = {"id": f"rbxassetid://{aid}", "length": lengths[("sfx", k)]}
        elif sprite_id and k in regions:
            s, e, ln = regions[k]
            sfx[k] = {"sprite": f"rbxassetid://{sprite_id}", "start": s, "stop": e, "length": ln}
    n_sprite = sum(1 for e in sfx.values() if "sprite" in e)
    note = f"{n_sprite} SFX play from the packed audio sprite (upload quota)." if n_sprite else ""

    if not args.dry_run and not only:
        write_manifest(music, sfx, note)
        print(f"manifest: {len(music)} music, {len(sfx)} sfx -> {os.path.relpath(MANIFEST, ROOT)}")
    if failures:
        print(f"{len(failures)} upload(s) failed:")
        for n, ex in failures:
            print(" ", n, "::", ex)
        sys.exit(1)


if __name__ == "__main__":
    main()
