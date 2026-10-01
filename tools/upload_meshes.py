"""Upload every exported FBX in meshes/ to Roblox with the Open Cloud Assets API.

    ROBLOX_API_KEY=... ROBLOX_USER_ID=... python3 tools/upload_meshes.py [--only A,B] [--force]

* The key can come from ROBLOX_API_KEY or from a Claude cloud environment "API credential"
  for apis.roblox.com (header x-api-key), which is added to requests automatically.
* The API key needs the "Assets: read + write" permission for the creator.
* Each FBX becomes a Model asset owned by ROBLOX_USER_ID (the account that owns the game,
  so the server can load it with InsertService).
* Already uploaded models (in meshes/uploaded_ids.json) are skipped unless --force.
* Results are written to meshes/uploaded_ids.json and src/shared/MeshCatalog.lua is
  regenerated.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MESHES = os.path.join(ROOT, "meshes")
IDS = os.path.join(MESHES, "uploaded_ids.json")
API = "https://apis.roblox.com/assets/v1"


def request(method, url, key, body=None, content_type=None):
    req = urllib.request.Request(url, data=body, method=method)
    if key:  # otherwise the cloud environment's API credential adds it on the way out
        req.add_header("x-api-key", key)
    if content_type:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode() or "{}")


def upload(path, name, key, user_id):
    boundary = uuid.uuid4().hex
    meta = {
        "assetType": "Model",
        "displayName": f"SWARM_{name}",
        "description": f"SWARM mesh model {name}",
        "creationContext": {"creator": {"userId": str(user_id)}},
    }
    with open(path, "rb") as f:
        data = f.read()
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\n"
        f"Content-Type: application/json\r\n\r\n{json.dumps(meta)}\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; filename=\"{name}.fbx\"\r\n"
        f"Content-Type: model/fbx\r\n\r\n".encode(),
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
        raise RuntimeError("upload did not finish in time")
    if "error" in op:
        raise RuntimeError(json.dumps(op["error"]))
    return int(op["response"]["assetId"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    key = os.environ.get("ROBLOX_API_KEY")
    user_id = os.environ.get("ROBLOX_USER_ID")
    if not user_id:
        sys.exit("Set ROBLOX_USER_ID first (and ROBLOX_API_KEY, unless the key is stored as an API credential).")
    ids = {}
    if os.path.exists(IDS):
        with open(IDS) as f:
            ids = json.load(f)
    only = {x for x in args.only.split(",") if x}
    files = []
    for category in sorted(os.listdir(MESHES)):
        folder = os.path.join(MESHES, category)
        if os.path.isdir(folder):
            for fn in sorted(os.listdir(folder)):
                if fn.endswith(".fbx"):
                    files.append((fn[:-4], os.path.join(folder, fn)))
    failed = []
    for name, path in files:
        if only and name not in only:
            continue
        if ids.get(name) and not args.force:
            continue
        try:
            asset_id = upload(path, name, key, user_id)
            ids[name] = asset_id
            print(f"{name:<22} -> {asset_id}")
            with open(IDS, "w") as f:
                json.dump(ids, f, indent=1, sort_keys=True)
        except Exception as err:  # keep going, report at the end
            failed.append(name)
            print(f"{name:<22} FAILED: {err}")
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "gen_mesh_catalog.py")], check=False)
    if failed:
        sys.exit("Failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
