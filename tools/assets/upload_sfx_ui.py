#!/usr/bin/env python3
"""The interface sound kit, from the studio's own sound packs (2026-10-04), in place of the first kit,
which was synthesised and whose pure tones were too high-pitched. Same sources as upload_sfx_extra.py:
BedWars' Asphalt sounds and Airship BedWars' _Sounds. Each sound was chosen by what it is in its own
game, not by measuring it:

  ui_click     BedWars  ui/common/ui_click              every button press
  ui_hover     BedWars  ui/common/ui_hover              the pointer over a button
  ui_open      BedWars  ui/common/ui_open_2             a panel opens (the softer of its two)
  ui_back      BedWars  ui/common/ui_close_2            close, cancel (ui_open_2's pair)
  ui_error     BedWars  ui/common/ui_error              "can't do that"
  ui_locked    BedWars  ui/common/error_notification    a locked Arsenal unit
  ui_tab       Airship  Spectate/SpectateClick          tabs, toggles, toasts (a second, lighter click)
  ui_confirm   BedWars  ui/queue/queue_join             a press that commits
  star_tick    BedWars  ui/common/roulette_tick         Stars counting up
  star_get     BedWars  ui/rewards/reward_claim         the Stars landing
  buy_spend    BedWars  ui/shop/bedwars_purchase_item   paying with Stars
  unlock       Airship  UI/Kit Selection Menu/Unlock/b_UI_Kits_Unlock_100Percent   an Arsenal unlock
  expand_pop   BedWars  ui/common/bubble_pop5           the border pop. One sound: with BedWars' six
               (each a different note) picked at random the run sounded random and chaotic
               (2026-10-04). bubble_pop5 is the one that is most one clear note (762 Hz), in the lower half.
  eliminate    BedWars  gameplay/match/kill             you eliminated someone (2026-10-04: satisfying,
               never grating): its kill sound, 0.4 s

The files are not changed beyond their level and their silence: the tail is cut where it falls under
-55 dB, and each is brought to the same loudness (the RMS of its sounding part, LEVEL_DB or its own
entry, never peaking above PEAK_DB) -- in their own games each plays at a volume set in code, and
the files' own levels are 20 dB apart. The pop is padded to 0.12 s. Written to build/sfx_ui (FLAC),
uploaded as the group with Open Cloud (upload_audio.py's uploader and cache), and listed in
src/shared/Assets/AudioUI.luau: {sfx = {name = {id, length}}}. AudioDirector merges these over
Assets/Audio and Assets/AudioExtra (a name here replaces the one there).

Usage: .venv/bin/python tools/assets/upload_sfx_ui.py --group 421623341 [--dry]
"""
import argparse
import os
import subprocess
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import upload_audio as ua  # noqa: E402

ROOT = ua.ROOT
BEDWARS = os.path.expanduser("~/roblox/bedwars/assets/Asphalt/Sounds")
AIRSHIP = os.path.expanduser("~/unity/airship-bedwars/Assets/_Sounds")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "AudioUI.luau")
OUT = os.path.join(ROOT, "build", "sfx_ui")
FORMAT = "uipack-v1"
LEVEL_DB = -21.0
PEAK_DB = -1.5
TAIL_DB = -55.0

# name -> (pack, file, loudness in dB (the sounding part's RMS) or None for LEVEL_DB, pad to seconds or 0)
SOUNDS = {
    "ui_click": ("BedWars", os.path.join(BEDWARS, "ui/common/ui_click.ogg"), None, 0),
    "ui_hover": ("BedWars", os.path.join(BEDWARS, "ui/common/ui_hover.ogg"), -24.0, 0.1),
    "ui_open": ("BedWars", os.path.join(BEDWARS, "ui/common/ui_open_2.ogg"), None, 0),
    "ui_back": ("BedWars", os.path.join(BEDWARS, "ui/common/ui_close_2.ogg"), -22.0, 0),
    "ui_error": ("BedWars", os.path.join(BEDWARS, "ui/common/ui_error.ogg"), None, 0),
    "ui_locked": ("BedWars", os.path.join(BEDWARS, "ui/common/error_notification.ogg"), None, 0),
    "ui_tab": ("Airship BedWars", os.path.join(AIRSHIP, "Spectate/SpectateClick.wav"), -23.0, 0.1),
    "ui_confirm": ("BedWars", os.path.join(BEDWARS, "ui/queue/queue_join.ogg"), None, 0),
    "star_tick": ("BedWars", os.path.join(BEDWARS, "ui/common/roulette_tick.ogg"), -24.0, 0),
    "star_get": ("BedWars", os.path.join(BEDWARS, "ui/rewards/reward_claim.ogg"), None, 0),
    "buy_spend": ("BedWars", os.path.join(BEDWARS, "ui/shop/bedwars_purchase_item.ogg"), None, 0),
    "unlock": ("Airship BedWars",
               os.path.join(AIRSHIP, "UI/Kit Selection Menu/Unlock/b_UI_Kits_Unlock_100Percent.wav"), -20.0, 0),
    "expand_pop": ("BedWars", os.path.join(BEDWARS, "ui/common/bubble_pop5.ogg"), -18.0, 0.12),
    "eliminate": ("BedWars", os.path.join(BEDWARS, "gameplay/match/kill.ogg"), -20.0, 0),
}


