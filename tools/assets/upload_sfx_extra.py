#!/usr/bin/env python3
"""Extra sound effects from the studio's own games,
uploaded as the group with Open Cloud (upload_audio.py's uploader and cache) into
src/shared/Assets/AudioExtra.luau: {sfx = {name = {id, length}}}. AudioDirector merges these over
Assets/Audio's sfx (a name here replaces the one there).

  countdown_tick      BedWars' ui/countdown/countdown_tick     (the waiting room, 10..6 s)
  countdown_tick_5..1 BedWars' ui/countdown/countdown_tick_N   (the last five seconds)
  countdown_gamestart BedWars' ui/countdown/countdown_gamestart (the match starts)
  spawn_confirm       BedWars' ui/common/ui_click               (picking your spawn: a plain click)
  game_start          Airship BedWars' Countdown/b_Game_Start   (the spawn phase ends, the war begins)
  queue_start         Airship BedWars' UI/b_UI_Queue_Start      (the public waiting room opens)
  spectate_switch     Airship BedWars' UI/b_UI_Spectate_Switch  (a spectator switches player)
  crate_drop          BedWars' treasure chest spawn (the crate drops in)
  crate_open / crate_shimmer / crate_preview_<rarity> / reveal_<rarity>
                      BedWars' lucky box: open, shimmer, the rarity previews and reveals
  crate_land / crate_rattle / card_whoosh / card_flip
                      the 3D opening: BedWars' block impact, the chest unlocking rattle (first 0.7 s),
                      the card kit's throw and turn (the same picks as Tribes' drop reveal)

Usage: .venv/bin/python tools/assets/upload_sfx_extra.py --group 421623341
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import upload_audio as ua  # noqa: E402

ROOT = ua.ROOT
BEDWARS = os.path.expanduser("~/roblox/bedwars/assets/Asphalt/Sounds")
AIRSHIP = os.path.expanduser("~/unity/airship-bedwars/Assets/_Sounds")
MANIFEST = os.path.join(ROOT, "src", "shared", "Assets", "AudioExtra.luau")
FORMAT = "extra-v1"

SOUNDS = {
    "countdown_tick": ("BedWars", os.path.join(BEDWARS, "ui/countdown/countdown_tick.ogg")),
    "countdown_tick_5": ("BedWars", os.path.join(BEDWARS, "ui/countdown/countdown_tick_5.ogg")),
    "countdown_tick_4": ("BedWars", os.path.join(BEDWARS, "ui/countdown/countdown_tick_4.ogg")),
    "countdown_tick_3": ("BedWars", os.path.join(BEDWARS, "ui/countdown/countdown_tick_3.ogg")),
    "countdown_tick_2": ("BedWars", os.path.join(BEDWARS, "ui/countdown/countdown_tick_2.ogg")),
    "countdown_tick_1": ("BedWars", os.path.join(BEDWARS, "ui/countdown/countdown_tick_1.ogg")),
    "countdown_gamestart": ("BedWars", os.path.join(BEDWARS, "ui/countdown/countdown_gamestart.ogg")),
    "spawn_confirm": ("BedWars", os.path.join(BEDWARS, "ui/common/ui_click.ogg")),
    "game_start": ("Airship BedWars", os.path.join(AIRSHIP, "Countdown/b_Game_Start.wav")),
    "queue_start": ("Airship BedWars", os.path.join(AIRSHIP, "UI/b_UI_Queue_Start.wav")),
    "spectate_switch": ("Airship BedWars", os.path.join(AIRSHIP, "UI/b_UI_Spectate_Switch.wav")),
    # the cosmetic crate opening (CrateOpening.luau; 2026-09-29)
    "crate_drop": ("BedWars", os.path.join(BEDWARS, "gameplay/treasure_chests/treasure_chest_spawn.ogg")),
    # the lid bursts open, the card holds, the reveal: BedWars' lucky box set (2026-09-29). Its reveals
    # have no epic: ours shift up one there (epic -> legendary, legendary -> mythic, its biggest)
    "crate_open": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_open.ogg")),
    "crate_shimmer": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_shimmer.ogg")),
    "crate_preview_common": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_preview_common.ogg")),
    "crate_preview_rare": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_preview_rare.ogg")),
    "crate_preview_epic": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_preview_epic.ogg")),
    "crate_preview_legendary": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_preview_legendary.ogg")),
    "reveal_common": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_reveal_common.ogg")),
    "reveal_rare": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_reveal_rare.ogg")),
    "reveal_epic": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_reveal_legendary.ogg")),
    "reveal_legendary": ("BedWars", os.path.join(BEDWARS, "gameplay/lucky_blocks/lucky_box_reveal_mythic.ogg")),
    # the 3D opening (Tribes' drop reveal picks): (source, path, ffmpeg -af filter or None)
    # (the lucky block slam was rejected by Roblox's audio moderation, 2026-09-29: a block impact instead)
    "crate_land": ("BedWars", os.path.join(BEDWARS, "kits/block_kicker/block_kicker_kit_block_impact_1.ogg")),
    "crate_rattle": ("BedWars", os.path.join(BEDWARS, "gameplay/treasure_chests/treasure_chest_unlocking.ogg"),
                     "atrim=0:0.7,afade=t=out:st=0.5:d=0.2"),
    "card_whoosh": ("BedWars", os.path.join(BEDWARS, "kits/card/card_throw_1.ogg")),
    "card_flip": ("BedWars", os.path.join(BEDWARS, "kits/card/card_turn.ogg"), "volume=1.6"),
}
PROCESSED = os.path.join(ROOT, "build", "sfx")


def source_file(name, entry):
    """The file to upload: the source, or (with a filter) the source run through ffmpeg into build/sfx (FLAC)."""
    path = entry[1]
    if len(entry) < 3 or not entry[2]:
        return path
    os.makedirs(PROCESSED, exist_ok=True)
    out = os.path.join(PROCESSED, name + ".flac")
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", path, "-af", entry[2], "-c:a", "flac",
                    "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", out], check=True)
    return out


def duration(path):
    p = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                       capture_output=True, text=True, check=True)
    return float(p.stdout.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", default="", help="upload as this group id (group-owned experiences)")
    args = ap.parse_args()
    prefix = ""
    if args.group:
        ua.CREATOR = {"groupId": str(args.group)}
        prefix = f"g{args.group}:"
    cache = ua.load_cache()
    out, failures = {}, []
    for name, entry in SOUNDS.items():
        source, path = entry[0], source_file(name, entry)
        ck = f"{prefix}{FORMAT}:{ua.sha256(path)}"
        e = cache.get(ck) or {}
        aid = e.get("asset_id")
        if aid is None:
            label = f"Rofront sfx {name}"
            try:
                op_id = e.get("pending_op")
                if not op_id:
                    op_id = ua.upload_start(path, label, f"Rofront sound effect ({source}: {name})")
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
    L = ["-- GENERATED by tools/assets/upload_sfx_extra.py — do not edit by hand.",
         "-- Extra sound effects (BedWars' countdown); AudioDirector merges them over Assets/Audio's sfx.",
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
