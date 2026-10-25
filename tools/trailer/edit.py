#!/usr/bin/env python3
"""Cuts the trailer from the frames tools/trailer/film.py captured (build/trailer/<dir>/NNNNN.jpg):
the shots in order (hard cuts, cut to the music), the ROWORLD wordmark at the end, and a few
captions that say what the gameplay is (Roblox's video rules: real footage, a logo overlay, sparse text
describing gameplay, no claims; Creator Hub > Configurations > Places > Videos: mp4/mov, <= 60 s,
<= 1920x1080, 16:9, <= 100 MB, 15 Mbps).

Usage: .venv/bin/python tools/trailer/edit.py   -> build/trailer/roworld_trailer.mp4
"""
import os
import shutil
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RAW = os.path.join(ROOT, "build", "trailer")
OUT_DIR = os.path.join(ROOT, "build", "trailer", "out")
MP4 = os.path.join(ROOT, "build", "trailer", "roworld_trailer.mp4")
FPS = 30
W, H = 1920, 1080
FONT = "/Applications/RobloxStudio.app/Contents/Resources/content/fonts/Montserrat-Black.ttf"
ACCENT = (245, 165, 36)
# hard cuts (user, on the first cut: "needs to be faster paced. get right into gameplay. no intro")
XFADE = 0  # frames

# (shot directory under build/trailer, first frame, last frame exclusive): each trimmed to its peak.
# Cut to the music (MUSIC below, 143.6 bpm: a beat is 12.5 frames): the first shots are whole beats long
# (62 / 63 frames: five, the two between them a frame over); the MIRVs come in over the music's two-second
# drop and land on its re-entry; the logo lands on the final chord.
SEGMENTS = [
    # building up a nation: a speck in India growing to a country, a city going up (5 beats, 4x
    # time-lapse; since the second cut the first scene is about building up a nation)
    ("v3/open2", 0, 62),
    ("v2/e_sudan", 100, 163),  # the army sweeps through Sudan (5 beats)
    # trade ships from every nation sailing into the player's ports round Iberia, each paid on arrival
    # ("+101.8K"; 2x speed; the third scene is about trading over the seas, in place of the
    # Mongolian front) (4 beats)
    ("v3/trade", 56, 106),
    ("v3/rail4", 80, 118),  # the rail network close up: a train into a city, paid "+10.0K" (3 beats)
    ("v3/hbomb", 150, 200),  # three hydrogen bombs on Bolivia: 500K -> 126K (lands at 175, 7.93 s)
    # the climax (the earlier second-to-last scene fell flat): two MIRVs, the camera riding
    # one over Canada under the music's drop, then wide on North America as they split (frame 170),
    # the first warheads landing (frame 175) on its re-entry (11.17 s), Iceland 674K -> 38K
    ("v3/climax8", 103, 212),
    # out to the whole world, the Americas glowing (the camera's clamp now continuous, the path at the
    # map's middle before it zooms out: the first cut snapped twice here, around 13-14 s, as the
    # camera zoomed out)
    ("v3/climax8", 299, 360),
]
HOLD = 74  # the end card: the last frame held, frames (from the final chord, 14.43 s)

# captions: (text, start s, end s) on the output timeline
CAPTIONS = [
    ("BUILD YOUR NATION", 0.25, 1.9),
    ("INVADE YOUR NEIGHBORS", 2.3, 4.0),
    ("TRADE ACROSS THE SEAS", 4.35, 5.75),
    ("NUKE YOUR RIVALS", 7.2, 10.6),
    ("CONTROL 80% OF THE WORLD TO WIN", 12.45, 14.35),
]
# The music: the game's own soundtrack (Rodrigo Flores, Orchestral Ambients, bought 2026-09-27, CC BY 4.0,
# no lyrics; tools/assets/upload_soundtrack.py), March of War from its last climb: a downbeat at
# MUSIC_START puts the re-entry after its drop (119.64 s) on the blast and its final chord (122.9 s) on
# the logo. Credited on the end card, as CC BY asks.
MUSIC = os.path.join(
    ROOT, "assets", "audio", "music", "Orchestral Ambients Bundle 1.0.2", "Orchestral_Ambients_Music_Pack_Vol_V",
    "Audio", "March_of_War", "March_of_War.wav",
)
MUSIC_START = 108.473
MUSIC_CREDIT = "MUSIC BY RODRIGO FLORES"
LOGO_IN = None  # no wordmark over the opening


