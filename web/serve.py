#!/usr/bin/env python3
"""Simple HTTP server with COOP/COEP headers for SharedArrayBuffer support."""
import http.server
import os

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        # The wasm build is single-threaded (no SharedArrayBuffer), so no COEP.
        # COOP must stay same-origin-allow-popups: same-origin severs the
        # popup<->opener channel the Google sign-in uses to hand back the token.
        self.send_header("Cross-Origin-Opener-Policy", "same-origin-allow-popups")
        # no-store: Safari's heuristic cache otherwise pairs a stale
        # styles/index with a freshly rebuilt em.js/em.wasm.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, format, *args):
        pass

os.chdir(os.path.dirname(os.path.abspath(__file__)))
httpd = http.server.HTTPServer(("", 8765), Handler)
print("Serving at http://localhost:8765")
httpd.serve_forever()
