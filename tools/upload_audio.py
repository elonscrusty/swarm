"""Upload the synthesized sound effects in art/audio/*.ogg to Roblox as Audio assets.

    ROBLOX_USER_ID=20194281 python3 tools/upload_audio.py [--only A,B] [--force]

* Auth works like tools/upload_icons.py (ROBLOX_API_KEY, or the cloud environment's
  credential for apis.roblox.com adds x-api-key automatically).
* Results go to art/audio/uploaded_ids.json as {Name: {"id": N, "status": "..."}}.
  Roblox moderates audio: an id is only pasted into Config.Sounds once its upload
  operation finished and the asset is approved (status "ok"). Anything else is listed as
  pending/failed and the current sound stays in place.
* Names that already have an id are not uploaded again unless --force (re-uploading
  creates a second asset); --check only refreshes the moderation status of stored ids.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIO = os.path.join(ROOT, "art", "audio")
IDS = os.path.join(AUDIO, "uploaded_ids.json")
API = "https://apis.roblox.com/assets/v1"


def request(method, url, key, body=None, content_type=None):
    delay = 2
    for attempt in range(6):
        req = urllib.request.Request(url, data=body, method=method)
        if key:
            req.add_header("x-api-key", key)
        if content_type:
            req.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read().decode() or "{}")
        except urllib.error.HTTPError as err:
            if err.code in (429, 500, 502, 503, 504) and attempt < 5:
                time.sleep(delay)
                delay *= 2
                continue
            raise RuntimeError(f"HTTP {err.code}: {err.read().decode(errors='replace')[:400]}")
        except urllib.error.URLError:
            if attempt < 5:
                time.sleep(delay)
                delay *= 2
                continue
            raise


def upload(path, name, key, user_id):
    boundary = uuid.uuid4().hex
    meta = {
        "assetType": "Audio",
        "displayName": f"SWARM_SFX_{name}",
        "description": f"SWARM sound effect {name} (original, synthesized)",
        "creationContext": {"creator": {"userId": str(user_id)}},
    }
    with open(path, "rb") as f:
        data = f.read()
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\n"
        f"Content-Type: application/json\r\n\r\n{json.dumps(meta)}\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; filename=\"{name}.ogg\"\r\n"
        f"Content-Type: audio/ogg\r\n\r\n".encode(),
        data,
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    op = request("POST", f"{API}/assets", key, body, f"multipart/form-data; boundary={boundary}")
    op_path = op.get("path") or f"operations/{op.get('operationId')}"
    for _ in range(60):
        if op.get("done"):
            break
        time.sleep(2)
        op = request("GET", f"{API}/{op_path}", key)
    if not op.get("done"):
        return None, "pending: " + op_path
    if "error" in op:
        return None, "error: " + json.dumps(op["error"])[:300]
    resp = op.get("response", {})
    mod = (resp.get("moderationResult") or {}).get("moderationState", "unknown")
    return int(resp["assetId"]), "ok" if mod == "Approved" else "moderation: " + mod


def check(ids, key):
    for name, entry in sorted(ids.items()):
        if not entry.get("id"):
            continue
        try:
            info = request("GET", f"{API}/assets/{entry['id']}?readMask=moderationResult", key)
            mod = (info.get("moderationResult") or {}).get("moderationState", "unknown")
            entry["status"] = "ok" if mod == "Approved" else "moderation: " + mod
        except Exception as err:
            entry["status"] = f"check failed: {err}"
        print(f"{name:<16} {entry['id']} {entry['status']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--check", action="store_true", help="refresh moderation status only")
    args = ap.parse_args()
    key = os.environ.get("ROBLOX_API_KEY")
    user_id = os.environ.get("ROBLOX_USER_ID")
    if not user_id:
        sys.exit("Set ROBLOX_USER_ID first.")
    ids = {}
    if os.path.exists(IDS):
        with open(IDS) as f:
            ids = json.load(f)
    only = {x for x in args.only.split(",") if x}
    if args.check:
        check(ids, key)
        with open(IDS, "w") as f:
            json.dump(ids, f, indent=1, sort_keys=True)
        pending = [n for n, e in ids.items() if e.get("status") != "ok"]
        sys.exit(("Not approved yet: " + ", ".join(sorted(pending))) if pending else 0)
    failed = []
    for fn in sorted(os.listdir(AUDIO)):
        if not fn.endswith(".ogg"):
            continue
        name = fn[:-4]
        if only and name not in only:
            continue
        if (ids.get(name) or {}).get("id") and not args.force:
            continue
        try:
            asset_id, status = upload(os.path.join(AUDIO, fn), name, key, user_id)
        except Exception as err:
            asset_id, status = None, f"failed: {err}"
        ids[name] = {"id": asset_id, "status": status}
        with open(IDS, "w") as f:
            json.dump(ids, f, indent=1, sort_keys=True)
        print(f"{name:<16} {asset_id} {status}")
        if status != "ok":
            failed.append(name)
    if failed:
        sys.exit("Not approved yet: " + ", ".join(failed))


if __name__ == "__main__":
    main()