def font(px):
    return ImageFont.truetype(FONT, px)


def wordmark(px=190):
    """ROWORLD: a warm gradient fill, a dark outline and a soft shadow (the title screen's look)."""
    f = font(px)
    text = "ROWORLD"
    l, t, r, b = f.getbbox(text)
    tw, th = r - l, b - t
    pad = 40
    w, h = tw + pad * 2, th + pad * 2
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).text((pad - l, pad - t), text, font=f, fill=255)
    stroke = Image.new("L", (w, h), 0)
    ImageDraw.Draw(stroke).text((pad - l, pad - t), text, font=f, fill=255, stroke_width=9, stroke_fill=255)
    grad = np.zeros((h, w, 3), np.float32)
    top, bot = np.array([255, 241, 206]), np.array([246, 170, 52])
    ys = np.linspace(0, 1, h)[:, None]
    grad[:] = (top + (bot - top) * ys)[:, None, :]
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    shadow = stroke.filter(ImageFilter.GaussianBlur(10))
    img.paste((10, 14, 26, 150), (6, 12), shadow)
    img.paste((44, 24, 6, 255), (0, 0), stroke)
    fill = Image.fromarray(grad.astype(np.uint8), "RGB").convert("RGBA")
    fill.putalpha(mask)
    img.alpha_composite(fill)
    return img


def caption_img(text):
    f = font(60)
    l, t, r, b = f.getbbox(text)
    tw, th = r - l, b - t
    pad = 28
    bar = 10
    w, h = tw + pad * 2 + bar + 22, th + pad * 2
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # a dark plate, the accent bar, the text
    d.rounded_rectangle([0, 0, w - 1, h - 1], radius=14, fill=(10, 14, 26, 190))
    d.rectangle([pad - 6, pad - 2, pad - 6 + bar, h - pad + 2], fill=ACCENT + (255,))
    d.text((pad + bar + 16 - l, pad - t), text, font=f, fill=(255, 255, 255, 255))
    return img


