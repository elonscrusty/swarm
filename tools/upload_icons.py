"""Upload the PNG icons in art/icons/ to Roblox as Image assets (Open Cloud Assets API).

    ROBLOX_API_KEY=... ROBLOX_USER_ID=... python3 tools/upload_icons.py [--only A,B] [--force]

* Auth works like tools/upload_meshes.py (ROBLOX_API_KEY, or the cloud environment's
  API credential for apis.roblox.com adds x-api-key automatically).
* Each PNG is resized to 512x512 (transparency kept, optimized) before upload.
* Default assetType is "Image": the returned id is directly usable as rbxassetid://ID.
  (A "Decal" upload, ICON_ASSET_TYPE=Decal, returns a Decal id; its Image id can only be
  resolved with a logged-in cookie, the API key gets 403 from asset delivery, so it is not
  the default.) With Decal, the text below applies: A Decal wraps an Image asset; the Image id is what ImageLabel.Image needs
  (rbxassetid://ID). It is resolved through the asset-delivery API (the Decal's XML
  holds the Texture id). If that cannot be resolved, the Decal id is stored and the
  name is listed in "unresolved" output (ImageLabel also accepts Decal ids in practice).
* Results: art/icons/uploaded_ids.json {Name: imageId}; decal ids go to
  art/icons/uploaded_decal_ids.json. Already uploaded names are skipped unless --force.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "art", "icons")
IDS = os.path.join(ICONS, "uploaded_ids.json")
DECAL_IDS = os.path.join(ICONS, "uploaded_decal_ids.json")
SMALL = os.environ.get("ICON_SMALL_DIR") or os.path.join(ROOT, "art", "icons512")
ASSET_TYPE = os.environ.get("ICON_ASSET_TYPE", "Image")
API = "https://apis.roblox.com/assets/v1"
DELIVERY = "https://apis.roblox.com/asset-delivery-api/v1/assetId"


def request(method, url, key, body=None, content_type=None, raw=False):
    delay = 2
    for attempt in range(6):
        req = urllib.request.Request(url, data=body, method=method)
        if key:
            req.add_header("x-api-key", key)
        if content_type:
            req.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = resp.read()
                return data if raw else json.loads(data.decode() or "{}")
        except urllib.error.HTTPError as err:
            if err.code in (429, 500, 502, 503, 504) and attempt < 5:
                time.sleep(delay)
                delay *= 2
                continue
            raise RuntimeError(f"HTTP {err.code}: {err.read().decode(errors='replace')[:300]}")
        except urllib.error.URLError:
            if attempt < 5:
                time.sleep(delay)
                delay *= 2
                continue
            raise


def shrink(src, name):
    os.makedirs(SMALL, exist_ok=True)
    dst = os.path.join(SMALL, name + ".png")
    img = Image.open(src).convert("RGBA").resize((512, 512), Image.LANCZOS)
    img.save(dst, optimize=True)
    return dst


def upload(path, name, key, user_id):
    boundary = uuid.uuid4().hex
    meta = {
        "assetType": os.environ.get("ICON_ASSET_TYPE", "Image"),
        "displayName": f"SWARM_Icon_{name}",
        "description": f"SWARM icon {name}",
        "creationContext": {"creator": {"userId": str(user_id)}},
    }
    with open(path, "rb") as f:
        data = f.read()
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\n"
        f"Content-Type: application/json\r\n\r\n{json.dumps(meta)}\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; filename=\"{name}.png\"\r\n"
        f"Content-Type: image/png\r\n\r\n".encode(),
        data,
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    op = request("POST", f"{API}/assets", key, body, f"multipart/form-data; boundary={boundary}")
    op_path = op.get("path") or f"operations/{op.get('operationId')}"
    for _ in range(90):
        if op.get("done"):
            break
        time.sleep(2)
        op = request("GET", f"{API}/{op_path}", key)
    if not op.get("done"):
        raise RuntimeError("upload did not finish in time (still pending)")
    if "error" in op:
        raise RuntimeError(json.dumps(op["error"]))
    return int(op["response"]["assetId"])


def resolve_image(decal_id, key):
    """Decal id -> Image id via asset delivery (XML contains the Texture url)."""
    info = request("GET", f"{DELIVERY}/{decal_id}", key)
    loc = info.get("location")
    if not loc:
        raise RuntimeError("no location: " + json.dumps(info)[:200])
    xml = urllib.request.urlopen(loc, timeout=60).read().decode(errors="replace")
    m = re.search(r"<url>[^<]*?(?:id=|rbxassetid://)(\d+)", xml)
    if not m:
        raise RuntimeError("no Texture url in decal xml")
    return int(m.group(1))


def load(path):
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}


def save(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=1, sort_keys=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    key = os.environ.get("ROBLOX_API_KEY")
    user_id = os.environ.get("ROBLOX_USER_ID")
    if not user_id:
        sys.exit("Set ROBLOX_USER_ID first.")
    ids, decals = load(IDS), load(DECAL_IDS)
    only = {x for x in args.only.split(",") if x}
    failed, unresolved = [], []
    for fn in sorted(os.listdir(ICONS)):
        if not fn.endswith(".png"):
            continue
        name = fn[:-4]
        if only and name not in only:
            continue
        if ids.get(name) and not args.force:
            continue
        try:
            if decals.get(name) and not args.force:
                decal = decals[name]
            else:
                decal = upload(shrink(os.path.join(ICONS, fn), name), name, key, user_id)
                decals[name] = decal
                save(DECAL_IDS, decals)
            try:
                if ASSET_TYPE == "Image":
                    image = decal
                else:
                    image = resolve_image(decal, key)
            except Exception as err:
                unresolved.append(name)
                image = decal
                print(f"  (could not resolve image id for {name}: {err}; using decal id)")
            ids[name] = image
            save(IDS, ids)
            print(f"{name:<22} decal {decal} -> image {image}")
        except Exception as err:
            failed.append(name)
            print(f"{name:<22} FAILED: {err}")
    if unresolved:
        print("Unresolved (decal id stored):", ", ".join(unresolved))
    if failed:
        sys.exit("Failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
