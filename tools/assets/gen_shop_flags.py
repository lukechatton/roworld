#!/usr/bin/env python3
"""The flag shop's art (docs/flag-shop.md): asks Codex (its image generation tool) for each flag in
assets/shop_flags/flags.json that has no assets/shop_flags/art/<key>.png yet, from the file's `style`
and the flag's `prompt`. One `codex exec` per flag (about 35 s each), JOBS at a time. The images are
1536 x 1024 and kept at 768 x 512 (plenty for the game's sheets and the product icons; the full size
stays in ~/.codex/generated_images); tools/assets/make_shop_flags.py makes the game's flags from them.

Codex is the user's own (the ChatGPT app's bundled CLI, or `codex` on PATH): it runs with their
account. Look at every image before it ships, and run a flag again with --only <key> --force.

Usage: .venv/bin/python tools/assets/gen_shop_flags.py [--only k1,k2] [--force] [--jobs 3]
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "assets", "shop_flags")
ART = os.path.join(SRC, "art")
APP_CODEX = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"


def codex_bin():
    return shutil.which("codex") or (APP_CODEX if os.path.exists(APP_CODEX) else None)


def prompt_for(style, f):
    return (
        f"Use your image generation tool to make exactly one image, then save it as the PNG file "
        f"{f['key']}.png in the current directory (copy it from wherever the tool puts it). Do nothing "
        f"else: no other files, no edits.\n\nImage: {style}\n\nSubject: {f['prompt']}."
    )


def ok_image(path):
    try:
        with Image.open(path) as im:
            w, h = im.size
        return abs(w / h - 1.5) < 0.05
    except Exception:
        return False


def generate(codex, style, f):
    out = os.path.join(ART, f["key"] + ".png")
    r = subprocess.run(
        [codex, "exec", "--skip-git-repo-check", "-C", ART, "-s", "workspace-write",
         "-c", 'model_reasoning_effort="low"', "-"],
        input=prompt_for(style, f), text=True, capture_output=True, timeout=600,
    )
    if os.path.exists(out) and ok_image(out):
        with Image.open(out) as im:
            small = im.convert("RGB").resize((768, 512), Image.LANCZOS)
        small.save(out, optimize=True)
        return f["key"], "ok"
    tail = (r.stdout + r.stderr).strip().splitlines()[-3:]
    return f["key"], "FAILED: " + " | ".join(tail)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--jobs", type=int, default=3)
    args = ap.parse_args()
    codex = codex_bin()
    if codex is None:
        sys.exit("no codex CLI (install the ChatGPT app or put codex on PATH)")
    data = json.load(open(os.path.join(SRC, "flags.json"), encoding="utf-8"))
    only = {k for k in args.only.split(",") if k}
    todo = []
    for f in data["flags"]:
        if only and f["key"] not in only:
            continue
        path = os.path.join(ART, f["key"] + ".png")
        if os.path.exists(path) and not args.force:
            continue
        if args.force and os.path.exists(path):
            os.remove(path)
        todo.append(f)
    os.makedirs(ART, exist_ok=True)
    print(f"{len(todo)} flags to make, {args.jobs} at a time", flush=True)
    failed = 0
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        for key, res in ex.map(lambda f: generate(codex, data["style"], f), todo):
            print(f"{key}: {res}", flush=True)
            failed += res != "ok"
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