def ease(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def load(shot, i):
    return Image.open(os.path.join(RAW, shot, "%05d.jpg" % i)).convert("RGB").resize((W, H), Image.LANCZOS)


def main():
    if os.path.isdir(OUT_DIR):
        shutil.rmtree(OUT_DIR)
    os.makedirs(OUT_DIR)
    # the timeline: segment frames, crossfaded
    frames = []  # list of lists of (shot, index, weight)
    for si, (shot, a, b) in enumerate(SEGMENTS):
        seg = [(shot, i) for i in range(a, b)]
        if si == 0 or XFADE == 0:
            frames.extend([[(s, i, 1.0)] for s, i in seg])
            continue
        # the first XFADE frames of this shot blend over the last XFADE of the timeline
        for k in range(XFADE):
            wgt = (k + 1) / (XFADE + 1)
            prev = frames[len(frames) - XFADE + k]
            frames[len(frames) - XFADE + k] = [(s, i, w * (1 - wgt)) for s, i, w in prev] + [(seg[k][0], seg[k][1], wgt)]
        frames.extend([[(s, i, 1.0)] for s, i in seg[XFADE:]])
    last = frames[-1]
    end_start = len(frames)
    frames.extend([last] * HOLD)
    n = len(frames)
    print("frames:", n, "=", round(n / FPS, 2), "s")

    logo = wordmark()
    logo_small = logo.resize((int(logo.width * 0.82), int(logo.height * 0.82)), Image.LANCZOS)
    credit = Image.new("RGBA", (W, 60), (0, 0, 0, 0))
    cf = font(24)
    cl, _, cr, _ = cf.getbbox(MUSIC_CREDIT)
    ImageDraw.Draw(credit).text(((W - (cr - cl)) // 2 - cl, 14), MUSIC_CREDIT, font=cf, fill=(230, 232, 240, 190))
    caps = {c[0]: caption_img(c[0]) for c in CAPTIONS}
    cache = {}

    def frame_img(spec):
        acc = None
        for s, i, w in spec:
            key = (s, i)
            if key not in cache:
                if len(cache) > 64:
                    cache.clear()
                cache[key] = np.asarray(load(s, i), np.float32)
            a = cache[key] * w
            acc = a if acc is None else acc + a
        return Image.fromarray(np.clip(acc, 0, 255).astype(np.uint8), "RGB")

    for fi, spec in enumerate(frames):
        t = fi / FPS
        img = frame_img(spec).convert("RGBA")
        # the opening: straight into the action (no fade, no wordmark)
        la = 0.0 if LOGO_IN is None else ease((t - LOGO_IN[0]) / 0.45) * (1 - ease((t - (LOGO_IN[1] - 0.45)) / 0.45))
        if la > 0:
            dim = Image.new("RGBA", (W, H), (6, 10, 20, int(110 * la)))
            img.alpha_composite(dim)
            k = 0.94 + 0.06 * ease((t - LOGO_IN[0]) / 0.8)
            lg = logo.resize((int(logo.width * k), int(logo.height * k)), Image.LANCZOS)
            arr = np.asarray(lg).copy()
            arr[..., 3] = (arr[..., 3] * la).astype(np.uint8)
            lg = Image.fromarray(arr, "RGBA")
            img.alpha_composite(lg, ((W - lg.width) // 2, (H - lg.height) // 2 - 20))
        # captions: slide in from the left and fade, hold, fade
        for text, a, b in CAPTIONS:
            if a - 0.1 <= t <= b + 0.1:
                ci = ease((t - a) / 0.2) * (1 - ease((t - (b - 0.25)) / 0.25))
                if ci <= 0:
                    continue
                cimg = caps[text]
                arr = np.asarray(cimg).copy()
                arr[..., 3] = (arr[..., 3] * ci).astype(np.uint8)
                x = 96 - int(40 * (1 - ease((t - a) / 0.2)))
                # (top left, under the menu buttons: clear of the HUD and the game's own banners)
                img.alpha_composite(Image.fromarray(arr, "RGBA"), (x, 118))
        # the end card: darken the held world view, the wordmark
        if fi >= end_start - 6:
            k = ease((fi - (end_start - 6)) / 14)
            img.alpha_composite(Image.new("RGBA", (W, H), (6, 10, 20, int(150 * k))))
            arr = np.asarray(logo_small).copy()
            arr[..., 3] = (arr[..., 3] * k).astype(np.uint8)
            img.alpha_composite(Image.fromarray(arr, "RGBA"), ((W - logo_small.width) // 2, (H - logo_small.height) // 2 - 10))
            carr = np.asarray(credit).copy()
            carr[..., 3] = (carr[..., 3] * k).astype(np.uint8)
            img.alpha_composite(Image.fromarray(carr, "RGBA"), (0, (H + logo_small.height) // 2 + 4))
        # and fade out at the very end
        tail = n - fi
        if tail <= 8:
            img = Image.blend(Image.new("RGBA", (W, H), (0, 0, 0, 255)), img, tail / 8)
        img.convert("RGB").save(os.path.join(OUT_DIR, "%05d.png" % fi), compress_level=1)
        if fi % 150 == 0:
            print("  frame", fi, flush=True)
    dur = n / FPS
    # the music: cut from MUSIC_START, a short fade in, out over the last half second, -14 LUFS
    wav = os.path.join(ROOT, "build", "trailer", "music.wav")
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error", "-ss", str(MUSIC_START), "-t", str(dur), "-i", MUSIC,
            "-af", "afade=t=in:d=0.04,afade=t=out:st=%.3f:d=0.5,loudnorm=I=-14:TP=-1.0:LRA=11" % (dur - 0.5),
            "-ar", "48000", "-ac", "2", wav,
        ],
        check=True,
    )
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", os.path.join(OUT_DIR, "%05d.png"),
            "-i", wav, "-c:v", "libx264", "-preset", "slow", "-profile:v", "high", "-pix_fmt", "yuv420p",
            "-b:v", "14M", "-maxrate", "15M", "-bufsize", "30M", "-c:a", "aac", "-b:a", "192k", "-shortest",
            "-movflags", "+faststart", MP4,
        ],
        check=True,
    )
    print("wrote", MP4)


if __name__ == "__main__":
    main()
