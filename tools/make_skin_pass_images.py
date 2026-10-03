#!/usr/bin/env python3
"""Renders the 512x512 skin game-pass pictures (art/store/skins/<SkinId>.png).

Each skin is rendered with the offline preview (scene `showcase`, --set skin=<id> --set bg=slate:
the real skin code path, the hero alone on a flat background), then the hero is cut out, cropped
square and composed onto the game's dark slate with a soft gold glow and vignette. No text.
Usage: python3 tools/make_skin_pass_images.py [--only Knight_Crimson] [--view three|front]
"""
import argparse, os, re, subprocess, sys
import numpy as np
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "art", "store", "skins")
TMP = os.environ.get("SKIN_TMP", "/tmp/skin_renders")
SIZE = 512


def skin_ids():
    src = open(os.path.join(ROOT, "src/shared/Config.lua")).read()
    block = src.split("SkinPasses = {", 1)[1].split("}", 1)[0]
    return re.findall(r"^\s*([A-Za-z]+_[A-Za-z]+)\s*=", block, re.M)


def render(skin, view, tag="dark", color="0,0,0"):
    os.makedirs(TMP, exist_ok=True)
    path = os.path.join(TMP, skin + "_" + tag + ".png")
    subprocess.run(["bash", os.path.join(ROOT, "tools/preview/render.sh"), "showcase", "--device", "pc",
                    "--set", "skin=" + skin, "--set", "view=" + view, "--set", "bg=slate", "--set", "bgcolor=" + color, "--out", path],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return path


def grow(mask, r):
    return mask.filter(ImageFilter.MaxFilter(r))


def compose(dark_path, light_path, out):
    """Difference matting: the same render on a black and on a white background gives the
    hero's alpha and true colour, so dark skins do not vanish into the dark picture."""
    d_img = np.asarray(Image.open(dark_path).convert("RGB")).astype(np.float32)
    l_img = np.asarray(Image.open(light_path).convert("RGB")).astype(np.float32)
    bd = d_img[2:10, 2:10].reshape(-1, 3).mean(0)
    bl = l_img[2:10, 2:10].reshape(-1, 3).mean(0)
    span = np.abs(bl - bd).mean()
    alpha = np.clip(1 - np.abs(l_img - d_img).mean(2) / span, 0, 1)
    colour = np.clip((d_img - (1 - alpha[..., None]) * bd) / np.maximum(alpha[..., None], 0.02), 0, 255)
    m = Image.fromarray(((alpha > 0.6) * 255).astype(np.uint8))
    core = grow(m.filter(ImageFilter.MinFilter(15)), 31)  # drops sparkles, keeps the hero
    # thin pieces close to the hero (the Angel's halo is a flat ring seen edge-on) count too;
    # the floating gold sparkles are smaller than 9 px and far from the body, so they still go
    near = np.asarray(grow(core, 61)) > 0
    thin = np.asarray(m.filter(ImageFilter.MinFilter(9)).filter(ImageFilter.MaxFilter(9))) > 0
    keep = (np.asarray(core) > 0) | (thin & near)
    mask = (alpha * keep * 255).astype(np.uint8)
    colour = 255 * (colour / 255) ** 0.8 * 1.06  # the offline night lighting is dim: lift the hero a little
    img = Image.fromarray(np.clip(colour, 0, 255).astype(np.uint8))
    ys, xs = np.where(keep)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    side = int(max(x1 - x0, y1 - y0) * 1.2)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2 - int(side * 0.01)
    box = (cx - side // 2, cy - side // 2, cx + side // 2, cy + side // 2)
    hero = img.crop(box).resize((SIZE, SIZE), Image.LANCZOS)
    alpha = Image.fromarray(mask).crop(box).resize((SIZE, SIZE), Image.LANCZOS)
    alpha = alpha.filter(ImageFilter.GaussianBlur(0.6))
    # background: dark slate, brighter in the middle, soft gold glow behind the hero, vignette
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    d = np.sqrt(((xx - SIZE / 2) / (SIZE / 2)) ** 2 + ((yy - SIZE * 0.52) / (SIZE / 2)) ** 2)
    base = np.array([48, 60, 78], np.float32)  # slate_700-ish
    dark = np.array([14, 19, 26], np.float32)  # slate_950
    gold = np.array([213, 176, 98], np.float32)
    t = np.clip(d, 0, 1.4)[..., None]
    col = base * (1 - np.clip(t, 0, 1)) + dark * np.clip(t, 0, 1)
    glow = np.exp(-(d ** 2) / 0.22)[..., None] * 0.26
    col = col * (1 - glow) + gold * glow
    # gold rim line near the edge (soft vignette frame)
    edge = np.clip((np.minimum(np.minimum(xx, SIZE - 1 - xx), np.minimum(yy, SIZE - 1 - yy)) - 0) / 28.0, 0, 1)[..., None]
    col = col * (0.82 + 0.18 * edge)
    bgimg = Image.fromarray(np.clip(col, 0, 255).astype(np.uint8))
    bgimg.paste(hero, (0, 0), alpha)
    os.makedirs(OUT, exist_ok=True)
    bgimg.save(out, optimize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--view", default="three")
    args = ap.parse_args()
    for skin in skin_ids():
        if args.only and skin != args.only:
            continue
        print(skin, flush=True)
        compose(render(skin, args.view), render(skin, args.view, "light", "255,255,255"), os.path.join(OUT, skin + ".png"))


if __name__ == "__main__":
    sys.exit(main())
