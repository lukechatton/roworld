#!/usr/bin/env python3
"""Rofront's soundtrack: Rodrigo Flores' Orchestral Ambients Bundle (bought 2026-09-27; human-made,
"No generative AI was used"; licensed CC BY 4.0 — the title screen credits "Music by Rodrigo Flores").

Picks the tracks below from the bundle (assets/audio/music/Orchestral Ambients Bundle 1.0.2, not in
git), levels each toward its mood's loudness (static gain from EBU R128 integrated loudness, never
past -1 dBTP — no compression, the dynamics stay), encodes MP3 V0, uploads them as the group with
Open Cloud (tools/assets/upload_audio.py's uploader and cache) and writes
src/shared/Assets/Soundtrack.luau (ids, lengths, mood playlists) for AudioDirector.

Moods (AudioDirector.set_music_mood): title (title screen; the first track is the opener), wait (a
public match's waiting room), calm (a match, no fighting), war (fighting a nation or player: attacks,
nukes), victory, defeat. Tracks are sorted into moods by their pack and title, cross-checked with
their loudness (the quiet ones are sparse suspense, the loud ones battle music) — nobody here listened
to them, so move tracks between moods freely and re-run (only new tracks upload).

Usage:
  .venv/bin/python tools/assets/upload_soundtrack.py --group 421623341            # convert + upload + manifest
  .venv/bin/python tools/assets/upload_soundtrack.py --group 421623341 --dry-run  # convert + report only
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import upload_audio as ua  # noqa: E402

ROOT = ua.ROOT
BUNDLE = os.path.join(ROOT, "assets", "audio", "music", "Orchestral Ambients Bundle 1.0.2")
OUT = os.path.join(ROOT, "assets", "audio", "soundtrack")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "Soundtrack.luau")
FORMAT = "mp3v0-lvl1"   # bump when the conversion changes (invalidates the cache)
CREDIT = "Music by Rodrigo Flores"
LICENSE = "CC BY 4.0"

PACKS = {
    "I": ("Orchestral_Ambients_Music_Pack_Vol_I", "Orchestral Ambients I: Tranquil"),
    "II": ("Orchestral_Ambients_Music_Pack_Vol_II", "Orchestral Ambients II: Ominous"),
    "III": ("Orchestral_Ambients_Music_Pack_Vol_III", "War & Diplomacy: Strategy Ambients"),
    "IV": ("Orchestral_Ambients_Music_Pack_Vol_IV", "Orchestral Ambients IV: Dark Fantasy"),
    "V": ("Orchestral_Ambients_Music_Pack_Vol_V", "Orchestral Ambients V: Epic Heroic"),
}
# Loudness each mood's tracks are brought toward (LUFS): battle music a little louder than the calm.
TARGET_LUFS = {"title": -19.0, "wait": -21.0, "calm": -21.0, "war": -18.5, "victory": -18.0, "defeat": -21.0}
MAX_BOOST_DB = 10.0
PEAK_CEILING_DBTP = -1.0

# (pack, track folder, moods) — upload order = priority (a quota stop keeps the essentials).
TRACKS = [
    ("V", "Glory_of_the_Nation", ["title"]),          # the opener
    ("III", "Uncovering_the_Past", ["calm"]),
    ("III", "War_Declaration", ["war"]),
    ("I", "Diplomatic_Exchange", ["calm"]),
    ("V", "March_of_War", ["war"]),
    ("III", "Uncertain_Times", ["wait", "calm"]),
    ("V", "Glorious_Fortress", ["victory"]),
    ("I", "A_Moment_of_Reflection", ["defeat"]),
    ("III", "Revolutionary_Thoughts", ["calm"]),
    ("III", "Clashing_Destiny", ["war"]),
    ("V", "Hope_Is_Our_Ally", ["title"]),
    ("II", "Political_Move", ["wait", "calm"]),
    ("III", "Dance_of_Fate", ["calm"]),
    ("V", "Formidable_Opponent", ["war"]),
    ("I", "Culture_Shock", ["calm"]),
    ("IV", "Ancient_Conflict", ["war"]),
    ("III", "National_Emblem", ["title"]),
    ("II", "Adventure_Ahead", ["calm"]),
    ("V", "Defending_Our_Land", ["war"]),
    ("III", "Friend_or_Foe", ["wait", "calm"]),
    ("I", "Forgotten_Glories", ["calm"]),
    ("III", "Stay_Alert!", ["war"]),
    ("V", "Grandiose_Court", ["title"]),
    ("II", "Foreign_Traditions", ["calm"]),
    ("IV", "Path_to_Greatness", ["war"]),
    ("III", "Heroes_of_the_Past", ["calm"]),
    ("V", "Unavoidable_Consequence", ["war"]),
    ("II", "Matters_of_the_Court", ["calm"]),
    ("V", "Cultural_Heritage", ["title"]),
    ("II", "State_of_Peril", ["war"]),
    ("I", "Looking_for_Answers", ["calm"]),
    ("V", "Abandoned_Fortress", ["war"]),
    ("II", "Corrupt_Policies", ["calm"]),
]


def key_of(folder):
    return re.sub(r"[^a-z0-9]+", "_", folder.lower()).strip("_")


def title_of(folder):
    return folder.replace("_", " ")


def measure(wav):
    """(integrated LUFS, true peak dBTP) via ffmpeg's ebur128 filter."""
    p = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", wav, "-af", "ebur128=peak=true",
                        "-f", "null", "-"], capture_output=True, text=True)
    tail = p.stderr[p.stderr.rfind("Summary:"):]
    i = float(re.search(r"I:\s+(-?[\d.]+) LUFS", tail).group(1))
    peak = float(re.search(r"Peak:\s+(-?[\d.]+) dBFS", tail).group(1))
    return i, peak


