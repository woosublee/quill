"""Local bridge between this folder and a browser tab, for building the Figma copy.

Usage: python3 docs/design-system/tools/figma/server.py
It listens on 127.0.0.1:8765 only. It serves this folder's scripts, the design
system's tokens.json and components/, and out/ (layer data walk.html posts back,
kept in a temporary folder and never committed). Only the Figma editor's origin
may read it from another site, and only its own pages may post. Stop the server
when you are done.
"""
import http.server
import os
import re
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGN_SYSTEM = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(tempfile.gettempdir(), "quill-figma-out")
OWN_ORIGIN = "http://127.0.0.1:8765"
FIGMA_ORIGIN = "https://www.figma.com"
MAX_BODY = 8 * 1024 * 1024
os.makedirs(OUT, exist_ok=True)


class Handler(http.server.SimpleHTTPRequestHandler):
    def translate_path(self, path):
        relative = os.path.normpath(path.split("?", 1)[0].lstrip("/"))
        if relative.startswith(".."):
            return os.path.join(HERE, "missing")
        if relative.startswith("out" + os.sep):
            return os.path.join(OUT, os.path.basename(relative))
        local = os.path.join(HERE, relative)
        return local if os.path.exists(local) else os.path.join(DESIGN_SYSTEM, relative)

    def end_headers(self):
        if self.headers.get("Origin") == FIGMA_ORIGIN:
            self.send_header("Access-Control-Allow-Origin", FIGMA_ORIGIN)
            self.send_header("Access-Control-Allow-Private-Network", "true")
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header("Vary", "Origin")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_POST(self):
        match = re.fullmatch(r"/save/([A-Za-z0-9_.-]+\.json)", self.path)
        length = int(self.headers.get("Content-Length", "0"))
        if self.headers.get("Origin") != OWN_ORIGIN or length > MAX_BODY:
            self.send_response(403)
            self.end_headers()
            return
        if not match:
            self.send_response(404)
            self.end_headers()
            return
        with open(os.path.join(OUT, match.group(1)), "wb") as f:
            f.write(self.rfile.read(length))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"http://127.0.0.1:8765/walk.html  (out: {OUT})")
    http.server.ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