def decode(path, sr=44100):
    p = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "1", "-ar", str(sr), "-"],
                       capture_output=True, check=True)
    return np.frombuffer(p.stdout, dtype=np.float32), sr


def levels(path):
    """(peak dB, RMS dB of the sounding part: first to last sample within 40 dB of the peak)."""
    x, _ = decode(path)
    peak = float(np.max(np.abs(x)))
    idx = np.nonzero(np.abs(x) > peak * 0.01)[0]
    part = x[idx[0]:idx[-1] + 1]
    rms = float(np.sqrt(np.mean(part.astype(np.float64) ** 2)))
    return 20 * np.log10(max(peak, 1e-9)), 20 * np.log10(max(rms, 1e-9))


def process(name, entry):
    """The file to upload: the source, its tail cut, at the kit's loudness (build/sfx_ui/<name>.flac)."""
    _pack, path, level, pad = entry
    peak, rms = levels(path)
    gain = min((LEVEL_DB if level is None else level) - rms, PEAK_DB - peak)
    af = [f"areverse,silenceremove=start_periods=1:start_silence=0.03:start_threshold={TAIL_DB}dB,areverse",
          f"volume={gain:.2f}dB"]
    if pad:
        af.append(f"apad=whole_dur={pad}")
    os.makedirs(OUT, exist_ok=True)
    out = os.path.join(OUT, name + ".flac")
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", path, "-af", ",".join(af), "-ar", "44100",
                    "-sample_fmt", "s16", "-c:a", "flac", "-map_metadata", "-1", "-fflags", "+bitexact",
                    "-flags:a", "+bitexact", out], check=True)
    return out, gain


def duration(path):
    p = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                       capture_output=True, text=True, check=True)
    return float(p.stdout.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", default="", help="upload as this group id (group-owned experiences)")
    ap.add_argument("--dry", action="store_true", help="process and print, upload nothing")
    args = ap.parse_args()
    prefix = ""
    if args.group:
        ua.CREATOR = {"groupId": str(args.group)}
        prefix = f"g{args.group}:"
    cache = ua.load_cache()
    out, failures = {}, []
    for name, entry in SOUNDS.items():
        pack = entry[0]
        if not os.path.exists(entry[1]):
            print(f"{name}: missing {entry[1]}")
            failures.append(name)
            continue
        path, gain = process(name, entry)
        peak, rms = levels(path)
        if args.dry:
            print(f"{name:14s} {pack:16s} gain {gain:+6.1f} dB -> peak {peak:6.1f} rms {rms:6.1f} "
                  f"{duration(path):5.2f} s  {os.path.relpath(entry[1], os.path.expanduser('~'))}")
            continue
        ck = f"{prefix}{FORMAT}:{ua.sha256(path)}"
        e = cache.get(ck) or {}
        aid = e.get("asset_id")
        if aid is None:
            label = f"Rofront ui {name}"
            try:
                op_id = e.get("pending_op")
                if not op_id:
                    op_id = ua.upload_start(path, label, f"Rofront interface sound ({pack}: {name})")
                    cache[ck] = {"pending_op": op_id, "name": label}
                    ua.save_cache(cache)
                aid, resp = ua.upload_wait(op_id)
            except ua.ApiError as ex:
                print(f"{name}: FAILED {ex}", flush=True)
                failures.append(name)
                continue
            mod = (resp.get("moderationResult") or {}).get("moderationState", "?")
            cache[ck] = {"asset_id": aid, "name": label, "file": path, "moderation": mod,
                         "uploaded": time.strftime("%Y-%m-%d %H:%M:%S")}
            ua.save_cache(cache)
            print(f"{name}: rbxassetid://{aid} moderation={mod}", flush=True)
        out[name] = {"id": f"rbxassetid://{aid}", "length": duration(path)}
    if args.dry:
        return
    L = ["-- GENERATED by tools/assets/upload_sfx_ui.py — do not edit by hand.",
         "-- The interface sound kit, from the studio's own packs (BedWars, Airship BedWars; 2026-10-04: pack",
         "-- sounds for most of the interface rather than ones made from scratch). expand_pop is the",
         "-- border pop. AudioDirector merges these over Assets/Audio and Assets/AudioExtra.",
         "return {", "\tsfx = {"]
    for k in sorted(out):
        L.append(f'\t\t{k} = {{ id = "{out[k]["id"]}", length = {ua.fmt(out[k]["length"])} }},')
    L += ["\t},", "}"]
    with open(MANIFEST, "w") as f:
        f.write("\n".join(L) + "\n")
    print(f"manifest: {len(out)} sounds -> {os.path.relpath(MANIFEST, ROOT)}")
    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