def level_gain(lufs, peak, target):
    g = min(target - lufs, MAX_BOOST_DB, PEAK_CEILING_DBTP - peak)
    return round(g, 2)


def encode(wav, gain_db, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-map_metadata", "-1",
                    "-af", f"volume={gain_db}dB", "-c:a", "libmp3lame", "-q:a", "0", dst], check=True)


def duration(path):
    p = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                       capture_output=True, text=True, check=True)
    return float(p.stdout.strip())


def write_manifest(tracks, moods):
    L = ["-- GENERATED by tools/assets/upload_soundtrack.py — do not edit by hand (edit its TRACKS).",
         f"-- {CREDIT} (Orchestral Ambients Bundle; human-made, no generative AI), {LICENSE}.",
         "-- tracks: key -> {id, length (s), title, pack}; moods: playlists by mood, the first title track",
         "-- is the opener. Played whole (intro to ending) and crossfaded by AudioDirector.",
         "return {",
         f'\tcredit = "{CREDIT}",',
         f'\tlicense = "{LICENSE}",',
         "\ttracks = {"]
    for k in sorted(tracks):
        e = tracks[k]
        L.append(f'\t\t{k} = {{ id = "{e["id"]}", length = {ua.fmt(e["length"])}, title = "{e["title"]}", '
                 f'pack = "{e["pack"]}" }},')
    L += ["\t},", "\tmoods = {"]
    for m in ["title", "wait", "calm", "war", "victory", "defeat"]:
        ks = [k for k in moods.get(m, []) if k in tracks]
        L.append(f"\t\t{m} = {{ " + ", ".join(f'"{k}"' for k in ks) + " },")
    L += ["\t},", "}"]
    with open(MANIFEST, "w") as f:
        f.write("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", default="", help="upload as this group id (group-owned experiences)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.group:
        ua.CREATOR = {"groupId": str(args.group)}
        prefix = f"g{args.group}:"
    else:
        prefix = ""
    cache = ua.load_cache()
    tracks, moods, failures = {}, {}, []
    blocked = False
    for pack, folder, track_moods in TRACKS:
        pdir, pname = PACKS[pack]
        wav = os.path.join(BUNDLE, pdir, "Audio", folder, folder + ".wav")
        key = key_of(folder)
        lufs, peak = measure(wav)
        gain = level_gain(lufs, peak, TARGET_LUFS[track_moods[0]])
        dst = os.path.join(OUT, key + ".mp3")
        ck = f"{prefix}{FORMAT}:{ua.sha256(wav)}:{gain}"
        if not os.path.exists(dst) or ck not in cache:
            encode(wav, gain, dst)
        length = duration(dst)
        print(f"{key:28} {lufs:6.1f} LUFS  peak {peak:5.1f}  gain {gain:+5.1f} dB  {length:6.1f}s  "
              f"{os.path.getsize(dst) / 1e6:5.2f} MB  {','.join(track_moods)}", flush=True)
        e = cache.get(ck)
        aid = e.get("asset_id") if e else None
        if aid is None and not args.dry_run and not blocked:
            name = f"Rofront music - {title_of(folder)}"
            desc = f"{title_of(folder)} — {CREDIT} ({pname}), {LICENSE}."
            try:
                # the operation id is kept until it finishes, so a network failure while waiting
                # resumes on the next run instead of uploading the track twice
                op_id = (e or {}).get("pending_op")
                if not op_id:
                    op_id = ua.upload_start(dst, name, desc)
                    cache[ck] = {"pending_op": op_id, "name": name}
                    ua.save_cache(cache)
                aid, resp = ua.upload_wait(op_id)
            except ua.ApiError as ex:
                print("  FAILED:", ex, flush=True)
                failures.append((key, str(ex)))
                if any(w in str(ex).lower() for w in ("quota", "limit", "429", "too many")):
                    blocked = True
                continue
            mod = (resp.get("moderationResult") or {}).get("moderationState", "?")
            cache[ck] = {"asset_id": aid, "name": name, "file": os.path.relpath(dst, ROOT),
                         "moderation": mod, "uploaded": time.strftime("%Y-%m-%d %H:%M:%S")}
            ua.save_cache(cache)
            print(f"  -> rbxassetid://{aid}  moderation={mod}", flush=True)
        if aid is not None:
            tracks[key] = {"id": f"rbxassetid://{aid}", "length": length, "title": title_of(folder),
                           "pack": pname}
            for m in track_moods:
                moods.setdefault(m, []).append(key)
    if not args.dry_run:
        write_manifest(tracks, moods)
        print(f"manifest: {len(tracks)} tracks -> {os.path.relpath(MANIFEST, ROOT)}")
    if failures:
        print(f"{len(failures)} upload(s) failed:")
        for k, ex in failures:
            print(" ", k, "::", ex)
        sys.exit(1)


if __name__ == "__main__":
    main()
