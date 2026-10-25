#!/usr/bin/env python3
"""Upload local images to Roblox (as the Studio-logged-in user) and return rbxassetid URIs.

Usage:
  .venv/bin/python tools/upload.py <file.png> [...]         # prints JSON {path: "rbxassetid://id"}
  (as a module) upload.upload_images([paths]) -> {path: uri}

Content-hash cached in build/upload_cache.json (shared by all agents, file-locked), so re-running a
generator re-uploads only images whose bytes changed. Images are served to Studio's `upload_image`
MCP tool from a throwaway localhost HTTP server. Max 1024x1024 recommended per image (Roblox
downsizes larger uploads); PNG with alpha is preserved.
"""
import fcntl
import hashlib
import http.server
import json
import os
import socketserver
import sys
import threading

sys.path.insert(0, os.path.dirname(__file__))
import studio  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "build", "upload_cache.json")
LOCK = os.path.join(ROOT, "build", "upload_cache.lock")
BATCH = 20


def _sha(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def _serve(files):
    """Serve {url_name: abs_path} on an ephemeral port. Returns (server, port)."""
    mapping = dict(files)

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            name = self.path.lstrip("/")
            p = mapping.get(name)
            if not p:
                self.send_response(404)
                self.end_headers()
                return
            data = open(p, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "image/png" if p.endswith(".png") else "image/jpeg")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    srv = socketserver.TCPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, srv.server_address[1]


def upload_images(paths):
    paths = [os.path.abspath(p) for p in paths]
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(LOCK, "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}
        result, todo = {}, []
        for p in paths:
            h = _sha(p)
            if h in cache:
                result[p] = cache[h]
            else:
                todo.append((p, h))
        if todo:
            c = studio.Client()
            try:
                sid = studio.pick_studio(c)
                for i in range(0, len(todo), BATCH):
                    chunk = todo[i:i + BATCH]
                    files = {f"{h[:16]}_{os.path.basename(p)}": p for p, h in chunk}
                    srv, port = _serve(files)
                    try:
                        urls = {name: f"http://localhost:{port}/{name}" for name in files}
                        res = c.call("upload_image", {"imagePaths": list(urls.values()), "studio_id": sid})
                        txt = studio.text_of(res)
                        try:
                            got = json.loads(txt)
                        except json.JSONDecodeError:
                            raise RuntimeError("upload_image failed: " + txt)
                        for name, url in urls.items():
                            uri = got.get(url)
                            p = files[name]
                            if not uri or not str(uri).startswith("rbxassetid://"):
                                raise RuntimeError(f"upload failed for {p}: {uri}")
                            h = next(hh for pp, hh in chunk if pp == p)
                            cache[h] = uri
                            result[p] = uri
                    finally:
                        srv.shutdown()
                    json.dump(cache, open(CACHE, "w"), indent=0)
            finally:
                c.close()
        return result


if __name__ == "__main__":
    out = upload_images(sys.argv[1:])
    print(json.dumps(out, indent=1))
